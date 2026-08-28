# 1.5 — The Stack: NGINX, TLS, WordPress + php-fpm, MariaDB, FastCGI

This file explains every piece of the Inception architecture — what each component is,
how they communicate, and why they were chosen. You must understand not just the "what"
but the "why" for evaluation.

---

## 1. The Big Picture — End-to-End Request Flow

```
Browser (https://rxy.42.fr)
   │
   │ HTTPS (TLSv1.2/v1.3, port 443)
   ▼
┌────────────────────────────────────────────────────────────────┐
│  NGINX Container                                                │
│  ───────────────                                                │
│  - Terminates TLS                                               │
│  - Serves static files directly (*.css, *.js, *.png)            │
│  - Forwards *.php requests to php-fpm via FastCGI               │
│  - Only container with a published port (443:443)               │
│                                                                 │
│  listen 443 ssl;                                                │
│  ssl_protocols TLSv1.2 TLSv1.3;                                 │
│  fastcgi_pass wordpress:9000;                                   │
└────────────────────┬────────────────────────────────────────────┘
                     │
                     │ FastCGI (tcp://wordpress:9000)
                     ▼
┌────────────────────────────────────────────────────────────────┐
│  WordPress + php-fpm Container                                  │
│  ────────────────────────────                                   │
│  - php-fpm master listens on port 9000 (TCP)                    │
│  - Receives FastCGI request from NGINX                          │
│  - Forks a worker to execute index.php                          │
│  - WordPress PHP code runs: parses request, generates HTML      │
│  - When DB is needed: connects to mariadb:3306                  │
│  - Responds to NGINX with generated HTML                        │
│                                                                 │
│  php-fpm pool config:                                           │
│    listen = 0.0.0.0:9000      (TCP, not unix socket)            │
│                                                                 │
│  wp-config.php:                                                 │
│    define('DB_NAME', getenv('MYSQL_DATABASE'));                 │
│    define('DB_USER', getenv('MYSQL_USER'));                     │
│    define('DB_HOST', 'mariadb:3306');                           │
└────────────────────┬────────────────────────────────────────────┘
                     │
                     │ MySQL protocol (tcp://mariadb:3306)
                     ▼
┌────────────────────────────────────────────────────────────────┐
│  MariaDB Container                                              │
│  ────────────────                                               │
│  - mysqld listens on port 3306                                  │
│  - Accepts connections from wordpress with WP user credentials  │
│  - Stores: posts, pages, users, comments, settings, metadata    │
│  - Data persisted to /home/yourlogin/data/mariadb               │
│                                                                 │
│  listen on 0.0.0.0:3306                                         │
│  bind-address = 0.0.0.0                                         │
└────────────────────────────────────────────────────────────────┘
```

---

## 2. NGINX — Web Server and Reverse Proxy

### 2.1 What Is NGINX?

NGINX (pronounced "engine-x") is a high-performance **web server** and **reverse proxy**
written in C. Created by Igor Sysoev in 2004 to solve the C10k problem (handling 10,000+
concurrent connections on a single server).

Core capabilities relevant to Inception:

| Role | What it does in our stack |
|------|---------------------------|
| **Web server** | Serves static files (CSS, JS, images) directly from the WordPress volume |
| **Reverse proxy** | Forwards PHP requests to php-fpm via FastCGI — the browser never talks to php-fpm directly |
| **TLS terminator** | Handles HTTPS encryption/decryption. php-fpm and MariaDB communicate over plain TCP inside the Docker network — only NGINX faces the outside world |
| **Single entrypoint** | The only container publishing a port to the host. No other container is directly reachable |

### 2.2 NGINX Architecture — Master + Workers (Event-Driven)

NGINX uses an **asynchronous, event-driven** architecture rather than a thread-per-connection
model:

```
Process tree inside the NGINX container:

PID 1: nginx master process
  │
  ├── PID 2: worker process   (handles connections asynchronously)
  ├── PID 3: worker process   (handles connections asynchronously)
  └── PID 4: cache manager    (optional, for file caching)

  Number of workers = number of CPU cores (auto-detected)
```

**Master process:** reads and validates configuration, binds to ports, manages worker
lifecycle (reap children, restart dead workers).

**Worker processes:** the ones doing actual work. Each worker handles thousands of
connections simultaneously using **epoll** (Linux) or **kqueue** (BSD) — event
notification mechanisms that let one process wait on thousands of file descriptors
without blocking.

**Why event-driven matters:** Apache (prefork/worker MPM) spawns a thread or process
per connection. 1000 concurrent users = 1000 threads = massive memory and context-switch
overhead. NGINX handles 1000 users with 1-4 workers. The actual connection context is
just a few kilobytes in the worker's event loop.

```
Apache (threaded model):        NGINX (event-driven model):

Request 1 → Thread 1 (blocked)  Request 1 ┐
Request 2 → Thread 2 (blocked)  Request 2 ├→ Worker 1 (epoll loop)
Request 3 → Thread 3 (blocked)  Request 3 ┘  Hundreds of connections
Request 4 → Thread 4 (blocked)               per worker. No blocking
...                                      Request 4 ┐
Request N → Thread N               Request 5 ├→ Worker 2 (epoll loop)
   N threads, N stacks,            Request 6 ┘  Also hundreds
   N × context-switch cost
```

This is why NGINX is the default frontend for WordPress deployments — it handles large
traffic spikes without falling over.

### 2.3 NGINX Configuration — The Server Block

An NGINX config file is organized into **directives** and **blocks**:

