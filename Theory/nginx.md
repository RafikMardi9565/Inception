# NGINX — Understanding Walkthrough

## 1. What NGINX Is

NGINX (pronounced "engine-x") is a high-performance **web server** and **reverse proxy** written in C. Created in 2004 to solve the C10k problem (10,000+ simultaneous connections on one server).

In our stack it has three roles at once:

| Role | What it does |
|---|---|
| **TLS terminator** | the only container facing the outside world; encrypts/decrypts HTTPS |
| **Static file server** | serves CSS/JS/images directly from the wordpress volume |
| **Reverse proxy** | forwards `.php` requests to php-fpm via FastCGI |

And the subject adds the hard rule: **NGINX is the ONLY entrypoint** — the only container publishing a port to the host, and that port is **443 only**, speaking **TLSv1.2/TLSv1.3 only**.

### 1.1 Architecture — master + workers (event-driven)

```
PID 1: nginx master process
  ├── worker process   ← handles connections asynchronously
  └── worker process   (one per CPU core, "worker_processes auto")
```

- **Master** — reads/validates config, binds ports, manages workers (reap, respawn). Never touches a request.
- **Workers** — the actual workhorses. Each one juggles *thousands* of connections using **epoll** (event notification): no thread-per-connection, no blocking.

Contrast for eval: Apache spawns a thread per request (1000 users = 1000 threads of overhead); NGINX serves 1000 users with 1–4 workers, each connection costing a few KB in an event loop. That's why it's the default WordPress frontend.

## 2. The Only Door — Port 443, TLS Only

```
Browser ──https://rmardi.42.fr:443──► NGINX (published 443:443)
                                        │
                        ┌───────────────┼───────────────┐
                        │ static file?  │ .php request? │
                        ▼               ▼               │
                serve from volume   FastCGI to           │
                (css/js/images)     wordpress:9000       │
                                                         ▼
                                              php-fpm executes,
                                              WordPress queries
                                              mariadb:3306
```

- **Port 80 is never published, never even listened on.** The subject's spec: TLS only.
- Ports 9000 and 3306 exist only inside the docker network — no `ports:` for wordpress/mariadb.
- `443:443` = host port : container port. The browser hits the VM's 443; docker forwards it to nginx.

### 2.1 TLS — what nginx does and why it needs a certificate

HTTP sends everything in plaintext — passwords, cookies, pages. TLS encrypts the whole conversation. nginx "terminates" TLS: it's the endpoint that decrypts incoming HTTPS and re-encrypts the reply. Everything *behind* nginx (FastCGI to php-fpm, MySQL to mariadb) stays plaintext **inside the trusted docker network** — that's normal and correct; the encryption only matters on the untrusted leg (browser ↔ VM).

For TLS, nginx needs:

1. A **private key** (`server.key`) — stays secret, never leaves the container
2. A **certificate** (`server.crt`) — public, presented to every visitor, contains the public key + the domain name + validity dates

We generate **self-signed** ones (issuer = ourselves). Browsers warn ("not trusted") because no Certificate Authority vouched for them — the evaluator clicks through the warning. Everything else about the encryption is exactly as strong as a paid certificate.

**SAN — the modern trap:** Chrome 58+ ignores the old `CN=` field entirely for hostname matching. A cert without a **Subject Alternative Name** entry triggers `NET::ERR_CERT_COMMON_NAME_INVALID` even when the CN is perfect. Our openssl command adds `-addext "subjectAltName=DNS:rmardi.42.fr"`.

**TLSv1.2/TLSv1.3 only:** v1.0/v1.1 are deprecated and vulnerable (BEAST, POODLE); SSLv2/v3 are broken; v1.3 is current (faster handshake, AEAD-only ciphers). The subject demands exactly this line:

```nginx
ssl_protocols TLSv1.2 TLSv1.3;
```

## 3. The Config — One Server Block

NGINX config = directives inside nested blocks: `http { server { location { } } }`. Our single `server` block defines the whole site:

```nginx
server {
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name rmardi.42.fr;

    ssl_certificate /etc/nginx/ssl/server.crt;
    ssl_certificate_key /etc/nginx/ssl/server.key;
    ssl_protocols TLSv1.2 TLSv1.3;

    root /var/www/html;
    index index.php index.html;

    location / {
        try_files $uri $uri/ /index.php?$args;
    }

    location ~ \.php$ {
        include fastcgi_params;
        fastcgi_pass wordpress:9000;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
    }
}
```

Key lines:

