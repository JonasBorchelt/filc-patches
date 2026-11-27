#!/usr/bin/env ruby
# frozen_string_literal: true

# Verify upstream tarball SHA-256 pins in ports/*/PORT against official upstream
# checksum files, GitHub release asset digests, or detached PGP signatures using
# pinned keys in ports/pgp-keys/.
#
# Ruby 3.3 / 4.0 stdlib parity implementation of scripts/verify-pins.
#
# Supported UPSTREAM_SHA256_SOURCE formats:
#   - sha256:<url>
#   - sha256-html:<url>
#   - pgp:<sig-url> key:<repo-rel-key> fpr:<40-hex-fpr> [sha256_b64:<url>]
#   - github-release-digest:<api-url>
#   - upstream-sha512-only:<url>
#   - upstream-sha3-256:<url>
#   - upstream-sig-unpinned:<url>
#   - unverified-github-tag-archive:<url>
#   - unverified-upstream-no-checksum:<url>

require "digest"
require "fileutils"
require "json"
require "open3"
require "openssl"
require "optparse"
require "stringio"
require "tmpdir"
require "zlib"

SHA256_RE = /\A[0-9a-f]{64}\z/
FPR_RE = /\A[0-9A-F]{40}\z/
DATE_RE = /\A\d{4}-\d{2}-\d{2}\z/
DIRECT_SCHEMES = %w[sha256: sha256-html: pgp: debian-elts:].freeze
VERIFIABLE_SCHEMES = %w[
  sha256:
  sha256-html:
  pgp:
  debian-elts:
  github-release-digest:
  upstream-sha512-only:
  upstream-sha3-256:
].freeze
KNOWN_PREFIXES = (VERIFIABLE_SCHEMES + %w[
  upstream-sig-unpinned:
  unverified-github-tag-archive:
  unverified-upstream-no-checksum:
]).freeze

def py_repr(str)
  s = str.to_s
  if s.include?("'") && !s.include?('"')
    "\"#{s.gsub('\\', '\\\\')}\""
  else
    "'#{s.gsub('\\', '\\\\').gsub("'", "\\\\'")}'"
  end
end

def py_list_repr(arr)
  "[#{arr.map { |x| py_repr(x) }.join(', ')}]"
end

def parse_port_file(port_file)
  data = {}
  File.foreach(port_file, encoding: "UTF-8") do |raw|
    line = raw.strip
    next if line.empty? || line.start_with?("#")
    break if line.start_with?("port_") && line.include?("()")

    m = /\A([A-Z0-9_]+)=(.*)\z/.match(line)
    next unless m

    key = m[1]
    val = m[2].strip
    if val.length >= 2 &&
       ((val.start_with?('"') && val.end_with?('"')) ||
        (val.start_with?("'") && val.end_with?("'")))
      val = val[1..-2]
    end
    data[key] = val
  end
  data
end

# Extract RFC 4880 v4 public key and subkey fingerprints without requiring gpg.
def parse_openpgp_v4_fingerprints(armored_bytes)
  text = armored_bytes.dup.force_encoding(Encoding::ASCII_8BIT)
                      .encode(Encoding::UTF_8, invalid: :replace, undef: :replace)
                      .gsub("\r\n", "\n")
  blocks = text.scan(/-----BEGIN PGP PUBLIC KEY BLOCK-----\n(.*?)\n-----END PGP PUBLIC KEY BLOCK-----/m)
  fprs = {}

  blocks.each do |match|
    lines = match[0].split("\n", -1)
    i = 0
    i += 1 while i < lines.length && !lines[i].strip.empty?
    b64_lines = (lines[(i + 1)..] || []).map(&:strip).reject { |l| l.empty? || l.start_with?("=") }
    raw = b64_lines.join.unpack1("m").b
    pos = 0
    raw_len = raw.bytesize

    while pos < raw_len
      b0 = raw.getbyte(pos)
      pos += 1
      break if (b0 & 0x80).zero?

      if (b0 & 0x40) != 0
        tag = b0 & 0x3F
        body = "".b
        loop do
          l0 = raw.getbyte(pos)
          pos += 1
          if l0 < 192
            plen = l0
            body << (raw.byteslice(pos, plen) || "".b)
            pos += plen
            break
          elsif l0 < 224
            l1 = raw.getbyte(pos)
            pos += 1
            plen = ((l0 - 192) << 8) + l1 + 192
            body << (raw.byteslice(pos, plen) || "".b)
            pos += plen
            break
          elsif l0 == 255
            plen = raw.byteslice(pos, 4).unpack1("N")
            pos += 4
            body << (raw.byteslice(pos, plen) || "".b)
            pos += plen
            break
          else
            plen = 1 << (l0 & 0x1F)
            body << (raw.byteslice(pos, plen) || "".b)
            pos += plen
          end
        end
        pkt = body
      else
        tag = (b0 >> 2) & 0x0F
        ltype = b0 & 0x03
        case ltype
        when 0
          plen = raw.getbyte(pos)
          pos += 1
        when 1
          plen = raw.byteslice(pos, 2).unpack1("n")
          pos += 2
        when 2
          plen = raw.byteslice(pos, 4).unpack1("N")
          pos += 4
        else
          plen = raw_len - pos
        end
        pkt = raw.byteslice(pos, plen) || "".b
        pos += plen
      end

      if (tag == 6 || tag == 14) && !pkt.empty? && pkt.getbyte(0) == 4
        prefix = "\x99".b + [pkt.bytesize].pack("n")
        fprs[Digest::SHA1.hexdigest(prefix + pkt).upcase] = true
      end
    end
  end

  fprs.keys.sort