```nginx
# Main context (nginx.conf)
# Affects the entire server globally

worker_processes auto;          # One worker per CPU core
error_log /var/log/nginx/error.log;
pid /run/nginx.pid;

# events block — connection handling
events {
    worker_connections 1024;    # Max connections per worker
    use epoll;                  # Linux event notification (auto-detected)
}

# http block — all HTTP-specific configuration
http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    # Global performance settings
    sendfile on;                # Zero-copy file transfer (kernel sendfile())
    tcp_nopush on;              # Send response headers and file in one packet
    keepalive_timeout 65;       # Keep idle connections open for reuse

    # server block — a virtual host definition
    server {
        listen 443 ssl;                   # Only HTTPS (port 80 forbidden)
        listen [::]:443 ssl;              # IPv6 support

        server_name rxy.42.fr;            # Domain this server block handles

        ssl_certificate /etc/nginx/ssl/server.crt;       # Public certificate
        ssl_certificate_key /etc/nginx/ssl/server.key;   # Private key
        ssl_protocols TLSv1.2 TLSv1.3;    # Only these TLS versions

        root /var/www/html;               # Document root (shared WordPress volume)
        index index.php index.html;       # Default files to serve

        # Location block — how to handle specific URI patterns
        location / {
            try_files $uri $uri/ /index.php?$args;
            # Try: exact file → directory → pass to index.php (WordPress permalink routing)
        }

        location ~ \.php$ {
            # All *.php requests → forward to php-fpm
            include fastcgi_params;                     # Standard FastCGI variables
            fastcgi_pass wordpress:9000;                # php-fpm container:port
            fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
            fastcgi_param PATH_INFO $fastcgi_path_info;
        }

        location ~ /\.ht {
            deny all;                    # Block access to hidden Apache files
        }
    }
}
```

**Why no plain HTTP on port 80?** The subject requires TLS only — port 443 is the only
published port. Two acceptable designs:

1. **Listen on 443 only** (simplest): requests to port 80 are simply refused.
2. **Add an internal redirect block** — a second `server { listen 80; return 301
   https://$host$request_uri; }` inside the container. If you do this, do NOT publish
   port 80 to the host: only 443 may be exposed outside the VM.

Evaluators care that HTTPS works and that port 80 is not published. Either design passes.

### 2.4 NGINX Directives in Detail

| Directive | Purpose |
|-----------|---------|
| `listen 443 ssl` | Binds to port 443, enables SSL/TLS |
| `server_name` | Virtual host matching — which domain this block responds to |
| `root` | Base directory for resolving file paths. In Inception, this is the WordPress volume |
| `index` | Default file when URI ends with `/` |
| `location /` | Catch-all block. All requests that don't match a more specific location end up here |
| `location ~ \.php$` | Regex match. Only requests ending in `.php` go through FastCGI |
| `try_files` | Attempts to serve files in order. The `?$args` appends the original query string |
| `fastcgi_pass` | The socket or TCP address of the php-fpm server |
| `fastcgi_param SCRIPT_FILENAME` | Tells php-fpm: "execute this exact file." Must be absolute path in php-fpm's filesystem |

### 2.5 The try_files Directive — WordPress Permalink Magic

```nginx
try_files $uri $uri/ /index.php?$args;
```

This is how WordPress "pretty permalinks" work. Let's trace three scenarios:

**Scenario A: Static file requested**
```
Request: GET /wp-content/themes/style.css
1. $uri → /wp-content/themes/style.css → EXISTS → serve it
2. Done. Never reaches /index.php.
```

**Scenario B: Directory requested**
```
Request: GET /wp-content/
1. $uri → /wp-content/ (not a file)
2. $uri/ → /wp-content/ (is a directory) → look for index file inside
3. Serves /wp-content/index.html or /wp-content/index.php
```

**Scenario C: WordPress virtual URL (pretty permalink)**
```
Request: GET /2024/my-blog-post/
1. $uri → /2024/my-blog-post/ → NO such file
2. $uri/ → /2024/my-blog-post/ → NO such directory
3. /index.php?$args → /index.php → Falls through to location ~ \.php$
4. php-fpm executes index.php
5. WordPress internally parses the URL
6. WordPress queries the DB for the post with slug "my-blog-post"
7. Renders and returns the post HTML
```

Without `try_files`, only `/index.php?p=123` would work. Pretty URLs would return 404.

---

## 3. TLS/SSL — Transport Layer Security

### 3.1 The Problem TLS Solves

HTTP (unencrypted) sends everything in plain text. Anyone between the browser and the server
can read your passwords, session cookies, and page content. On a coffee shop Wi-Fi, an attacker
with a $20 device can intercept all your traffic.

```
HTTP (no TLS):
Browser ── "username=admin&password=hunter2" ────→ Server
                   │
                   ├── Attacker sniffing the network: reads password
                   └── ISP logging your browsing history: reads everything

HTTPS (with TLS):
Browser ── [encrypted blob] ────→ Server
                   │
                   ├── Attacker sniffing: sees meaningless ciphertext
                   └── ISP: sees only that you visited rxy.42.fr, nothing more
```

### 3.2 How TLS Works (Simplified Handshake)

```
Client (Browser)                              Server (NGINX)
────────────────                              ───────────────

1. ClientHello ──────────────────────────────→
   "I support TLSv1.3, these cipher suites:
    AES-256-GCM, ChaCha20-Poly1305, ..."

2.                            ←────────────── ServerHello
                              "Let's use TLSv1.3, AES-256-GCM"

3.                            ←────────────── Certificate
                              "Here's my public key, signed.
                               Common-Name: rxy.42.fr"

4. Client verifies certificate:
   - Is it signed by a trusted CA? (No — self-signed)
   - Does the CN match rxy.42.fr? (Yes)
   - Is it expired? (No)
   - Browser shows warning: "Certificate not trusted"
   - User clicks "Accept the risk"

5. Key Exchange (Diffie-Hellman or similar)
   Both sides compute a shared symmetric session key.
   This key is NEVER transmitted. Computed independently.

6. Client Finished ──────────────────────────→
   (encrypted with session key)

7.                            ←────────────── Server Finished
                              (encrypted with session key)

8. All subsequent data is encrypted with the session key.
   Use symmetric encryption (fast) — AES-256-GCM.
```

### 3.3 Certificate Components

