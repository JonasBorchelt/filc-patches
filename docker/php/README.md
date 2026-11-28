# Unofficial PHP built with Fil-C (`jonasborchelt/filc-php`)

**Unofficial PHP built with Fil-C (memory-safe). Toolchain and ports: https://filc.connected.link**

Drop-in container images for memory-safe PHP compiled with [Fil-C](https://filc.connected.link) (hardware-independent C/C++ memory safety via capability pointers and garbage-collected runtime checks), modeled after the official Debian `php` Docker images so existing Dockerfiles only need to swap `FROM php:8.x-...` for `FROM jonasborchelt/filc-php:8.x-...`.

## Tags

| Series | CLI tags | FPM tags | Support |
|---|---|---|---|
| PHP 8.5 | `8.5-cli`, `8.5`, `8.5.13-cli`, `8.5.13`, `latest` | `8.5-fpm`, `8.5.13-fpm` | active |
| PHP 8.4 | `8.4-cli`, `8.4`, `8.4.28-cli`, `8.4.28` | `8.4-fpm`, `8.4.28-fpm` | active |
| PHP 8.3 | `8.3-cli`, `8.3`, `8.3.37-cli`, `8.3.37` | `8.3-fpm`, `8.3.37-fpm` | active |
| PHP 8.2 | `8.2-cli`, `8.2`, `8.2.36-cli`, `8.2.36` | `8.2-fpm`, `8.2.36-fpm` | active |
| PHP 7.4 (Freexian ELTS) | `7.4-cli`, `7.4`, `7.4.33-cli`, `7.4.33` | `7.4-fpm`, `7.4.33-fpm` | eol (Freexian ELTS, OpenSSL 1.1.1w) |
| PHP 7.3 (Freexian ELTS) | `7.3-cli`, `7.3`, `7.3.31-cli`, `7.3.31` | `7.3-fpm`, `7.3.31-fpm` | eol (Freexian ELTS, OpenSSL 1.1.1w) |
| PHP 7.0 (Freexian ELTS) | `7.0-cli`, `7.0`, `7.0.33-cli`, `7.0.33` | `7.0-fpm`, `7.0.33-fpm` | eol (Freexian ELTS, OpenSSL 1.1.1w) |
| PHP 5.6 (Freexian ELTS) | `5.6-cli`, `5.6`, `5.6.40-cli`, `5.6.40` | `5.6-fpm`, `5.6.40-fpm` | eol (Freexian ELTS, OpenSSL 1.1.1w, static pecl-jsonc, no opcache) |

Legacy PHP 7.4, 7.3, 7.0, and 5.6 images are built from Freexian Extended LTS sources with backported CVE patches and OpenSSL 1.1.1w, labeled `support=eol`, and controlled by the workflow's `ENABLE_LEGACY_PHP` switch (`false` while channel 0.1.7 revision 2 fixes legacy callback signatures and PHP 5.6 OPcache).

## Drop-In Compatibility

- Official paths and environment variables: `/usr/local/bin/php`, `/usr/local/sbin/php-fpm`, `PHP_INI_DIR=/usr/local/etc/php` with `php.ini-development`, `php.ini-production`, `conf.d/`, and `php-fpm.d/` (`www.conf`, `docker.conf`, `zz-docker.conf`).
- Official `docker-php-entrypoint`, `WORKDIR /var/www/html`, `STOPSIGNAL SIGQUIT`, `EXPOSE 9000`, and `www-data` worker user for FPM.
- Drop-in helper commands: `docker-php-ext-install`, `docker-php-ext-enable`, `docker-php-ext-configure`, and `docker-php-source`. Prebuilt Fil-C extensions are activated without invoking a C compiler; unavailable extensions exit with a clear Fil-C guidance message.
- Prebuilt loadable shared extensions ready for `docker-php-ext-enable` / `docker-php-ext-install`: `mysqli`, `pdo_mysql`, `pgsql`, `pdo_pgsql`, `gmp`, and `soap` (plus built-in `openssl`, `curl`, `sqlite3`, `pdo_sqlite`, `intl`, `mbstring`, `sodium`, `bcmath`, `exif`, `pcntl`, `sockets`, `zlib`, `bz2`, and `opcache`).

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

Swap `FROM` in an existing Dockerfile:

```dockerfile
FROM jonasborchelt/filc-php:8.5-fpm
RUN cp "$PHP_INI_DIR/php.ini-production" "$PHP_INI_DIR/php.ini" && \
    docker-php-ext-install pdo_mysql mysqli pdo_pgsql pgsql gmp soap intl bcmath opcache
COPY . /var/www/html
```

## Supply-Chain Verification

During build, the builder stage downloads the Fil-C runtime and PHP port packages from the pinned channel on `https://filc.connected.link` via `install.sh`, verifies the minisign signatures on `index.json` and `SHA256SUMS` against the pinned public key (`ports/ports-pubkey.pub`), and verifies the SHA-256 digest of every package archive before extracting. The final runtime stage contains only the Fil-C runtime libraries and PHP binaries (no compiler toolchain or build tools).
