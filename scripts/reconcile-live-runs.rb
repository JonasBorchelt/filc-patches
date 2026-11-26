#!/usr/bin/env ruby
# frozen_string_literal: true

# Admin & reconciliation utility for filc-live run states.
#
# Closes orphaned "running" / "pending" runs (whose CI pipeline was canceled or
# killed before report-finish could execute) permanently as "aborted", and
# supports explicit run status corrections (e.g. repairing a misreported run).
#
# Uses only the standard /api/runs GET/POST endpoints with Bearer auth from
# FILC_LIVE_TOKEN, so it works against both current and future filc-live builds.

require "json"
require "net/http"
require "optparse"
require "time"
require "uri"

ALLOWED_TARGET_STATUSES = %w[success failure killed aborted].freeze
ALLOWED_STEP_STATUSES = %w[pending running success failure skipped killed].freeze
ALLOWED_WORKFLOWS = %w[nightly toolchain ports release publish publish-ports].freeze
DEFAULT_STALE_SECONDS = 600
DEFAULT_MIN_AGE_SECONDS = 30
DEFAULT_MAX_PAGES = 5

def now_utc
  Time.now.utc
end

def iso8601_utc(t)
  t.utc.strftime("%Y-%m-%dT%H:%M:%SZ")
end

def parse_int_list(raw)
  return [] if raw.nil? || raw.strip.empty?

  out = []
  raw.split(/[\s,]+/).each do |tok|
    next if tok.empty?
    raise ArgumentError, "invalid run number: #{tok.inspect}" unless /\A[1-9]\d*\z/.match?(tok)

    out << tok.to_i
  end
  out.uniq
end

def parse_status_specs(raw)
  return {} if raw.nil? || raw.strip.empty?

  specs = {}
  raw.split(/[\s,]+/).each do |tok|
    next if tok.empty?

    m = /\A([1-9]\d*)=([a-z]+)\z/.match(tok.downcase)
    raise ArgumentError, "invalid status spec #{tok.inspect} (expected NUM=STATUS)" unless m

    num = m[1].to_i
    st = m[2]
    unless ALLOWED_TARGET_STATUSES.include?(st)
      raise ArgumentError, "unsupported target status #{st.inspect} (allowed: #{ALLOWED_TARGET_STATUSES.join(', ')})"
    end

    specs[num] = st
  end
  specs
end

def http_json(url, method:, token: nil, payload: nil, timeout: 10.0)
  uri = URI.parse(url)
  http = Net::HTTP.new(uri.host, uri.port, nil)
  http.use_ssl = (uri.scheme == "https")
  http.open_timeout = timeout
  http.read_timeout = timeout

  req = case method
        when :get then Net::HTTP::Get.new(uri.request_uri)
        when :post then Net::HTTP::Post.new(uri.request_uri)
        else raise ArgumentError, "unsupported HTTP method: #{method}"
        end
  req["Accept"] = "application/json"
  req["Authorization"] = "Bearer #{token}" if token && !token.empty?
  unless payload.nil?
    req["Content-Type"] = "application/json; charset=utf-8"
    req.body = JSON.generate(payload).encode(Encoding::UTF_8)
  end

  resp = http.request(req)
  code = resp.code.to_i
  raw = resp.body.to_s.dup.force_encoding(Encoding::UTF_8).scrub("\uFFFD")
  parsed = raw.strip.empty? ? {} : JSON.parse(raw)
  [code, parsed, raw]
end

def fetch_run(live_url, number)
  base = live_url.sub(%r{/+\z}, "")
  code, data, raw = http_json("#{base}/#{number}", method: :get)
  return nil if code == 404
  raise RuntimeError, "GET #{base}/#{number} failed: HTTP #{code}: #{raw[0, 200]}" unless code == 200

  data
end

