# Inception — Complete Beginner's Checklist

> Goal: Build a small infrastructure of Docker containers (NGINX + WordPress/php-fpm + MariaDB)
> orchestrated with docker-compose, running inside a Virtual Machine.
> This guide assumes you know **nothing**. Work top to bottom.

---

## 1. Understand the Theory (before writing any code)

- [ ] **What is virtualization vs containerization?**
  - [ ] Understand what a Virtual Machine (VM) is (hypervisor, guest OS, full isolation)
  - [ ] Understand what a container is (shares host kernel, isolated processes)
  - [ ] Know the difference between a VM and a container (this WILL be asked in evaluation)
- [ ] **What is Docker?**
  - [ ] Understand the Docker daemon / client architecture
  - [ ] Understand what an **image** is (read-only template, built in layers)
  - [ ] Understand what a **container** is (a running instance of an image)
  - [ ] Understand image **layers** and build cache
  - [ ] Understand what a **Dockerfile** is and how `docker build` works
  - [ ] Know what Docker Hub / registries are (you may only pull base OS images!)
- [ ] **How Docker works under the hood** (evaluation favorite)
  - [ ] Linux **namespaces** (PID, NET, MNT, UTS, IPC, USER)
  - [ ] **cgroups** (resource limiting)
  - [ ] Union filesystems (OverlayFS)
- [ ] **What is docker-compose?**
  - [ ] Understand it orchestrates multiple containers declaratively (YAML)
  - [ ] Difference between `docker run` and `docker compose up`
  - [ ] Difference between docker network types (bridge, host, none)
