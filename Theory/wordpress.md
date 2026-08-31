# WordPress — Understanding Walkthrough

## 1. What WordPress Is

WordPress is an open-source **Content Management System (CMS)** — the software that powers ~43% of the web. It's written in **PHP**: a pile of PHP files that, when executed, assemble HTML pages from content stored in a database.

For Inception, the crucial mental model:

- **WordPress is not a program that runs.** It has no process of its own. It's *code*.
- The **process** that executes it is **php-fpm** — the PHP runtime (PID 1 of the wordpress container).
- The **content** lives in MariaDB (posts, users, settings — text in tables).
- The **files** live on the `wordpress_data` volume (themes, plugins, `index.php`, uploads).

Page request in one line: browser → nginx (443) → php-fpm executes `index.php` (9000) → PHP queries MariaDB (3306) → HTML travels back down the chain.

**The layers:** MariaDB stores raw content (text in tables) — never HTML. php-fpm is the engine: reads the PHP code, runs it, asks the DB for content, and produces the HTML page. The HTML/CSS/JS is the finished product generated at request time.

## 2. php-fpm — The Engine

**php-fpm (FastCGI Process Manager)** is the PHP execution engine. It is **NOT a web server** — it cannot speak HTTP. It speaks **FastCGI**, a binary protocol made for "web server asks PHP engine to run a script".

```
NGINX ──FastCGI──► php-fpm master
                       ├── worker 1  (executes ONE php script at a time)
                       ├── worker 2
                       └── worker 3
```

- **Master process** — reads config, manages the workers, reaps and respawns them. Does NOT execute PHP.
- **Workers** — the ones actually running PHP. Stateless: one request per worker, then ready for the next.

**Why TCP port 9000, not a unix socket:** Debian's stock config has `listen = /run/php/php8.2-fpm.sock` — a *file* on the filesystem. That only works if nginx and php-fpm share the same filesystem. In Inception they're in **separate containers** — separate filesystem namespaces. A file in the wordpress container does not exist in the nginx container. TCP (`listen = 0.0.0.0:9000`) is network-reachable: nginx connects to `wordpress:9000`, and Docker's embedded DNS resolves `wordpress` to the container's IP. **Overwriting the stock www.conf is not optional — it's the whole point of C.4.**

**Foreground flag:** `php-fpm -F` (or `--nodaemonize`). Without it, php-fpm forks to the background, the original PID 1 exits, the container dies. With `-F` the master stays PID 1. Note Debian names the binary with the version: **`php-fpm8.2`** on bookworm.

## 3. wp-config.php — The Bridge to the Database

One file connects WordPress to MariaDB. It is created by our entrypoint (via wp-cli) on the volume, and holds:

```php
define( 'DB_NAME', 'wordpress' );        // from ${MYSQL_DATABASE}
define( 'DB_USER', 'wpuser' );           // from ${MYSQL_USER}
define( 'DB_PASSWORD', 'B7Hr...' );      // from the db_password SECRET
define( 'DB_HOST', 'mariadb:3306' );     // Docker service name = DNS name!
```

- `DB_HOST = mariadb:3306` — NOT `localhost`, NOT `127.0.0.1`. From the wordpress container's world, MariaDB is a *remote machine* on the Docker network. The embedded DNS resolves `mariadb` to its IP.
- Every value must **exactly match** what the mariadb entrypoint created, or "Access denied" / "Error establishing a database connection".
- wp-cli also generates the eight security **salts** (unique random strings) into wp-config.php — they sign login cookies, and wp-cli handles them automatically.

## 4. WP-CLI — Installing WordPress Without a Browser

**WP-CLI** is WordPress's command-line tool — a single PHP archive (a "phar") at `/usr/local/bin/wp`. It replaces the point-and-click install wizard entirely:

- `wp core download` — download the WordPress files
- `wp config create` — generate `wp-config.php`
- `wp core install` — create the DB tables + admin user (this is when the `wp_` tables appear in MariaDB!)
- `wp user create` — create the second user

