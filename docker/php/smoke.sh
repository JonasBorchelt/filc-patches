#!/usr/bin/env bash
# Smoke-test and drop-in acceptance test for a built filc-php Docker image.
#
# Usage: docker/php/smoke.sh <image-ref> <php-series> <variant>
# Example: docker/php/smoke.sh jonasborchelt/filc-php:8.5-cli 8.5 cli
#          docker/php/smoke.sh jonasborchelt/filc-php:7.4-fpm 7.4 fpm
#          docker/php/smoke.sh jonasborchelt/filc-php:5.6-cli 5.6 cli

set -euo pipefail

IMAGE="${1:?usage: smoke.sh <image-ref> <php-series> <variant>}"
PHP_SERIES="${2:?usage: smoke.sh <image-ref> <php-series> <variant>}"
VARIANT="${3:?usage: smoke.sh <image-ref> <php-series> <variant>}"
PHP_MAJOR="${PHP_SERIES%%.*}"
PHP_MINOR="${PHP_SERIES#*.}"
PHP_ASSERT_ARGS=()
PHP_OPCACHE_ARGS=(-d opcache.enable_cli=1)
if [[ "$PHP_MAJOR" -ge 7 ]]; then
  PHP_ASSERT_ARGS=(-d zend.assertions=1 -d assert.exception=1)
fi

echo "=== Smoke-testing ${IMAGE} (PHP ${PHP_SERIES}, major=${PHP_MAJOR}, variant=${VARIANT}) ==="

set -x

# 1. Verify official image layout, ENV, helper binaries, and INI templates
docker run --rm "${IMAGE}" sh -eux -c '
  ls -la /usr/local/bin/php /usr/local/etc/php
  test -x /usr/local/bin/php
  test -x /usr/local/bin/docker-php-entrypoint
  test -x /usr/local/bin/docker-php-ext-install
  test -x /usr/local/bin/docker-php-ext-enable
  test -x /usr/local/bin/docker-php-ext-configure
  test -x /usr/local/bin/docker-php-source
  test "$PHP_INI_DIR" = "/usr/local/etc/php"
  test "$PHP_SERIES" = "'"${PHP_SERIES}"'"
  case "$PHP_LDFLAGS" in *-Wl,-Bsymbolic-functions*) ;; *) exit 1 ;; esac
  test -f /usr/local/etc/php/php.ini-development
  test -f /usr/local/etc/php/php.ini-production
  test -d /usr/local/etc/php/conf.d
  test -d /var/www/html
'

RC=0
VER_OUT="$(docker run --rm "${IMAGE}" php -v 2>&1)" || RC=$?
echo "php -v (rc=${RC}): ${VER_OUT}"
if [[ "$RC" -ne 0 ]]; then
  docker run --rm "${IMAGE}" sh -c 'ls -la /opt/filc/*/pizfix/bin /opt/filc/*/pizfix/lib | head -n 60' 2>&1 || true
  exit "$RC"
fi
printf '%s\n' "$VER_OUT" | head -n 1 | grep -Eq "^PHP ${PHP_SERIES//./\\.}\."
printf '%s\n' "$VER_OUT" | grep -Fq "with Zend OPcache"

RC=0
MOD_OUT="$(docker run --rm "${IMAGE}" php -m 2>&1)" || RC=$?
echo "php -m (rc=${RC}): $(printf '%s' "$MOD_OUT" | tr '\n' ' ')"
if [[ "$RC" -ne 0 ]]; then
  exit "$RC"
fi
REQUIRED_MODS=(
  openssl sqlite3 pdo_sqlite curl mbstring intl bcmath exif pcntl sockets
  json pcre zlib dom simplexml xmlwriter iconv "Zend OPcache"
)
if [[ "$PHP_MAJOR" -ge 8 ]] || { [[ "$PHP_MAJOR" -eq 7 ]] && [[ "$PHP_MINOR" -ge 2 ]]; }; then
  REQUIRED_MODS+=(sodium)
fi
for mod in "${REQUIRED_MODS[@]}"; do
  printf '%s\n' "$MOD_OUT" | grep -Fxiq "$mod" || {
    echo "error: expected PHP module missing: $mod" >&2
    exit 1
  }