end

def parse_pgp_source(source)
  tokens = source.split
  out = {}
  tokens.each do |tok|
    raise ArgumentError, "malformed pgp source token: #{py_repr(tok)}" unless tok.include?(":")

    k, v = tok.split(":", 2)
    out[k] = v
  end
  %w[pgp key fpr].each do |req|
    val = out[req]
    if val.nil? || val.empty?
      raise ArgumentError, "pgp source missing '#{req}:' field: #{py_repr(source)}"
    end
  end
  unless FPR_RE.match?(out["fpr"])
    raise ArgumentError, "invalid 40-char uppercase hex fingerprint: #{py_repr(out['fpr'])}"
  end

  out
end

def parse_debian_elts_source(source)
  tokens = source.split
  out = {}
  tokens.each do |tok|
    raise ArgumentError, "malformed debian-elts source token: #{py_repr(tok)}" unless tok.include?(":")

    k, v = tok.split(":", 2)
    out[k] = v
  end
  %w[debian-elts pkg ver key fpr].each do |req|
    val = out[req]
    if val.nil? || val.empty?
      raise ArgumentError, "debian-elts source missing '#{req}:' field: #{py_repr(source)}"
    end
  end
  unless FPR_RE.match?(out["fpr"])
    raise ArgumentError, "invalid 40-char uppercase hex fingerprint: #{py_repr(out['fpr'])}"
  end

  out
end

def validate_metadata(name, meta, repo_root)
  errors = []
  sha = meta.fetch("UPSTREAM_SHA256", "")
  errors << "#{name}: invalid UPSTREAM_SHA256=#{py_repr(sha)}" unless SHA256_RE.match?(sha)

  support = meta.fetch("SUPPORT_STATUS", "").strip
  unless support.empty?
    unless %w[active eol].include?(support)
      errors << "#{name}: invalid SUPPORT_STATUS=#{py_repr(support)} (expected 'active' or 'eol')"
    end
    if support == "eol"
      eol_date = meta.fetch("EOL_DATE", "").strip
      errors << "#{name}: EOL port missing valid YYYY-MM-DD EOL_DATE" unless DATE_RE.match?(eol_date)
      sec_src = meta.fetch("SECURITY_SOURCE", "").strip
      errors << "#{name}: EOL port missing SECURITY_SOURCE" if sec_src.empty?
    end
  end

  src = meta.fetch("UPSTREAM_SHA256_SOURCE", "")
  if src.empty?
    errors << "#{name}: missing UPSTREAM_SHA256_SOURCE"
    return errors
  end

  unless KNOWN_PREFIXES.any? { |p| src.start_with?(p) }
    errors << "#{name}: unrecognized UPSTREAM_SHA256_SOURCE prefix: #{py_repr(src)}"
    return errors
  end

  if src.start_with?("pgp:")
    begin
      spec = parse_pgp_source(src)
    rescue ArgumentError => e
      errors << "#{name}: #{e.message}"
      return errors
    end

    if meta["UPSTREAM_SIG_URL"] && !meta["UPSTREAM_SIG_URL"].empty? && meta["UPSTREAM_SIG_URL"] != spec["pgp"]
      errors << "#{name}: UPSTREAM_SIG_URL does not match UPSTREAM_SHA256_SOURCE"
    end
    if meta["UPSTREAM_PGP_KEY"] && !meta["UPSTREAM_PGP_KEY"].empty? && meta["UPSTREAM_PGP_KEY"] != spec["key"]
      errors << "#{name}: UPSTREAM_PGP_KEY does not match UPSTREAM_SHA256_SOURCE"
    end
    if meta["UPSTREAM_PGP_FPR"] && !meta["UPSTREAM_PGP_FPR"].empty? && meta["UPSTREAM_PGP_FPR"] != spec["fpr"]
      errors << "#{name}: UPSTREAM_PGP_FPR does not match UPSTREAM_SHA256_SOURCE"
    end

    key_abs = File.expand_path(spec["key"], repo_root)
    if !File.file?(key_abs)
      errors << "#{name}: pinned PGP key file not found: #{spec['key']}"
    else
      fprs = parse_openpgp_v4_fingerprints(File.binread(key_abs))
      unless fprs.include?(spec["fpr"])
        errors << "#{name}: fingerprint #{spec['fpr']} not found in #{spec['key']} " \
                  "(found: #{py_list_repr(fprs)})"
      end
    end
  elsif src.start_with?("debian-elts:")
    begin
      spec = parse_debian_elts_source(src)
    rescue ArgumentError => e
      errors << "#{name}: #{e.message}"
      return errors
    end

    deb_url = meta.fetch("DEBIAN_TARBALL_URL", "")
    deb_sha = meta.fetch("DEBIAN_TARBALL_SHA256", "")
    errors << "#{name}: missing DEBIAN_TARBALL_URL for debian-elts source" if deb_url.empty?
    errors << "#{name}: invalid DEBIAN_TARBALL_SHA256=#{py_repr(deb_sha)}" unless SHA256_RE.match?(deb_sha)
    dsc_sha = meta.fetch("DEBIAN_DSC_SHA256", "")
    if !dsc_sha.empty? && !SHA256_RE.match?(dsc_sha)
      errors << "#{name}: invalid DEBIAN_DSC_SHA256=#{py_repr(dsc_sha)}"
    end
    meta.fetch("DEBIAN_BINARY_TARBALLS", "").split.each do |bspec|
      bname, bsha = bspec.split(":", 2)
      if bname.nil? || bname.empty? || bname.include?("/") || bname.include?("..") || !SHA256_RE.match?(bsha.to_s)
        errors << "#{name}: invalid DEBIAN_BINARY_TARBALLS entry #{py_repr(bspec)}"
      end
    end

    key_abs = File.expand_path(spec["key"], repo_root)
    if !File.file?(key_abs)
      errors << "#{name}: pinned PGP key file not found: #{spec['key']}"
    else
      fprs = parse_openpgp_v4_fingerprints(File.binread(key_abs))
      unless fprs.include?(spec["fpr"])
        errors << "#{name}: fingerprint #{spec['fpr']} not found in #{spec['key']} " \
                  "(found: #{py_list_repr(fprs)})"
      end
    end
  end

  errors
