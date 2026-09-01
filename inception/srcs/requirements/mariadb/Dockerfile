# ---------- BASE IMAGE ----------

FROM debian:bookworm

# ---------- CONFIGURATION ----------

RUN apt-get update && apt-get install -y mariadb-server \
    && rm -rf /var/lib/mysql/*

# ---------- CONFIG FILE ----------

COPY conf/99-custom.cnf /etc/mysql/mariadb.conf.d/99-custom.cnf

# ---------- TOOLS ----------

COPY tools/entrypoint.sh /entrypoint.sh
RUN  chmod +x /entrypoint.sh

# ---------- ENTRYPOINT ----------

ENTRYPOINT ["/entrypoint.sh"]