- **`listen 443 ssl`** — HTTPS only. `[::]:443` = the IPv6 twin.
- **`server_name rmardi.42.fr`** — which domain this block serves. The browser's `Host` header is matched against it.
- **`ssl_certificate` / `ssl_certificate_key`** — the two TLS files from the entrypoint.
- **`root /var/www/html`** — where files live: the wordpress volume, mounted read-only in this container.
- **`location /`** — the catch-all. **`try_files $uri $uri/ /index.php?$args;`** is WordPress's permalink magic: try the literal file → try it as a directory → otherwise hand everything to `index.php` (which routes by the URL internally).
- **`location ~ \.php$`** — regex match: anything ending `.php` goes to php-fpm. **`fastcgi_pass wordpress:9000`** — the docker DNS name + port. **`SCRIPT_FILENAME`** — tells php-fpm the exact absolute file to execute (`/var/www/html/index.php`) — the most important FastCGI parameter, not in the stock `fastcgi_params` file.

**Why a full `nginx.conf` and not a site file:** we COPY a complete main config over Debian's `/etc/nginx/nginx.conf` — one self-contained file, no leftover Debian default site interfering. It must therefore include the main-context and `events`/`http` scaffolding yourself (`user`, `worker_processes`, `mime.types` include, etc.).

## 4. The Shared Volume — Read-Only

nginx and wordpress mount the **same** volume at `/var/www/html`:

```
Host: /home/rmardi/data/wordpress/
        │                        │
   rw (wordpress)           ro (nginx!)
        ▼                        ▼
   ┌────────────┐          ┌──────────┐
   │ wordpress  │          │  nginx   │
   │ wp-cli,    │          │ serves   │
   │ uploads    │          │ static   │
   └────────────┘          └──────────┘
```

