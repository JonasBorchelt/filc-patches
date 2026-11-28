# syntax=docker/dockerfile:1.7

ARG DEBIAN_IMAGE=debian:trixie-slim

FROM ${DEBIAN_IMAGE} AS builder

ARG PHP_VERSION=8.5
ARG FILC_CHANNEL=0.1.7
ARG FILC_BASE_URL=https://filc.connected.link
ARG FILC_GITHUB_RELEASE_URL=
ARG FILC_PORTS_PUBKEY=RWT2dYx3VZcu1VQHTUZVtNBb3pczC9wO94+zUWYQt2gE0+I8KuF3PGy/
ARG FILC_USER_AGENT=

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update -qq && \
    apt-get install -y -qq --no-install-recommends \
      bash ca-certificates coreutils curl linux-libc-dev mawk minisign patchelf tar xz-utils && \
    rm -rf /var/lib/apt/lists/*

COPY ports/ports-pubkey.pub /tmp/ports-pubkey.pub
COPY docker/php/install-filc-php.sh /tmp/install-filc-php.sh

RUN chmod 0755 /tmp/install-filc-php.sh && \
    PHP_VERSION="${PHP_VERSION}" \
    FILC_CHANNEL="${FILC_CHANNEL}" \
    FILC_BASE_URL="${FILC_BASE_URL}" \
    FILC_GITHUB_RELEASE_URL="${FILC_GITHUB_RELEASE_URL}" \
    FILC_PORTS_PUBKEY="${FILC_PORTS_PUBKEY}" \
    FILC_PUBKEY_FILE="/tmp/ports-pubkey.pub" \
    FILC_USER_AGENT="${FILC_USER_AGENT:-filc-image-ci/${PHP_VERSION}}" \
    /tmp/install-filc-php.sh /runtime && \
    rm -f /tmp/install-filc-php.sh /tmp/ports-pubkey.pub

FROM ${DEBIAN_IMAGE} AS base

ARG PHP_VERSION=8.5
ARG PHP_FULL_VERSION=8.5.13
ARG FILC_CHANNEL=0.1.7
ARG SUPPORT_TIER=active

ENV DEBIAN_FRONTEND=noninteractive \
    FILC_CHANNEL="${FILC_CHANNEL}" \
    PHP_SERIES="${PHP_VERSION}"
# Fil-C 0.1.6 marks pizlonatedFIP<sig>_* hidden in FilPizlonator; keep
# -Wl,-Bsymbolic-functions as a harmless compatibility safety net for older
# channels or custom PECL builds.
ENV PHP_VERSION="${PHP_FULL_VERSION}" \
    PHP_INI_DIR="/usr/local/etc/php" \
    PHP_CFLAGS="-O2" \
    PHP_CPPFLAGS="-O2" \
    PHP_LDFLAGS="-Wl,-Bsymbolic-functions" \
    SSL_CERT_FILE="/etc/ssl/certs/ca-certificates.crt" \
    SSL_CERT_DIR="/etc/ssl/certs" \
    PATH="/usr/local/sbin:/usr/local/bin:/opt/filc/${FILC_CHANNEL}/pizfix/bin:/usr/sbin:/usr/bin:/sbin:/bin"

LABEL org.opencontainers.image.vendor="filc-patches" \
      org.opencontainers.image.source="https://github.com/JonasBorchelt/filc-patches" \
      org.opencontainers.image.url="https://filc.connected.link" \
      org.opencontainers.image.documentation="https://filc.connected.link" \
      org.opencontainers.image.description="Unofficial PHP built with Fil-C (memory-safe). Toolchain and ports: https://filc.connected.link" \
      org.opencontainers.image.licenses="PHP-3.01 AND Apache-2.0 WITH LLVM-exception AND BSD-2-Clause AND MIT" \
      org.opencontainers.image.version="${PHP_FULL_VERSION}" \
      dev.filc.channel="${FILC_CHANNEL}" \
      dev.filc.php.series="${PHP_SERIES}" \
      support="${SUPPORT_TIER}"

RUN apt-get update -qq && \
    apt-get install -y -qq --no-install-recommends ca-certificates tzdata && \
    rm -rf /var/lib/apt/lists/* && \
    mkdir -p /var/www/html && \
    chown www-data:www-data /var/www/html && \
    chmod 1777 /var/www/html

COPY --from=builder /runtime/opt/filc /opt/filc
COPY docker/php/docker-php-entrypoint /usr/local/bin/docker-php-entrypoint
COPY docker/php/docker-php-ext-install /usr/local/bin/docker-php-ext-install
COPY docker/php/docker-php-ext-enable /usr/local/bin/docker-php-ext-enable
COPY docker/php/docker-php-ext-configure /usr/local/bin/docker-php-ext-configure
COPY docker/php/docker-php-source /usr/local/bin/docker-php-source
COPY docker/php/ini/php.ini-development /tmp/php.ini-development
COPY docker/php/ini/php.ini-production /tmp/php.ini-production

RUN chmod 0755 \
      /usr/local/bin/docker-php-entrypoint \
      /usr/local/bin/docker-php-ext-install \
      /usr/local/bin/docker-php-ext-enable \
      /usr/local/bin/docker-php-ext-configure \
      /usr/local/bin/docker-php-source && \
    mkdir -p "/opt/filc/${FILC_CHANNEL}/pizfix/etc/php${PHP_SERIES}/conf.d" && \
    mv /tmp/php.ini-development "/opt/filc/${FILC_CHANNEL}/pizfix/etc/php${PHP_SERIES}/php.ini-development" && \
    mv /tmp/php.ini-production "/opt/filc/${FILC_CHANNEL}/pizfix/etc/php${PHP_SERIES}/php.ini-production" && \
    ln -sfn "/opt/filc/${FILC_CHANNEL}/pizfix/etc/php${PHP_SERIES}" /usr/local/etc/php && \
    ln -sfn "/opt/filc/${FILC_CHANNEL}/pizfix/bin/php${PHP_SERIES}" /usr/local/bin/php && \
    test -x /usr/local/bin/php && \
    if [ -x "/opt/filc/${FILC_CHANNEL}/pizfix/bin/php-cgi${PHP_SERIES}" ]; then \
      ln -sfn "/opt/filc/${FILC_CHANNEL}/pizfix/bin/php-cgi${PHP_SERIES}" /usr/local/bin/php-cgi; \
    fi && \
    if [ -x "/opt/filc/${FILC_CHANNEL}/pizfix/bin/phpdbg${PHP_SERIES}" ]; then \
      ln -sfn "/opt/filc/${FILC_CHANNEL}/pizfix/bin/phpdbg${PHP_SERIES}" /usr/local/bin/phpdbg; \
    fi

FROM base AS cli

LABEL org.opencontainers.image.title="Unofficial PHP ${PHP_SERIES} CLI built with Fil-C"

RUN rm -f "/opt/filc/${FILC_CHANNEL}/pizfix/sbin/php-fpm${PHP_SERIES}"

ENTRYPOINT ["docker-php-entrypoint"]
CMD ["php", "-a"]

FROM base AS fpm

LABEL org.opencontainers.image.title="Unofficial PHP ${PHP_SERIES} FPM built with Fil-C"

COPY docker/php/fpm/php-fpm.conf /tmp/filc-php-fpm.conf
COPY docker/php/fpm/www.conf /tmp/filc-php-www.conf
COPY docker/php/fpm/docker.conf /tmp/filc-php-docker.conf
COPY docker/php/fpm/zz-docker.conf /tmp/filc-php-zz-docker.conf

RUN ln -sfn "/opt/filc/${FILC_CHANNEL}/pizfix/sbin/php-fpm${PHP_SERIES}" /usr/local/sbin/php-fpm && \
    test -x /usr/local/sbin/php-fpm && \
    mkdir -p "/opt/filc/${FILC_CHANNEL}/pizfix/etc/php${PHP_SERIES}/php-fpm.d" \
             "/opt/filc/${FILC_CHANNEL}/pizfix/var/php${PHP_SERIES}/run" \
             "/opt/filc/${FILC_CHANNEL}/pizfix/var/php${PHP_SERIES}/log" && \
    mv /tmp/filc-php-fpm.conf "/opt/filc/${FILC_CHANNEL}/pizfix/etc/php${PHP_SERIES}/php-fpm.conf" && \
    mv /tmp/filc-php-www.conf "/opt/filc/${FILC_CHANNEL}/pizfix/etc/php${PHP_SERIES}/php-fpm.d/www.conf" && \
    mv /tmp/filc-php-docker.conf "/opt/filc/${FILC_CHANNEL}/pizfix/etc/php${PHP_SERIES}/php-fpm.d/docker.conf" && \
    mv /tmp/filc-php-zz-docker.conf "/opt/filc/${FILC_CHANNEL}/pizfix/etc/php${PHP_SERIES}/php-fpm.d/zz-docker.conf"

WORKDIR /var/www/html
STOPSIGNAL SIGQUIT
EXPOSE 9000

ENTRYPOINT ["docker-php-entrypoint"]
CMD ["php-fpm"]
