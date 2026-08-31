# MariaDB — Questions

## Concepts

1. What is MariaDB, and why does WordPress not care that it's not MySQL?

> **Answer:** A fork of MySQL created by its original developers after Oracle bought MySQL (MySQL AB → Sun → Oracle). Same SQL dialect, same port 3306, same wire protocol, same client tools — WordPress literally cannot tell the difference. The subject demands MariaDB.

2. MariaDB's architecture — one process or many? Contrast with nginx.

> **Answer:** ONE process, many THREADS: `mysqld` (PID 1) with a connection-acceptor thread, one worker thread per client, an I/O thread (flushes dirty pages lazily), and a purge thread (garbage-collects old row versions lazily). Contrast: nginx is multi-PROCESS (master + worker processes); mysqld is multi-THREADED (one process, threads inside it share one PID and one address space).

3. What is the "stateful layer" — and what happens if you wipe the mariadb volume?

> **Answer:** The DB holds ALL content — posts, users, settings, comments. Wipe the volume and the site is a perfectly working codebase with zero content. The code (wordpress volume) is interchangeable; the DB is the one thing that can't be regenerated. That's why it gets its own named volume in `/home/rmardi/data/mariadb`.

4. Why does the default `bind-address = 127.0.0.1` break our stack?

> **Answer:** By default MariaDB listens only on loopback — "same machine only". But WordPress is a DIFFERENT machine from MariaDB's perspective: each container has its own network namespace, so WordPress's 127.0.0.1 points at itself. Our `50-server.cnf` sets `bind-address = 0.0.0.0` (all interfaces), so the server answers on the docker bridge at `mariadb:3306`. Without it: the classic "WordPress connection hangs and dies".

## Users & Auth

5. Explain the two-part account model: `'wpuser'@'%'`.

> **Answer:** WHO + FROM WHERE. Both must match for a connection to succeed. `%` = any host — required because Docker container IPs change on every restart (pinning `172.18.0.3` breaks the moment the IP rotates).

6. Why can't we use `'wpuser'@'wordpress'` (the container name) instead of `%`?

> **Answer:** MariaDB matches against the SOURCE IP of the TCP connection, not any client-reported name. The MySQL wire protocol carries no "my name is wordpress" — the server sees an IP. And Docker's embedded DNS does forward resolution only (name→IP), no reverse (IP→name). So `%` is the only correct choice.

7. What's the special case where `'user'@'%'` does NOT match — and how did it bite us in testing?

> **Answer:** Connections that resolve to `localhost` — the unix socket, or TCP from 127.0.0.1 (which MariaDB reverse-resolves) — are matched against `'user'@'localhost'` rows and NEVER against `%`. So `mariadb -u wpuser` from INSIDE the mariadb container gets `Access denied for 'wpuser'@'localhost'` even though WordPress connects fine over TCP. Inspect with root inside the container; `%` works for every other container.

8. The Debian root-auth gotcha — explain `unix_socket` auth and the trap of `ALTER USER`.

> **Answer:** Debian ships MariaDB's `root` with NO password, protected by the `unix_socket` plugin: the kernel vouches for the connecting OS user through the local socket — DB root works only as OS root, locally, passwordless. Running `ALTER USER 'root'@'localhost' IDENTIFIED BY '...'` switches root to password auth: bare `mysql -u root` starts failing (Access denied) — which feels like breakage but is the switch working. Rule: be consistent — once the password is set, EVERY script/healthcheck connecting as root must use `-p`.

9. Walk through every line of the setup SQL and what it does:

```sql
CREATE DATABASE IF NOT EXISTS `wordpress`;
CREATE USER IF NOT EXISTS 'wpuser'@'%' IDENTIFIED BY '...';
GRANT ALL PRIVILEGES ON `wordpress`.* TO 'wpuser'@'%';
ALTER USER 'root'@'localhost' IDENTIFIED BY '...';
FLUSH PRIVILEGES;
```

> **Answer:** 1. Create the empty wordpress database (backticks = identifier quoting; IF NOT EXISTS = idempotency). 2. Create the wpuser account, allowed from any host, with its password. 3. Grant full rights on the wordpress database ONLY (`wordpress.*` = all its tables; the fence: nothing outside). 4. Set root's password — the unix_socket→password switch. 5. Reload privilege tables so it all applies without a restart.

10. Why does WordPress need the `CREATE` privilege — the DB was empty!

> **Answer:** Exactly because it's empty: the grant includes CREATE so that later, wp-cli's `wp core install` can create the `wp_` tables inside `wordpress.*`. Our entrypoint only builds the empty database + user; WordPress builds the tables. Grant first, use later.

## First Boot & the Entrypoint

11. What is `mariadb-install-db` and why can't mysqld boot without it?

> **Answer:** The initializer that builds the SYSTEM tables — the internal `mysql` database (user, db, tables_priv bookkeeping). mysqld hard-refuses to start without system tables. It runs only when the volume is fresh, `--user=mysql` so files are owned by the service account, `--datadir=/var/lib/mysql` so it lands on the volume.

12. Why does mysqld refuse to run as root — and how do we run it anyway?

> **Answer:** Security by design: a database server parses untrusted network input; running as OS root means one bug = machine owned. So it hard-refuses root unless forced, and drops to the low-privilege `mysql` OS user. Our invocations pass `--user=mysql` — the container itself still starts as root, mysqld demotes ITSELF before serving.

13. Why does the entrypoint start a TEMPORARY mysqld with `--skip-networking` instead of just using the final one?