```
X.509 Certificate
─────────────────
Subject: CN=rxy.42.fr, O=42 School, C=FR
Issuer:  CN=rxy.42.fr, O=42 School, C=FR   ← Same as Subject = self-signed
Public Key: RSA 2048-bit / ECDSA P-256
Validity:
  Not Before: 2024-01-01 00:00:00 UTC
  Not After:  2025-01-01 00:00:00 UTC
Serial Number: 1234567890abcdef
Signature Algorithm: sha256WithRSAEncryption
Fingerprint: SHA256:ab12cd34ef56...
Extensions:
  - Subject Alternative Name: DNS:rxy.42.fr
  - Key Usage: Digital Signature, Key Encipherment
```

**Public key:** anyone can have it. Used to encrypt data that only the private key can decrypt.

**Private key:** must NEVER leave the server. Used to decrypt data encrypted with the public key,
and to sign the handshake to prove identity.

**Self-signed:** the issuer IS the subject. No external CA vouched for this certificate.
The browser cannot verify trust — hence the warning.

### 3.4 Certificate Generation — openssl

```bash
openssl req -x509 \
    -nodes \
    -days 365 \
    -newkey rsa:2048 \
    -keyout /etc/nginx/ssl/server.key \
    -out /etc/nginx/ssl/server.crt \
    -subj "/C=FR/ST=Paris/L=Paris/O=42/OU=42/CN=${DOMAIN_NAME}" \
    -addext "subjectAltName=DNS:${DOMAIN_NAME}"
```

| Flag | Meaning |
|------|---------|
| `req -x509` | Generate a self-signed X.509 certificate (not a CSR) |
| `-nodes` | "No DES" — do NOT encrypt the private key with a passphrase (NGINX needs to read it without human input) |
| `-days 365` | Certificate validity period |
| `-newkey rsa:2048` | Generate a 2048-bit RSA key pair |
| `-keyout` | Path to write the private key |
| `-out` | Path to write the public certificate |
| `-subj` | Certificate subject fields (DN — Distinguished Name) |
| `/C=FR` | Country |
| `/ST=Paris` | State/Province |
| `/L=Paris` | Locality/City |
| `/O=42` | Organization |
| `/OU=42` | Organizational Unit |
| `/CN=rxy.42.fr` | Common Name — the domain (legacy field; see SAN note below) |
| `-addext "subjectAltName=DNS:..."` | Adds a SAN entry — **required by modern browsers** |

**Why the SAN matters:** Chrome 58+ and modern Firefox ignore the CN field entirely for
hostname matching — they only look at the Subject Alternative Name extension. A certificate
generated with only `-subj /CN=...` and no SAN triggers `NET::ERR_CERT_COMMON_NAME_INVALID`
even though the CN matches. Always add the SAN.

### 3.5 TLSv1.2 vs TLSv1.3

| Feature | TLSv1.2 | TLSv1.3 |
|---------|---------|---------|
| **Handshake speed** | 2 round trips (client→server→client→server) | 1 round trip (client→server→client) |
| **Cipher suites** | Supports older, weaker algorithms (RSA key exchange, CBC mode) | Only modern AEAD ciphers (AES-GCM, ChaCha20-Poly1305) |
| **Forward secrecy** | Optional | Mandatory for all cipher suites |
| **Obsolete features** | SHA-1, RC4, 3DES, static RSA, compression | All removed. Lean protocol. |
| **0-RTT resumption** | Not available | Optional — clients can send data in the first packet if they've connected before |
| **Standardized** | RFC 5246 (2008) | RFC 8446 (2018) |

**Why Inception requires both and nothing else:**

```nginx
ssl_protocols TLSv1.2 TLSv1.3;
```

- **TLSv1.0 and TLSv1.1:** Deprecated. Vulnerable to BEAST, POODLE attacks. Removed from modern browsers.
- **SSLv2, SSLv3:** Completely broken. Do not ever use.
- **TLSv1.2:** Minimum acceptable. Supported by all clients.
- **TLSv1.3:** Current standard. Faster, more secure. Use it.
- Including **only** TLSv1.2 and TLSv1.3 is the correct modern posture.

### 3.6 What the Evaluator Will See

- Browser: `https://rxy.42.fr` → certificate warning → click Advanced → Proceed
- `curl -k -v https://rxy.42.fr` shows:
  ```
  * SSL connection using TLSv1.3
  * Server certificate:
  *  subject: CN=rxy.42.fr
  *  SSL certificate verify result: self-signed certificate (18)
  ```

---

## 4. WordPress

### 4.1 What Is WordPress?

WordPress is an open-source **Content Management System (CMS)** written in PHP.
It powers ~43% of all websites on the internet.

Architecture:
- **PHP application** that runs on a web server (or php-fpm)
- **MySQL/MariaDB database** stores all content (posts, pages, users, settings)
- **Admin dashboard** at `/wp-admin` for content management
- **Theme system** for appearance, **plugin system** for functionality

Data flow when a visitor requests a page:

```
Browser → NGINX (HTTPS) → FastCGI → php-fpm worker → PHP engine executes WordPress
    → WordPress queries MariaDB for post content
    → WordPress renders HTML with theme
    → HTML returned through FastCGI → NGINX → Browser
```

WordPress pages are **dynamically generated** — assembled from PHP code + database content
at request time. Unlike a static HTML site where files exist as-is on disk.

### 4.2 wp-config.php — The WordPress Configuration File

This is the heart of a WordPress installation. It connects WordPress to the database and
configures security keys:

```php
<?php
// Database connection (from environment variables — NEVER hardcoded)
define('DB_NAME',     getenv('MYSQL_DATABASE'));
define('DB_USER',     getenv('MYSQL_USER'));
define('DB_PASSWORD', getenv('MYSQL_PASSWORD'));
define('DB_HOST',     'mariadb:3306');          // Docker service name = DNS name
define('DB_CHARSET',  'utf8');
define('DB_COLLATE',  '');

// Security salts — unique per install, prevents cookie forgery
define('AUTH_KEY',         '...long random string...');
define('SECURE_AUTH_KEY',  '...');
define('LOGGED_IN_KEY',    '...');
define('NONCE_KEY',        '...');
define('AUTH_SALT',        '...');
define('SECURE_AUTH_SALT', '...');
define('LOGGED_IN_SALT',   '...');
define('NONCE_SALT',       '...');

// Table prefix — default is 'wp_'
$table_prefix = 'wp_';

// Debug mode — off in production
define('WP_DEBUG', false);

// Absolute path to WordPress directory
if (!defined('ABSPATH'))
    define('ABSPATH', dirname(__FILE__) . '/');

require_once(ABSPATH . 'wp-settings.php');
```

**Critical for Inception:**
- `DB_HOST = 'mariadb:3306'` — the DNS name of the MariaDB container on the Docker network.
  Not `localhost`. Not `127.0.0.1`. The Docker embedded DNS resolves `mariadb` to the container IP.
- All credentials come from environment variables, set by docker-compose from `.env`.
- Security salts should be generated fresh (wp-cli can auto-generate them).

### 4.3 WP-CLI — WordPress Command Line Interface

WP-CLI is a command-line tool that automates WordPress administration. Instead of clicking
through the GUI install wizard, you run commands:

```bash
# Download WordPress core files
wp core download --path=/var/www/html --allow-root

# Create wp-config.php
wp config create \
    --dbname="$MYSQL_DATABASE" \
    --dbuser="$MYSQL_USER" \
    --dbpass="$MYSQL_PASSWORD" \
    --dbhost="mariadb:3306" \
    --path=/var/www/html \
    --allow-root

# Install WordPress (creates DB tables, sets up admin user)
wp core install \
    --url="https://rxy.42.fr" \
    --title="Inception" \
    --admin_user="$WP_ADMIN_USER" \
    --admin_password="$WP_ADMIN_PASSWORD" \
    --admin_email="$WP_ADMIN_EMAIL" \
    --path=/var/www/html \
    --allow-root

# Create a second (non-admin) user
wp user create \
    "$WP_USER" \
    "$WP_USER_EMAIL" \
    --role=author \
    --user_pass="$WP_USER_PASSWORD" \
    --path=/var/www/html \
    --allow-root
```

### 4.3.1 Installing WP-CLI in the Image

WP-CLI is a single PHP archive (a "phar"). To get it into your WordPress image:

```dockerfile
RUN apt-get update && apt-get install -y --no-install-recommends \
        php-cli php-mysql curl mariadb-client less \
 && curl -O https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar \
 && chmod +x wp-cli.phar \
 && mv wp-cli.phar /usr/local/bin/wp \
 && rm -rf /var/lib/apt/lists/*
```

Dependencies matter: `php-cli` to run it, `php-mysql` (mysqli/PDO) so WordPress and
`wp db` can talk to MariaDB, `mariadb-client` for `wp db` operations, `less` for pager
support. Pin a specific wp-cli release URL instead of always taking the moving target
(e.g. `.../gh-pages/phar/wp-cli-2.10.0.phar`).

**Why WP-CLI for Inception:**
- Automates the install process — no manual clicking through `/wp-admin/install.php`
- Idempotent — `wp core is-installed` checks if WP is already set up, so re-runs don't break
- The evaluator visits `https://rxy.42.fr` and sees a fully installed WordPress,
  not a "choose your language" install wizard

### 4.4 WordPress Database Schema

WordPress creates these tables (each prefixed with `wp_`):

| Table | Content |
|-------|---------|
| `wp_posts` | Blog posts, pages, custom post types |
| `wp_postmeta` | Extra metadata for posts (custom fields) |
| `wp_users` | User accounts (login, email, hashed password) |
| `wp_usermeta` | User profile fields, capabilities |
| `wp_comments` | Post comments |
| `wp_commentmeta` | Comment metadata |
| `wp_terms` | Categories and tags |
| `wp_term_taxonomy` | Category/tag type definitions |
| `wp_term_relationships` | Which posts belong to which categories/tags |
| `wp_options` | Site-wide settings (site URL, theme, plugins, etc.) |
| `wp_links` | Blogroll links (mostly legacy) |

When the evaluator asks "show me the WordPress tables," you log into the MariaDB container
and run:

```bash
docker exec -it mariadb mysql -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" "$MYSQL_DATABASE" -e "SHOW TABLES;"
```

### 4.5 WordPress Admin vs Regular User (Subject Rule)

The subject requires **two users**:

1. **Admin user** — has full administrative privileges. But their username **must NOT**
   contain `admin`, `Admin`, or `administrator`. This is a subject rule and a security
   best practice (bots brute-force default "admin" usernames).

2. **Regular user** — limited capabilities (e.g., author role). Cannot install plugins,
   change themes, or modify site settings.

The evaluator will test both: can the admin user access `/wp-admin`? Can the regular
user log in but only see limited dashboard options?

---

## 5. php-fpm — FastCGI Process Manager

### 5.1 What Is php-fpm?

php-fpm (FastCGI Process Manager) is the **PHP execution engine** — it runs PHP code and
returns the output. It is NOT a web server. It cannot handle HTTP requests directly.

```
Traditional Apache mod_php:         NGINX + php-fpm:
───────────────────────────         ──────────────────
┌────────────┐                      ┌──────────┐      ┌─────────┐
│   Apache   │                      │  NGINX   │ ──── │ php-fpm │
│  + mod_php │                      │ (web     │      │ (PHP    │
│  (one      │                      │  server) │      │  engine)│
│  process)  │                      └──────────┘      └─────────┘
└────────────┘
                                    Separate processes. Separate containers.
PHP embedded in web server.         Communicate via FastCGI protocol over TCP.
One process = one request at a time. Web server and PHP scale independently.
```