Every command needs **`--allow-root`** — we run as root in the container, and wp-cli refuses to run as root unless you explicitly say so. And `--path=/var/www/html` tells it where the site lives (the volume).

**Why wp-cli for Inception:** the evaluator opens `https://rmardi.42.fr` and must see a *fully installed* WordPress — not the "choose your language" wizard. wp-cli makes installation scriptable and idempotent.

## 5. First Boot: The Entrypoint's Job

On a fresh, empty volume the entrypoint must turn `/var/www/html` from *nothing* into *a working WordPress install*. Every step guarded by an idempotency check:

| Check | If empty/missing | If already there |
|---|---|---|
| `index.php` exists? | `wp core download` | skip |
| `wp-config.php` exists? | `wp config create` | skip |
| `wp core is-installed`? | `wp core install` + `wp user create` | skip |

Same philosophy as mariadb: **the check IS the idempotency.** Second boot → everything skipped → straight to `exec php-fpm8.2 -F`.

Before all of it: the **wait loop**. The wordpress container starts the instant mariadb's container starts (compose's `depends_on` only waits for "container running", not "database ready"). So the entrypoint pings mariadb for up to 30s before touching it.

**The ping user — a trap worth understanding:** do NOT ping as `root`. Root's account is `'root'@'localhost'` — and over the network, the connection comes from WordPress's IP, not localhost. `Access denied`. The **`wpuser` account was created as `'wpuser'@'%'`** (any host) — it *can* cross the network. So the readiness probe uses wpuser's credentials.

## 6. Two Users (Subject Rule)

The subject requires **two users** in the WordPress database:

1. **Administrator** — full control (`/wp-admin`). Their username **must NOT contain** `admin`/`Admin`/`administrator`/`Administrator` (bots brute-force those). Ours: `rmardi`.
2. **Regular user** — limited role (`author`): can write posts, cannot touch settings/plugins/themes. Ours: `author`.

The evaluator logs in as both: admin reaches everything, regular user sees a reduced dashboard.

## 7. The Shared Volume — With NGINX

The `wordpress_data` volume (data at `/home/rmardi/data/wordpress` on the host) is mounted in **two** containers:

```
Host: /home/rmardi/data/wordpress/
   ├── index.php
   ├── wp-config.php
   ├── wp-content/ (themes, plugins, uploads)
   └── ...

        │ bind            │ bind (ro for nginx!)
        ▼                 ▼
   ┌────────────┐   ┌──────────────┐
   │  wordpress  │   │    nginx     │
   │  (rw)       │   │  (read-only) │
   │  wp-cli     │   │  serves the  │
   │  php-fpm    │   │  static files│
   └────────────┘   └──────────────┘
```

- WordPress **writes**: wp-cli installs the files, users upload media.
- NGINX **reads**: serves CSS/JS/images directly, forwards `.php` to php-fpm.
- Same volume, same files. WordPress populates; nginx serves. That's why the subject's diagram shows nginx mounting it `ro`.

## 8. Ports Summary

```
Browser → nginx (443, HTTPS/TLS) → wordpress/php-fpm (9000, FastCGI/TCP) → mariadb (3306, MySQL protocol)
```

The wordpress container **publishes nothing** — port 9000 exists only on the Docker network. Outside the VM, only nginx's 443 is reachable.

---

# CREATION — Building the WordPress Container (step by step)

Everything below is the complete recipe. Work through it file by file, top to bottom.

## C.1 Files you'll create

```
srcs/requirements/wordpress/
├── Dockerfile              ← already written (C.5)
├── .dockerignore           ← C.7
├── conf/
│   └── www.conf            ← C.4  (php-fpm pool)
└── tools/
    └── entrypoint.sh       ← C.6
```

Plus, outside `srcs/`:

```
secrets/
├── wp_admin_password.txt   ← C.2  (admin's password)
└── wp_user_password.txt    ← C.2  (author's password)

srcs/.env                   ← C.3  (WP user names + emails, non-secret)
```

## C.2 secrets/wp_admin_password.txt and wp_user_password.txt

One line each, no newline needed:

