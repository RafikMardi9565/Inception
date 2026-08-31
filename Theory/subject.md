# Inception — Subject

> Single source of truth for this project. Every design decision must comply with this file.
> **Login: `rmardi`** → domain `rmardi.42.fr`, host data dir `/home/rmardi/data`.

---

## General Guidelines

- This project needs to be done on a **Virtual Machine**.
- All files required for the configuration of the project must be placed in a `srcs` folder.
- A **Makefile** is required and must be located at the root of the project directory. It must set up the entire application (i.e., it has to build the Docker images using `docker-compose.yml`).
- The whole project has to be done in a virtual machine. You have to use **docker compose**.

## Mandatory Requirements

### Containers & Images

- Each Docker image must have the **same name as its corresponding service**.
- Each service has to run in a **dedicated container**.
- For performance reasons, the containers must be built either from the **penultimate stable version of Alpine or Debian**. The choice is yours.
- You have to write your own **Dockerfiles, one per service**. The Dockerfiles must be called in your `docker-compose.yml` by your Makefile.
  - This means you have to build the Docker images of your project yourself. It is then forbidden to pull ready-made Docker images, as well as using services such as DockerHub (**Alpine/Debian being excluded from this rule**).

### The Services

You then have to set up:

- A Docker container that contains **NGINX with TLSv1.2 or TLSv1.3 only**.
- A Docker container that contains **WordPress + php-fpm** (it must be installed and configured) **only, without nginx**.
- A Docker container that contains **MariaDB only, without nginx**.
- **A volume that contains your WordPress database.**
- **A second volume that contains your WordPress website files.**
  - You must use **Docker named volumes** for these two persistent storages. **Bind mounts are not allowed for these volumes.**
  - Both named volumes must store their data inside **`/home/login/data`** on the host machine. Replace "login" with your learner's username (`rmardi` → `/home/rmardi/data`).
- A **docker-network** that establishes the connection between your containers.

### Reliability & PID 1

- Your containers have to **restart in case of a crash**.

> **Info:** A Docker container is not a virtual machine. Thus, it is not recommended to use any hacky patches based on `tail -f` and similar methods when trying to run it. Read about how daemons work and whether it's a good idea to use them or not.

> **Alert:** Of course, using `network: host` or `--link` or `links:` is **forbidden**. The `networks:` line must be present in your `docker-compose.yml` file. Your containers must not be started with a command running an infinite loop. Thus, this also applies to any command used as entrypoint, or used in entrypoint scripts. The following are a few prohibited hacky patches: `tail -f`, `bash`, `sleep infinity`, `while true`.

> **Info:** Read about PID 1 and the best practices for writing Dockerfiles.

### WordPress Users

- In your WordPress database, there must be **two users**, one of them being the **administrator**. The administrator's username **can't contain** `admin`/`Admin` or `administrator`/`Administrator` (e.g., admin, administrator, Administrator, admin-123, and so forth).

### Domain Name

- To make things simpler, you have to configure your domain name so it points to your local IP address.
  - This domain name must be **`login.42.fr`**. Again, you have to use your own login (`rmardi.42.fr`).
  - For example, if your login is `wil`, `wil.42.fr` will redirect to the IP address pointing to wil's website.

### Security

> **Alert:** The `latest` tag is prohibited. **No password must be present in your Dockerfiles**. It is mandatory to use **environment variables**. Also, it is mandatory to use a **`.env` file** to store environment variables. It is strongly recommended that you use **Docker secrets** to store any confidential information. Any credentials, API keys, or passwords found in your Git repository (outside of properly configured secrets) will result in project failure.

> **Alert:** For obvious security reasons, any credentials, API keys, passwords, etc., must be saved locally in various ways/files and **ignored by git**. Publicly stored credentials will lead you directly to a failure of the project.

> **Info:** You can store your variables (as a domain name) in an environment variable file like `.env`.

### Network Entrypoint

- Your NGINX container must be the **only entrypoint** into your infrastructure via **port 443 only**, using the **TLSv1.2 or TLSv1.3** protocol.

---

## Architecture Diagram