This separation is why Inception requires php-fpm (not Apache's mod_php, not PHP's built-in dev server).
It's the correct production architecture.

### 5.2 php-fpm Architecture — Master + Pool of Workers

```
PID 1: php-fpm master process
  │
  ├── worker (PID 2)   ← handles PHP execution
  ├── worker (PID 3)
  ├── worker (PID 4)
  └── worker (PID 5)
       ...
  Number of workers depends on your pool configuration
```

**Master process:**
- Reads configuration (php-fpm.conf + pool configs)
- Manages worker lifecycle (spawn, reap, respawn if a worker dies)
- Logs errors and slow requests
- Does NOT execute PHP code

**Worker processes:**
- Each worker can handle one PHP request at a time
- Executes the PHP script, returns the output
- Stateless — one request per worker, then the worker is ready for the next

```
Request lifecycle:
  1. NGINX receives HTTPS request → passes FastCGI request to php-fpm master (port 9000 TCP)
  2. Master assigns the request to an idle worker
  3. Worker reads SCRIPT_FILENAME from FastCGI params: /var/www/html/index.php
  4. Worker executes the PHP file
  5. PHP code runs: queries MariaDB, renders HTML, etc.
  6. Worker sends response back through FastCGI to NGINX
  7. Worker becomes idle, waits for next request
  8. NGINX sends response to browser
```

### 5.3 php-fpm Pool Configuration (www.conf)

```ini
; /etc/php/X.Y/fpm/pool.d/www.conf

[www]                     ; Pool name

user = www-data           ; Worker process runs as this user
group = www-data

; LISTEN — the critical setting for Inception:
listen = 0.0.0.0:9000    ; TCP on port 9000, binds to all interfaces
; NOT: listen = /run/php/php-fpm.sock   ← Unix socket — CANNOT WORK
;                                        because NGINX is in a different container

; Process management
pm = dynamic              ; Dynamic worker pool sizing
pm.max_children = 5       ; Maximum concurrent PHP requests
pm.start_servers = 2      ; Workers spawned at startup
pm.min_spare_servers = 1  ; Minimum idle workers kept alive
pm.max_spare_servers = 3  ; Maximum idle workers (extra are killed)

; Logging
access.log = /var/log/php-fpm/access.log
slowlog = /var/log/php-fpm/slow.log
request_slowlog_timeout = 5s

; Security
security.limit_extensions = .php .php5 ; Only execute .php files
```

**Why TCP and not a Unix socket:**

A Unix socket (`listen = /run/php/php-fpm.sock`) is a file on the filesystem.
NGINX and php-fpm must be on the same machine (same container) to share that file.
In Inception, they're in separate containers. Separate filesystem namespaces.
A file in the php-fpm container at `/run/php/php-fpm.sock` does NOT exist in
the NGINX container.

TCP (`listen = 0.0.0.0:9000`) is network-reachable. NGINX connects to `wordpress:9000`
— the Docker DNS resolves `wordpress` to the php-fpm container's IP.

### 5.4 Starting php-fpm — The Foreground Flag

```dockerfile
CMD ["php-fpm", "-F"]
```

- **`-F`** or `--nodaemonize`: Stays in the foreground. No forking.
  Required for containers. PID 1 stays php-fpm master.

- **Without `-F`:** php-fpm daemonizes, original PID 1 exits, container dies.

- **`-R`** or `--allow-to-run-as-root`: Allow running as root. Use only if you
  haven't set `user = www-data` in the pool config. Not needed if pool config
  specifies a non-root user.

---

## 6. FastCGI — The Protocol Between NGINX and php-fpm

### 6.1 What Is FastCGI?

FastCGI is a **binary wire protocol** that a web server uses to ask a separate process
(like php-fpm) to execute a script and return the result. It's not HTTP. It's a
specialized protocol for server-to-PHP-engine communication.

```
HTTP Request (browser → NGINX):
  GET /index.php HTTP/1.1
  Host: rxy.42.fr
  User-Agent: Mozilla/5.0...

NGINX translates HTTP → FastCGI:

FastCGI Request (NGINX → php-fpm):
  ┌─────────────────────────────────────────┐
  │ FastCGI Binary Header                    │
  │   Version: 1                             │
  │   Type: FCGI_BEGIN_REQUEST              │
  │   Request ID: 1                          │
  ├─────────────────────────────────────────┤
  │ FastCGI Parameters (key-value pairs):    │
  │   SCRIPT_FILENAME: /var/www/html/index.php│
  │   REQUEST_METHOD: GET                    │
  │   QUERY_STRING: (empty)                  │
  │   REQUEST_URI: /index.php               │
  │   SERVER_NAME: rxy.42.fr                │
  │   SERVER_PROTOCOL: HTTP/1.1              │
  │   REMOTE_ADDR: 192.168.1.100            │
  │   DOCUMENT_ROOT: /var/www/html           │
  │   ...                                    │
  ├─────────────────────────────────────────┤
  │ FastCGI STDIN (if POST data):            │
  │   (empty for GET)                        │
  └─────────────────────────────────────────┘

php-fpm processes it:
  Executes /var/www/html/index.php

  $_SERVER in PHP:
    'SCRIPT_FILENAME' => '/var/www/html/index.php'
    'REQUEST_METHOD' => 'GET'
    'SERVER_NAME' => 'rxy.42.fr'
    'REQUEST_URI' => '/index.php'
    ...


FastCGI Response (php-fpm → NGINX):
  ┌─────────────────────────────────────────┐
  │ FastCGI STDOUT:                          │
  │   <!DOCTYPE html>                        │
  │   <html>                                 │
  │   <head>...                              │
  │   (entire HTML page)                     │
  ├─────────────────────────────────────────┤
  │ FastCGI STDERR (if errors):              │
  │   PHP Notice: Undefined variable $x ...  │
  ├─────────────────────────────────────────┤
  │ FastCGI END_REQUEST                      │
  │   App Status: 0 (OK)                     │
  └─────────────────────────────────────────┘

NGINX translates FastCGI → HTTP Response:
  HTTP/1.1 200 OK
  Content-Type: text/html
  ...
  (HTML page sent to browser)
```