```
wp_admin_password.txt →  sHrUGkSZP1WEJqYRS1Jj8xW
wp_user_password.txt  →  rbYATbeXNG2upoXg7Y4B1X4l
```

**Never commit.** Mounted read-only at `/run/secrets/` (three secrets total land in the wordpress container: `db_password`, `wp_admin_password`, `wp_user_password`).

## C.3 srcs/.env — the WordPress block

```env
DOMAIN_NAME=rmardi.42.fr

MYSQL_DATABASE=wordpress
MYSQL_USER=wpuser

WP_ADMIN_USER=rmardi
WP_ADMIN_EMAIL=rmardi@rmardi.42.fr
WP_USER=author
WP_USER_EMAIL=author@rmardi.42.fr
```

- `WP_ADMIN_USER=rmardi` — contains no `admin` → subject rule satisfied.
- `WP_USER=author` — the second user; role is set in the entrypoint (`--role=author`).
- Non-secret values only. Passwords travel via `/run/secrets`, never through `.env`.

## C.4 requirements/wordpress/conf/www.conf

```ini
[www]
user = www-data
group = www-data
listen = 0.0.0.0:9000
pm = dynamic
pm.max_children = 5
pm.start_servers = 2
pm.min_spare_servers = 1
pm.max_spare_servers = 3
```

The minimal version — and that's enough. Line by line:

