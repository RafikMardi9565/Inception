# ---------- BASE IMAGE ----------

FROM debian:bookworm

# ---------- CONFIGURATION ----------

RUN apt-get update && apt-get install -y mariadb-server \
    && rm -rf /var/lib/apt/lists/*