```
                        INTERNET  (browser)
                             |
                             |  https://rmardi.42.fr:443
                             |
                    +--------v--------+
                    |   Host Machine  |
                    |   (localhost)   |
                    +--------+--------+
                             |
              /etc/hosts    |
              resolves to    |
              localhost      |
                             |
               +-------------v-------------+
               |     Docker Network        |
               |     (inception_net)       |
               |      bridge driver        |
               |                           |
               |  +---------------------+  |
               |  |     NGINX           |  |
               |  |   (published:443)   |  |
               |  |   TLSv1.2/v1.3      |  |
               |  |   server_name       |  |
               |  |   rmardi.42.fr      |  |
               |  |                     |  |
               |  |  fastcgi_pass       |  |
               |  |  wordpress:9000     |  |
               |  +---------+----------+  |
               |            |             |
               |            | port 9000   |
               |            v             |
               |  +---------------------+  |
               |  |   WordPress+php-fpm |  |
               |  |                     |  |
               |  |   php-fpm :9000     |  |
               |  |   DB_HOST =         |  |
               |  |   mariadb:3306      |  |
               |  +---------+----------+  |
               |            |             |
               |            | port 3306   |
               |            v             |
               |  +---------------------+  |
               |  |     MariaDB         |  |
               |  |                     |  |
               |  |   bind-address      |  |
               |  |   0.0.0.0:3306      |  |
               |  +---------------------+  |
               |                           |
               |   Named Volumes:          |
               |   +------------------+    |
               |   | /home/rmardi/data|    |
               |   |   wordpress/     |<---+-- mounted by NGINX (ro)
               |   |   mariadb/       |<---+-- mounted by WordPress (rw)
               |   +------------------+    |    mounted by MariaDB
               +---------------------------+
                                      ^
                                      |
                        /home/rmardi/data directory
                        on host filesystem
```

**Flow:**

1. Browser sends `https://rmardi.42.fr` → resolves to `127.0.0.1` via `/etc/hosts`.
2. Request hits Docker host port 443 → forwarded to NGINX container.
3. NGINX terminates TLS, checks `server_name`, serves static files directly or passes PHP requests to `wordpress:9000` via FastCGI.
4. WordPress (php-fpm) processes PHP, talks to MariaDB at `mariadb:3306`.
5. Both WordPress file uploads and MariaDB data persist in named volumes under `/home/rmardi/data/`.

---

## Required Directory Structure

```
.
├── Makefile
├── secrets/
│   ├── credentials.txt
│   ├── db_password.txt
│   └── db_root_password.txt
└── srcs/
    ├── docker-compose.yml
    ├── .env
    └── requirements/
        ├── nginx/
        │   ├── Dockerfile
        │   ├── .dockerignore
        │   ├── conf/
        │   └── tools/
        ├── wordpress/
        │   ├── Dockerfile
        │   ├── .dockerignore
        │   ├── conf/
        │   └── tools/
        ├── mariadb/
        │   ├── Dockerfile
        │   ├── .dockerignore
        │   ├── conf/
        │   └── tools/
        ├── bonus/
        └── tools/
```

### Official `ls -alR` Example