- `[www]` — the **pool name**. php-fpm can run several independent pools; Debian ships one called `www`. Our file replaces it entirely.
- `user = www-data` / `group = www-data` — the workers run as the low-privilege `www-data` OS user, not root. (The entrypoint's final `chown` must match this — files owned by www-data so workers can write uploads.)
- **`listen = 0.0.0.0:9000`** — THE critical line (section 2). TCP on port 9000, all interfaces — reachable from the nginx container at `wordpress:9000`. Debian's stock file says `listen = /run/php/php8.2-fpm.sock` (a unix socket file) — unusable across containers. Our COPY overwrites it.
- **`pm = dynamic`** — the process manager mode. **Mandatory** — php-fpm refuses to start without it (`ALERT: the process manager is missing`).
- **`pm.max_children = 5`** — the worker cap. Also mandatory in practice: `pm.max_children must be a positive value` — no default.
- `pm.start_servers = 2` / `pm.min_spare_servers = 1` / `pm.max_spare_servers = 3` — workers at boot, and the idle-spare bounds. Specify them explicitly — relying on chained defaults is exactly the kind of config failure the eval will punish.

The lesson here: "minimal" means *no extra lines*, not *fewer than required*. php-fpm validated our file for us — twice.

## C.5 requirements/wordpress/Dockerfile

Already written — the full file with commentary:

```dockerfile
# ---------- BASE IMAGE ----------

FROM debian:bookworm
```
Penultimate stable Debian, pinned. No `latest`.

```dockerfile
# ---------- CONFIGURATION ----------

RUN apt-get update && apt-get install -y php-fpm php-cli php-mysql mariadb-client curl \
    && curl -LO https://github.com/wp-cli/wp-cli/releases/download/v2.11.0/wp-cli-2.11.0.phar \
    && chmod +x wp-cli-2.11.0.phar \
    && mv wp-cli-2.11.0.phar /usr/local/bin/wp \
    && mkdir -p /run/php
```
- `php-fpm` — the engine itself.
- `php-cli` — the PHP interpreter needed to run wp-cli.
- `php-mysql` — the mysqli/PDO extensions so PHP can talk to MariaDB (WordPress dies without it).
- `mariadb-client` — for the `mariadb-admin` readiness ping in the entrypoint.
- `curl` — to download the wp-cli phar.
- `wp-cli-2.11.0.phar` — **pinned version**, not the moving `wp-cli.phar` URL. Download → `chmod +x` (make executable) → `mv` to `/usr/local/bin/wp-cli.phar` — **keep the original filename!** The phar's internal alias is `wp-cli.phar`; renaming the file breaks its template lookups (`wp config create` dies with a mangled `phar://` path). The `ln -s` then gives us the short `wp` command without touching the filename.
- `mkdir -p /run/php` — php-fpm needs this directory for its pid file (created at *build* time, so it exists on every boot — no repeat of the mariadb bug).

```dockerfile
COPY conf/www.conf /etc/php/8.2/fpm/pool.d/www.conf
```
Overwrites Debian's stock pool (unix socket) with ours (TCP 9000). `8.2` = PHP version shipped by bookworm.

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
Exec form — the script is PID 1 until its final `exec` turns it into php-fpm.

**Subject check:** WordPress + php-fpm **only** — no nginx, no apache. ✓

## C.6 requirements/wordpress/tools/entrypoint.sh

```sh
#!/bin/sh
set -e

MYSQL_PASSWORD=$(cat /run/secrets/db_password)
WP_ADMIN_PASSWORD=$(cat /run/secrets/wp_admin_password)
WP_USER_PASSWORD=$(cat /run/secrets/wp_user_password)

for i in $(seq 1 30); do
	if mariadb-admin -h mariadb -u "${MYSQL_USER}" -p"${MYSQL_PASSWORD}" ping --silent; then
		break
	fi
	sleep 1
done

if [ ! -f /var/www/html/index.php ]; then
	wp core download --path=/var/www/html --allow-root
fi

if [ ! -f /var/www/html/wp-config.php ]; then
	wp config create \
		--dbname="${MYSQL_DATABASE}" \
		--dbuser="${MYSQL_USER}" \
		--dbpass="${MYSQL_PASSWORD}" \
		--dbhost=mariadb:3306 \
		--path=/var/www/html \
		--allow-root
fi

if ! wp core is-installed --path=/var/www/html --allow-root; then
	wp core install \
		--url="https://${DOMAIN_NAME}" \
		--title="Inception" \
		--admin_user="${WP_ADMIN_USER}" \
		--admin_password="${WP_ADMIN_PASSWORD}" \
		--admin_email="${WP_ADMIN_EMAIL}" \
		--skip-email \
		--path=/var/www/html \
		--allow-root
	wp user create "${WP_USER}" "${WP_USER_EMAIL}" \
		--role=author \
		--user_pass="${WP_USER_PASSWORD}" \
		--path=/var/www/html \
		--allow-root
fi

chown -R www-data:www-data /var/www/html

exec php-fpm8.2 -F
```

Line by line:

- `set -e` — exit on first failure.
- The three `cat` lines — read the passwords from the Docker secrets into variables. Never hardcoded.
- **The wait loop** — same race-condition safety as mariadb's, but now *across the network*: `-h mariadb` connects over TCP to the mariadb container. Note `-u "${MYSQL_USER}"` — wpuser, NOT root (section 5: `'root'@'localhost'` can't cross the network; `'wpuser'@'%'` can). Up to 30 seconds of patience for mariadb's own init.
- `if [ ! -f /var/www/html/index.php ]` — **idempotency check 1.** Fresh volume → download WordPress core. Second boot → skip.
  - `wp core download` — fetches all WordPress files into the volume. `--allow-root` because we're root; `--path` because the site lives on the volume.
- `if [ ! -f /var/www/html/wp-config.php ]` — **idempotency check 2.**
  - `wp config create` — writes wp-config.php with the DB credentials (from env + secrets) and generates the salts. `--dbhost=mariadb:3306` — the Docker DNS name.
- `if ! wp core is-installed ...` — **idempotency check 3.** The truth comes from the *database*: if WordPress was ever installed (tables exist in MariaDB), skip. This survives even if the wordpress volume is wiped but the DB volume isn't.
  - `wp core install` — creates the `wp_` tables in MariaDB and the admin user. `--url="https://${DOMAIN_NAME}"` — the site URL. `--skip-email` — don't try to send a notification mail (no MTA in the container).
  - `wp user create ... --role=author` — the second user, limited role. Username and password from env + secret.
- `chown -R www-data:www-data /var/www/html` — everything wp-cli just wrote is owned by **root** (we ran as root). The php-fpm workers run as `www-data` and must be able to write (uploads, plugin updates). Hand the files over — every boot, harmless if already correct.
- `exec php-fpm8.2 -F` — replace the script with php-fpm: **foreground (`-F`), PID 1**. The container's life is now tied to the PHP engine. Note `php-fpm8.2` — Debian's versioned binary name.

