#!/usr/bin/env bash
# Smoke-test and drop-in acceptance test for a built filc-php Docker image.
#
# Usage: docker/php/smoke.sh <image-ref> <php-series> <variant>
# Example: docker/php/smoke.sh jonasborchelt/filc-php:8.5-cli 8.5 cli

set -euo pipefail

IMAGE="${1:?usage: smoke.sh <image-ref> <php-series> <variant>}"
PHP_SERIES="${2:?usage: smoke.sh <image-ref> <php-series> <variant>}"
VARIANT="${3:?usage: smoke.sh <image-ref> <php-series> <variant>}"

echo "=== Smoke-testing ${IMAGE} (PHP ${PHP_SERIES}, variant=${VARIANT}) ==="

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

RC=0
MOD_OUT="$(docker run --rm "${IMAGE}" php -m 2>&1)" || RC=$?
echo "php -m (rc=${RC}): $(printf '%s' "$MOD_OUT" | tr '\n' ' ')"
if [[ "$RC" -ne 0 ]]; then
  exit "$RC"
fi
for mod in openssl sqlite3 pdo_sqlite curl mbstring intl sodium bcmath exif pcntl sockets json pcre zlib; do
  printf '%s\n' "$MOD_OUT" | grep -Fxiq "$mod" || {
    echo "error: expected PHP module missing: $mod" >&2
    exit 1
  }
done

SCRIPT_OUT="$(docker run --rm -i "${IMAGE}" php -d zend.assertions=1 -d assert.exception=1 -d opcache.enable_cli=1 <<'EOF'
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

assert(hash("sha256", "hello\n") === "5891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be03");
assert(openssl_digest("hello\n", "sha256") === "5891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be03");
assert(mb_strlen("hällo", "UTF-8") === 5);
assert(strlen(sodium_crypto_generichash("filc")) === SODIUM_CRYPTO_GENERICHASH_BYTES);
assert(opcache_get_status(false)["opcache_enabled"] === true);

$db = new SQLite3(":memory:");
$db->exec("CREATE TABLE t (v INT); INSERT INTO t VALUES (42);");
assert($db->querySingle("SELECT v FROM t") === 42);
$db->close();

echo "FILC_PHP_DOCKER_SMOKE_OK\n";
EOF
)"
echo "$SCRIPT_OUT"
printf '%s\n' "$SCRIPT_OUT" | grep -Fxq "FILC_PHP_DOCKER_SMOKE_OK"

# 2. Verify all 6 prebuilt shared extensions exist and activate cleanly via docker-php-ext-enable
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

# 3. Verify unknown extension fails clearly with Fil-C hint
ERR_OUT="$(docker run --rm "${IMAGE}" sh -c 'docker-php-ext-install nonexistent_ext_filc 2>&1; echo "RC=$?"')"
printf '%s\n' "$ERR_OUT" | grep -Fq "RC=1"
printf '%s\n' "$ERR_OUT" | grep -Fqi "fil-c"

# 4. Drop-in acceptance test (build a realistic downstream Dockerfile by only swapping FROM)
TMP_CTX="$(mktemp -d)"
DROPIN_TAG="filc-php-dropin-test:${PHP_SERIES}-${VARIANT}-$$"
cleanup_dropin() {
  docker rmi -f "$DROPIN_TAG" >/dev/null 2>&1 || true
  rm -rf "$TMP_CTX"
}
trap cleanup_dropin EXIT

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
    docker-php-ext-install -j2 intl bcmath exif opcache sockets pcntl mysqli pdo_mysql pgsql pdo_pgsql gmp soap && \\
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
  printf '%s\n' "$DROPIN_OUT" | grep -Fq '"opcache":true'
  printf '%s\n' "$DROPIN_OUT" | grep -Fq '"mysqli":true'
  printf '%s\n' "$DROPIN_OUT" | grep -Fq '"pdo_mysql":true'
  printf '%s\n' "$DROPIN_OUT" | grep -Fq '"pgsql":true'
  printf '%s\n' "$DROPIN_OUT" | grep -Fq '"pdo_pgsql":true'
  printf '%s\n' "$DROPIN_OUT" | grep -Fq '"gmp":true'
  printf '%s\n' "$DROPIN_OUT" | grep -Fq '"soap":true'
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
    docker-php-ext-install intl bcmath opcache mysqli pdo_mysql pgsql pdo_pgsql gmp soap
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
  for ext in mysqli pdo_mysql pgsql pdo_pgsql gmp soap; do
    printf '%s\n' "$FPM_MODS" | grep -Fxiq "$ext" || {
      echo "error: expected shared extension missing in php-fpm -m: $ext" >&2
      exit 1
    }
  done
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