end

def mirror_fallback_urls(url)
  urls = [url]
  replacements = [
    ["https://download.savannah.gnu.org/releases/", "https://download-mirror.savannah.gnu.org/releases/"],
    ["https://download-mirror.savannah.gnu.org/releases/", "https://download.savannah.gnu.org/releases/"],
    ["https://download.savannah.nongnu.org/releases/", "https://download-mirror.savannah.nongnu.org/releases/"],
    ["https://download-mirror.savannah.nongnu.org/releases/", "https://download.savannah.nongnu.org/releases/"],
    ["https://ftp.gnu.org/gnu/", "https://ftpmirror.gnu.org/gnu/"],
    ["https://ftpmirror.gnu.org/gnu/", "https://ftp.gnu.org/gnu/"],
  ]
  replacements.each do |src_prefix, dst_prefix|
    if url.start_with?(src_prefix)
      alt = dst_prefix + url[src_prefix.length..]
      urls << alt unless urls.include?(alt)
    end
  end
  urls
end

def curl_bytes(url, extra_headers: nil, attempts: 3)
  candidates = mirror_fallback_urls(url)
  is_local = url.start_with?("file://")
  max_rounds = is_local ? 1 : [1, attempts].max
  backoffs = [2, 5, 10]
  last_err = ""

  max_rounds.times do |rnd|
    candidates.each do |cand|
      cmd = ["curl", "-fsSL", "--connect-timeout", "10", "--max-time", "20"]
      extra_headers&.each { |h| cmd.push("-H", h) }
      cmd << cand
      out, err, status = Open3.capture3(*cmd)
      return out.b if status.success?

      err_txt = err.dup.force_encoding(Encoding::UTF_8).scrub.strip
      last_err = "curl failed (#{status.exitstatus}) for #{cand}: #{err_txt}"
    end
    sleep(backoffs[[rnd, backoffs.length - 1].min]) if rnd + 1 < max_rounds
  end

  raise RuntimeError, (last_err.empty? ? "curl failed for #{url}" : last_err)
end

def meta_cache_path(url, cache_dir)
  meta_dir = File.join(cache_dir, "verify-meta")
  FileUtils.mkdir_p(meta_dir)
  url_hash = Digest::SHA256.hexdigest(url.encode(Encoding::UTF_8))[0, 16]
  base = File.basename(url.split("?", 2)[0].sub(%r{/+\z}, ""))
  base = "index" if base.empty?
  safe = base.gsub(/[^A-Za-z0-9._-]+/, "_")[0, 64]
  File.join(meta_dir, "#{url_hash}-#{safe}")
end

def fetch_cached_bytes(url, cache_dir, extra_headers: nil, force_refresh: false)
  cpath = cache_dir && !cache_dir.empty? ? meta_cache_path(url, cache_dir) : ""
  if !cpath.empty? && !force_refresh && File.file?(cpath) && File.size(cpath) > 0
    return [File.binread(cpath), true]
  end

  data = curl_bytes(url, extra_headers: extra_headers)
  if !cpath.empty? && !data.empty?
    tmp_path = "#{cpath}.part.#{Process.pid}"
    begin
      File.binwrite(tmp_path, data)
      File.rename(tmp_path, cpath)
    ensure
      File.unlink(tmp_path) if File.exist?(tmp_path)
    end
  end
  [data, false]
end

def fetch_and_extract(url, cache_dir, extra_headers: nil)
  raw, from_cache = fetch_cached_bytes(url, cache_dir, extra_headers: extra_headers)
  begin
    [yield(raw), from_cache]
  rescue StandardError
    raise unless from_cache

    raw, = fetch_cached_bytes(url, cache_dir, extra_headers: extra_headers, force_refresh: true)
    [yield(raw), false]
  end
end

def file_hash(path, algo)
  digest = case algo
           when "sha256" then Digest::SHA256.new
           when "sha512" then Digest::SHA512.new
           when "sha3_256" then OpenSSL::Digest.new("SHA3-256")
           else raise ArgumentError, "unsupported hash algorithm: #{algo}"
           end
  File.open(path, "rb") do |f|
    buf = "".b
    digest.update(buf) while f.read(1024 * 1024, buf)
  end
  digest.hexdigest
end

