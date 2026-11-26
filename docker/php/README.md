# Fil-C PHP Docker Images (`jonasborchelt/filc-php`)

Memory-safe PHP container images compiled with [Fil-C](https://filc.connected.link) (hardware-independent C/C++ memory safety via capability pointers and garbage-collected runtime checks), modeled after the official `php` Docker images.

## Tags

| Series | CLI tags | FPM tags |
|---|---|---|
| PHP 8.5 | `8.5-cli`, `8.5`, `8.5.13-cli`, `8.5.13`, `latest` | `8.5-fpm`, `8.5.13-fpm` |
| PHP 8.4 | `8.4-cli`, `8.4`, `8.4.28-cli`, `8.4.28` | `8.4-fpm`, `8.4.28-fpm` |
| PHP 8.3 | `8.3-cli`, `8.3`, `8.3.37-cli`, `8.3.37` | `8.3-fpm`, `8.3.37-fpm` |
| PHP 8.2 | `8.2-cli`, `8.2`, `8.2.36-cli`, `8.2.36` | `8.2-fpm`, `8.2.36-fpm` |

## Usage

Run a CLI script:

```bash
docker run --rm jonasborchelt/filc-php:8.5-cli php -v
docker run --rm -v "$PWD:/app" -w /app jonasborchelt/filc-php:8.5-cli php script.php
```

Run PHP-FPM on port `9000`:

```bash
docker run --rm -p 9000:9000 -v "$PWD:/var/www/html" jonasborchelt/filc-php:8.5-fpm
```

Custom INI files can be mounted under `/usr/local/etc/php/conf.d/` (`PHP_INI_DIR`), matching the official PHP image layout.

## Supply-Chain Verification

During build, the builder stage downloads the Fil-C runtime and PHP port packages from the pinned channel on `https://filc.connected.link` via `install.sh`, verifies the minisign signatures on `index.json` and `SHA256SUMS` against the pinned public key (`ports/ports-pubkey.pub`), and verifies the SHA-256 digest of every package archive before extracting. The final runtime stage contains only the Fil-C runtime libraries and PHP binaries (no compiler toolchain or build tools).

## Local Build & Smoke Test

```bash
docker build -f docker/php/Dockerfile \
  --target cli \
  --build-arg PHP_VERSION=8.5 \
  --build-arg PHP_FULL_VERSION=8.5.13 \
  --build-arg FILC_CHANNEL=0.1.5 \
  -t filc-php:8.5-cli .

bash docker/php/smoke.sh filc-php:8.5-cli 8.5 cli
```