```
$> ls -alR
total XX
drwxrwxr-x 3 rmardi rmardi 4096 avril 42 20:42 .
drwxrwxrwt 17 rmardi rmardi 4096 avril 42 20:42 ..
-rw-rw-r-- 1 rmardi rmardi XXXX avril 42 20:42 Makefile
drwxrwxr-x 3 rmardi rmardi 4096 avril 42 20:42 secrets
drwxrwxr-x 3 rmardi rmardi 4096 avril 42 20:42 srcs

./secrets:
total XX
drwxrwxr-x 2 rmardi rmardi 4096 avril 42 20:42 .
drwxrwxr-x 6 rmardi rmardi 4096 avril 42 20:42 ..
-rw-r--r-- 1 rmardi rmardi XXXX avril 42 20:42 credentials.txt
-rw-r--r-- 1 rmardi rmardi XXXX avril 42 20:42 db_password.txt
-rw-r--r-- 1 rmardi rmardi XXXX avril 42 20:42 db_root_password.txt

./srcs:
total XX
drwxrwxr-x 3 rmardi rmardi 4096 avril 42 20:42 .
drwxrwxr-x 3 rmardi rmardi 4096 avril 42 20:42 ..
-rw-rw-r-- 1 rmardi rmardi XXXX avril 42 20:42 docker-compose.yml
-rw-rw-r-- 1 rmardi rmardi XXXX avril 42 20:42 .env
drwxrwxr-x 5 rmardi rmardi 4096 avril 42 20:42 requirements

./srcs/requirements:
total XX
drwxrwxr-x 5 rmardi rmardi 4096 avril 42 20:42 .
drwxrwxr-x 3 rmardi rmardi 4096 avril 42 20:42 ..
drwxrwxr-x 4 rmardi rmardi 4096 avril 42 20:42 bonus
drwxrwxr-x 4 rmardi rmardi 4096 avril 42 20:42 mariadb
drwxrwxr-x 4 rmardi rmardi 4096 avril 42 20:42 nginx
drwxrwxr-x 4 rmardi rmardi 4096 avril 42 20:42 tools
drwxrwxr-x 4 rmardi rmardi 4096 avril 42 20:42 wordpress

./srcs/requirements/mariadb:
total XX
drwxrwxr-x 4 rmardi rmardi 4096 avril 42 20:45 .
drwxrwxr-x 5 rmardi rmardi 4096 avril 42 20:42 ..
drwxrwxr-x 2 rmardi rmardi 4096 avril 42 20:42 conf
-rw-rw-r-- 1 rmardi rmardi XXXX avril 42 20:42 Dockerfile
-rw-rw-r-- 1 rmardi rmardi XXXX avril 42 20:42 .dockerignore
drwxrwxr-x 2 rmardi rmardi 4096 avril 42 20:42 tools
[...]

./srcs/requirements/nginx:
total XX
drwxrwxr-x 4 rmardi rmardi 4096 avril 42 20:42 .
drwxrwxr-x 5 rmardi rmardi 4096 avril 42 20:42 ..
drwxrwxr-x 2 rmardi rmardi 4096 avril 42 20:42 conf
-rw-rw-r-- 1 rmardi rmardi XXXX avril 42 20:42 Dockerfile
-rw-rw-r-- 1 rmardi rmardi XXXX avril 42 20:42 .dockerignore
drwxrwxr-x 2 rmardi rmardi 4096 avril 42 20:42 tools
[...]

$> cat srcs/.env
DOMAIN_NAME=rmardi.42.fr
# MYSQL SETUP
MYSQL_USER=XXXXXXXXXXXX
[...]
```

---

## Compliance Checklist (audit of this project vs subject)

| # | Subject rule | Our design | Status |
|---|--------------|------------|--------|
| 1 | Project runs in a VM | Docker inside the project VM (dev machine has no Docker) | TODO (env) |
| 2 | `srcs/` + Makefile at project root, Makefile builds via compose | `Makefile` at `inception_project/` root | TODO (file empty) |
| 3 | One Dockerfile per service, images built by us | 3 Dockerfiles, `build:` contexts in compose | IN PROGRESS (stubs) |
| 4 | Penultimate stable Debian or Alpine, no `latest` | `debian:bookworm` (stable is trixie) | OK |
| 5 | Image name = service name | `image: nginx` / `wordpress` / `mariadb` | TODO (compose empty) |
| 6 | NGINX: TLSv1.2/TLSv1.3 only, sole entrypoint, port 443 only | nginx conf with `ssl_protocols TLSv1.2 TLSv1.3;`, `443:443` only publish | TODO |
| 7 | WordPress + php-fpm only, **no nginx** | php-fpm image with wp-cli | **BUG: current stub Dockerfile installs nginx — must be replaced** |
| 8 | MariaDB only | mariadb-server image | IN PROGRESS (stub missing conf COPY) |
| 9 | 2 named volumes, no bind mounts, data in `/home/rmardi/data` | `driver_opts` (local, type none, o bind, device) named volumes | Design OK (docs corrected) |
| 10 | Docker network, `networks:` key present, no `host`/`--link`/`links` | `inception_net` bridge | TODO (compose empty) |
| 11 | Restart on crash | `restart: always` on all 3 | TODO (compose empty) |
| 12 | No infinite-loop entrypoints (`tail -f`, `sleep infinity`, `while true`, `bash`) | `exec` pattern, real daemon as PID 1 | Design OK |
| 13 | 2 WP users; admin username must not contain `admin` | wp-cli creates admin + author | TODO |
| 14 | Domain `rmardi.42.fr` → local IP via `/etc/hosts` | `server_name rmardi.42.fr;` | TODO (env) |
| 15 | No passwords in Dockerfiles; env vars mandatory; `.env` mandatory | `.env` (non-secrets) + Docker secrets for passwords | Design OK |
| 16 | Credentials never in git | `secrets/` + `.env` gitignored, secrets untracked | TODO (add `.gitignore`, `git rm --cached` the empty secrets) |

---

*Source: subject.txt provided by the student (transcribed).*
