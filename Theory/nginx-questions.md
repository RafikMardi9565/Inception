# NGINX — Questions

## What NGINX Is

1. What is nginx — and what THREE roles does it play in our stack?

> **Answer:** A high-performance web server + reverse proxy in C, built for the C10k problem (10,000 concurrent connections). Our three roles: (1) TLS terminator — the only container facing the outside; (2) static file server — CSS/JS/images straight from the wordpress volume; (3) reverse proxy — forwards `.php` requests to php-fpm over FastCGI.

2. Explain nginx's process architecture — master and workers.

> **Answer:** One MASTER (PID 1): reads/validates config, binds ports, manages workers (reap + respawn). N WORKERS (one per CPU core via `worker_processes auto`): the actual workhorses, each juggling thousands of connections with epoll. The master never touches a request.

3. Why is nginx event-driven, and what's the contrast with Apache?

> **Answer:** Apache (prefork/worker) = thread-per-connection: 1000 users = 1000 threads = memory + context-switch storm. nginx = each worker runs an epoll event loop: 1000 users on 1–4 workers, each connection costing a few KB, no blocking. That's why nginx is the default WordPress frontend under load.

4. Why is nginx the ONLY container publishing a port — and why 443 only?

> **Answer:** Subject rule: single entrypoint, TLS only. One door minimizes attack surface: everything else (php-fpm 9000, mariadb 3306) stays internal on the docker network. Port 80 is never published, never even listened on — our config has no `listen 80` at all.

## The Config

5. Walk through the main-context directives we wrote: `user www-data;`, `worker_processes auto;`, `events {}`, `include mime.types`, `sendfile on;`.

> **Answer:** `user www-data` — workers drop privileges (master needs root to bind 443; workers don't). `worker_processes auto` — one worker per CPU. `events { worker_connections 1024; }` — max connections per worker. `include mime.types` — extension→Content-Type map (without it browsers download CSS as garbage). `sendfile on` — zero-copy kernel file transfer, free performance.

6. Explain each line of our server block:

```nginx
listen 443 ssl;
listen [::]:443 ssl;
server_name rmardi.42.fr;
ssl_certificate /etc/nginx/ssl/server.crt;
ssl_certificate_key /etc/nginx/ssl/server.key;
ssl_protocols TLSv1.2 TLSv1.3;
root /var/www/html;
index index.php index.html;
location / { try_files $uri $uri/ /index.php?$args; }
location ~ \.php$ { ... fastcgi_pass wordpress:9000; ... }
```

> **Answer:** `listen 443 ssl` — HTTPS only (+ IPv6 twin). `server_name` — matches the browser's Host header against the domain. `ssl_certificate(_key)` — the TLS keypair from the entrypoint. `ssl_protocols TLSv1.2 TLSv1.3;` — the subject's exact requirement: modern versions only. `root` — the wordpress volume (mounted read-only). `index` — default file for directory requests. `location /` — catch-all with try_files (permalink magic). `location ~ \.php$` — regex: PHP requests go to php-fpm via FastCGI.

7. Why does `fastcgi_pass wordpress:9000` work — what resolves `wordpress`?

> **Answer:** Docker's embedded DNS (127.0.0.11 inside the container) resolves the service name to the wordpress container's IP on the user-defined network — and updates automatically when the container restarts with a new IP. It only works on a user-defined network; the default bridge has no DNS.

8. What is `fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;` — and why isn't it in the stock fastcgi_params?

> **Answer:** It tells php-fpm the EXACT absolute file to execute (`/var/www/html/index.php`). The stock `fastcgi_params` file deliberately omits it (it's deployment-specific), so we add it after `include fastcgi_params;`. Wrong or missing → php-fpm can't find the file → errors.

9. Why did we copy a FULL nginx.conf instead of a site file into sites-enabled?

> **Answer:** One self-contained file, zero leftovers: we overwrite `/etc/nginx/nginx.conf` entirely, which kills Debian's default welcome-page server block in one move. The price: we must write the main context ourselves (user, worker_processes, events, http scaffolding). If we'd only added a site file, Debian's default site could still be answering.

## TLS & Certificates

10. Where does the certificate come from — and why is it generated at container startup?

> **Answer:** The entrypoint generates a self-signed keypair with openssl IF `/etc/nginx/ssl/server.crt` doesn't exist (idempotent). It must exist BEFORE nginx starts — a `listen 443 ssl` with missing cert files is fatal. Certs live in the container's own filesystem, not a volume: they're disposable per-container config, regenerated each fresh container.

11. What does "self-signed" mean, and why does the browser warn — while still encrypting perfectly?

> **Answer:** The certificate's issuer IS itself; no Certificate Authority vouched for it, so the browser can't establish a chain of trust → "not secure" warning → user clicks through. The ENCRYPTION is then identical to a paid cert (same TLSv1.3, same AES-256-GCM). Self-signed = different trust, not weaker crypto.

12. Why is the SAN (`subjectAltName=DNS:rmardi.42.fr`) mandatory on modern browsers?

> **Answer:** Chrome 58+/modern Firefox ignore the legacy CN field for hostname matching — they only read the SAN extension. Without SAN: `NET::ERR_CERT_COMMON_NAME_INVALID` even with a correct CN. Our openssl adds it with `-addext`.

13. What does `-nodes` mean in our openssl command — and why is it required?

> **Answer:** "No DES" — don't encrypt the private key with a passphrase. nginx must load the key at startup with no human around to type anything. A passphrase-protected key would hang/fail the container boot.

14. What exactly will the evaluator's `curl -k -v` show — and why is each line expected?

> **Answer:** `SSL connection using TLSv1.3` (subject: v1.2/v1.3 only), `subject: CN=rmardi.42.fr` (correct domain), `SSL certificate verify result: self-signed certificate (18)` (expected — we generated it). This trio proves TLS-only + correct domain + self-signed in one command.

## PID 1 & the Entrypoint

15. Why `exec nginx -g "daemon off;"` — decode both parts.

> **Answer:** `-g "daemon off;"` — a global directive stopping nginx's classic fork-to-background: without it, the original PID 1 exits after forking and the container dies instantly. `exec` — the shell is REPLACED by nginx: no wrapper remains, nginx master becomes PID 1 and receives signals directly. Both are non-negotiable.

16. What's the entrypoint's idempotency check — and why is it the ONLY setup work?

> **Answer:** `if [ ! -f /etc/nginx/ssl/server.crt ]` — cert missing → generate; exists → skip straight to `exec nginx`. That's the entire init: nginx needs nothing else (no DB wait — php-fpm's own entrypoint handles mariadb readiness; nginx only resolves the name at startup).

## Traps & Troubleshooting

17. Why did nginx die at boot with `[emerg] host not found in upstream "wordpress"` — and how is it prevented in the real project?

> **Answer:** nginx resolves upstream hostnames AT CONFIG LOAD (startup), and refuses to boot if the name doesn't resolve. We had started nginx while the wordpress container wasn't on the network. Fix: start mariadb → wordpress → nginx in order — which is exactly what compose's `depends_on` guarantees. (Also why a fresh `docker compose up` won't hit this if ordering is declared.)