### 6.2 Critical FastCGI Parameters

`fastcgi_params` is a standard file included with NGINX that defines the mapping of
NGINX variables to FastCGI parameters:

```nginx
# /etc/nginx/fastcgi_params (ships with NGINX)
fastcgi_param  QUERY_STRING       $query_string;
fastcgi_param  REQUEST_METHOD     $request_method;
fastcgi_param  CONTENT_TYPE       $content_type;
fastcgi_param  CONTENT_LENGTH     $content_length;
fastcgi_param  SCRIPT_NAME        $fastcgi_script_name;
fastcgi_param  REQUEST_URI        $request_uri;
fastcgi_param  DOCUMENT_URI       $document_uri;
fastcgi_param  DOCUMENT_ROOT      $document_root;
fastcgi_param  SERVER_PROTOCOL    $server_protocol;
fastcgi_param  GATEWAY_INTERFACE  CGI/1.1;
fastcgi_param  SERVER_SOFTWARE    nginx/$nginx_version;
fastcgi_param  REMOTE_ADDR        $remote_addr;
fastcgi_param  REMOTE_PORT        $remote_port;
fastcgi_param  SERVER_ADDR        $server_addr;
fastcgi_param  SERVER_PORT        $server_port;
fastcgi_param  SERVER_NAME        $server_name;

# You must add this one explicitly — it's NOT in the default file:
fastcgi_param  SCRIPT_FILENAME    $document_root$fastcgi_script_name;
```

**`SCRIPT_FILENAME` is the most important parameter.** Without it, php-fpm doesn't know
which file to execute. It must be an **absolute path** valid inside the php-fpm container's
filesystem.

The `$document_root` is resolved from the `root` directive in NGINX's config:
```nginx
root /var/www/html;
```

For a request to `/index.php`:
- `$document_root` = `/var/www/html`
- `$fastcgi_script_name` = `/index.php`
- `$document_root$fastcgi_script_name` = `/var/www/html/index.php`

php-fpm receives `SCRIPT_FILENAME=/var/www/html/index.php`, opens the file (which exists
because the WordPress volume is mounted in both containers at the same path), and executes it.

### 6.3 Why FastCGI Over Plain HTTP

- **Binary protocol, not text-based** — lower overhead than HTTP headers
- **Multiplexing** — a single FastCGI connection can handle interleaved requests (though NGINX keeps it simple with one request per connection)
- **Built for the job** — FastCGI was designed specifically for web-server-to-application communication
- **STDERR separate from STDOUT** — PHP errors/warnings go to STDERR, HTML output to STDOUT, cleanly separated
- **Persistent connections** — the connection between NGINX and php-fpm stays open across multiple requests. No TCP handshake per request

### 6.4 Timeout Handling

```nginx
fastcgi_connect_timeout 60s;    # Max time to establish connection to php-fpm
fastcgi_send_timeout 60s;       # Max time to send request to php-fpm
fastcgi_read_timeout 60s;       # Max time to wait for php-fpm response
fastcgi_buffers 16 16k;         # Response buffer config
fastcgi_buffer_size 32k;
```

If php-fpm takes longer than `fastcgi_read_timeout` to respond, NGINX returns a 504
Gateway Timeout to the browser. This prevents NGINX from waiting forever if php-fpm
is dead or stuck.

---

## 7. MariaDB

### 7.1 What Is MariaDB?

MariaDB is a **fork of MySQL**, created by MySQL's original developers after Oracle
acquired MySQL AB in 2009. They wanted to keep the project fully open-source (GPL v2),
independent of Oracle's commercial interests.

```
MySQL AB (company) → Bought by Sun (2008) → Sun bought by Oracle (2009)
                                                            │
                        MySQL founders forked it ───────────┘
                                                            │
                                                        MariaDB
```

For **practical purposes in Inception**, MariaDB and MySQL are interchangeable:
- Same SQL dialect
- Same default port (3306)
- Same protocol (MySQL wire protocol)
- Same client tools (`mysql`, `mysqldump`, `mysqladmin`)
- Same authentication system
- WordPress works identically with both

### 7.2 MariaDB Architecture

```
Container process tree:

PID 1: mysqld (the server)
  ├── thread 1: connection handler (accepts TCP connections on port 3306)
  ├── thread 2: worker (executing queries for client A)
  ├── thread 3: worker (executing queries for client B)
  ├── thread 4: I/O thread (writing to InnoDB log files)
  ├── thread 5: purge thread (cleaning up old InnoDB row versions)
  └── ...
```

mysqld is **multi-threaded but single-process**. All threads share the same PID and
the same address space. It listens on port 3306 (by default, only on localhost).
For Inception, it must listen on `0.0.0.0` (all interfaces) so the WordPress container
can reach it over the Docker network.

### 7.3 MariaDB Configuration — Making It Reachable

```ini
# /etc/mysql/mariadb.conf.d/50-server.cnf or /etc/mysql/my.cnf

[mysqld]

# Bind address — CRITICAL for Docker
bind-address = 0.0.0.0        # Listen on ALL network interfaces
                               # Default is 127.0.0.1 (localhost only)
                               # DEFAULT WON'T WORK — wordpress is in another container

# Port
port = 3306

# Data directory
datadir = /var/lib/mysql

# Character set
character-set-server = utf8mb4
collation-server = utf8mb4_general_ci

# InnoDB settings (storage engine for WordPress tables)
innodb_buffer_pool_size = 128M
innodb_log_file_size = 48M

# Security — disable network if not needed (we DO need it, so keep enabled)
skip-networking = 0            # Default, explicit

# Error log
log_error = /var/log/mysql/error.log
```