def ensure_cached_tarball(meta, cache_dir)
  FileUtils.mkdir_p(cache_dir)
  name = meta.fetch("NAME")
  version = meta.fetch("VERSION")
  expected = meta.fetch("UPSTREAM_SHA256")
  url = meta.fetch("UPSTREAM_URL")
  tarball_name = File.basename(url.split("?", 2)[0])
  tarball_path = File.join(cache_dir, "#{name}-#{version}-#{expected[0, 12]}-#{tarball_name}")

  unless File.file?(tarball_path)
    tmp_path = "#{tarball_path}.part.#{Process.pid}"
    begin
      _out, err, status = Open3.capture3(
        "curl", "-fsSL", "--retry", "3", "--retry-delay", "2", "-o", tmp_path, url
      )
      unless status.success?
        raise RuntimeError, "curl failed (#{status.exitstatus}) for #{url}: #{err.strip}"
      end

      File.rename(tmp_path, tarball_path)
    ensure
      File.unlink(tmp_path) if File.exist?(tmp_path)
    end
  end

  actual = file_hash(tarball_path, "sha256")
  if actual != expected
    File.unlink(tarball_path)
    raise RuntimeError,
          "tarball SHA-256 mismatch for #{tarball_name}: expected #{expected}, got #{actual}"
  end
  tarball_path
end

def decode_utf8(raw)
  raw.dup.force_encoding(Encoding::UTF_8).scrub
end

def extract_sha256_from_checksum_text(text, filename)
  lines = text.lines.map(&:strip).reject { |l| l.empty? || l.start_with?("#") }

  lines.each do |line|
    if (m = /\A([0-9a-fA-F]{64})\s+\*?(.+)\z/.match(line))
      h = m[1].downcase
      fname = File.basename(m[2].strip)
      return h if fname == filename
    end
    if (m_bsd = /\ASHA256\s*\(([^)]+)\)\s*=\s*([0-9a-fA-F]{64})\z/.match(line))
      return m_bsd[2].downcase if File.basename(m_bsd[1].strip) == filename
    end
  end

  # Header-aware TSV table (e.g. Ruby's index.txt: name\turl\tsha1\tsha256\tsha512)
  if !lines.empty? && lines[0].include?("\t")
    hdr = lines[0].split("\t").map { |c| c.strip.downcase }
    if hdr.include?("url") && hdr.include?("sha256")
      url_idx = hdr.index("url")
      sha_idx = hdr.index("sha256")
      lines[1..].each do |line|
        cols = line.split("\t")
        next unless cols.length > [url_idx, sha_idx].max

        if File.basename(cols[url_idx].strip.split("?", 2)[0]) == filename
          cand = cols[sha_idx].strip.downcase
          return cand if SHA256_RE.match?(cand)
        end
      end
    end
  end

  # Fallback: bare single-hash file containing only one 64-hex digest
  if lines.length == 1
    parts = lines[0].split
    return parts[0].downcase if parts.length == 1 && SHA256_RE.match?(parts[0].downcase)
  end

  raise RuntimeError, "could not find SHA-256 entry for #{py_repr(filename)} in upstream checksum file"
end

def extract_sha256_b64_from_text(text, filename)
  pat = /SHA256\s*\(#{Regexp.escape(filename)}\)\s*=\s*([A-Za-z0-9+\/=]+)/
  m = pat.match(text)
  unless m
    raise RuntimeError, "could not find base64 SHA256(#{filename}) entry in release announcement"
  end

  raw = m[1].unpack1("m").b
  if raw.bytesize != 32
    raise RuntimeError, "decoded base64 SHA256 has unexpected length #{raw.bytesize}"
  end

  raw.unpack1("H*")
end

def which_bin(name)
  ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).each do |dir|
    next if dir.empty?

    cand = File.join(dir, name)
    return cand if File.file?(cand) && File.executable?(cand)
  end
  nil
end

def run_gpg_verify(gpg_bin, sig_bytes, tarball_path, key_abs, expected_fpr)
  Dir.mktmpdir("filc-verify-gpg-") do |td|
    gnupg_home = File.join(td, "gnupg")
    Dir.mkdir(gnupg_home, 0o700)
    sig_path = File.join(td, "tarball.sig")
    File.binwrite(sig_path, sig_bytes)

    env = ENV.to_h.merge("GNUPGHOME" => gnupg_home)

    _imp_out, imp_err, imp_st = Open3.capture3(env, gpg_bin, "--batch", "--quiet", "--import", key_abs)
    unless imp_st.success?
      raise RuntimeError, "gpg --import failed: #{decode_utf8(imp_err).strip}"
    end

    fpr_out, fpr_err, fpr_st = Open3.capture3(env, gpg_bin, "--batch", "--with-colons", "--fingerprint")
    unless fpr_st.success?
      raise RuntimeError, "gpg --fingerprint failed: #{decode_utf8(fpr_err).strip}"
    end

    imported_fprs = {}
    decode_utf8(fpr_out).each_line do |line|
      next unless line.start_with?("fpr:")

      cols = line.split(":")
      imported_fprs[cols[9].upcase] = true if cols.length > 9 && cols[9]
    end
    unless imported_fprs.key?(expected_fpr)
      raise RuntimeError, "pinned fingerprint #{expected_fpr} missing after gpg --import"
    end

    ver_out, ver_err, ver_st = Open3.capture3(
      env, gpg_bin, "--batch", "--status-fd", "1", "--verify", sig_path, tarball_path
    )
    status_txt = decode_utf8(ver_out)
    unless ver_st.success?
      raise RuntimeError, "gpg --verify failed (#{ver_st.exitstatus}): #{decode_utf8(ver_err).strip}"
    end

    matched = false
    status_txt.each_line do |line|
      next unless line.start_with?("[GNUPG:] VALIDSIG ")

      fields = line.split
      sig_fpr = fields.length > 2 ? fields[2].upcase : ""
      primary_fpr = fields.length > 11 ? fields[11].upcase : ""
      if expected_fpr == sig_fpr || expected_fpr == primary_fpr
        matched = true
        break
      end
    end
    unless matched
      raise RuntimeError,
            "gpg verified signature but VALIDSIG did not match pinned fingerprint #{expected_fpr}"
    end
  end