def fetch_recent_runs(live_url, max_pages: DEFAULT_MAX_PAGES)
  base = live_url.sub(%r{/+\z}, "")
  sep = base.include?("?") ? "&" : "?"
  all = []
  (1..max_pages).each do |page|
    code, data, raw = http_json("#{base}#{sep}page=#{page}&per_page=100", method: :get)
    raise RuntimeError, "GET #{base} page=#{page} failed: HTTP #{code}: #{raw[0, 200]}" unless code == 200

    runs = data["runs"]
    break unless runs.is_a?(Array) && !runs.empty?

    all.concat(runs)
    total_pages = data["pages"].to_i
    break if total_pages > 0 && page >= total_pages
  end
  all
end

def fetch_ci_active_pipelines(api_url, repo_id, token)
  base = api_url.sub(%r{/+\z}, "")
  active = []
  %w[running pending].each do |st|
    url = "#{base}/repos/#{repo_id}/pipelines?status=#{st}&perPage=50"
    code, data, raw = http_json(url, method: :get, token: token)
    raise RuntimeError, "CI API GET #{url} failed: HTTP #{code}: #{raw[0, 200]}" unless code == 200
    raise RuntimeError, "CI API returned non-array payload for status=#{st}" unless data.is_a?(Array)

    data.each do |item|
      next unless item.is_a?(Hash)

      num = item["number"].to_i
      active << num if num > 0
    end
  end
  active.uniq
end

def run_last_activity_time(run)
  %w[updated_at started_at created_at].each do |field|
    raw = run[field]
    next unless raw.is_a?(String) && !raw.empty?

    begin
      return Time.iso8601(raw).utc
    rescue ArgumentError
      next
    end
  end
  nil
end

def build_update_payload(existing, target_status, now_time)
  number = existing["number"].to_i
  raise ArgumentError, "invalid existing run number" if number < 1

  payload = {
    "number" => number,
    "status" => target_status,
  }

  wf = existing["workflow"]
  payload["workflow"] = wf if wf.is_a?(String) && ALLOWED_WORKFLOWS.include?(wf)

  finished_at = existing["finished_at"]
  if finished_at.is_a?(String) && /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/.match?(finished_at)
    payload["finished_at"] = finished_at
  else
    payload["finished_at"] = iso8601_utc(now_time)
  end

  if existing["steps"].is_a?(Array) && !existing["steps"].empty?
    step_target = target_status == "aborted" ? "killed" : target_status
    new_steps = existing["steps"].filter_map do |st|
      next unless st.is_a?(Hash) && st["name"].is_a?(String) && !st["name"].empty?

      cur = st["status"].to_s
      next_st =
        if %w[running pending].include?(cur) || target_status == "success"
          step_target
        elsif ALLOWED_STEP_STATUSES.include?(cur)
          cur
        else
          step_target
        end
      entry = { "name" => st["name"], "status" => next_st }
      if st["duration_seconds"].is_a?(Numeric) && st["duration_seconds"] >= 0
        entry["duration_seconds"] = st["duration_seconds"]
      end
      entry
    end
    payload["steps"] = new_steps unless new_steps.empty?
  end

  if target_status == "success"
    prog = existing["progress"].is_a?(Hash) ? existing["progress"].dup : {}
    prog["percent"] = 100
    prog.delete("phase")
    prog.delete("phases")
    allowed_prog = %w[stage phase phases percent done total elapsed_seconds parallel planned]
    prog.select! { |k, _| allowed_prog.include?(k) }
    payload["progress"] = prog
  end

  payload
end

