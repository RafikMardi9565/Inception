# ---------- BASE IMAGE ----------

FROM debian:bookworm

# ---------- CONFIGURATION ----------

RUN apt-get update && apt-get install -y mariadb-server \
    && rm -rf /var/lib/mysql/*

# ---------- CONFIG FILE ----------

COPY conf/50-server.cnf /etc/mysql/mariadb.conf.d/50-server.cnf

# ---------- TOOLS ----------

COPY tools/entrypoint.sh /entrypoint.sh
RUN  chmod +x /entrypoint.sh

# ---------- ENTRYPOINT ----------

ENTRYPOINT ["/entrypoint.sh"]
