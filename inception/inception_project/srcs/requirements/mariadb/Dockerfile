# ---------- BASE IMAGE ----------

FROM debian:bookworm

# ---------- CONFIGURATION ----------

RUN apt-get update && apt-get install -y mariadb-server

# ---------- TOOLS ----------

COPY tools/entrypoint.sh /entrypoint.sh
RUN  chmod +x /entrypoint.sh

# ---------- ENTRYPOINT ----------

ENTRYPOINT ["/entrypoint.sh"]