Second boot in a nutshell: secrets read → ping (instant, mariadb is up) → all three checks fail → skip everything → chown (no-op) → `exec php-fpm8.2 -F`. ~1 second.

## C.7 requirements/wordpress/.dockerignore

```
Dockerfile
.dockerignore
```

Only `conf/` and `tools/` enter the build context. No accidental secrets in the image.

## C.8 Run it manually (before compose exists)

The catch for a manual test: **containers only resolve each other's names on a user-defined network.** The default bridge gives you nothing — no embedded DNS. So create a network and put both containers on it:

```bash
mkdir -p ~/data/wordpress
docker network create wpnet

# re-run mariadb ON the network (names only resolve there)
docker rm -f mariadb3
docker run -d --name mariadb --network wpnet \
  -e MYSQL_DATABASE=wordpress -e MYSQL_USER=wpuser \
  -v ~/data/mariadb:/var/lib/mysql \
  -v $(pwd)/secrets/db_password.txt:/run/secrets/db_password:ro \
  -v $(pwd)/secrets/db_root_password.txt:/run/secrets/db_root_password:ro \
  mariadb

# build + run wordpress on the same network
docker build -t wordpress srcs/requirements/wordpress

docker run -d --name wordpress --network wpnet \
  -e DOMAIN_NAME=rmardi.42.fr \
  -e MYSQL_DATABASE=wordpress -e MYSQL_USER=wpuser \
  -e WP_ADMIN_USER=rmardi -e WP_ADMIN_EMAIL=rmardi@rmardi.42.fr \
  -e WP_USER=author -e WP_USER_EMAIL=author@rmardi.42.fr \
  -v ~/data/wordpress:/var/www/html \
  -v $(pwd)/secrets/db_password.txt:/run/secrets/db_password:ro \
  -v $(pwd)/secrets/wp_admin_password.txt:/run/secrets/wp_admin_password:ro \
  -v $(pwd)/secrets/wp_user_password.txt:/run/secrets/wp_user_password:ro \
  wordpress
```

(All of this wiring — network, volumes, secrets, env — is exactly what docker-compose will declare in YAML later.)

## C.9 Verify, in order

```bash
# 1. Running?
docker ps

# 2. The install story (wp-cli output)
docker logs wordpress

# 3. The files really landed on the HOST volume
ls ~/data/wordpress          # expect index.php, wp-config.php, wp-content/ ...

# 4. Inside: PID 1 must be php-fpm (exec worked)
docker top wordpress         # expect php-fpm8.2 as the main process

# 5. The wp_ tables were created in MariaDB by wp core install
#    (as root — see mariadb.md: 'wpuser'@'%' does NOT match socket/localhost connections)
docker exec -it mariadb mariadb -u root -p'LVGTjxOZiG0GAGxA6sZt9Cbj' wordpress -e "SHOW TABLES;"
docker exec -it mariadb mariadb -u root -p'LVGTjxOZiG0GAGxA6sZt9Cbj' wordpress -e "SELECT user_login FROM wp_users;"

# 6. Port 9000 listening (php is in the image, ss/netstat aren't)
docker exec wordpress php -r 'echo @fsockopen("localhost",9000) ? "9000 OPEN\n" : "9000 CLOSED\n";'
```

Persistence test:

```bash
docker rm -f wordpress
# re-run the same docker run command
docker logs wordpress        # no re-download, no re-install — all three checks skipped
```