done

if [[ "$PHP_MAJOR" -ge 8 ]]; then
  PHP8_OUT="$(docker run --rm -i "${IMAGE}" php "${PHP_ASSERT_ARGS[@]}" -d opcache.enable_cli=1 <<'EOF'
<?php
$m = new WeakMap();
$o = new stdClass();
$wr = WeakReference::create($o);
$m[$o] = 'filc';
assert($m[$o] === 'filc');
assert($wr->get() === $o);
unset($o);
gc_collect_cycles();
assert(count($m) === 0 && $wr->get() === null);

$f = new Fiber(function (string $x): string {
    $y = Fiber::suspend("got:" . $x);
    return "done:" . $y;
});
assert($f->start("a") === "got:a");
assert($f->resume("b") === null);
assert($f->getReturn() === "done:b");
echo "FILC_PHP8_SMOKE_OK\n";
EOF
  )"
  echo "$PHP8_OUT"
  printf '%s\n' "$PHP8_OUT" | grep -Fxq "FILC_PHP8_SMOKE_OK"
fi

SCRIPT_OUT="$(docker run --rm -i "${IMAGE}" php ${PHP_ASSERT_ARGS[@]+"${PHP_ASSERT_ARGS[@]}"} ${PHP_OPCACHE_ARGS[@]+"${PHP_OPCACHE_ARGS[@]}"} <<'EOF'
<?php
if (PHP_VERSION_ID < 70000) {
    assert_options(ASSERT_ACTIVE, 1);
    assert_options(ASSERT_BAIL, 1);
    assert_options(ASSERT_WARNING, 1);
}
if (PHP_VERSION_ID < 80000) {
    assert(strpos(OPENSSL_VERSION_TEXT, "OpenSSL 1.1.1") === 0);
    $cv = curl_version();
    assert(is_array($cv) && isset($cv["ssl_version"]) && strpos($cv["ssl_version"], "OpenSSL/1.1.1") === 0);
    if (PHP_VERSION_ID >= 70400) {
        $o = new stdClass();
        $wr = WeakReference::create($o);
        assert($wr->get() === $o);
        unset($o);
        gc_collect_cycles();
        assert($wr->get() === null);
    }
    if (PHP_VERSION_ID < 70000) {
        $sfi_empty = new SplFileInfo("");
        assert($sfi_empty->getPathname() === "" && $sfi_empty->getFilename() === "" && $sfi_empty->getPath() === "");
        $sfi_root = new SplFileInfo("/");
        assert($sfi_root->getPathname() === "/" && $sfi_root->getBasename() === "" && $sfi_root->getPath() === "");
        assert(basename("") === "" && dirname("") === "");
    }
}

// JSON + Unicode smoke (especially verifies static pecl-jsonc 1.3.6 on PHP 5.6)
$jpayload = array("ok" => array(1, 2, 3), "unicode" => "hällo 日本語");
$jenc = json_encode($jpayload);
assert(is_string($jenc) && strpos($jenc, "\\u00e4") !== false && json_last_error() === JSON_ERROR_NONE);
$jenc_u = json_encode($jpayload, JSON_UNESCAPED_UNICODE);
assert(is_string($jenc_u) && strpos($jenc_u, "hällo 日本語") !== false);
assert(json_decode($jenc, true) === $jpayload && json_last_error() === JSON_ERROR_NONE);
assert(json_decode($jenc_u, true) === $jpayload && json_last_error() === JSON_ERROR_NONE);
assert(json_decode("{invalid-json") === null && json_last_error() === JSON_ERROR_SYNTAX);

assert(hash("sha256", "hello\n") === "5891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be03");
assert(openssl_digest("hello\n", "sha256") === "5891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be03");
assert(mb_strlen("hällo", "UTF-8") === 5);
assert(strtoupper("filc_ok") === "FILC_OK");
assert(strtolower("FILC_OK") === "filc_ok");
if (PHP_VERSION_ID >= 70200) {
    assert(strlen(sodium_crypto_generichash("filc")) === SODIUM_CRYPTO_GENERICHASH_BYTES);
}
$op = opcache_get_status(false);
assert(is_array($op) && $op["opcache_enabled"] === true);
assert(in_array("Zend OPcache", get_loaded_extensions(true), true));
$coll = new Collator("en_US");
assert($coll->compare("a", "b") < 0);