end

def verify_pgp_signature(tarball_path, sig_url, key_abs, expected_fpr, cache_dir: "")
  gpg_bin = which_bin("gpg")
  unless gpg_bin
    raise RuntimeError, "gpg is required for PGP signature verification but is not installed"
  end

  sig_bytes, from_cache = fetch_cached_bytes(sig_url, cache_dir)
  begin
    run_gpg_verify(gpg_bin, sig_bytes, tarball_path, key_abs, expected_fpr)
    from_cache
  rescue StandardError
    raise unless from_cache

    sig_bytes, = fetch_cached_bytes(sig_url, cache_dir, force_refresh: true)
    run_gpg_verify(gpg_bin, sig_bytes, tarball_path, key_abs, expected_fpr)
    false
  end
end

def verify_pgp_clearsign(signed_bytes, key_abs, expected_fpr)
  gpg_bin = which_bin("gpg")
  raise RuntimeError, "gpg is required for PGP clearsign verification but is not installed" unless gpg_bin

  Dir.mktmpdir("filc-verify-gpg-") do |td|
    gnupg_home = File.join(td, "gnupg")
    Dir.mkdir(gnupg_home, 0o700)
    signed_path = File.join(td, "InRelease")
    verified_path = File.join(td, "verified.txt")
    File.binwrite(signed_path, signed_bytes)
    env = ENV.to_h.merge("GNUPGHOME" => gnupg_home)

    _imp_out, imp_err, imp_st = Open3.capture3(env, gpg_bin, "--batch", "--quiet", "--import", key_abs)
    raise RuntimeError, "gpg --import failed: #{decode_utf8(imp_err).strip}" unless imp_st.success?

    fpr_out, fpr_err, fpr_st = Open3.capture3(env, gpg_bin, "--batch", "--with-colons", "--fingerprint")
    raise RuntimeError, "gpg --fingerprint failed: #{decode_utf8(fpr_err).strip}" unless fpr_st.success?

    imported_fprs = {}
    decode_utf8(fpr_out).each_line do |line|
      next unless line.start_with?("fpr:")

      cols = line.split(":")
      imported_fprs[cols[9].upcase] = true if cols.length > 9 && cols[9]
    end
    unless imported_fprs.key?(expected_fpr)
      raise RuntimeError, "pinned fingerprint #{expected_fpr} missing after gpg --import"
    end

    ver_out, ver_err, ver_st = Open3.capture3(
      env, gpg_bin, "--batch", "--status-fd", "1", "--output", verified_path, "--decrypt", signed_path
    )
    status_txt = decode_utf8(ver_out)
    unless ver_st.success?
      raise RuntimeError, "gpg --decrypt InRelease failed (#{ver_st.exitstatus}): #{decode_utf8(ver_err).strip}"
    end

    matched = false
    status_txt.each_line do |line|
      next unless line.start_with?("[GNUPG:] VALIDSIG ")

      fields = line.split
      sig_fpr = fields.length > 2 ? fields[2].upcase : ""
      primary_fpr = fields.length > 11 ? fields[11].upcase : ""
      if expected_fpr == sig_fpr || expected_fpr == primary_fpr
        matched = true
        break
      end
    end
    unless matched
      raise RuntimeError, "gpg verified InRelease but VALIDSIG did not match pinned fingerprint #{expected_fpr}"
    end

    decode_utf8(File.binread(verified_path))
  end
end