## C.10 Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `Access denied for user 'root'@'172.x'` in the wait loop | pinging as root — `'root'@'localhost'` cannot cross the network | ping as `wpuser` (`-u "${MYSQL_USER}"`) |
| `Error establishing a database connection` during install | mariadb not ready yet, or secret mismatch | wait loop should cover readiness; passwords must match the mariadb entrypoint's secrets |
| `wp: command not found` | phar download failed or not moved | check curl + network during build; `/usr/local/bin/wp` exists? |
| `/usr/local/bin/wp: 1: 404:: not found` | the phar URL returned 404 — curl saved the HTML error page as if it were the binary | use the GitHub release URL with `curl -LO` (the old `gh-pages` paths 404 now) |
| `Error: Could not create new 'wp-config.php' file` + a mangled double `phar://` path in the PHP warning | the phar was renamed — its internal alias is `wp-cli.phar`, and path lookups inside break | keep the filename `wp-cli.phar` and expose the `wp` command via a symlink |
| php-fpm: `no pool defined` / starts but nginx gets 502 | stock www.conf not overwritten (still unix socket) | confirm `COPY conf/www.conf /etc/php/8.2/fpm/pool.d/www.conf` and `listen = 0.0.0.0:9000` |
| `ALERT: [pool www] the process manager is missing` → `FPM initialization failed`, exit 78 | `pm =` line absent — the process-manager mode is MANDATORY, no default | add `pm = dynamic` to www.conf |
| Container exits right after init | forgot `exec` — script ends, PID 1 dies | `exec php-fpm8.2 -F` must replace the shell |
| `cannot create ... permission denied` on uploads | files owned by root, workers are www-data | `chown -R www-data:www-data /var/www/html` |
| Can't resolve `mariadb` from wordpress | containers not on the same **user-defined** network | default bridge has NO embedded DNS — use a custom network (compose does this automatically) |
| wp-cli complains about running as root | missing `--allow-root` | add `--allow-root` to every `wp` command |

---

# The Whole Map

Everything on one page. Point at any box — it has a section above.

```
═══════════════════════ PHASE 1: BUILD (docker build, once) ═══════════════════════

        Dockerfile
        ┌─────────────────────────────────────────────┐
        │ FROM debian:bookworm        ← base OS        │
        │                                             │
        │ apt install:                                │
        │   php-fpm        → ENGINE (server for PHP)  │
        │   php-cli        → interpreter (runs wp)    │
        │   php-mysql      → courier to MariaDB       │
        │   mariadb-client → "are you ready?" pinger  │
        │   curl           → downloader               │
        │                                             │
        │ curl → wp-cli    → INSTALLER TOOL (wp cmd)  │
        │ COPY www.conf    → make engine listen :9000 │
        │ COPY entrypoint  → startup script           │
        └─────────────────────────────────────────────┘
                            ▼
                    IMAGE "wordpress"
              (engine + tools ONLY — no website yet)

══════════════════ PHASE 2: FIRST BOOT (docker run, once) ═══════════════════

        entrypoint.sh
        ┌─────────────────────────────────────────────┐
        │ 1. read passwords from /run/secrets          │
        │ 2. PING mariadb:3306  ← wait, is DB ready?  │
        │ 3. wp core download    → THE WEBSITE files  │──┐
        │ 4. wp config create    → wp-config.php      │  │
        │ 5. wp core install     → tables in MariaDB  │  │
        │    wp user create      → 2 users            │  │
        │ 6. chown www-data                           │  │
        │ 7. exec php-fpm8.2 -F → ENGINE BECOMES PID 1│  │
        └─────────────────────────────────────────────┘  │
                            ▼                            ▼
                  VOLUME: ~/data/wordpress        MariaDB container
                  (index.php, themes...)          (wp_ tables, content)

══════════════════════ RUNTIME (every page view) ═══════════════════════

 Browser ──HTTPS──► nginx ──FastCGI──► php-fpm worker ──SQL──► MariaDB
    ◄──HTML────      :443          (runs index.php)   :9000    :3306
```

**The three "somethings" that confuse everyone:**

| Thing | What it is | Where it lives | When it exists |
|---|---|---|---|
| **Engine** (php-fpm) | the running program, PID 1 | baked in the image | from first boot |
| **Code** (WordPress files) | PHP files, incl. `index.php` | the volume | downloaded at first boot |
| **Content** (posts/users) | rows in tables | mariadb volume | created at `wp core install` |

**Two downloads, don't mix them:**

- `curl` → **wp-cli** (the installer tool) — build time, in the image
- `wp core download` → **the website** — runtime, on the volume