Without `bind-address = 0.0.0.0`, MariaDB only listens on the loopback interface
(`127.0.0.1`). The WordPress container, with its own network namespace, has a different
`127.0.0.1` — it cannot reach MariaDB's loopback. The `0.0.0.0` tells MariaDB to listen
on **all** network interfaces, including the Docker bridge interface, making it reachable
at `mariadb:3306` from any container on the network.

### 7.4 How WordPress Queries MariaDB

```php
// WordPress internals — simplified

// 1. Establish connection (using the credentials from wp-config.php)
$mysqli = new mysqli('mariadb', 'wpuser', 'password', 'wordpress', 3306);

// 2. Query for blog post
$result = $mysqli->query("
    SELECT post_title, post_content
    FROM wp_posts
    WHERE post_name = 'hello-world'
      AND post_status = 'publish'
    LIMIT 1
");

// 3. Fetch result
$post = $result->fetch_assoc();

// 4. Render in template
echo '<h1>' . $post['post_title'] . '</h1>';
echo '<div>' . $post['post_content'] . '</div>';
```

Every page load triggers multiple database queries. A typical WordPress homepage might
execute 20-40 queries. The database is the stateful layer — all content lives there.

### 7.5 MariaDB Initialization — First Boot

On first boot (empty data directory `/var/lib/mysql`), MariaDB must be initialized:

1. **Install system tables:** `mysql_install_db` (or `mariadb-install-db`) creates
   the `mysql` database containing `user`, `db`, `tables_priv` tables.

2. **Create WordPress database:**
   ```sql
   CREATE DATABASE IF NOT EXISTS wordpress;
   ```

3. **Create WordPress user with remote access:**
   ```sql
   CREATE USER IF NOT EXISTS 'wpuser'@'%' IDENTIFIED BY 'password';
   GRANT ALL PRIVILEGES ON wordpress.* TO 'wpuser'@'%';
   FLUSH PRIVILEGES;
   ```

   **`'user'@'%'`:** The `%` is a wildcard meaning "from any host." This allows
   the WordPress container (which has its own IP on the Docker network) to connect.
   `'user'@'localhost'` would only allow connections via Unix socket on the same machine.

4. **Set root password:**
   ```sql
   ALTER USER 'root'@'localhost' IDENTIFIED BY 'rootpassword';
   FLUSH PRIVILEGES;
   ```

5. **Idempotency:** The init script must check if the data directory is already initialized
   (e.g., check for the existence of `mysql` system database). If yes, skip initialization.
   This is how data survives `docker compose down` + `docker compose up`.

### 7.6 MariaDB User Authentication

```sql
-- Wordpress user with remote access
CREATE USER 'wpuser'@'%' IDENTIFIED BY 'strong_password_123';
GRANT ALL PRIVILEGES ON wordpress.* TO 'wpuser'@'%';

-- The % means: allow connections from ANY host
-- '%' = any IP
-- '192.168.%' = any IP on the 192.168.0.0/16 subnet
-- '172.18.0.3' = only this specific IP
```

MariaDB's access control has TWO parts:
1. **The user** (who): username + password
2. **The host** (from where): what IP/subnet the user connects from

Both must match for the connection to succeed. `'wpuser'@'%'` means: user `wpuser` can
connect from anywhere. This is required because Docker container IPs change on restart.
Unless you pin the container IP (not recommended), `%` is the correct choice.

**Debian root-auth gotcha:** On Debian/Ubuntu images, MariaDB's `root` account ships with
the `unix_socket` auth plugin by default — `mysql -u root` only works as OS root through
the local socket, and there is **no root password**. If your init script runs
`ALTER USER 'root'@'localhost' IDENTIFIED BY '...'`, root switches to password auth and
bare `mysql -u root` (no `-p`) stops working. Be consistent: either keep socket auth for
root and only create password-authenticated app users, or set the root password and always
use `-p` in your scripts and in `mariadb-admin ping` healthchecks.

---

## 8. Communication Summary — Ports and Protocols

```
┌──────────────────────────────────────────────────────────────────────────┐
│                          DOCKER BRIDGE NETWORK                             │
│                          (inception_net)                                   │
│                                                                            │
│  ┌─────────────────┐    ┌───────────────────┐    ┌───────────────────┐   │
│  │     NGINX       │    │     WordPress     │    │     MariaDB       │   │
│  │  (inception_net)│    │  (inception_net)  │    │  (inception_net)  │   │
│  │                 │    │                   │    │                   │   │
│  │  Port: 443      │    │  Port: 9000       │    │  Port: 3306       │   │
│  │  (published to  │    │  (NOT published)  │    │  (NOT published)  │   │
│  │   host 443)     │    │                   │    │                   │   │
│  │                 │    │  Wordpress:9000   │    │                   │   │
│  │                 │    │  = DNS name       │    │  Mariadb:3306     │   │
│  │                 │    │  + container IP   │    │  = DNS name       │   │
│  │                 │    │                   │    │  + container IP   │   │
│  └────────┬────────┘    └────────┬──────────┘    └────────┬──────────┘   │
│           │                      │                        │              │
│    Port 443               Port 9000                 Port 3306            │
│    (TLS)                  (FastCGI/TCP)            (MySQL/TCP)           │
│           │                      │                        │              │
│           └──────── fastcgi_pass ─┘                        │              │
│                     wordpress:9000                        │              │
│                            │                              │              │
│                            └─────── DB_HOST ──────────────┘              │
│                                    mariadb:3306                           │
└──────────────────────────────────────────────────────────────────────────┘
```

| Source | Target | Port | Protocol | Data |
|--------|--------|------|----------|------|
| Browser | NGINX | 443 | HTTPS (TLSv1.2/1.3) | Web pages |
| NGINX | WordPress/php-fpm | 9000 | FastCGI over TCP | PHP execution requests |
| WordPress | MariaDB | 3306 | MySQL wire protocol | SQL queries |