def verify_debian_elts_pin(name, meta, spec, repo_root, cache_dir)
  inrelease_url = spec["debian-elts"]
  key_abs = File.expand_path(spec["key"], repo_root)
  inrelease_bytes, inr_cached = fetch_cached_bytes(inrelease_url, cache_dir)
  verified_inrelease = begin
    verify_pgp_clearsign(inrelease_bytes, key_abs, spec["fpr"])
  rescue StandardError
    raise unless inr_cached

    inrelease_bytes, = fetch_cached_bytes(inrelease_url, cache_dir, force_refresh: true)
    inr_cached = false
    verify_pgp_clearsign(inrelease_bytes, key_abs, spec["fpr"])
  end

  sources_rel = nil
  sources_sha = nil
  in_sha256 = false
  verified_inrelease.each_line do |raw|
    if raw.start_with?("SHA256:")
      in_sha256 = true
      next
    elsif in_sha256 && raw.start_with?(" ")
      parts = raw.strip.split(/\s+/, 3)
      if parts.length == 3 && parts[2] == "main/source/Sources.gz" && SHA256_RE.match?(parts[0].downcase)
        sources_sha = parts[0].downcase
        sources_rel = parts[2]
        break
      end
    elsif in_sha256
      in_sha256 = false
    end
  end
  raise RuntimeError, "could not find main/source/Sources.gz SHA256 in verified #{inrelease_url}" unless sources_rel

  base_url = inrelease_url.sub(%r{/[^/]+\z}, "")
  sources_url = "#{base_url}/#{sources_rel}"
  src_bytes, = fetch_cached_bytes(sources_url, cache_dir)
  got_src_sha = Digest::SHA256.hexdigest(src_bytes)
  if got_src_sha != sources_sha
    src_bytes, = fetch_cached_bytes(sources_url, cache_dir, force_refresh: true)
    got_src_sha = Digest::SHA256.hexdigest(src_bytes)
    if got_src_sha != sources_sha
      raise RuntimeError, "Sources.gz SHA-256 mismatch for #{sources_url}: InRelease=#{sources_sha}, got=#{got_src_sha}"
    end
  end

  sources_txt = Zlib::GzipReader.new(StringIO.new(src_bytes)).read.force_encoding(Encoding::UTF_8).scrub
  checksums = nil
  sources_txt.split("\n\n").each do |stanza|
    pkg_m = /^Package:\s*(\S+)/.match(stanza)
    ver_m = /^Version:\s*(\S+)/.match(stanza)
    next unless pkg_m && ver_m && pkg_m[1] == spec["pkg"] && ver_m[1] == spec["ver"]

    map = {}
    in_cs = false
    stanza.each_line do |ln|
      if ln.start_with?("Checksums-Sha256:")
        in_cs = true
      elsif in_cs && ln.start_with?(" ")
        parts = ln.strip.split(/\s+/, 3)
        map[parts[2]] = parts[0].downcase if parts.length == 3
      elsif in_cs
        in_cs = false
      end
    end
    checksums = map
    break
  end
  raise RuntimeError, "package #{spec['pkg']} #{spec['ver']} not found in #{sources_url}" unless checksums

  orig_name = File.basename(meta.fetch("UPSTREAM_URL").split("?", 2)[0])
  deb_name = File.basename(meta.fetch("DEBIAN_TARBALL_URL").split("?", 2)[0])
  want_orig = meta.fetch("UPSTREAM_SHA256")
  want_deb = meta.fetch("DEBIAN_TARBALL_SHA256")
  got_orig = checksums[orig_name]
  got_deb = checksums[deb_name]
  if got_orig != want_orig
    raise RuntimeError, "orig SHA-256 mismatch for #{orig_name}: PORT=#{want_orig}, ELTS=#{py_repr(got_orig)}"
  end
  if got_deb != want_deb
    raise RuntimeError, "debian tarball SHA-256 mismatch for #{deb_name}: PORT=#{want_deb}, ELTS=#{py_repr(got_deb)}"
  end

  want_dsc = meta.fetch("DEBIAN_DSC_SHA256", "")
  unless want_dsc.empty?
    dsc_entry = checksums.find { |fname, _| fname.end_with?(".dsc") }
    got_dsc = dsc_entry ? dsc_entry[1] : nil
    if got_dsc != want_dsc
      raise RuntimeError, "dsc SHA-256 mismatch for #{spec['pkg']} #{spec['ver']}: PORT=#{want_dsc}, ELTS=#{py_repr(got_dsc)}"
    end
  end

  src_note = inr_cached ? "cached InRelease, verified" : "fetched InRelease, verified"
  "OK [debian-elts] #{name} #{meta['VERSION']} " \
  "(fpr=#{spec['fpr'][0, 12]}..., orig=#{want_orig[0, 12]}..., deb=#{want_deb[0, 12]}..., #{src_note})"
end

