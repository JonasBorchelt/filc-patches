#!/usr/bin/env bash
# Verified Fil-C runtime + PHP port installer for container image builds.
#
# Uses the official filc.connected.link install.sh path with:
#   - Pinned minisign public key verification (index.json + SHA256SUMS + tarballs)
#   - Channel PROVENANCE version check (aborts on mismatch)
#   - Dedicated CI User-Agent (filc-image-ci/<version>) so image builds do not
#     inflate public port download counters
#   - Runtime-only staging into the output root (omits Clang/LLVM, headers, .a)

set -euo pipefail

STAGE_ROOT="${1:?usage: install-filc-php.sh <stage-root>}"
PHP_VERSION="${PHP_VERSION:?PHP_VERSION is required (e.g. 8.5)}"
FILC_CHANNEL="${FILC_CHANNEL:-0.1.5}"
FILC_BASE_URL="${FILC_BASE_URL:-https://filc.connected.link}"
FILC_BASE_URL="${FILC_BASE_URL%/}"
FILC_GITHUB_RELEASE_URL="${FILC_GITHUB_RELEASE_URL:-https://github.com/JonasBorchelt/filc-patches/releases/download/v${FILC_CHANNEL}}"
FILC_USER_AGENT="${FILC_USER_AGENT:-filc-image-ci/${PHP_VERSION}}"

if [[ ! "$PHP_VERSION" =~ ^[0-9]+\.[0-9]+$ ]]; then
  echo "error: invalid PHP_VERSION: $PHP_VERSION" >&2
  exit 1
fi
if [[ ! "$FILC_CHANNEL" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[a-z0-9.]+)?$ ]]; then
  echo "error: invalid FILC_CHANNEL: $FILC_CHANNEL" >&2
  exit 1
fi

# Extract pinned minisign public key from repository pubkey file when provided.
if [[ -n "${FILC_PUBKEY_FILE:-}" && -f "${FILC_PUBKEY_FILE}" ]]; then
  PUBKEY_FROM_FILE="$(awk 'NR == 2 { print $1; exit }' "${FILC_PUBKEY_FILE}")"
  if [[ -n "$PUBKEY_FROM_FILE" ]]; then
    FILC_PORTS_PUBKEY="$PUBKEY_FROM_FILE"
  fi
fi
if [[ -z "${FILC_PORTS_PUBKEY:-}" ]]; then
  echo "error: FILC_PORTS_PUBKEY must not be empty" >&2
  exit 1
fi

TMP_WORK="$(mktemp -d)"
cleanup() {
  rm -rf "$TMP_WORK"
}
trap cleanup EXIT

# Force dedicated CI User-Agent across all curl calls (works both with
# FILC_USER_AGENT-aware install.sh and older versions via CURL_HOME/.curlrc).
export CURL_HOME="$TMP_WORK/curl"
mkdir -p "$CURL_HOME"
printf 'user-agent = "%s"\n' "$FILC_USER_AGENT" > "$CURL_HOME/.curlrc"

export FILC_ROOT="/opt/filc/${FILC_CHANNEL}"
export FILC_BASE_URL
export FILC_PORTS_PUBKEY
export FILC_USER_AGENT
export FILC_GITHUB_LATEST_URL="${FILC_GITHUB_RELEASE_URL%/}"

INSTALL_SH="$TMP_WORK/install.sh"
echo "Fetching installer from ${FILC_BASE_URL}/install.sh (UA=${FILC_USER_AGENT}) ..."
curl -fsSL "${FILC_BASE_URL}/install.sh" -o "$INSTALL_SH"

# 1. Install pinned Fil-C toolchain channel and verify PROVENANCE matches exactly.
echo "Installing Fil-C toolchain channel ${FILC_CHANNEL} into ${FILC_ROOT} ..."
bash "$INSTALL_SH"

if [[ ! -f "${FILC_ROOT}/PROVENANCE" ]]; then
  echo "error: missing ${FILC_ROOT}/PROVENANCE after toolchain installation" >&2
  exit 1
fi
ACTUAL_VERSION="$(awk -F= '$1 == "VERSION" { print $2; exit }' "${FILC_ROOT}/PROVENANCE" | tr -d '\r')"
if [[ "$ACTUAL_VERSION" != "$FILC_CHANNEL" ]]; then
  echo "error: toolchain PROVENANCE VERSION=${ACTUAL_VERSION} != expected FILC_CHANNEL=${FILC_CHANNEL}" >&2
  exit 1
fi