$db = new SQLite3(":memory:");
$db->exec("CREATE TABLE t (v INT); INSERT INTO t VALUES (42);");
assert($db->querySingle("SELECT v FROM t") === 42);
$db->close();

// XML / XPath / SimpleXML / XMLWriter (libxml2 2.12+ compatibility)
libxml_use_internal_errors(true);
$bad = new DOMDocument();
assert($bad->loadXML('<broken>') === false);
$err = libxml_get_last_error();
assert($err instanceof LibXMLError && $err->code > 0);
libxml_clear_errors();
libxml_use_internal_errors(false);

$xml = new DOMDocument();
assert($xml->loadXML('<root xmlns="urn:test"><child a="1">ok</child></root>') === true);
assert(strpos($xml->C14N(), '<child a="1">ok</child>') !== false);
$xml2 = new DOMDocument();
assert($xml2->loadXML('<root><item id="a">one</item><item id="b">two</item></root>') === true);
$xp = new DOMXPath($xml2);
$nodes = $xp->query('//item[@id="b"]');
assert($nodes !== false && $nodes->length === 1 && $nodes->item(0)->textContent === 'two');

$sxe = simplexml_load_string('<root><item id="a">one</item><item id="b">two</item></root>');
assert($sxe !== false);
$sxe_nodes = $sxe->xpath('//item[@id="a"]');
assert(is_array($sxe_nodes) && count($sxe_nodes) === 1 && (string)$sxe_nodes[0] === 'one');

$xw = new XMLWriter();
$xw->openMemory();
$xw->startElement('doc');
$xw->writeElement('n', 'ok');
$xw->endElement();
assert($xw->outputMemory() === '<doc><n>ok</n></doc>');

// iconv UTF-8 <-> ISO-8859-1 round-trip
$latin1 = iconv("UTF-8", "ISO-8859-1", "hällo");
assert($latin1 !== false && iconv("ISO-8859-1", "UTF-8", $latin1) === "hällo");
assert(iconv_strlen("hällo", "UTF-8") === 5);

// pcntl fork + waitpid
$pid = pcntl_fork();
assert($pid !== -1);
if ($pid === 0) {
    exit(42);
}
$status = 0;
assert(pcntl_waitpid($pid, $status) === $pid);
assert(pcntl_wifexited($status) && pcntl_wexitstatus($status) === 42);

echo "FILC_PHP_DOCKER_SMOKE_OK\n";
EOF
)"
echo "$SCRIPT_OUT"
printf '%s\n' "$SCRIPT_OUT" | grep -Fxq "FILC_PHP_DOCKER_SMOKE_OK"

# 2. Verify prebuilt shared extensions exist and activate cleanly via docker-php-ext-enable
if [[ "$PHP_MAJOR" -ge 8 ]]; then
  SHARED_EXTS="mysqli pdo_mysql pgsql pdo_pgsql gmp soap"
  SHARED_OUT="$(docker run --rm "${IMAGE}" sh -eux -c '
    ext_dir="$(php -r "echo ini_get(\"extension_dir\");")"
    for ext in mysqli pdo_mysql pgsql pdo_pgsql gmp soap; do
      test -f "${ext_dir}/${ext}.so"
    done
    docker-php-ext-enable mysqli pdo_mysql pgsql pdo_pgsql gmp soap
    php -d display_startup_errors=1 -d display_errors=1 -d error_reporting=E_ALL -d zend.assertions=1 -d assert.exception=1 -r '\''
      foreach (["mysqli", "pdo_mysql", "pgsql", "pdo_pgsql", "gmp", "soap"] as $e) {
        assert(extension_loaded($e), "missing:$e");
      }
      $drivers = PDO::getAvailableDrivers();
      assert(in_array("mysql", $drivers, true));
      assert(in_array("pgsql", $drivers, true));
      assert(in_array("sqlite", $drivers, true));
      assert(gmp_strval(gmp_add("123456789012345678901234567890", "1")) === "123456789012345678901234567891");
      assert(class_exists("SoapClient") && class_exists("SoapServer"));
      echo "SHARED_EXTS_ENABLE_OK\n";
    '\''
  ' 2>&1)"
  echo "$SHARED_OUT"
  printf '%s\n' "$SHARED_OUT" | grep -Fxq "SHARED_EXTS_ENABLE_OK"
  if printf '%s\n' "$SHARED_OUT" | grep -Eq 'Warning:|Cannot load'; then
    echo "error: unexpected PHP startup warning while enabling shared extensions (${SHARED_EXTS})" >&2
    exit 1
  fi