def select_runs_to_abort(runs, active_numbers:, exclude_numbers:, stale_seconds:, min_age_seconds:, now_time:)
  candidates = []
  active_authoritative = !active_numbers.nil?
  active_set = active_authoritative ? active_numbers.each_with_object({}) { |n, h| h[n] = true } : {}
  exclude_set = exclude_numbers.each_with_object({}) { |n, h| h[n] = true }

  runs.each do |run|
    next unless run.is_a?(Hash)

    num = run["number"].to_i
    next if num < 1
    next if exclude_set[num]

    raw_status = run["status"].to_s
    is_stale_virtual = run["stale_aborted"] == true
    next unless %w[running pending].include?(raw_status) || is_stale_virtual

    next if active_authoritative && active_set[num]

    last_t = run_last_activity_time(run)
    age = last_t ? (now_time - last_t) : Float::INFINITY

    if is_stale_virtual
      candidates << [run, "stale_aborted_on_disk (age=#{age.finite? ? age.round : 'unknown'}s)"]
    elsif active_authoritative
      if age >= min_age_seconds
        candidates << [run, "not_in_active_pipelines (age=#{age.finite? ? age.round : 'unknown'}s)"]
      end
    elsif age >= stale_seconds
      candidates << [run, "stale_running (age=#{age.finite? ? age.round : 'unknown'}s >= #{stale_seconds}s)"]
    end
  end

  candidates.sort_by { |r, _| r["number"].to_i }
end

