# ---------- BASE IMAGE ----------

FROM debian:bookworm

# ---------- CONFIGURATION ----------

RUN apt-get update && apt-get install -y nginx \
    && rm -rf /var/lib/apt/lists/*

# ---------- TOOLS -----------

COPY tools/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# ---------- PORT -------------
# 443 = TLS port. Remember: this is documentation only 
# the real publishing happens in docker-compose (ports:)

EXPOSE 443

# ---------- ENTRYPOINT ----------

ENTRYPOINT ["/entrypoint.sh"]
CMD ["nginx", "-g", "daemon off;"]