else
  # Legacy PHP 5.6 and 7.x ports all ship opcache.so enabled by default.
  SHARED_OUT="$(docker run --rm "${IMAGE}" sh -eux -c '
    ext_dir="$(php -r "echo ini_get(\"extension_dir\");")"
    test -f "${ext_dir}/opcache.so"
    opt_exts=""
    for ext in mysqli pdo_mysql pgsql pdo_pgsql gmp soap; do
      if [ -f "${ext_dir}/${ext}.so" ]; then
        opt_exts="${opt_exts} ${ext}"
      fi
    done
    if [ -n "$opt_exts" ]; then
      docker-php-ext-enable $opt_exts
    fi
    cat > /tmp/filc-opcache-smoke.php <<'\''PHP'\''
<?php
if (PHP_VERSION_ID < 70000) {
    assert_options(ASSERT_ACTIVE, 1);
    assert_options(ASSERT_BAIL, 1);
    assert_options(ASSERT_WARNING, 1);
}
class FilcDockerOpcacheProbe {
    public $v = "ok";
    public function get() { return $this->v; }
}
$p = new FilcDockerOpcacheProbe();
assert($p->get() === "ok");
assert(extension_loaded("Zend OPcache"));
assert(in_array("Zend OPcache", get_loaded_extensions(true), true));
$op = opcache_get_status(true);
assert(is_array($op) && $op["opcache_enabled"] === true && isset($op["scripts"]) && count($op["scripts"]) >= 1);
assert(extension_loaded("json"));
$drivers = PDO::getAvailableDrivers();
assert(in_array("sqlite", $drivers, true));
echo "LEGACY_PHP_EXTS_OK\n";
PHP
    php -d display_startup_errors=1 -d display_errors=1 -d error_reporting=E_ALL '"${PHP_ASSERT_ARGS[*]:-}"' -d opcache.enable_cli=1 -d opcache.file_update_protection=0 /tmp/filc-opcache-smoke.php
    rm -f /tmp/filc-opcache-smoke.php
  ' 2>&1)"
  echo "$SHARED_OUT"
  printf '%s\n' "$SHARED_OUT" | grep -Fxq "LEGACY_PHP_EXTS_OK"
  if printf '%s\n' "$SHARED_OUT" | grep -Eq 'Warning:|Cannot load'; then
    echo "error: unexpected PHP startup warning on PHP ${PHP_SERIES}" >&2
    exit 1
  fi
fi

# 3. Verify unknown extension and PECL source dir fail clearly with Fil-C + -Wl,-Bsymbolic-functions hint
ERR_OUT="$(docker run --rm "${IMAGE}" sh -c 'docker-php-ext-install nonexistent_ext_filc 2>&1; echo "RC=$?"')"
printf '%s\n' "$ERR_OUT" | grep -Fq "RC=1"
printf '%s\n' "$ERR_OUT" | grep -Fqi "fil-c"
printf '%s\n' "$ERR_OUT" | grep -Fq -- "-Wl,-Bsymbolic-functions"
PECL_ERR_OUT="$(docker run --rm "${IMAGE}" sh -c 'mkdir -p /tmp/fake-pecl && : > /tmp/fake-pecl/config.m4 && docker-php-ext-install /tmp/fake-pecl 2>&1; echo "RC=$?"')"
printf '%s\n' "$PECL_ERR_OUT" | grep -Fq "RC=1"
printf '%s\n' "$PECL_ERR_OUT" | grep -Fq -- "-Wl,-Bsymbolic-functions"