> **Answer:** Because SQL must run against a live server, and the final server must not be reachable mid-configuration. The temp instance listens on the unix socket ONLY (no TCP) while the setup SQL executes — a private workshop. Then it's shut down cleanly, and the real server starts with networking on. Two launches, two jobs.

14. Why the ping loop — and why does it work without `-p` there but need `-p` at shutdown?

> **Answer:** The loop waits for the temp server to actually accept connections (booting isn't instant) — up to 30 tries, one per second. It works passwordless because at that point root is STILL on unix_socket auth (OS root + local socket = in). By shutdown time, the heredoc already ran `ALTER USER` — root now has a password, so `mariadb-admin -u root -p"$..." shutdown` carries `-p`. Same account, two auth eras.

15. What is the idempotency check — and what's the bug we shipped first and fixed?

> **Answer:** `if [ ! -d /var/lib/mysql/mysql ]` — the `mysql` system DB exists only after initialization. Exists → skip init; missing → initialize. Our first version had `mkdir -p /run/mysqld` INSIDE that if — so on the second boot (init skipped) the socket dir was never created and the final mysqld died with `Bind on unix socket: No such file or directory`. Fix: socket-dir creation moved OUTSIDE the if — it must run on EVERY boot, init or not. Your persistence test caught a real bug.

16. Why does the temp server get `wait $pid || true` after shutdown?

> **Answer:** `wait` blocks until the backgrounded temp mysqld fully exits (proper reaping, no zombie — the stored `$!` PID makes it target the right process). `|| true` because a shutdown server exits non-zero, which would otherwise trip `set -e` and kill the script for a "failure" that's the expected ending.

17. Trace the exact sequence of the mariadb entrypoint, first boot vs second boot.

> **Answer:** First boot: mkdir socket dir (now unconditional) → check: system DB missing → `mariadb-install-db` → start temp mysqld (`&`, socket-only) → ping loop → read secrets → heredoc SQL (DB, user, grant, root password) → `shutdown -p...` → `wait` → `exec mysqld --user=mysql` (PID 1). Second boot: mkdir socket dir → check: system DB EXISTS → skip the entire block → `exec mysqld`. ~1 second.

18. What junk rows does Debian's bootstrap leave in mysql.user — and are they a problem?

> **Answer:** A `test` database, anonymous users `''@localhost` and `''@<hostname>` (in a container the hostname IS the container ID, e.g. `''@7ba2da57b42c`), and a `PUBLIC` role row (MariaDB 10.11+). Not corruption — standard Debian/MariaDB bootstrap artifacts. Harmless for Inception; `mysql_secure_installation` removes them if you ever want hardening. Know them so the eval doesn't rattle you.

## Data & Tables

19. List the wp_ tables WordPress creates — and WHEN do they appear?

> **Answer:** wp_posts, wp_postmeta, wp_users, wp_usermeta, wp_comments, wp_commentmeta, wp_terms, wp_term_taxonomy, wp_term_relationships, wp_options, wp_links. They appear when the WORDPRESS entrypoint runs `wp core install` (wp-cli connects with the credentials our entrypoint created) — not when mariadb initializes. Fresh mariadb = empty `wordpress` DB with zero tables; that's expected.

20. How do you show the evaluator the tables, live?

> **Answer:** `docker exec -it mariadb mariadb -u root -p'<rootpass>' wordpress -e "SHOW TABLES;"` (root — remember wpuser@'%' won't match a socket connection from inside the container). Expect the 12 wp_ tables plus the users check: `SELECT user_login FROM wp_users;` → rmardi + author.

21. Where does the database physically live — and how do you prove persistence?

> **Answer:** On the host at `/home/rmardi/data/mariadb` (the named volume's device) — visible with plain `ls`. Proof: `docker rm -f mariadb` → re-run → logs show NO re-initialization; the DB is intact. The container is disposable; the directory is sacred.

22. Why does a FRESH volume sometimes skip initialization and produce error 1130?

> **Answer:** The Docker **copy-up trap**. The mariadb image baked in a virgin datadir (`apt-get install mariadb-server` writes system tables to `/var/lib/mysql` in the image). When a *named volume* (ours included — it's `Type: volume` even with `o: bind` device opts) is mounted over that path while empty, Docker copies the image's content into the volume on first mount. The entrypoint's `if [ ! -d /var/lib/mysql/mysql ]` then sees `mysql/` and believes init already ran → no `wpuser` → WordPress's first DB connection dies with `ERROR 1130 Host 'wordpress.inception' is not allowed`. Manual `-v` runs never hit this because plain *bind mounts* are exempt from copy-up. Fix: `RUN ... && rm -rf /var/lib/mysql/*` in the Dockerfile — empty image datadir → copy-up copies nothing → the check works. Diagnosed by: volume device dir containing files with the *image build date* as mtime, and `docker logs mariadb` starting directly with the final mysqld (no `mariadb-install-db` output).

## Security

23. How do the DB passwords reach the entrypoint without touching the image or git?

> **Answer:** Compose mounts `secrets/db_password.txt` and `secrets/db_root_password.txt` read-only at `/run/secrets/` inside the container (in our manual runs: `-v` mounts with `:ro`). The entrypoint reads them at runtime: `MYSQL_PASSWORD=$(cat /run/secrets/db_password)`. The files are gitignored + untracked; the Dockerfile never sees them.

24. What port does mariadb publish — and why none?

> **Answer:** NONE. Port 3306 exists only on the internal docker network — reachable from other containers at `mariadb:3306`, invisible outside the VM. Publishing it would hand attackers a direct line to the database, bypassing nginx + WordPress entirely. Only nginx publishes (443).