- WordPress **writes** (installs files, user uploads) — rw
- nginx only **reads** — `:ro` (the subject's diagram shows this exactly)

The read-only flag is defense-in-depth: even a compromised nginx can't deface the site files.

## 5. First Boot — The Entrypoint's One Job

nginx needs the cert pair to exist **before** it starts (a `listen 443 ssl` without cert files = fatal). So the entrypoint does one idempotent thing:

```sh
if [ ! -f /etc/nginx/ssl/server.crt ]; then
    ... openssl generates server.key + server.crt ...
fi
exec nginx -g "daemon off;"
```

- Check: cert exists? → skip. Missing (fresh container) → generate. Same pattern as everywhere else in this project.
- Certs live in the container's own filesystem (not a volume) — they're disposable config, regenerated per container; nothing here needs to survive.
- **`exec nginx -g "daemon off;"`** — `daemon off;` stops nginx from forking to the background; `exec` replaces the script → nginx master becomes PID 1. The `-g` flag sets a global directive from the command line.

## 6. Ports Summary

| Source | Target | Port | Protocol |
|---|---|---|---|
| Browser | NGINX | 443 | HTTPS (TLSv1.2/1.3) |
| NGINX | php-fpm | 9000 | FastCGI over TCP |
| php-fpm | MariaDB | 3306 | MySQL protocol |

443 is the **only** published port in the entire infrastructure. 9000 and 3306 exist solely inside the docker network.

---

# CREATION — Building the NGINX Container (step by step)

## C.1 Files you'll create

```
srcs/requirements/nginx/
├── Dockerfile              ← C.2 (stub exists — needs openssl + conf COPY)
├── .dockerignore           ← C.5
├── conf/
│   └── nginx.conf          ← C.3
└── tools/
    └── entrypoint.sh       ← C.4
```

## C.2 requirements/nginx/Dockerfile

```dockerfile
# ---------- BASE IMAGE ----------

FROM debian:bookworm
```
Penultimate stable Debian, pinned — same base as the other two.

```dockerfile
# ---------- CONFIGURATION ----------

RUN apt-get update && apt-get install -y nginx openssl
```
- `nginx` — the web server itself
- `openssl` — the toolkit that generates our self-signed certificate

```dockerfile
COPY conf/nginx.conf /etc/nginx/nginx.conf
```
Overwrite Debian's stock main config with ours — one self-contained file: TLS-only server block, wordpress root, FastCGI to `wordpress:9000`.

```dockerfile
# ---------- TOOLS -----------

COPY tools/entrypoint.sh /entrypoint.sh
RUN  chmod +x /entrypoint.sh
```
Copy the init script, make it executable.

```dockerfile
# ---------- ENTRYPOINT ----------

ENTRYPOINT ["/entrypoint.sh"]
```
Exec form — the script is PID 1 until `exec` hands the crown to nginx.

**Subject check:** no `latest`, no passwords, no `EXPOSE` lies — publishing happens in compose (`443:443`) or `-p` at run time. ✓

## C.3 requirements/nginx/conf/nginx.conf

```nginx
user www-data;
worker_processes auto;

events {
	worker_connections 1024;
}

http {
	include /etc/nginx/mime.types;
	default_type application/octet-stream;
	sendfile on;

	server {
		listen 443 ssl;
		listen [::]:443 ssl;
		server_name rmardi.42.fr;

		ssl_certificate /etc/nginx/ssl/server.crt;
		ssl_certificate_key /etc/nginx/ssl/server.key;
		ssl_protocols TLSv1.2 TLSv1.3;

		root /var/www/html;
		index index.php index.html;

		location / {
			try_files $uri $uri/ /index.php?$args;
		}

		location ~ \.php$ {
			include fastcgi_params;
			fastcgi_pass wordpress:9000;
			fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
		}
	}
}
```

Line by line (main context first):

- **`user www-data;`** — worker processes drop to the low-privilege `www-data` user (the master needs root to bind 443, workers don't need it).
- **`worker_processes auto;`** — one worker per CPU core.
- **`events { worker_connections 1024; }`** — max simultaneous connections per worker.
- **`include /etc/nginx/mime.types;`** — the map from file extensions to Content-Types (`.css → text/css`) — without it browsers download CSS as raw text. Debian ships this file; keep it.
- **`default_type application/octet-stream;`** — fallback for unknown extensions.
- **`sendfile on;`** — zero-copy file serving (kernel does disk→socket without userspace copying) — free performance.
- The `server` block — see section 3 for each directive.

## C.4 requirements/nginx/tools/entrypoint.sh

```sh
#!/bin/sh
set -e

if [ ! -f /etc/nginx/ssl/server.crt ]; then
	mkdir -p /etc/nginx/ssl
	openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
		-keyout /etc/nginx/ssl/server.key \
		-out /etc/nginx/ssl/server.crt \
		-subj "/C=FR/ST=Paris/L=Paris/O=42/OU=42/CN=rmardi.42.fr" \
		-addext "subjectAltName=DNS:rmardi.42.fr"
fi

exec nginx -g "daemon off;"
```

Line by line:

- `set -e` — fail fast.
- **`if [ ! -f /etc/nginx/ssl/server.crt ]`** — the idempotency check. Cert exists → skip; missing → generate. Second boot: straight to `exec`.
- `mkdir -p /etc/nginx/ssl` — the cert home.
- **`openssl req -x509`** — generate a self-signed X.509 certificate (not a signing request).
- **`-nodes`** — "no DES": don't encrypt the private key with a passphrase (nginx must read it with no human around).
- **`-days 365`** — one year validity.
- **`-newkey rsa:2048`** — generate a fresh 2048-bit RSA keypair.
- **`-keyout` / `-out`** — where the private key and the certificate land (paths must match nginx.conf).
- **`-subj "..."`** — the certificate's identity fields (Country/State/Locality/Org/OU/**CN=domain**).
- **`-addext "subjectAltName=DNS:rmardi.42.fr"`** — the SAN entry modern browsers require (section 2.1).
- **`exec nginx -g "daemon off;"`** — replace the script with nginx, foreground, PID 1. `-g` sets the global `daemon off;` directive — without it nginx forks to background, PID 1 exits, container dies. The forbidden-hack rules are satisfied: no `sleep`, no `tail -f`, no `while true` — the real daemon IS the process.

## C.5 requirements/nginx/.dockerignore

```
Dockerfile
.dockerignore
```

Only `conf/` and `tools/` enter the build context.

## C.6 Run it manually (the finale — all three containers)

Prerequisites: mariadb + wordpress running on `wpnet` (previous docs), and **the domain in `/etc/hosts`**:

```bash
sudo sed -i '/rmardi.42.fr/d' /etc/hosts
echo "127.0.0.1 rmardi.42.fr" | sudo tee -a /etc/hosts
```

(The subject's domain rule: `rmardi.42.fr` must point to the local IP — the browser sends the right Host header, nginx's `server_name` matches.)

```bash
docker build -t nginx srcs/requirements/nginx

docker run -d --name nginx --network wpnet \
  -p 443:443 \
  -v ~/data/wordpress:/var/www/html:ro \
  nginx
```

- `--network wpnet` — same user-defined network → `wordpress:9000` resolves (no DNS on the default bridge!)
- **`-p 443:443`** — the ONLY port published in the whole project
- **`-v ~/data/wordpress:/var/www/html:ro`** — the shared volume, **read-only**
- No secrets, no env vars — nginx needs neither.

## C.7 Verify, in order

```bash
# 1. All three Up?
docker ps

# 2. nginx's main process
docker top nginx          # PID 1 = "nginx: master process nginx -g daemon off;"

# 3. THE moment of truth — the actual website over HTTPS:
curl -k https://rmardi.42.fr | head -20        # real WordPress HTML, <title>Inception</title>

# 4. TLS details (eval will do this):
curl -k -v https://rmardi.42.fr 2>&1 | grep -E "SSL connection|subject:|issuer:"

# 5. Port 80 must NOT answer:
curl http://rmardi.42.fr --max-time 2; echo "exit: $?"   # connection refused/failed

# 6. Static file served by nginx directly:
curl -k -I https://rmardi.42.fr/wp-content/themes/twentytwentyfour/style.css
```

Then the browser test: open `https://rmardi.42.fr` → accept the self-signed warning → full WordPress. Log in at `/wp-admin` with `rmardi` (admin) and `author` (second user).

## C.8 Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `502 Bad Gateway` | nginx can't reach php-fpm | wordpress container down, or not on the same user-defined network (`fastcgi_pass wordpress:9000` needs DNS) |
| `[emerg] host not found in upstream "wordpress"` — nginx exits at boot | nginx **resolves upstream names at startup**; the wordpress container wasn't on the network yet | start mariadb + wordpress FIRST, then nginx — this is exactly why compose's `depends_on` ordering exists |
| `nginx: [emerg] cannot load certificate` | cert files missing / wrong path | entrypoint must generate them before `exec`; paths must match nginx.conf |
| `NET::ERR_CERT_COMMON_NAME_INVALID` in Chrome | no SAN in the certificate | `-addext "subjectAltName=DNS:rmardi.42.fr"` |
| `SSL_ERROR_UNSUPPORTED_VERSION` / handshake failure | client only offers TLSv1.3, server old TLS | keep `ssl_protocols TLSv1.2 TLSv1.3;` |
| `404 Not Found` on pretty permalinks | `try_files` missing | `try_files $uri $uri/ /index.php?$args;` in `location /` |
| `403 Forbidden` on everything | volume mounted `:ro` but files unreadable, or no index | files must be `www-data`-owned (wordpress entrypoint's chown) |
| `address already in use` binding 443 | another container/process published 443 | `docker ps`/`ss -tlnp` and remove the squatter |
| Container exits immediately after cert generation | forgot `exec` or `daemon off;` | `exec nginx -g "daemon off;"` must be the last line |
| Browsers see Debian's default nginx page | our conf didn't overwrite the default site | our COPY must replace `/etc/nginx/nginx.conf` (Debian's default server block lives there) |

---

# The Whole Map

```
                    INTERNET (browser)
                         │
                  https://rmardi.42.fr:443
                         ▼
              ┌──────────────────────┐
              │  HOST (VM) :443      │  ← /etc/hosts: rmardi.42.fr → 127.0.0.1
              └──────────┬───────────┘
                         │  -p 443:443  (the ONLY published port)
              ┌──────────▼───────────┐
              │  NGINX container     │  TLS terminate · static files · PID 1
              │  ┌───────────────┐   │
              │  │ server.crt/key│   │  (generated at first boot)
              │  └───────────────┘   │
              └──────┬──────────┬────┘
      static files  │          │  .php requests
     (volume :ro)   │          │  FastCGI wordpress:9000
              ┌─────▼────┐ ┌───▼──────────────┐
              │  VOLUME  │ │  WORDPRESS       │  php-fpm PID 1 · port 9000
              │ ~/data/  │ │  (index.php ...) │
              │ wordpress│ └───┬──────────────┘
              └──────────┘     │  MySQL mariadb:3306
                        ┌──────▼───────┐
                        │   MARIADB    │  mysqld PID 1 · port 3306
                        │  ~/data/     │  wp_ tables
                        │  mariadb     │
                        └──────────────┘

        docker network: wpnet (bridge, embedded DNS: wordpress ⇄ mariadb)
```

**One line per container:** nginx = the door (443, TLS). wordpress = the engine (9000, php-fpm). mariadb = the memory (3306, mysqld). One published port, one network, two volumes — everything else lives inside.