def main(argv)
  options = {
    live_url: ENV.fetch("FILC_LIVE_URL", ""),
    set_status_raw: ENV.fetch("FILC_RECONCILE_SET_STATUS", ""),
    abort_runs_raw: ENV.fetch("FILC_RECONCILE_ABORT_RUNS", ""),
    close_stale: ENV.fetch("FILC_RECONCILE_CLOSE_STALE", "") == "1",
    active_runs_raw: ENV.fetch("FILC_RECONCILE_ACTIVE_RUNS", ""),
    exclude_runs_raw: ENV.fetch("FILC_RECONCILE_EXCLUDE_RUNS", ""),
    stale_seconds: ENV.fetch("FILC_RECONCILE_STALE_SECONDS", DEFAULT_STALE_SECONDS.to_s).to_i,
    min_age_seconds: ENV.fetch("FILC_RECONCILE_MIN_AGE_SECONDS", DEFAULT_MIN_AGE_SECONDS.to_s).to_i,
    max_pages: DEFAULT_MAX_PAGES,
    ci_api_url: ENV.fetch("FILC_CI_API_URL", ""),
    ci_repo_id: ENV.fetch("FILC_CI_REPO_ID", ""),
    include_self: false,
    dry_run: ENV.fetch("FILC_RECONCILE_DRY_RUN", "") == "1",
  }

  parser = OptionParser.new do |opts|
    opts.banner = "Usage: reconcile-live-runs.rb [options]"
    opts.on("--live-url URL", "filc-live /api/runs URL") { |v| options[:live_url] = v }
    opts.on("--set-status SPECS", "Comma/space list of NUM=STATUS (e.g. 285=success)") { |v| options[:set_status_raw] = v }
    opts.on("--abort-runs NUMS", "Comma/space list of run numbers to mark aborted (e.g. 284)") { |v| options[:abort_runs_raw] = v }
    opts.on("--close-stale", "Scan and permanently abort stale/orphaned running runs") { options[:close_stale] = true }
    opts.on("--active-runs NUMS", "Authoritative list of currently active CI pipeline numbers") { |v| options[:active_runs_raw] = v }
    opts.on("--exclude-runs NUMS", "Run numbers to skip during --close-stale") { |v| options[:exclude_runs_raw] = v }
    opts.on("--stale-seconds N", Integer, "Inactivity threshold in seconds (default #{DEFAULT_STALE_SECONDS})") { |v| options[:stale_seconds] = v }
    opts.on("--min-age-seconds N", Integer, "Minimum age before aborting non-active runs (default #{DEFAULT_MIN_AGE_SECONDS})") { |v| options[:min_age_seconds] = v }
    opts.on("--max-pages N", Integer, "Max /api/runs pages to scan (default #{DEFAULT_MAX_PAGES})") { |v| options[:max_pages] = v }
    opts.on("--ci-api-url URL", "Optional CI API base URL for active pipeline lookup") { |v| options[:ci_api_url] = v }
    opts.on("--ci-repo-id ID", "Optional CI repository ID for active pipeline lookup") { |v| options[:ci_repo_id] = v }
    opts.on("--include-self", "Do not auto-exclude CI_PIPELINE_NUMBER") { options[:include_self] = true }
    opts.on("--dry-run", "Print planned updates without POSTing to filc-live") { options[:dry_run] = true }
  end
  parser.parse!(argv)

  live_url = options[:live_url].strip
  raise ArgumentError, "FILC_LIVE_URL (or --live-url) is required" if live_url.empty?

  token = ENV.fetch("FILC_LIVE_TOKEN", "").strip
  if !options[:dry_run] && token.empty?
    raise ArgumentError, "FILC_LIVE_TOKEN is required unless --dry-run is set"
  end

  set_specs = parse_status_specs(options[:set_status_raw])
  abort_nums = parse_int_list(options[:abort_runs_raw])
  abort_nums.each { |n| set_specs[n] ||= "aborted" }

  # Default to --close-stale when invoked with no explicit targets.
  close_stale = options[:close_stale] || set_specs.empty?

  now_time = now_utc
  planned = [] # [[number, target_status, reason, payload]]

  # 1. Explicit status overrides / explicit aborts
  set_specs.keys.sort.each do |num|
    target = set_specs[num]
    existing = fetch_run(live_url, num)
    if existing.nil?
      warn "reconcile-live: run ##{num} not found on filc-live (skipped)"
      next
    end
    payload = build_update_payload(existing, target, now_time)
    planned << [num, target, "explicit (#{existing['status']} -> #{target})", payload]
  end

  # 2. Sweep orphaned / stale running runs
  if close_stale
    exclude = parse_int_list(options[:exclude_runs_raw]) + set_specs.keys
    unless options[:include_self]
      self_num = ENV.fetch("CI_PIPELINE_NUMBER", "").strip
      exclude << self_num.to_i if /\A[1-9]\d*\z/.match?(self_num)
    end
    exclude.uniq!

    active_numbers = nil
    if !options[:active_runs_raw].strip.empty?
      active_numbers = parse_int_list(options[:active_runs_raw])
    elsif !options[:ci_api_url].strip.empty? && !options[:ci_repo_id].strip.empty?
      ci_token = ENV.fetch("FILC_CI_API_TOKEN", "").strip
      raise ArgumentError, "FILC_CI_API_TOKEN required when FILC_CI_API_URL is set" if ci_token.empty?

      active_numbers = fetch_ci_active_pipelines(
        options[:ci_api_url].strip,
        options[:ci_repo_id].strip,
        ci_token
      )
      puts "reconcile-live: queried active CI pipelines: #{active_numbers.inspect}"
    end

    runs = fetch_recent_runs(live_url, max_pages: [options[:max_pages], 1].max)
    to_abort = select_runs_to_abort(
      runs,
      active_numbers: active_numbers,
      exclude_numbers: exclude,
      stale_seconds: [options[:stale_seconds], 0].max,
      min_age_seconds: [options[:min_age_seconds], 0].max,
      now_time: now_time
    )

    to_abort.each do |run, reason|
      num = run["number"].to_i
      payload = build_update_payload(run, "aborted", now_time)
      planned << [num, "aborted", reason, payload]
    end
  end

  if planned.empty?
    puts "reconcile-live: nothing to update (0 runs matched)"
    return 0
  end

  updated = 0
  planned.each do |num, target, reason, payload|
    if options[:dry_run]
      puts "DRY_RUN: run ##{num} -> #{target} (#{reason}) payload=#{JSON.generate(payload)}"
      updated += 1
    else
      code, _data, raw = http_json(live_url, method: :post, token: token, payload: payload)
      unless code == 200 || code == 201
        raise RuntimeError, "POST #{live_url} for run ##{num} failed: HTTP #{code}: #{raw[0, 200]}"
      end

      puts "reconcile-live: updated run ##{num} -> #{target} (#{reason}) HTTP #{code}"
      updated += 1
    end
  end

  puts "RECONCILE_LIVE: OK (updated=#{updated}, dry_run=#{options[:dry_run] ? 1 : 0})"
  0
rescue StandardError => e
  warn "reconcile-live: error: #{e.message}"
  1
end

exit(main(ARGV)) if $PROGRAM_NAME == __FILE__