**Port 443 is the ONLY port exposed to the host.** Ports 9000 and 3306 exist only on the
internal Docker bridge network. Outside the VM, they are unreachable. This is by design.

---

## 9. Volume Sharing Between NGINX and WordPress

Both containers mount the same host directory at `/var/www/html`:

```
Host: /home/rxy/data/wordpress/
  ├── index.php
  ├── wp-config.php
  ├── wp-content/
  │   ├── themes/
  │   ├── plugins/
  │   └── uploads/
  └── ...

        │                        │
        │ (bind mount)           │ (bind mount)
        ▼                        ▼
┌───────────────┐        ┌───────────────┐
│ NGINX         │        │ WordPress     │
│               │        │               │
│ Serves static │        │ wp-cli install
│ files: CSS,   │        │ creates wp-   │
│ JS, images    │        │ config.php    │
│               │        │               │
│ Forwards .php │        │ php-fpm       │
│ to php-fpm    │        │ executes PHP  │
└───────────────┘        └───────────────┘
```

The WordPress container writes files (via wp-cli install, user uploads, plugin/theme installs).
The NGINX container reads those same files to serve them. Both see the exact same filesystem
at `/var/www/html` because it's the same host directory bind-mounted into both containers.

**This is why both containers must be alive for the site to work:**
- NGINX serves the front door — without it, nothing answers on port 443
- WordPress/php-fpm handles all dynamic content — without it, PHP requests return errors
- MariaDB stores the content — without it, WordPress queries fail and the site shows "Error establishing database connection"

---

## 10. The Inception Network Diagram (What the Evaluator Wants)

Be able to draw this and explain every arrow:

```
                    ┌─────────────────────────┐
                    │   HOST (VM)              │
                    │                          │
  User ──HTTPS──────│  Port 443               │
  (Browser)         │                          │
                    │  ┌───────────────────┐   │
                    │  │ docker-compose    │   │
                    │  │  ┌─────────────┐  │   │
                    │  │  │ NGINX       │  │   │
                    │  │  │ TLS         │  │   │
                    │  │  │ Port 443    │  │   │
                    │  │  └──┬───┬──────┘  │   │
                    │  │     │   │         │   │
                    │  │     │   │FastCGI  │   │
                    │  │     │   │(9000)   │   │
                    │  │     │   ▼         │   │
                    │  │  ┌──┴──────────┐  │   │
                    │  │  │ WordPress    │  │   │
                    │  │  │ php-fpm      │  │   │
                    │  │  │ Port 9000    │  │   │
                    │  │  └──┬───────────┘  │   │
                    │  │     │MySQL (3306)  │   │
                    │  │     ▼              │   │
                    │  │  ┌──────────┐      │   │
                    │  │  │ MariaDB  │      │   │
                    │  │  │ Port 3306│      │   │
                    │  │  └──────────┘      │   │
                    │  │                    │   │
                    │  │  Bridge Network    │   │
                    │  └────────────────────┘   │
                    │                          │
                    │  /home/rxy/data/         │
                    │  ├── wordpress/  ←─── Two volumes, both bind-mounted
                    │  └── mariadb/    ←─── into containers
                    └─────────────────────────┘
```

---

## 11. Bonus Services (Optional)

The subject's bonus part is worth points but never risks the mandatory part. Each bonus
service follows the same rules: own Dockerfile, own container, pinned image tag, custom
bridge network, no host networking.

| Bonus | What it is | Notes for Inception |
|-------|-----------|---------------------|
| **Redis** | In-memory key-value store (cache) | Debian + redis-server; WordPress can use it for object caching |
| **FTP server** | vsftpd or ProFTPD | Serves files over FTP (port 21 + passive port range); usually points at the WordPress volume |
| **Adminer** | Web-based DB admin UI | Tiny PHP app; connects to `mariadb:3306`; publish its port (e.g. 8080) |
| **Static website** | A plain HTML site | A second tiny nginx/httpd container; publish its own port |
| **Portainer / cAdvisor** | Management / monitoring | Possible but rarer choices |

Practical rules:
- Publish a **different** port per bonus (443 stays with the main NGINX)
- Keep the same patterns: no `latest`, env via compose, foreground process as PID 1
- A broken bonus service must not block `docker compose up` or break the mandatory stack

---

## 12. Check Your Understanding

Answer without looking:

1. What are the three containers in Inception and what port does each listen on?
2. Why must php-fpm listen on TCP port 9000 rather than a Unix socket?
3. What protocol does NGINX use to forward PHP requests to php-fpm? What is the key parameter that tells php-fpm which file to execute?
4. Why does `DB_HOST` in `wp-config.php` equal `mariadb:3306` rather than `localhost` or `127.0.0.1`?
5. Why does MariaDB need `bind-address = 0.0.0.0`? What would happen with the default `127.0.0.1`?
6. What does `fastcgi_pass wordpress:9000;` mean? How does NGINX know the IP address of `wordpress`?
7. Why is NGINX the only container with a published port (`443:443`)? What happens if you try to access `https://rxy.42.fr:9000`?
8. What are the components of a TLS certificate? What does "self-signed" mean?
9. Why does the subject require at least TLSv1.2? Why are earlier versions forbidden?
10. What's the difference between the NGINX master process and a worker process?
11. How does `try_files $uri $uri/ /index.php?$args;` route a request to `/2024/hello-world/`?
12. Why does the subject require two WordPress users? What restriction applies to the admin username?
13. How do the NGINX and WordPress containers share the WordPress files if they're in separate containers?
14. What SQL command creates a MariaDB user that can connect from the WordPress container? What does the `%` mean?
15. Why must the MariaDB initialization script be idempotent? What happens on a second `docker compose up`?
16. Why must your self-signed certificate include a Subject Alternative Name (SAN)?
17. Name the common bonus services and the rules they must follow.

---

*End of theory section. Next: Section 2 — Environment Setup (VM, Docker install, domain config).*