def verify_port_online(name, meta, repo_root, cache_dir, strict)
  src = meta.fetch("UPSTREAM_SHA256_SOURCE")
  expected = meta.fetch("UPSTREAM_SHA256")
  filename = File.basename(meta.fetch("UPSTREAM_URL").split("?", 2)[0])

  if src.start_with?("sha256:")
    url = src["sha256:".length..]
    got, from_cache = fetch_and_extract(url, cache_dir) do |raw|
      extract_sha256_from_checksum_text(decode_utf8(raw), filename)
    end
    if got != expected
      raise RuntimeError, "upstream checksum mismatch from #{url}: PORT=#{expected}, upstream=#{got}"
    end

    src_note = from_cache ? "cached, verified" : "fetched, verified"
    return "OK [sha256] #{name} #{meta['VERSION']} (#{expected[0, 12]}..., #{src_note})"
  end

  if src.start_with?("pgp:")
    spec = parse_pgp_source(src)
    details = ["pgp"]
    if spec.key?("sha256_b64")
      got_b64, = fetch_and_extract(spec["sha256_b64"], cache_dir) do |raw|
        extract_sha256_b64_from_text(decode_utf8(raw), filename)
      end
      if got_b64 != expected
        raise RuntimeError, "release announcement SHA256 mismatch: PORT=#{expected}, upstream=#{got_b64}"
      end

      details << "sha256_b64"
    end
    tarball_path = ensure_cached_tarball(meta, cache_dir)
    key_abs = File.expand_path(spec["key"], repo_root)
    sig_cached = verify_pgp_signature(
      tarball_path, spec["pgp"], key_abs, spec["fpr"], cache_dir: cache_dir
    )
    sig_note = sig_cached ? "cached .sig, verified" : "fetched .sig, verified"
    return "OK [#{details.join('+')}] #{name} #{meta['VERSION']} " \
           "(fpr=#{spec['fpr'][0, 12]}..., sha256=#{expected[0, 12]}..., #{sig_note})"
  end

  if src.start_with?("debian-elts:")
    spec = parse_debian_elts_source(src)
    return verify_debian_elts_pin(name, meta, spec, repo_root, cache_dir)
  end

  if src.start_with?("github-release-digest:")
    api_url = src["github-release-digest:".length..]
    digest, from_cache = fetch_and_extract(
      api_url, cache_dir, extra_headers: ["Accept: application/vnd.github+json"]
    ) do |raw|
      rel = JSON.parse(decode_utf8(raw))
      assets = {}
      (rel["assets"] || []).each { |a| assets[a["name"]] = a }
      asset = assets[filename]
      unless asset
        raise RuntimeError, "asset #{py_repr(filename)} not found in GitHub release #{api_url}"
      end

      asset["digest"] || ""
    end
    if digest != "sha256:#{expected}"
      raise RuntimeError,
            "GitHub release digest mismatch for #{filename}: PORT=sha256:#{expected}, api=#{py_repr(digest)}"
    end

    src_note = from_cache ? "cached, verified" : "fetched, verified"
    return "OK [github-release-digest] #{name} #{meta['VERSION']} (#{expected[0, 12]}..., #{src_note})"
  end

  if src.start_with?("sha256-html:")
    url = src["sha256-html:".length..]
    got, from_cache = fetch_and_extract(url, cache_dir) do |raw|
      txt = decode_utf8(raw)
      m_row = /#{Regexp.escape(filename)}.*?(?:<\/tr|<\/tr>|\n\n)/mi.match(txt)
      raise RuntimeError, "could not find row for #{py_repr(filename)} in #{url}" unless m_row

      hashes = m_row[0].scan(/\b([0-9a-fA-F]{64})\b/).flatten
      if hashes.empty?
        raise RuntimeError, "could not find 64-hex SHA-256 for #{py_repr(filename)} in #{url}"
      end

      hashes[0].downcase
    end
    if got != expected
      raise RuntimeError, "upstream HTML checksum mismatch from #{url}: PORT=#{expected}, upstream=#{got}"
    end

    src_note = from_cache ? "cached, verified" : "fetched, verified"
    return "OK [sha256-html] #{name} #{meta['VERSION']} (#{expected[0, 12]}..., #{src_note})"
  end

  if src.start_with?("upstream-sha512-only:")
    url = src["upstream-sha512-only:".length..]
    upstream_sha512, from_cache = fetch_and_extract(url, cache_dir) do |raw|
      found = nil
      decode_utf8(raw).each_line do |line|
        m = /\A([0-9a-fA-F]{128})\s+(?:\d+\s+)?\*?(.+)\z/.match(line.strip)
        if m && File.basename(m[2].strip) == filename
          found = m[1].downcase
          break
        end
      end
      raise RuntimeError, "could not find SHA-512 for #{py_repr(filename)} at #{url}" unless found

      found
    end
    tarball_path = ensure_cached_tarball(meta, cache_dir)
    got512 = file_hash(tarball_path, "sha512")
    if got512 != upstream_sha512
      raise RuntimeError, "SHA-512 mismatch for #{filename}: expected #{upstream_sha512}, got #{got512}"
    end

    src_note = from_cache ? "cached, verified" : "fetched, verified"
    return "OK [upstream-sha512] #{name} #{meta['VERSION']} (#{expected[0, 12]}..., #{src_note})"
  end

  if src.start_with?("upstream-sha3-256:")
    url = src["upstream-sha3-256:".length..]
    upstream_sha3, from_cache = fetch_and_extract(url, cache_dir) do |raw|
      found = nil
      decode_utf8(raw).each_line do |line|
        stripped = line.strip
        next unless line.include?(filename) && stripped.start_with?("PRODUCT,")

        parts = stripped.split(",")
        if parts.length >= 5 && /\A[0-9a-fA-F]{64}\z/.match?(parts[4])
          found = parts[4].downcase
          break
        end
      end
      raise RuntimeError, "could not find SHA3-256 for #{py_repr(filename)} at #{url}" unless found

      found
    end
    tarball_path = ensure_cached_tarball(meta, cache_dir)
    got3 = file_hash(tarball_path, "sha3_256")
    if got3 != upstream_sha3
      raise RuntimeError, "SHA3-256 mismatch for #{filename}: expected #{upstream_sha3}, got #{got3}"
    end

    src_note = from_cache ? "cached, verified" : "fetched, verified"
    return "OK [upstream-sha3-256] #{name} #{meta['VERSION']} (#{expected[0, 12]}..., #{src_note})"
  end

  if strict
    raise RuntimeError, "#{name}: non-verifiable UPSTREAM_SHA256_SOURCE under --strict: #{src}"
  end

  "NOTE [unverified-source] #{name} #{meta['VERSION']} (#{src.split(':', 2)[0]})"
end

def detect_changed_ports(repo_root, base_ref)
  candidates = base_ref && !base_ref.empty? ? [base_ref] : %w[origin/main main HEAD~1]
  chosen = nil
  candidates.each do |ref|
    _, _, status = Open3.capture3("git", "-C", repo_root, "rev-parse", "--verify", "#{ref}^{commit}")
    if status.success?
      chosen = ref
      break
    end
  end
  return [] unless chosen

  out, _err, status = Open3.capture3("git", "-C", repo_root, "diff", "--name-only", "#{chosen}...HEAD")
  return [] unless status.success?

  changed = {}
  out.each_line do |path|
    m = %r{\Aports/([^/]+)/PORT\z}.match(path.strip)
    changed[m[1]] = true if m
  end
  changed.keys.sort
end

def expand_with_deps(all_ports, initial_names)
  selected = {}
  stack = initial_names.dup
  until stack.empty?
    cur = stack.pop
    raise ArgumentError, "unknown port: #{cur}" unless all_ports.key?(cur)
    next if selected.key?(cur)

    selected[cur] = true
    all_ports[cur].fetch("DEPS", "").split.each do |dep|
      dep = dep.strip
      next if dep.empty?
      raise ArgumentError, "port '#{cur}' depends on unknown port '#{dep}'" unless all_ports.key?(dep)

      stack << dep
    end
  end
  selected.keys.sort
end

def parse_port_list(raw)
  raw.to_s.split(/[\s,]+/).reject(&:empty?).uniq