# 4. Drop-in acceptance test (build a realistic downstream Dockerfile by only swapping FROM)
TMP_CTX="$(mktemp -d)"
DROPIN_TAG="filc-php-dropin-test:${PHP_SERIES}-${VARIANT}-$$"
cleanup_dropin() {
  docker rmi -f "$DROPIN_TAG" >/dev/null 2>&1 || true
  rm -rf "$TMP_CTX"
}
trap cleanup_dropin EXIT

if [[ "$PHP_MAJOR" -ge 8 ]]; then
  DROPIN_CLI_EXTS="intl bcmath exif opcache sockets pcntl mysqli pdo_mysql pgsql pdo_pgsql gmp soap"
  DROPIN_FPM_EXTS="intl bcmath opcache mysqli pdo_mysql pgsql pdo_pgsql gmp soap"
else
  DROPIN_CLI_EXTS="intl bcmath exif opcache sockets pcntl"
  DROPIN_FPM_EXTS="intl bcmath opcache"
fi

if [[ "$VARIANT" == "cli" ]]; then
  cat > "${TMP_CTX}/app.php" <<'EOF'
<?php
echo json_encode([
    'sapi' => PHP_SAPI,
    'memory_limit' => ini_get('memory_limit'),
    'intl' => extension_loaded('intl'),
    'bcmath' => extension_loaded('bcmath'),
    'exif' => extension_loaded('exif'),
    'sockets' => extension_loaded('sockets'),
    'pcntl' => extension_loaded('pcntl'),
    'iconv' => extension_loaded('iconv'),
    'dom' => extension_loaded('dom'),
    'simplexml' => extension_loaded('SimpleXML'),
    'xmlwriter' => extension_loaded('xmlwriter'),
    'opcache' => extension_loaded('Zend OPcache'),
    'mysqli' => extension_loaded('mysqli'),
    'pdo_mysql' => extension_loaded('pdo_mysql'),
    'pgsql' => extension_loaded('pgsql'),
    'pdo_pgsql' => extension_loaded('pdo_pgsql'),
    'gmp' => extension_loaded('gmp'),
    'soap' => extension_loaded('soap'),
    'pdo_drivers' => PDO::getAvailableDrivers(),
]) . "\n";
EOF
  cat > "${TMP_CTX}/Dockerfile" <<EOF
FROM ${IMAGE}
RUN cp "\$PHP_INI_DIR/php.ini-production" "\$PHP_INI_DIR/php.ini" && \\
    printf 'memory_limit=256M\n' > "\$PHP_INI_DIR/conf.d/99-app.ini" && \\
    docker-php-source extract && \\
    docker-php-ext-configure intl && \\
    docker-php-ext-install -j2 ${DROPIN_CLI_EXTS} && \\
    docker-php-source delete
WORKDIR /app
COPY app.php /app/app.php
CMD ["php", "/app/app.php"]
EOF
  docker build -q -t "$DROPIN_TAG" "$TMP_CTX" >/dev/null
  DROPIN_OUT="$(docker run --rm "$DROPIN_TAG" 2>&1)"
  echo "Drop-in CLI app output: $DROPIN_OUT"
  if printf '%s\n' "$DROPIN_OUT" | grep -Eq 'Warning:|Cannot load'; then
    echo "error: unexpected PHP warning in Drop-in CLI app" >&2
    exit 1
  fi
  printf '%s\n' "$DROPIN_OUT" | grep -Fq '"memory_limit":"256M"'
  printf '%s\n' "$DROPIN_OUT" | grep -Fq '"intl":true'
  printf '%s\n' "$DROPIN_OUT" | grep -Fq '"pcntl":true'
  printf '%s\n' "$DROPIN_OUT" | grep -Fq '"iconv":true'
  printf '%s\n' "$DROPIN_OUT" | grep -Fq '"dom":true'
  printf '%s\n' "$DROPIN_OUT" | grep -Fq '"simplexml":true'
  printf '%s\n' "$DROPIN_OUT" | grep -Fq '"xmlwriter":true'
  printf '%s\n' "$DROPIN_OUT" | grep -Fq '"opcache":true'
  if [[ "$PHP_MAJOR" -ge 8 ]]; then
    printf '%s\n' "$DROPIN_OUT" | grep -Fq '"mysqli":true'
    printf '%s\n' "$DROPIN_OUT" | grep -Fq '"pdo_mysql":true'
    printf '%s\n' "$DROPIN_OUT" | grep -Fq '"pgsql":true'
    printf '%s\n' "$DROPIN_OUT" | grep -Fq '"pdo_pgsql":true'
    printf '%s\n' "$DROPIN_OUT" | grep -Fq '"gmp":true'
    printf '%s\n' "$DROPIN_OUT" | grep -Fq '"soap":true'
  fi