18. What causes `502 Bad Gateway` — the three most likely suspects?

> **Answer:** (1) php-fpm container down. (2) Not on the same user-defined network (no DNS for `wordpress`). (3) php-fpm listening on the default unix socket instead of TCP 9000 (stock www.conf not overwritten).

19. What causes `NET::ERR_CERT_COMMON_NAME_INVALID` in Chrome even though the CN is right?

> **Answer:** Missing SAN — modern browsers ignore CN. Regenerate the cert with `-addext "subjectAltName=DNS:rmardi.42.fr"`.

20. Why does visiting `http://rmardi.42.fr` fail — and why is that a FEATURE?

> **Answer:** Nothing listens on port 80 — no `listen 80`, no published 80. Connection refused. That's the subject requirement: TLS-only entrypoint. The test is `curl http://rmardi.42.fr --max-time 2` → exit 7.

21. What are the symptoms of mounting the wordpress volume WITHOUT `:ro` vs forgetting the mount entirely?

> **Answer:** Without `:ro`: functionally identical (nginx only reads) but you lose the defense-in-depth guarantee — the subject's diagram expects ro, and a compromised nginx could write. Forgetting the mount: nginx serves its OWN empty `/var/www/html` (no index) → 403/404s even though wordpress is healthy — the volume sharing is the whole trick.

22. nginx serves static files directly — how can you prove php-fpm was NOT involved?

> **Answer:** `curl -k -I https://rmardi.42.fr/wp-content/themes/twentytwentyfive/style.css` → 200 from nginx alone; then check the request never hit php-fpm (its access log in `docker logs wordpress` shows nothing). The `location ~ \.php$` regex is what routes PHP to php-fpm — everything else is served from the volume by nginx itself.

## Stack-Wide

23. Draw the complete end-to-end flow — all three containers, all three ports, all three protocols.

> **Answer:** Browser → `https://rmardi.42.fr:443` (HTTPS/TLSv1.2-1.3, the only published port) → nginx: TLS terminated; static → served from shared volume (:ro); `.php` → FastCGI/TCP → `wordpress:9000` → php-fpm executes → MySQL protocol → `mariadb:3306` → content back up the chain. One door, one network, two volumes, three PID 1s: nginx master, php-fpm master, mysqld.

24. What happens if each container dies — which failures are fatal to a page load?

> **Answer:** nginx down → nothing answers on 443 (site unreachable). php-fpm down → static files still serve, but every PHP page = 502. mariadb down → WordPress renders "Error establishing a database connection" — PHP runs but the content layer is gone. All three are required; only nginx faces the user. `restart: always` in compose heals crashes automatically.
