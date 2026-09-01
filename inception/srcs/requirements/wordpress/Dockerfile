# ---------- BASE IMAGE ----------

FROM debian:bookworm

# ---------- CONFIGURATION ----------

RUN apt-get update && apt-get install -y php-fpm php-cli php-mysql mariadb-client curl \
    && curl -LO https://github.com/wp-cli/wp-cli/releases/download/v2.11.0/wp-cli-2.11.0.phar \
    && chmod +x wp-cli-2.11.0.phar \
    && mv wp-cli-2.11.0.phar /usr/local/bin/wp-cli.phar \
    && ln -s /usr/local/bin/wp-cli.phar /usr/local/bin/wp \
    && mkdir -p /run/php \
    && sed -i 's|listen = /run/php/php8.2-fpm.sock|listen = 0.0.0.0:9000|' /etc/php/8.2/fpm/pool.d/www.conf

# ---------- TOOLS -----------

COPY tools/entrypoint.sh /entrypoint.sh
RUN  chmod +x /entrypoint.sh

# ---------- ENTRYPOINT ----------

ENTRYPOINT ["/entrypoint.sh"]