- [ ] **PID 1 and daemons** (critical for the subject's rules)
  - [ ] What is PID 1 inside a container and why it matters
  - [ ] Why the subject forbids `tail -f`, `sleep infinity`, `while true` hacks
  - [ ] What "running a program in the foreground" means (e.g. `nginx -g "daemon off;"`, `php-fpm -F`, `mysqld` in foreground)
  - [ ] What zombie processes are and how PID 1 should reap them
- [ ] **The stack you are building (LEMP-ish)**
  - [ ] What NGINX is (web server / reverse proxy)
  - [ ] What TLS/SSL is, what a self-signed certificate is, TLSv1.2 vs TLSv1.3
  - [ ] What WordPress is and what **php-fpm** is (FastCGI process manager)
  - [ ] How NGINX talks to php-fpm via **FastCGI** (port 9000)
  - [ ] What MariaDB is (MySQL fork) and how WordPress uses it (port 3306)

---

## 2. Set Up Your Environment

- [ ] **Create a Virtual Machine** (the project MUST run in a VM)
  - [ ] Install VirtualBox (or UTM on Mac)
  - [ ] Install a Linux distro (Debian is the common choice — pick the penultimate stable version, as the subject requires for containers; Alpine is the alternative)
  - [ ] Give it enough disk (~15-30 GB) and RAM (~2-4 GB)
- [ ] **Install Docker inside the VM**
  - [ ] Install `docker` and `docker compose` (v2 plugin)
  - [ ] Add your user to the `docker` group (`sudo usermod -aG docker $USER`)
  - [ ] Verify: `docker run hello-world`
- [ ] **Install tooling**
  - [ ] `git`, `make`, a text editor
  - [ ] Set up SSH access to the VM (optional but very comfortable)
- [ ] **Configure the domain name**
  - [ ] Edit `/etc/hosts` so `yourlogin.42.fr` points to `127.0.0.1` (or the VM's IP)
  - [ ] Understand what `/etc/hosts` does (local DNS resolution)

---

## 3. Project Structure (required by the subject)

- [ ] Create the exact directory layout:
  ```
  inception/
  ├── Makefile
  └── srcs/
      ├── docker-compose.yml
      ├── .env
      └── requirements/
          ├── nginx/
          │   ├── Dockerfile
          │   ├── conf/
          │   └── tools/
          ├── wordpress/
          │   ├── Dockerfile
          │   ├── conf/
          │   └── tools/
          └── mariadb/
              ├── Dockerfile
              ├── conf/
              └── tools/
  ```
- [ ] Understand the rules of the subject:
  - [ ] One service per container (NGINX, WordPress+php-fpm, MariaDB — 3 containers minimum)
  - [ ] Each Dockerfile written by YOU — pulling ready-made images is **forbidden** (except base Debian/Alpine)
  - [ ] Base image must be the **penultimate stable** version of Debian or Alpine
  - [ ] The `latest` tag is **forbidden**
  - [ ] Images must be **named the same as their service**
  - [ ] No passwords in Dockerfiles — use environment variables / `.env` / Docker secrets
  - [ ] `network: host`, `--link`, and `links:` are **forbidden**
  - [ ] Containers must **restart automatically** on crash (`restart: always` / `on-failure`)
  - [ ] No infinite-loop hacks to keep containers alive
  - [ ] The `.env` file must NOT be committed to git (add `.gitignore`); credentials must not appear in the repo

---

## 4. MariaDB Container (build this first)

- [ ] Learn the basics of MariaDB administration
  - [ ] What a database, user, and grant are
  - [ ] SQL basics: `CREATE DATABASE`, `CREATE USER`, `GRANT`, `FLUSH PRIVILEGES`
- [ ] Write the Dockerfile
  - [ ] `FROM debian:bullseye` (or the current penultimate stable) / `alpine:3.xx`
  - [ ] Install `mariadb-server`
  - [ ] Copy a custom config that makes MariaDB listen on `0.0.0.0` (not just localhost/socket)
- [ ] Write an init script (`tools/`) that on first run:
  - [ ] Initializes the data directory if empty (`mariadb-install-db` if needed)
  - [ ] Creates the WordPress database (name from env var)
  - [ ] Creates the WordPress user with password (from env vars) with remote access (`'user'@'%'`)
  - [ ] Sets the root password (from env var)
  - [ ] Is **idempotent** (doesn't break if the volume already has data)
- [ ] Run `mysqld` in the **foreground** as the final process (use `exec`)
- [ ] Expose port **3306** (only on the docker network — NOT published to the host)
- [ ] Attach the database volume to `/var/lib/mysql`
- [ ] Test:
  - [ ] `docker exec -it mariadb mysql -u<user> -p` works
  - [ ] Database and user exist
  - [ ] Data survives `docker compose down` + `up` (volume persistence)

---

## 5. WordPress + php-fpm Container (build this second)

- [ ] Learn what php-fpm is and how it differs from Apache's mod_php
- [ ] Learn what **WP-CLI** is (command-line WordPress installer — makes this MUCH easier)
- [ ] Write the Dockerfile
  - [ ] Base Debian/Alpine image
  - [ ] Install `php`, `php-fpm`, `php-mysqli` (and friends: `php-curl`, `php-gd`, etc.)
  - [ ] Install `wp-cli` (download the phar, make it executable)
  - [ ] **Do NOT install NGINX or Apache here** (forbidden — NGINX has its own container)
- [ ] Configure php-fpm
  - [ ] Make php-fpm listen on **port 9000** (TCP, not a unix socket — NGINX is in another container)
  - [ ] Know where the pool config lives (`www.conf`)
- [ ] Write an init script that on first run:
  - [ ] Waits for MariaDB to be ready (loop with `mariadb-admin ping` or similar)
  - [ ] Downloads WordPress (`wp core download`)
  - [ ] Creates `wp-config.php` with DB credentials from env vars (`wp config create`)
  - [ ] Installs WordPress (`wp core install`) with site URL `https://yourlogin.42.fr`
  - [ ] Creates **two users**: an admin (whose username must NOT contain `admin`/`Admin`/`administrator` — subject rule!) and a regular user
  - [ ] Is idempotent
- [ ] Run `php-fpm -F` in the **foreground** (use `exec`)
- [ ] Attach the WordPress files volume to `/var/www/html` (or your chosen path — must match NGINX)
- [ ] Test:
  - [ ] `docker exec -it wordpress ps aux` shows php-fpm as the main process
  - [ ] Port 9000 is listening

---

## 6. NGINX Container (build this third — the only entrypoint)

- [ ] Learn NGINX configuration basics
  - [ ] `server` blocks, `listen`, `server_name`, `root`, `index`, `location`
  - [ ] How `fastcgi_pass` forwards `.php` requests to php-fpm
  - [ ] `fastcgi_param SCRIPT_FILENAME` and including `fastcgi_params`
- [ ] Learn TLS basics
  - [ ] What a self-signed certificate is; generate one with `openssl req -x509 ...`
  - [ ] Understand key vs certificate (`.key` / `.crt`)
- [ ] Write the Dockerfile
  - [ ] Base Debian/Alpine image, install `nginx` and `openssl`
  - [ ] Generate (or copy a script that generates) the self-signed cert for `yourlogin.42.fr`
  - [ ] Copy your custom nginx config
- [ ] Configure NGINX
  - [ ] Listen ONLY on port **443** with `ssl` — port 80 must NOT be reachable
  - [ ] `ssl_protocols TLSv1.2 TLSv1.3;` **only**
  - [ ] `server_name yourlogin.42.fr`
  - [ ] Root pointing at the shared WordPress volume (`/var/www/html`)
  - [ ] `location ~ \.php$` block with `fastcgi_pass wordpress:9000;` (container name = DNS name!)
- [ ] Run `nginx -g "daemon off;"` in the **foreground**
- [ ] NGINX is the **only** container publishing a port to the host: `443:443`
- [ ] Test:
  - [ ] `https://yourlogin.42.fr` loads WordPress (accept the self-signed cert warning)
  - [ ] `http://yourlogin.42.fr` does NOT work
  - [ ] `curl -k -v https://yourlogin.42.fr` shows TLSv1.2 or v1.3

---

## 7. docker-compose.yml

- [ ] Learn docker-compose YAML syntax (services, volumes, networks, env_file)
- [ ] Define the 3 services: `nginx`, `wordpress`, `mariadb`
  - [ ] Each with `build:` pointing to its `requirements/<service>` dir
  - [ ] `image:` name identical to the service name
  - [ ] `container_name:` set for convenience
  - [ ] `restart: always` (or `on-failure`)
  - [ ] `env_file: .env` (or `environment:` mapping from `.env`)
  - [ ] `depends_on:` (wordpress → mariadb, nginx → wordpress)
- [ ] Define one custom **bridge network**; all 3 services join it
  - [ ] The `networks:` key MUST be present (subject requirement)
  - [ ] Understand Docker's embedded DNS (containers reach each other by service name)
- [ ] Define the 2 **volumes** with bind-mount style config pointing to `/home/yourlogin/data/...`:
  - [ ] `wordpress` volume → `/home/yourlogin/data/wordpress` (site files)
  - [ ] `mariadb` volume → `/home/yourlogin/data/mariadb` (database)
  - [ ] Learn the `driver: local` + `driver_opts` (`type: none`, `o: bind`, `device:`) pattern
- [ ] Write the `.env` file
  - [ ] `DOMAIN_NAME=yourlogin.42.fr`
  - [ ] DB name, DB user, DB password, DB root password
  - [ ] WP admin user/password/email, WP second user/password/email
  - [ ] Ensure `.env` is in `.gitignore`
- [ ] (Recommended/modern subject) Use **Docker secrets** for passwords and understand how they work

---

## 8. Makefile

- [ ] Write rules:
  - [ ] `all` / `up`: create `/home/yourlogin/data/{wordpress,mariadb}` dirs, then `docker compose -f srcs/docker-compose.yml up -d --build`
  - [ ] `down`: `docker compose ... down`
  - [ ] `stop` / `start`
  - [ ] `clean`: down + remove images
  - [ ] `fclean`: clean + remove volumes + wipe `/home/yourlogin/data` (careful with `sudo rm -rf`)
  - [ ] `re`: fclean + all
- [ ] Understand every command your Makefile runs

---

## 9. Testing & Debugging Skills

- [ ] Master these commands (you'll live in them):
  - [ ] `docker ps -a`, `docker images`, `docker logs <container>` / `docker compose logs -f`
  - [ ] `docker exec -it <container> bash|sh`
  - [ ] `docker network ls` / `docker network inspect`
  - [ ] `docker volume ls` / `docker volume inspect`
  - [ ] `docker system prune -af --volumes` (nuke everything and rebuild fresh)
- [ ] Full validation pass:
  - [ ] `make` builds everything from scratch with no errors
  - [ ] All 3 containers stay up (`docker ps` — no restart loops)
  - [ ] Site loads at `https://yourlogin.42.fr`, WordPress is installed (no install wizard shown)
  - [ ] Log in to `/wp-admin` with the admin user; publish/edit a comment or post with the second user
  - [ ] Restart the VM → `make` → everything comes back, data intact
  - [ ] Kill a container (`docker kill`) → it restarts automatically
  - [ ] Check DB really contains WordPress tables (`docker exec -it mariadb mysql ... SHOW TABLES;`)
  - [ ] No credentials anywhere in git history

---

## 10. Prepare for Evaluation (know how to EXPLAIN everything)

- [ ] Explain Docker vs VM
- [ ] Explain what a Dockerfile instruction does line by line (`FROM`, `RUN`, `COPY`, `EXPOSE`, `ENTRYPOINT`, `CMD` — and ENTRYPOINT vs CMD!)
- [ ] Explain why you chose Debian or Alpine
- [ ] Explain docker network and how containers resolve each other's names
- [ ] Explain volumes and where the data physically lives on the host
- [ ] Explain how NGINX ↔ php-fpm ↔ MariaDB communicate (ports 443 → 9000 → 3306)
- [ ] Explain TLS and your certificate generation
- [ ] Explain PID 1, foreground processes, and why no hacky infinite loops
- [ ] Explain Docker secrets / env vars strategy
- [ ] Be ready to change a password / show `.env` handling live

---

## 11. Bonus (only if mandatory is PERFECT)

- [ ] **Redis cache** container + WordPress redis-cache plugin configured
- [ ] **FTP server** container pointing to the WordPress volume
- [ ] **Adminer** container (DB web UI, served through NGINX or its own port)
- [ ] **Static website** container (any language except PHP — e.g. plain HTML/CSS or Python http server) — a small résumé/showcase site
- [ ] **One service of your choice** — you must justify its usefulness in defense (e.g. Portainer, cAdvisor, a mail service…)
- [ ] Each bonus = its own Dockerfile, own service in compose, follows all the same rules

---

# Resources

## Docker & Containers Fundamentals
- Docker official "Get Started": https://docs.docker.com/get-started/
- Docker overview (architecture): https://docs.docker.com/get-started/docker-overview/
- Dockerfile reference: https://docs.docker.com/reference/dockerfile/
- Dockerfile best practices: https://docs.docker.com/build/building/best-practices/
- Docker Compose manual: https://docs.docker.com/compose/
- Compose file reference: https://docs.docker.com/reference/compose-file/
- Docker networking: https://docs.docker.com/engine/network/
- Docker volumes: https://docs.docker.com/engine/storage/volumes/
- Docker secrets in Compose: https://docs.docker.com/compose/how-tos/use-secrets/
- Containers vs VMs (IBM article): https://www.ibm.com/think/topics/containers-vs-vms
- Namespaces & cgroups deep dive: https://www.nginx.com/blog/what-are-namespaces-cgroups-how-do-they-work/
- Video — "Docker Tutorial for Beginners" (TechWorld with Nana): https://www.youtube.com/watch?v=3c-iBn73dDE
- Video — "Learn Docker in 7 Easy Steps" (Fireship): https://www.youtube.com/watch?v=gAkwW2tuIqE

## PID 1 / Entrypoint behavior
- Docker & PID 1 zombie reaping problem: https://blog.phusion.nl/2015/01/20/docker-and-the-pid-1-zombie-reaping-problem/
- ENTRYPOINT vs CMD explained: https://docs.docker.com/reference/dockerfile/#understand-how-cmd-and-entrypoint-interact

## NGINX & TLS
- NGINX beginner's guide: https://nginx.org/en/docs/beginners_guide.html
- NGINX + php-fpm (FastCGI): https://www.nginx.com/resources/wiki/start/topics/examples/phpfcgi/
- Configuring HTTPS servers in NGINX: https://nginx.org/en/docs/http/configuring_https_servers.html
- OpenSSL self-signed cert how-to: https://www.digitalocean.com/community/tutorials/openssl-essentials-working-with-ssl-certificates-private-keys-and-csrs
- How TLS/SSL works (Cloudflare): https://www.cloudflare.com/learning/ssl/what-is-ssl/

## WordPress & PHP-FPM
- WP-CLI handbook: https://make.wordpress.org/cli/handbook/
- WP-CLI commands reference: https://developer.wordpress.org/cli/commands/
- What is PHP-FPM: https://www.php.net/manual/en/install.fpm.php
- wp-config.php reference: https://developer.wordpress.org/advanced-administration/wordpress/wp-config/

## MariaDB
- MariaDB basics tutorial: https://mariadb.com/kb/en/a-mariadb-primer/
- CREATE USER / GRANT docs: https://mariadb.com/kb/en/create-user/ and https://mariadb.com/kb/en/grant/
- Configuring MariaDB (bind-address, etc.): https://mariadb.com/kb/en/configuring-mariadb-for-remote-client-access/

## VM Setup
- VirtualBox manual: https://www.virtualbox.org/manual/
- Install Debian: https://www.debian.org/releases/stable/installmanual
- Install Docker Engine on Debian: https://docs.docker.com/engine/install/debian/

## Inception-specific Guides (read AFTER learning the basics — do not copy-paste)
- "Inception guide" by @gemartin (popular walkthrough): https://github.com/gemartin99/Inception-Tutorial
- Inception explanation series (codesshaman): https://github.com/codesshaman/inception
- 42 Docs — Inception: https://harm-smits.github.io/42docs/projects/inception

> Tip: Do the project in this order: **Theory → VM → MariaDB → WordPress → NGINX → compose polish → Makefile → bonus.**
> Test each container alone before wiring them together. Good luck!