elif [[ "$VARIANT" == "fpm" ]]; then
  docker run --rm "${IMAGE}" sh -eu -c '
    test -x /usr/local/sbin/php-fpm
    test -f /usr/local/etc/php/php-fpm.conf
    test -f /usr/local/etc/php/php-fpm.d/www.conf
    test -f /usr/local/etc/php/php-fpm.d/docker.conf
    test -f /usr/local/etc/php/php-fpm.d/zz-docker.conf
  '
  FPM_VER="$(docker run --rm "${IMAGE}" php-fpm -v)"
  echo "$FPM_VER"
  printf '%s\n' "$FPM_VER" | head -n 1 | grep -Eq "^PHP ${PHP_SERIES//./\\.}\."

  echo "Running php-fpm config test (-t) ..."
  docker run --rm "${IMAGE}" php-fpm -t

  cat > "${TMP_CTX}/index.php" <<'EOF'
<?php echo "OK\n";
EOF
  cat > "${TMP_CTX}/Dockerfile" <<EOF
FROM ${IMAGE}
RUN cp "\$PHP_INI_DIR/php.ini-production" "\$PHP_INI_DIR/php.ini" && \\
    printf 'memory_limit=256M\n' > "\$PHP_INI_DIR/conf.d/99-app.ini" && \\
    printf '[www]\npm.max_children = 8\n' > "\$PHP_INI_DIR/php-fpm.d/zz-app.conf" && \\
    docker-php-ext-install ${DROPIN_FPM_EXTS}
COPY index.php /var/www/html/index.php
EOF
  docker build -q -t "$DROPIN_TAG" "$TMP_CTX" >/dev/null
  FPM_TEST_OUT="$(docker run --rm "$DROPIN_TAG" php-fpm -t 2>&1)"
  echo "$FPM_TEST_OUT"
  if printf '%s\n' "$FPM_TEST_OUT" | grep -Eq 'Warning:|Cannot load'; then
    echo "error: unexpected warning in Drop-in FPM config test" >&2
    exit 1
  fi
  FPM_MODS="$(docker run --rm "$DROPIN_TAG" php-fpm -m 2>&1)"
  if [[ "$PHP_MAJOR" -ge 8 ]]; then
    for ext in mysqli pdo_mysql pgsql pdo_pgsql gmp soap; do
      printf '%s\n' "$FPM_MODS" | grep -Fxiq "$ext" || {
        echo "error: expected shared extension missing in php-fpm -m: $ext" >&2
        exit 1
      }
    done
  else
    FPM_REQUIRED=("Zend OPcache" openssl intl iconv dom SimpleXML xmlwriter pcntl json)
    for ext in "${FPM_REQUIRED[@]}"; do
      printf '%s\n' "$FPM_MODS" | grep -Fxiq "$ext" || {
        echo "error: expected extension missing in php-fpm -m: $ext" >&2
        exit 1
      }
    done
  fi
  # Start php-fpm briefly as default CMD and confirm clean startup + SIGQUIT stop
  CID="$(docker run -d "$DROPIN_TAG")"
  sleep 2
  STATE="$(docker inspect -f '{{.State.Running}}' "$CID")"
  if [[ "$STATE" != "true" ]]; then
    echo "error: php-fpm container exited prematurely:" >&2
    docker logs "$CID" >&2 || true
    docker rm -f "$CID" >/dev/null 2>&1 || true
    exit 1
  fi
  docker stop -t 5 "$CID" >/dev/null
  docker rm -f "$CID" >/dev/null 2>&1 || true
  echo "Drop-in FPM app startup & SIGQUIT shutdown OK"
fi

echo "SMOKE_OK: ${IMAGE}"
