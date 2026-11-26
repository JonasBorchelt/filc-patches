#!/usr/bin/env bash
# Smoke-test a built filc-php Docker image (cli or fpm) before push.
#
# Usage: docker/php/smoke.sh <image-ref> <php-series> <variant>
# Example: docker/php/smoke.sh jonasborchelt/filc-php:8.5-cli 8.5 cli

set -euo pipefail

IMAGE="${1:?usage: smoke.sh <image-ref> <php-series> <variant>}"
PHP_SERIES="${2:?usage: smoke.sh <image-ref> <php-series> <variant>}"
VARIANT="${3:?usage: smoke.sh <image-ref> <php-series> <variant>}"

echo "=== Smoke-testing ${IMAGE} (PHP ${PHP_SERIES}, variant=${VARIANT}) ==="

VER_OUT="$(docker run --rm "${IMAGE}" php -v)"
echo "$VER_OUT"
printf '%s\n' "$VER_OUT" | head -n 1 | grep -Eq "^PHP ${PHP_SERIES//./\\.}\."

MOD_OUT="$(docker run --rm "${IMAGE}" php -m)"
echo "Loaded modules: $(printf '%s' "$MOD_OUT" | tr '\n' ' ')"
for mod in openssl sqlite3 pdo_sqlite curl mbstring intl sodium bcmath json pcre zlib; do
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

if [[ "$VARIANT" == "fpm" ]]; then
  FPM_VER="$(docker run --rm "${IMAGE}" php-fpm -v)"
  echo "$FPM_VER"
  printf '%s\n' "$FPM_VER" | head -n 1 | grep -Eq "^PHP ${PHP_SERIES//./\\.}\."

  echo "Running php-fpm config test (-t) ..."
  docker run --rm "${IMAGE}" php-fpm -t
fi

echo "SMOKE_OK: ${IMAGE}"
