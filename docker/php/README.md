# Unofficial PHP built with Fil-C (`jonasborchelt/filc-php`)

**Unofficial PHP built with Fil-C (memory-safe). Toolchain and ports: https://filc.connected.link**

Drop-in container images for memory-safe PHP compiled with [Fil-C](https://filc.connected.link) (hardware-independent C/C++ memory safety via capability pointers and garbage-collected runtime checks), modeled after the official Debian `php` Docker images so existing Dockerfiles only need to swap `FROM php:8.x-...` for `FROM jonasborchelt/filc-php:8.x-...`.

## Tags

| Series | CLI tags | FPM tags |
|---|---|---|
| PHP 8.5 | `8.5-cli`, `8.5`, `8.5.13-cli`, `8.5.13`, `latest` | `8.5-fpm`, `8.5.13-fpm` |
| PHP 8.4 | `8.4-cli`, `8.4`, `8.4.28-cli`, `8.4.28` | `8.4-fpm`, `8.4.28-fpm` |
| PHP 8.3 | `8.3-cli`, `8.3`, `8.3.37-cli`, `8.3.37` | `8.3-fpm`, `8.3.37-fpm` |
| PHP 8.2 | `8.2-cli`, `8.2`, `8.2.36-cli`, `8.2.36` | `8.2-fpm`, `8.2.36-fpm` |

## Drop-In Compatibility

- Official paths and environment variables: `/usr/local/bin/php`, `/usr/local/sbin/php-fpm`, `PHP_INI_DIR=/usr/local/etc/php` with `php.ini-development`, `php.ini-production`, `conf.d/`, and `php-fpm.d/` (`www.conf`, `docker.conf`, `zz-docker.conf`).
- Official `docker-php-entrypoint`, `WORKDIR /var/www/html`, `STOPSIGNAL SIGQUIT`, `EXPOSE 9000`, and `www-data` worker user for FPM.
- Drop-in helper commands: `docker-php-ext-install`, `docker-php-ext-enable`, `docker-php-ext-configure`, and `docker-php-source`. Prebuilt Fil-C extensions are activated without invoking a C compiler; unavailable extensions exit with a clear Fil-C guidance message.

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
    docker-php-ext-install intl bcmath exif opcache sockets pcntl
COPY . /var/www/html
```

## Supply-Chain Verification

During build, the builder stage downloads the Fil-C runtime and PHP port packages from the pinned channel on `https://filc.connected.link` via `install.sh`, verifies the minisign signatures on `index.json` and `SHA256SUMS` against the pinned public key (`ports/ports-pubkey.pub`), and verifies the SHA-256 digest of every package archive before extracting. The final runtime stage contains only the Fil-C runtime libraries and PHP binaries (no compiler toolchain or build tools).