# 2. Install PHP port + transitive dependencies via signed channel index.
# install.sh strictly verifies index.json.minisig, SHA256SUMS.minisig,
# index.json digest, and every downloaded package SHA-256 against FILC_PORTS_PUBKEY.
PHP_PORT="php${PHP_VERSION}"
echo "Installing verified port ${PHP_PORT} from ${FILC_BASE_URL}/ports/${FILC_CHANNEL} ..."
bash "$INSTALL_SH" "$PHP_PORT"

# 3. Stage minimal runtime files (no Clang/LLVM compiler, headers, .a, manpages).
DST_ROOT="${STAGE_ROOT}/opt/filc/${FILC_CHANNEL}"
DST_PIZFIX="${DST_ROOT}/pizfix"
SRC_PIZFIX="${FILC_ROOT}/pizfix"

mkdir -p \
  "${DST_PIZFIX}/bin" \
  "${DST_PIZFIX}/sbin" \
  "${DST_PIZFIX}/lib" \
  "${DST_PIZFIX}/etc/php${PHP_VERSION}/conf.d" \
  "${DST_PIZFIX}/etc/php${PHP_VERSION}/php-fpm.d" \
  "${DST_PIZFIX}/var/php${PHP_VERSION}/run" \
  "${DST_PIZFIX}/var/php${PHP_VERSION}/log"

for meta in PROVENANCE NOTICE; do
  if [[ -f "${FILC_ROOT}/${meta}" ]]; then
    cp -a "${FILC_ROOT}/${meta}" "${DST_ROOT}/${meta}"
  fi
done
if [[ -d "${FILC_ROOT}/LICENSES" ]]; then
  cp -a "${FILC_ROOT}/LICENSES" "${DST_ROOT}/LICENSES"
fi

# Copy Fil-C runtime and port shared libraries (skip static archives and CRT objects).
shopt -s nullglob
for lib in "${SRC_PIZFIX}/lib"/*.so "${SRC_PIZFIX}/lib"/*.so.*; do
  cp -a "$lib" "${DST_PIZFIX}/lib/"
done
for subdir in "php${PHP_VERSION}" ossl-modules engines-3 engines-1.1; do
  if [[ -d "${SRC_PIZFIX}/lib/${subdir}" ]]; then
    cp -a "${SRC_PIZFIX}/lib/${subdir}" "${DST_PIZFIX}/lib/"
  fi
done

# Copy PHP binaries.
for bin in "php${PHP_VERSION}" "php-cgi${PHP_VERSION}" "phpdbg${PHP_VERSION}"; do
  if [[ -e "${SRC_PIZFIX}/bin/${bin}" ]]; then
    cp -a "${SRC_PIZFIX}/bin/${bin}" "${DST_PIZFIX}/bin/"
  fi
done
if [[ -e "${SRC_PIZFIX}/sbin/php-fpm${PHP_VERSION}" ]]; then
  cp -a "${SRC_PIZFIX}/sbin/php-fpm${PHP_VERSION}" "${DST_PIZFIX}/sbin/"
fi
if [[ ! -x "${DST_PIZFIX}/bin/php${PHP_VERSION}" ]]; then
  echo "error: missing ${DST_PIZFIX}/bin/php${PHP_VERSION} after port installation" >&2
  exit 1
fi
if [[ ! -x "${DST_PIZFIX}/sbin/php-fpm${PHP_VERSION}" ]]; then
  echo "error: missing ${DST_PIZFIX}/sbin/php-fpm${PHP_VERSION} after port installation" >&2
  exit 1
fi

# Copy PHP etc/share trees if present.
if [[ -d "${SRC_PIZFIX}/etc/php${PHP_VERSION}" ]]; then
  cp -a "${SRC_PIZFIX}/etc/php${PHP_VERSION}/." "${DST_PIZFIX}/etc/php${PHP_VERSION}/"
fi
if [[ -d "${SRC_PIZFIX}/share/php${PHP_VERSION}" ]]; then
  mkdir -p "${DST_PIZFIX}/share"
  cp -a "${SRC_PIZFIX}/share/php${PHP_VERSION}" "${DST_PIZFIX}/share/"
fi
if [[ -d "${SRC_PIZFIX}/etc/ssl" ]]; then
  mkdir -p "${DST_PIZFIX}/etc"
  cp -a "${SRC_PIZFIX}/etc/ssl" "${DST_PIZFIX}/etc/"
fi

# Enable loadable OPcache extension on PHP 8.2-8.4 (PHP 8.5 has OPcache built-in).
if [[ -f "${DST_PIZFIX}/lib/php${PHP_VERSION}/extensions/opcache.so" ]]; then
  printf 'zend_extension=opcache\n' > "${DST_PIZFIX}/etc/php${PHP_VERSION}/conf.d/10-opcache.ini"
fi

echo "Staged minimal Fil-C PHP ${PHP_VERSION} runtime into ${DST_ROOT}"