end

def main(argv)
  repo_root = File.expand_path("..", __dir__)
  options = {
    all: false,
    verifiable_direct: false,
    respect_filc_ports: false,
    with_deps: false,
    changed: nil,
    check_metadata_only: false,
    strict: false,
    ports_dir: File.join(repo_root, "ports"),
    cache_dir: ENV.fetch("FILC_PORTS_CACHE_DIR", File.join(repo_root, ".work", "ports", "ports-cache")),
  }

  parser = OptionParser.new do |opts|
    opts.banner = "Usage: verify-pins [options] [ports...]"
    opts.on("--all", "Verify all ports in ports/") { options[:all] = true }
    opts.on("--verifiable-direct", "Verify all ports with direct sha256: or pgp: sources") do
      options[:verifiable_direct] = true
    end
    opts.on("--respect-filc-ports", "When FILC_PORTS env var is set, restrict verification to its transitive dependency closure") do
      options[:respect_filc_ports] = true
    end
    opts.on("--with-deps", "Expand explicitly listed ports to include transitive DEPS") do
      options[:with_deps] = true
    end
    opts.on("--changed [BASE_REF]", "Verify ports whose PORT file changed relative to BASE_REF (default: origin/main)") do |ref|
      options[:changed] = ref.nil? ? "" : ref
    end
    opts.on("--check-metadata-only", "Offline check: validate UPSTREAM_SHA256_SOURCE metadata and pinned PGP key fingerprints only") do
      options[:check_metadata_only] = true
    end
    opts.on("--strict", "Fail if any selected port has an unverified/unpinned source") do
      options[:strict] = true
    end
    opts.on("--ports-dir DIR") { |v| options[:ports_dir] = v }
    opts.on("--cache-dir DIR") { |v| options[:cache_dir] = v }
  end

  positional = parser.parse(argv)

  all_ports = {}
  Dir.children(options[:ports_dir]).sort.each do |entry|
    pfile = File.join(options[:ports_dir], entry, "PORT")
    all_ports[entry] = parse_port_file(pfile) if File.file?(pfile)
  end

  if all_ports.empty?
    warn "error: no PORT recipes found"
    return 1
  end

  filc_ports_env = options[:respect_filc_ports] ? ENV.fetch("FILC_PORTS", "").strip : ""
  filc_ports_list = filc_ports_env.empty? ? [] : parse_port_list(filc_ports_env)
  pos_ports = positional.flat_map { |raw| parse_port_list(raw) }.uniq

  selected =
    if !pos_ports.empty?
      pos_ports.each do |p|
        unless all_ports.key?(p)
          warn "error: unknown port: #{p}"
          return 1
        end
      end
      options[:with_deps] ? expand_with_deps(all_ports, pos_ports) : pos_ports.dup
    elsif !filc_ports_list.empty?
      wanted = filc_ports_list
      begin
        closure = expand_with_deps(all_ports, wanted)
      rescue ArgumentError => e
        warn "error: #{e.message}"
        return 1
      end
      sel = if options[:verifiable_direct]
              closure.select do |n|
                src = all_ports[n].fetch("UPSTREAM_SHA256_SOURCE", "")
                DIRECT_SCHEMES.any? { |s| src.start_with?(s) }
              end
            else
              closure
            end
      $stdout.puts("verify-pins: FILC_PORTS=#{wanted.join(',')} -> closure=#{closure.length}, selected=#{sel.length}")
      $stdout.flush
      sel
    elsif options[:verifiable_direct]
      all_ports.keys.sort.select do |n|
        src = all_ports[n].fetch("UPSTREAM_SHA256_SOURCE", "")
        DIRECT_SCHEMES.any? { |s| src.start_with?(s) }
      end
    elsif !options[:changed].nil?
      changed = detect_changed_ports(repo_root, options[:changed])
      if changed.empty?
        puts "verify-pins: no changed PORT files detected; falling back to --verifiable-direct"
        all_ports.keys.sort.select do |n|
          src = all_ports[n].fetch("UPSTREAM_SHA256_SOURCE", "")
          DIRECT_SCHEMES.any? { |s| src.start_with?(s) }
        end
      else
        changed
      end
    else
      all_ports.keys.sort
    end

  meta_errors = []
  selected.each do |name|
    meta_errors.concat(validate_metadata(name, all_ports[name], repo_root))
  end
  unless meta_errors.empty?
    meta_errors.each { |e| warn "FAIL [metadata] #{e}" }
    return 1
  end

  if options[:check_metadata_only]
    verifiable = selected.count do |n|
      src = all_ports[n].fetch("UPSTREAM_SHA256_SOURCE", "")
      VERIFIABLE_SCHEMES.any? { |s| src.start_with?(s) }
    end
    puts "PIN METADATA OK (checked=#{selected.length}, verifiable=#{verifiable}, " \
         "unverified=#{selected.length - verifiable})"
    return 0
  end

  failures = []
  selected.each do |name|
    msg = verify_port_online(name, all_ports[name], repo_root, options[:cache_dir], options[:strict])
    $stdout.puts(msg)
    $stdout.flush
  rescue StandardError => e
    $stderr.puts("FAIL [#{name}] #{e.message}")
    $stderr.flush
    failures << [name, e.message]
  end

  unless failures.empty?
    warn "VERIFY_PINS: FAILED (#{failures.length}/#{selected.length})"
    return 1
  end

  puts "VERIFY_PINS: PASS (#{selected.length} ports checked)"
  0
end

exit(main(ARGV)) if $PROGRAM_NAME == __FILE__
