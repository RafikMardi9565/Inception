# 1.5 — Questions: The Cross-Cutting Layer (TLS handshake, FastCGI protocol, try_files, bonuses)

## TLS / SSL

1. Why does TLS exist — what does it actually protect?

> **Answer:** HTTP sends everything in plaintext: passwords, session cookies, page content — readable by anyone on the path (coffee-shop Wi-Fi attacker, ISP). TLS encrypts the entire conversation: eavesdroppers see only meaningless ciphertext; they know you visited the domain, nothing more.

2. Walk through the TLS handshake.

> **Answer:** 1. ClientHello: browser offers supported versions + cipher suites. 2. ServerHello: server picks TLS version + cipher, sends its **certificate** (public key, signed). 3. Client verifies the cert (trusted CA? CN/SAN matches? not expired?) — with a self-signed cert this is where the browser warning appears and the user proceeds anyway. 4. Key exchange (Diffie-Hellman): both sides independently compute a shared **session key** that is NEVER transmitted. 5. Finished messages encrypted with the session key. 6. Everything afterwards = symmetric encryption (fast, e.g. AES-256-GCM).

3. What's in an X.509 certificate?

> **Answer:** Subject (CN + SAN), Issuer (for self-signed: identical to subject), the public key, validity window (Not Before/Not After), serial number, signature algorithm, fingerprint, and extensions (SAN list, Key Usage). The private key is NEVER in the certificate — it stays on the server.

4. What does "self-signed" mean — and why does the browser complain?

> **Answer:** Issuer = Subject: nobody external vouched for the cert. The browser cannot build a chain of trust to a Certificate Authority, so it warns "not secure". The user clicks through — and from then on the encryption is exactly as strong as a paid cert. Self-signed = trusted differently, not encrypted weakly.

5. Why must the certificate include a Subject Alternative Name (SAN)?

> **Answer:** Chrome 58+ and modern Firefox IGNORE the legacy `CN=` field entirely for hostname matching. A cert generated with only `-subj /CN=...` triggers `NET::ERR_CERT_COMMON_NAME_INVALID` even when the CN is correct. Our openssl command adds `-addext "subjectAltName=DNS:rmardi.42.fr"`.

6. Decode our openssl command flag by flag:

```
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout .../server.key -out .../server.crt \
  -subj "/C=FR/ST=Paris/L=Paris/O=42/OU=42/CN=rmardi.42.fr" \
  -addext "subjectAltName=DNS:rmardi.42.fr"
```

> **Answer:** `req -x509` = make a self-signed certificate (not a signing request). `-nodes` = "no DES": don't encrypt the private key with a passphrase (nginx must read it with no human). `-days 365` = validity. `-newkey rsa:2048` = fresh 2048-bit RSA keypair. `-keyout`/`-out` = private key / certificate paths. `-subj` = identity fields (C=country, ST=state, L=city, O=org, OU=unit, CN=domain). `-addext` = the SAN entry modern browsers demand.

7. TLSv1.2 vs TLSv1.3 — and why does the subject demand "TLSv1.2 or TLSv1.3 only"?

> **Answer:** v1.3: 1-round-trip handshake (vs 2), only modern AEAD ciphers (AES-GCM, ChaCha20-Poly1305), mandatory forward secrecy, 0-RTT resumption, no legacy cruft. v1.2: minimum acceptable, universally supported. Everything older is broken/deprecated: TLSv1.0/1.1 (BEAST, POODLE), SSLv2/3 (completely broken). Hence `ssl_protocols TLSv1.2 TLSv1.3;` — the only correct modern posture.

8. What does "nginx terminates TLS" mean — and why is everything behind it plaintext?

> **Answer:** nginx is the endpoint that decrypts incoming HTTPS and encrypts the reply. Behind it (FastCGI to php-fpm, MySQL to mariadb) traffic is plaintext — but that's fine: those links live inside the trusted docker network, never crossing the untrusted browser↔server leg. Encryption is only needed on the public stretch.

9. What will the evaluator see with `curl -k -v https://rmardi.42.fr`?

> **Answer:** `SSL connection using TLSv1.3` (or v1.2), the certificate subject `CN=rmardi.42.fr`, and `SSL certificate verify result: self-signed certificate (18)` — the expected trio that proves TLS-only + self-signed + correct domain.

## try_files — Permalink Magic

10. What does `try_files $uri $uri/ /index.php?$args;` do, and why is it critical for WordPress?

