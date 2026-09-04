FROM debian:bookworm

RUN apt-get update && apt-get install -y mariadb-server \
     && rm -rf /var/lib/mysql/*

COPY conf/99-custom.cnf /etc/mysql/mariadb.conf.d/99-custom.cnf

COPY tools/entrypoint.sh /entrypoint.sh
RUN  chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
