# ---------- BASE IMAGE ----------

FROM debian:bookworm

# ---------- CONFIGURATION ----------

RUN apt-get update && apt-get install -y nginx openssl

# ---------- CONFIG FILE ----------

COPY conf/nginx.conf /etc/nginx/nginx.conf

# ---------- TOOLS -----------

COPY tools/entrypoint.sh /entrypoint.sh
RUN  chmod +x /entrypoint.sh

# ---------- ENTRYPOINT ----------

ENTRYPOINT ["/entrypoint.sh"]