> **Answer:** It tries each location in order: the literal file ($uri), the directory ($uri/), and finally hands the request to /index.php with the original query string. Without it, only `/index.php?p=123` style URLs work — every pretty permalink (`/2024/my-post/`) 404s. It's the bridge between nginx's filesystem view and WordPress's internal router.

11. Trace three scenarios: static CSS, directory, pretty permalink.

> **Answer:** (a) `/wp-content/style.css`: file exists → served directly by nginx, php-fpm never touched. (b) `/wp-content/`: directory exists → its index file served. (c) `/2024/my-post/`: no file, no directory → falls through to `/index.php?$args` → regex location `\.php$` → FastCGI to php-fpm → WordPress's router looks up the slug in the DB and renders the post.

## FastCGI — The Wire Protocol

12. What is FastCGI, and why not just HTTP between nginx and php-fpm?

> **Answer:** A binary protocol designed for web-server ↔ application-engine communication. Leaner than HTTP (binary headers), persistent connections (no per-request handshake), and stdout (HTML) is kept separate from stderr (PHP errors). It's the standard bridge for PHP — that's why the subject's stack is nginx + php-fpm, not nginx + a PHP HTTP server.

13. Walk a request across the FastCGI boundary — what does nginx send, what comes back?

> **Answer:** nginx translates the HTTP request into FastCGI records: a BEGIN_REQUEST header + parameter key/values (SCRIPT_FILENAME, REQUEST_METHOD, QUERY_STRING, REQUEST_URI, SERVER_NAME, DOCUMENT_ROOT, REMOTE_ADDR...) + STDIN (POST body). php-fpm's worker reads SCRIPT_FILENAME, executes that PHP file, and streams back STDOUT (the HTML) + STDERR (errors) + END_REQUEST with status. nginx wraps the HTML into an HTTP response for the browser.

14. What is SCRIPT_FILENAME and why is it the most important parameter?

> **Answer:** It tells php-fpm the exact absolute file to execute — `/var/www/html/index.php`. It's NOT in the stock `fastcgi_params` file; we add it explicitly: `fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;` ($document_root from nginx's `root`, + the requested script). Missing or wrong → php-fpm can't find the file → 404/500s.

15. Why does php-fpm listen on TCP :9000 instead of its default unix socket?

> **Answer:** A unix socket is a FILE in the filesystem — only shareable by processes on the same machine (same container). nginx and php-fpm are in separate containers with separate filesystem namespaces: php-fpm's socket file doesn't exist in nginx's world. TCP `0.0.0.0:9000` is network-reachable, and Docker's DNS resolves `wordpress:9000` across the bridge.

## End-to-End

16. Draw (verbally) the complete path of one page load — every hop, every port, every protocol.

> **Answer:** Browser → `https://rmardi.42.fr:443` (HTTPS, TLSv1.2/1.3) → host's 443 (the ONLY published port) → nginx container: TLS terminated; static files served directly from the wordpress volume; `.php` → FastCGI over TCP to `wordpress:9000` → php-fpm worker executes index.php → PHP connects to `mariadb:3306` (MySQL protocol) with wpuser credentials → 20–40 SQL queries return content → PHP renders HTML → back up the same chain → browser. Ports: 443 published; 9000 and 3306 internal-only.

17. Why can a compromised php-fpm or mariadb not be reached directly from outside the VM?

> **Answer:** Neither container publishes ports. They exist only on the internal bridge network — from outside, only nginx's 443 is forwarded. Attackers must go through nginx → TLS → WordPress first. One door, everything else internal: that's the subject's architecture requirement, and it's defense in depth.

## Bonus Services

18. Name the common bonus services and the rule they must all follow.

> **Answer:** Redis (object cache, with the WordPress redis plugin), vsftpd/ProFTPD (FTP pointing at the wordpress volume), Adminer (DB web UI), a static site (any non-PHP language, e.g. plain HTML or Python http.server), Portainer/cAdvisor. Rules: own Dockerfile + own container, pinned base image (no `latest`), custom bridge network, no host networking, foreground PID 1, env via compose, a different published port each (443 stays with the main nginx) — and a broken bonus must never break the mandatory stack.

19. Why is the bonus section "never risk the mandatory part"?

> **Answer:** Bonus points are awarded only if the mandatory part is perfect; a broken bonus service that blocks `docker compose up` or breaks the network can cost the whole evaluation. Isolation: separate containers, separate ports, no dependency from the mandatory stack onto bonus services.
