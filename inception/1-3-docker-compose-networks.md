# 1.3 — docker-compose, Networks, Volumes, and Environment

Now that one container makes sense, the Inception project requires three — all running
together, talking to each other, sharing data, and sharing configuration. That's what
docker-compose solves.

---

## 1. What Is docker-compose?

docker-compose is a tool that lets you define and run **multiple containers as a single stack**
using a declarative YAML file. Instead of:

```bash
docker run -d --name mariadb -v /data/mariadb:/var/lib/mysql -e MYSQL_ROOT_PASSWORD=... mariadb
docker run -d --name wordpress -v /data/wordpress:/var/www/html --link mariadb wordpress
docker run -d --name nginx -p 443:443 --link wordpress nginx
```

You write:

```yaml
services:
  mariadb:
    image: mariadb
    volumes:
      - /data/mariadb:/var/lib/mysql
    environment:
      - MYSQL_ROOT_PASSWORD=${DB_ROOT_PASS}

  wordpress:
    image: wordpress
    volumes:
      - /data/wordpress:/var/www/html
    depends_on:
      - mariadb

  nginx:
    image: nginx
    ports:
      - "443:443"
    depends_on:
      - wordpress
```

Then one command: `docker compose up -d`. The entire stack starts.

### 1.1 `docker run` vs `docker compose up`

| | `docker run` | `docker compose up` |
|---|---|---|
| **Scope** | One container at a time | Entire stack defined in one file |
| **State** | You mentally track the command-line flags | Written in YAML, reproducible, version-controlled |
| **Networking** | You manually create networks, assign IPs | Compose creates a default network automatically, each container reachable by its service name |
| **Dependencies** | You manually start mariadb, wait, then wordpress | `depends_on` and health-checks handle ordering |
| **Cleanup** | You `docker rm` each container individually | `docker compose down` removes the whole stack |
| **Config reuse** | None — retype into terminal each time | The YAML file IS the config, committed to git |

`docker run` is great for quick experiments. docker-compose is for anything with 2+ services
that must be rebuilt reliably.

### 1.2 Compose v1 vs v2

| | v1 | v2 |
|---|---|---|
| Command | `docker-compose` (hyphen) | `docker compose` (space) |
| Implementation | Standalone Python binary (deprecated) | Go plugin distributed with Docker Engine/Desktop |
| Status | Deprecated since 2020, unmaintained | Current standard |

Always use `docker compose` (v2) in Inception. If a Makefile or script calls the v1
`docker-compose`, fix it — v1 will misbehave or be missing on evaluation machines.

---

## 2. The docker-compose.yml File — Structure

```yaml
version: '3.8'          # Optional in modern Docker (Compose V2 ignores it)

services:               # Container definitions — the core of the file
  service_name:
    build: ./path       # Path to build context (directory with Dockerfile)
    image: myimage      # Tag for the built image
    container_name: c1  # Fixed name (optional — Compose names auto otherwise)
    ports:
      - "443:443"       # host:container
    volumes:
      - /host/path:/container/path
    environment:
      - VAR=value
    env_file:
      - ../.env
    restart: always
    depends_on:
      - other_service

networks:               # Custom network definitions
  mynet:
    driver: bridge

volumes:                # Named volume definitions
  db_data:
    driver: local
    driver_opts:
      type: none
      o: bind
      device: /home/user/data/mariadb

secrets:                # Docker Swarm-style secrets (optional but recommended)
  db_password:
    file: ./secrets/db_password.txt
```

### 2.1 Important Inception Rules Regarding Compose

The subject imposes specific constraints:

| Rule | Meaning in Compose |
|------|--------------------|
| No `latest` tag | Pin exact versions everywhere (e.g., `FROM debian:bookworm`) |
| Images must be named the same as their service | `image: nginx` for the nginx service, `image: wordpress` for wordpress, `image: mariadb` for mariadb |
| Build your own images — pulling ready-made ones is forbidden | One Dockerfile per service; `image:` only tags your build. You may NOT use the official wordpress/mariadb/nginx images from Docker Hub |
| Only port 443 published | Only NGINX publishes `443:443`. Ports 9000 (php-fpm) and 3306 (mariadb) stay internal to the bridge network |
| `network: host` forbidden | Do not use `network_mode: host` — use a custom bridge network |
| `--link` / `links:` forbidden | Never use `links:` in compose — use service name resolution via the bridge network's embedded DNS |
| No passwords in Dockerfiles | Use `env_file` or `environment` mapping from `.env`; never hardcode credentials |
| Restart on crash | Use `restart: always` or `restart: on-failure` |
| No hacky keepalives | No `tail -f`, `sleep infinity`, `while true` — the process itself must stay foreground |
| `.env` must not be committed | Add `.env` to `.gitignore` |

---

## 3. Compose Build Flow — What Happens When You `docker compose up --build`

```
$ docker compose -f srcs/docker-compose.yml up -d --build
```

The daemon processes the compose file top-to-bottom, service by service. Here's the exact sequence:

### Phase 1: Parse and Validate
1. Compose reads the YAML file and interpolates variables from `.env` / shell environment.
2. Validates the syntax and checks for circular dependencies.
3. Determines the build order from `depends_on` chains: mariadb first, then wordpress, then nginx.
4. Checks if a custom network was requested; if not, creates one automatically (default: `projectname_default`, bridge driver).

### Phase 2: Build Images (because of `--build`)
1. For each service with a `build:` key: `docker build -t <image_name> -f <Dockerfile> <context_dir>`
2. Each image is tagged with the `image:` name.
3. If `--no-build` is omitted and an image already exists with that tag, Compose **reuses** the cached image (even if the Dockerfile changed). `--build` forces a rebuild. Use it.

### Phase 3: Create Network
1. If a custom network is defined, Compose creates it.
2. If no network is defined, Compose creates one automatically and attaches all services to it.
3. The network gets a subnet (e.g., `172.18.0.0/16`) and an embedded DNS server at `127.0.0.11`.

### Phase 4: Create Volumes
1. For each named volume, Compose creates it (if `external: true`, it expects it to already exist).
2. For bind mounts (which Inception uses), Compose ensures the host path exists.

### Phase 5: Start Services in Dependency Order
1. Start `mariadb` (no dependencies).
2. Once `mariadb` is running (CONTAINER STATE = running), start `wordpress` (depends_on mariadb).
3. Once `wordpress` is running, start `nginx` (depends_on wordpress).

**Caveat:** `depends_on` only waits for the container to **start**, not for the service inside
to be **ready** (e.g., mariadb might still be initializing when wordpress tries to connect).
Inception's init scripts must handle this with retry loops.

### Phase 6: Attach the Writable Layer
1. Each container gets its unique thin read-write layer (upperdir) on top of the image layers.
2. Volume mounts are overlaid on top of the stacked filesystem at their specified paths.

### Phase 7: Apply Constraints
1. Namespaces and cgroups are set up by containerd → runc.
2. `restart: always` is installed as a policy in the container's metadata.

---

## 4. Docker Networks

### 4.1 What Is a Docker Network?

A virtual network that runs entirely inside the host kernel — no physical cables, no router,
no external switch. Docker creates it using Linux kernel features:

- **Network namespace** → Each container gets its own virtual network stack (interfaces, routing table, iptables rules) isolated from the host
- **Virtual Ethernet pair (veth)** → A virtual cable. One end in the container, one end plugged into a virtual bridge on the host
- **Bridge** → A virtual switch (like `docker0`) that connects all containers on the same network
- **iptables / NAT** → For outbound access and port publishing

```
Host Network Stack
──────────────────
┌────────────────────────────────────────────────────────────┐
│  Physical NIC: eth0 (192.168.1.10)                         │
│                                                            │
│  ┌──────────────────────────────────────────┐              │
│  │  Docker Bridge: br-xxxx (172.18.0.1)     │              │
│  │  ┌─────────┐  ┌─────────┐  ┌─────────┐   │              │
│  │  │ vethA   │  │ vethB   │  │ vethC   │   │              │
│  │  └────┬────┘  └────┬────┘  └────┬────┘   │              │
│  └───────┼────────────┼────────────┼──────────┘              │
│          │            │            │                        │
│  ┌───────┴──┐  ┌──────┴────┐ ┌────┴──────┐                  │
│  │   NS A  │  │   NS B    │ │   NS C    │  ← Network       │
│  │  eth0:  │  │  eth0:    │ │  eth0:    │     Namespaces   │
│  │172.18.0│  │172.18.0.3 │ │172.18.0.4 │                  │
│  │ nginx   │  │ wordpress │ │ mariadb   │                  │
│  └─────────┘  └───────────┘ └───────────┘                  │
└────────────────────────────────────────────────────────────┘
```

**Flow: nginx → wordpress → mariadb**
1. nginx (172.18.0.2) sends a TCP packet to `wordpress:9000`
2. Docker's embedded DNS (127.0.0.11 inside the container) resolves `wordpress` → `172.18.0.3`
3. The packet leaves nginx's vethA, hits the bridge, and is delivered to vethB (wordpress)
4. wordpress processes the request and sends a MySQL query to `mariadb:3306`
5. DNS resolves `mariadb` → `172.18.0.4`
6. The packet flows through the bridge to vethC

**No port publishing is needed for container-to-container communication.**
The containers are on the same virtual LAN.

### 4.2 Network Driver Types

| Driver | Behavior |
|--------|----------|
| **bridge** | Default. Containers are on a private virtual network. They can talk to each other. To reach them from the host, you must publish ports (`-p`). This is what Inception uses. |
| **host** | Container shares the host's network namespace directly. No isolation. `localhost` in container = `localhost` on host. **Forbidden in Inception.** |
| **none** | Container has a network namespace but no interface (`lo` only). Completely isolated. |
| **overlay** | Swarm mode only. Multi-host networking across a cluster. Not relevant. |
| **macvlan** | Container gets a real MAC address on the physical network. Rarely needed. Not relevant. |

### 4.3 Embedded DNS — "magic" Service Name Resolution

Docker's bridge network includes a built-in DNS server at `127.0.0.11` inside each container.
When a container tries to resolve `mariadb`, this DNS server:

1. Checks: "Is there a container on this network named `mariadb`?"
2. If yes, returns that container's IP.
3. If the container restarts and gets a new IP, the DNS record updates automatically.

```
$ docker exec -it nginx ping mariadb
PING mariadb (172.18.0.4) 56(84) bytes of data.
```

This is why `--link` and `links:` are obsolete and forbidden. You don't need them.
Service name = DNS name = reachable from any container on the same network. Inception's
three containers communicate entirely through these DNS-resolved service names:
- `nginx → wordpress:9000`  (FastCGI)
- `wordpress → mariadb:3306` (MySQL protocol)

### 4.4 Port Publishing vs Container-to-Container Communication

| Purpose | Syntax | Effect |
|---------|--------|--------|
| Expose to **host** only (or other containers) | `EXPOSE 3306` in Dockerfile | Documentation. No actual action. Still reachable between containers on same network regardless. |
| Publish to **host** | `ports: "443:443"` in compose | The host's port 443 → container's port 443. Accessible from outside the VM. |
| Declare in compose | `expose: ["9000"]` | Same as EXPOSE: documentation only. No effect — containers on the same network can already reach each other's ports regardless. |
| Container-to-container | Nothing needed | All containers on the same bridge network can reach each other's ports. No publish, no expose required. |

**Inception only publishes port 443 on nginx.** Ports 9000 (php-fpm) and 3306 (mariadb) are
never published to the host — only accessible within the Docker network.

### 4.5 Subnet and IP Allocation

```
$ docker network inspect mynetwork
[
    {
        "Name": "mynetwork",
        "IPAM": {
            "Config": [
                {
                    "Subnet": "172.18.0.0/16",
                    "Gateway": "172.18.0.1"
                }
            ]
        },
        "Containers": {
            "abc123...": {
                "Name": "nginx",
                "IPv4Address": "172.18.0.2/16"
            },
            "def456...": {
                "Name": "wordpress",
                "IPv4Address": "172.18.0.3/16"
            }
        }
    }
]
```

- Subnet defaults to a private range (172.x or 10.x).
- Gateway (172.18.0.1) is the bridge interface on the host.
- Each container gets a routable IP within the subnet.
- You can lock IPs down with `ipam` config, but almost never need to — let DNS handle naming.

---

## 5. Docker Volumes

### 5.1 Why Volumes Exist

```
┌──────────────────────────────────────────────────────┐
│  Container filesystem (view from inside)              │
│                                                       │
│  upperdir (rw layer)  ← temporary. dies with container│
│  layer 3 (app)        ← read-only image layers        │
│  layer 2 (php)        ← persist across containers     │
│  layer 1 (debian)     ←                           │
│                                                       │
│  VOLUME MOUNT: /var/lib/mysql                         │
│      ↕                                               │
│  /home/user/data/mariadb   ← host directory. persists │
│                                forever (until rm -rf) │
└──────────────────────────────────────────────────────┘
```

Volumes solve the fundamental problem: **containers are ephemeral by design, but data must survive.**

- Delete the container: the writable layer is gone. Volume data survives.
- Recreate the container with the same volume mount: data is back.
- Two containers can share the same volume (e.g., nginx and wordpress containers both mount the WordPress files volume).

### 5.2 Volume Types

| Type | Syntax | Example | In Inception? |
|------|--------|---------|---------------|
| **Bind mount** | Absolute host path → container path | `/home/user/data/mariadb:/var/lib/mysql` | Yes — the subject requires volumes in `/home/yourlogin/data/` |
| **Named volume** | Volume name → container path. Managed by Docker under `/var/lib/docker/volumes/` | `mariadb_data:/var/lib/mysql` | Optional. Bind mounts are more explicit. |
| **Anonymous volume** | Container path only | `/var/lib/mysql` (no host side) | No — uncontrolled. |

### 5.3 Bind Mount Syntax Deep Dive

The subject requires a specific bind mount pattern:

```yaml
volumes:
  mariadb_data:
    driver: local
    driver_opts:
      type: none
      o: bind
      device: /home/yourlogin/data/mariadb
```

This is the **long syntax**. It explicitly declares a bind mount. Each field:

| Field | Meaning |
|-------|---------|
| `driver: local` | Volume stored on the local filesystem (the VM's disk) |
| `type: none` | Not an NFS share, CIFS mount, or tmpfs — it's a plain directory |
| `o: bind` | The mount option is `bind`, meaning it directly maps a host path |
| `device: /home/.../mariadb` | The absolute host directory to bind |

This is equivalent to `-v /home/yourlogin/data/mariadb:/var/lib/mysql` but declared
in compose YAML explicitly.

### 5.4 Short Syntax vs Long Syntax

```yaml
# Short syntax (still valid):
volumes:
  - /home/yourlogin/data/mariadb:/var/lib/mysql

# Long syntax (explicit, preferred for project clarity):
volumes:
  - type: bind
    source: /home/yourlogin/data/mariadb
    target: /var/lib/mysql
```

Either works. The long syntax is more readable and lets you set read-only mode (`read_only: true`).

### 5.5 The Inception Volume Layout

```yaml
services:
  mariadb:
    volumes:
      - mariadb_data:/var/lib/mysql    # database files

  wordpress:
    volumes:
      - wordpress_data:/var/www/html   # wp-content, themes, plugins

  nginx:
    volumes:
      - wordpress_data:/var/www/html   # SAME volume — nginx serves the WP files
                                        # that wordpress installed

volumes:
  mariadb_data:
    driver: local
    driver_opts:
      type: none
      o: bind
      device: /home/yourlogin/data/mariadb

  wordpress_data:
    driver: local
    driver_opts:
      type: none
      o: bind
      device: /home/yourlogin/data/wordpress
```

**Critical detail:** nginx and wordpress must **share** the same WordPress volume.
WordPress installs and maintains the files; NGINX serves them. Two containers with two
different read-write upper layers + one shared volume. The volume overrides the image
content at `/var/www/html` in both containers (or at least, the volume content shadows
the image's copy of that path).

### 5.6 Volume Mount Behavior — First-Time Initialization

When you mount a volume to a container path:

- **Host directory is empty:** The content from the image layer at that path is **temporarily**
  visible, but as soon as something writes to the volume, that shadowing is lost.
  Docker does NOT copy image content to the volume on bind mounts (it does for named volumes).
  Your init script must populate the directory.

- **Host directory has data:** The host data shadows any image content at that path.
  The container sees the host files, not the image's original content.

This is why Inception's init scripts are crucial. On first run with empty host directories,
the scripts must download and populate WordPress (via wp-cli) and initialize MariaDB
(via `mariadb-install-db` or equivalent).

---

## 6. The .env File

### 6.1 What It Is

A plain text file containing key=value pairs. It lives **outside** the Dockerfiles,
outside the images, and must be excluded from git.

```bash
# .env — DO NOT COMMIT
DOMAIN_NAME=rxy.42.fr

MYSQL_DATABASE=wordpress
MYSQL_USER=wpuser
MYSQL_PASSWORD=ThisIsAStrongPassword123
MYSQL_ROOT_PASSWORD=AnEvenStrongerRootPass456

WP_ADMIN_USER=siteadmin
WP_ADMIN_PASSWORD=AdminPass789
WP_ADMIN_EMAIL=admin@rxy.42.fr

WP_USER=author
WP_USER_PASSWORD=AuthorPass012
WP_USER_EMAIL=author@rxy.42.fr
```

### 6.2 How Compose Consumes It

`docker compose` automatically reads `.env` from the project directory (the directory
containing the compose file or the working directory where you run `docker compose`).

If your compose file lives at `srcs/docker-compose.yml` and your `.env` is in `srcs/`,
you say:

```yaml
services:
  wordpress:
    env_file:
      - .env    # relative to compose file
```

Or you interpolate variables inline:

```yaml
environment:
  MYSQL_DATABASE: ${MYSQL_DATABASE}
  MYSQL_USER: ${MYSQL_USER}
  MYSQL_PASSWORD: ${MYSQL_PASSWORD}
```

Or feed it with `--env-file`:

```bash
docker compose --env-file srcs/.env -f srcs/docker-compose.yml up -d
```

### 6.3 The Lifecycle of a Secret — .env Does NOT Leave the Host

```
.env (host only, gitignored)
    │
    │ docker compose reads it at `up` time
    ▼
docker-compose.yml (references ${VAR})
    │
    │ Compose interpolates the values
    ▼
Container environment variables:
  MYSQL_PASSWORD=ThisIsAStrongPassword123

    │ init script inside container reads the env var
    ▼
wp config create --dbpass="$MYSQL_PASSWORD" ...
mariadb CREATE USER ... IDENTIFIED BY '$MYSQL_PASSWORD';

The password is:
  1. On host: in .env only (not in image, not in git)
  2. In container: in memory (process env) and in WordPress/MariaDB config files inside the volume
  3. In image: NEVER. The Dockerfile doesn't see .env at all.
```

### 6.4 Security Checklist for Inception

- `.env` is in `.gitignore` ✓
- No `COPY .env` in any Dockerfile ✓
- `.dockerignore` contains `.env` ✓
- Images are validated: `docker history <image>` shows no passwords ✓
- `git log -p` shows no passwords in any commit ✓

### 6.5 `.env` vs `env_file` — Two Different Mechanisms (Frequent Confusion)

These are easy to conflate. They do two completely different jobs:

| | `.env` (project directory) | `env_file:` / `environment:` |
|---|---|---|
| **Who reads it** | The Compose **CLI itself**, while parsing the YAML | The **container runtime**, when starting the container |
| **What it does** | Interpolates `${VAR}` placeholders *inside* docker-compose.yml | Sets variables *inside the container's* process environment |
| **Automatic?** | Yes — Compose auto-reads `.env` from the project directory | No — only the keys you declare via `env_file:` or `environment:` are set |

The two most common traps:

1. **`.env` does NOT inject anything into containers by itself.** If you write
   `MYSQL_PASSWORD: ${MYSQL_PASSWORD}` under `environment:`, the interpolation comes
   from `.env` — and because the result sits in `environment:`, the container sees it.
   But a bare `.env` next to the compose file does not make the container see
   `MYSQL_PASSWORD`.

2. **`env_file:` does NOT enable interpolation.** A `.env` listed under `env_file:`
   puts every key/value into the container's environment, but `${...}` placeholders
   elsewhere in the YAML are still interpolated from the project `.env` (or the
   `--env-file` flag), not from what `env_file:` declares.

Rule of thumb for Inception:
- `.env` in `srcs/` → interpolation of the compose file (and gitignored)
- `env_file: [.env]` or explicit `environment:` keys → what the containers actually see

---

## 7. depends_on and Startup Ordering

### 7.1 What It Does (and Doesn't)

```yaml
wordpress:
  depends_on:
    - mariadb
```

**What it guarantees:** Compose starts `mariadb` before `wordpress`. If `mariadb` fails
to start, `wordpress` won't be started.

**What it does NOT guarantee:** That MariaDB is **ready to accept connections** when
wordpress starts. The container is running, but `mysqld` might still be initializing
the data directory (especially on first boot with an empty volume). WordPress's init
script will connect, get a "connection refused," and fail.

### 7.2 The Solution: Retry Logic in Init Scripts

Every init script must handle the "dependency not ready yet" case:

```bash
# In wordpress init script
wait_for_mariadb() {
    echo "Waiting for MariaDB to be ready..."
    for i in $(seq 1 30); do
        if mariadb-admin -h mariadb -u root -p"${MYSQL_ROOT_PASSWORD}" ping --silent; then
            echo "MariaDB is ready."
            return 0
        fi
        echo "Attempt $i/30: MariaDB not ready yet..."
        sleep 2
    done
    echo "ERROR: MariaDB never became ready."
    exit 1
}
```

**Modern approach (Docker Compose v3.8+):** Use healthchecks. Compose waits for the
health status to become `healthy`:

```yaml
mariadb:
  healthcheck:
    test: ["CMD", "mariadb-admin", "ping", "--silent"]
    interval: 5s
    timeout: 5s
    retries: 10

wordpress:
  depends_on:
    mariadb:
      condition: service_healthy   # Don't start until mariadb passes healthcheck
```

Both approaches are valid. The retry loop is more portable (works in older Docker versions).
Healthchecks are cleaner and declarative.

---

## 8. restart Policy

```yaml
restart: always
```

| Policy | Behavior |
|--------|----------|
| `no` (default) | Never restart. Container dies → stays dead. |
| `always` | Restart no matter what. Crash, `docker stop`, even daemon restart → always comes back. |
| `on-failure` | Restart only if the container exits with a non-zero exit code (crash). Normal `docker stop` (exit 0) won't trigger restart. |
| `unless-stopped` | Like `always`, but won't restart if you explicitly `docker stop` it and then restart the daemon. |

**For Inception:** Use `restart: always` on all three services. If MariaDB crashes at 3 AM,
it comes back automatically. If NGINX segfaults, it restarts. High availability, minimal
configuration.

---

## 9. Custom Network Configuration (Inception-Specific)

```yaml
networks:
  inception_net:
    name: inception_net
    driver: bridge
```

All three services attach to it:

```yaml
services:
  nginx:
    networks:
      - inception_net
    # Only NGINX publishes a port
    ports:
      - "443:443"

  wordpress:
    networks:
      - inception_net
    # No ports published — only accessible within inception_net

  mariadb:
    networks:
      - inception_net
    # No ports published — only accessible within inception_net
```

Result:
- Isolated bridge network named `inception_net`
- Subnet automatically assigned
- DNS resolution: `nginx` ↔ `wordpress` ↔ `mariadb`
- Only port `443` bound to the host (VM)
- External traffic path: Browser → `https://rxy.42.fr:443` → Host (VM) port 443 → NGINX container → `fastcgi_pass wordpress:9000` → `wp-config.php` → `DB_HOST=mariadb:3306`

---

## 10. Multi-Stage Networks (Advanced — Not Needed but Good to Know)

You can create multiple networks to further limit communication:

```yaml
networks:
  frontend:
  backend:

services:
  nginx:
    networks:
      - frontend
      - backend       # nginx can talk to both
  wordpress:
    networks:
      - backend       # wordpress only on backend
  mariadb:
    networks:
      - backend       # mariadb only on backend
```

Here, mariadb and wordpress can't be reached from anything on the `frontend` network
except through nginx. Defense-in-depth networking. Not required by the Inception subject
but worth understanding.

---

## 11. Debugging Compose

### 11.1 Key Commands

```bash
docker compose -f srcs/docker-compose.yml up -d --build   # build + start
docker compose -f srcs/docker-compose.yml ps               # list stack status
docker compose -f srcs/docker-compose.yml logs -f           # follow all logs
docker compose -f srcs/docker-compose.yml logs nginx        # logs of one service
docker compose -f srcs/docker-compose.yml exec wordpress bash  # shell into a service
docker compose -f srcs/docker-compose.yml down             # stop + remove containers
docker compose -f srcs/docker-compose.yml down -v           # also remove volumes (careful!)
docker compose -f srcs/docker-compose.yml down --rmi all   # also remove images
docker compose -f srcs/docker-compose.yml config            # validate + print the compose file
```

### 11.2 Config Validation

```bash
$ docker compose config
name: inception
services:
  nginx:
    build:
      context: ./requirements/nginx
    ...
```

This dumps the parsed compose file with all variables interpolated. If there's a syntax
error, it'll tell you. If a variable from `.env` is missing, it'll warn. Always run this
before pushing to eval.

---

## 12. Check Your Understanding

Answer without looking:

1. What's the difference between `docker run` and `docker compose up`? Why would you use one over the other?
2. How does `nginx:443` inside the NGINX container become reachable at `https://rxy.42.fr` from the browser?
3. How does the NGINX container reach the WordPress container without any port publishing on WordPress?
4. What mechanism resolves the service name `wordpress` to an IP address inside the container?
5. Why are `--link` and `links:` deprecated and forbidden in Inception?
6. Why is `network_mode: host` forbidden?
7. What's the difference between `ports:` in compose and `EXPOSE` in a Dockerfile?
8. What survives when you `docker compose down`? What doesn't?
9. If the MariaDB data directory at `/home/yourlogin/data/mariadb` is empty on first boot, what happens? Who populates it?
10. How does WordPress know which database host, user, and password to connect to?
11. What does `restart: always` guarantee? What does it NOT guarantee?
12. Where does the `.env` file live? How does it reach the container's environment? Why must it be gitignored?
13. What does `depends_on` actually wait for? What does it NOT wait for?
14. What is the difference between `.env` (project directory) and `env_file:`? Which one interpolates the compose file and which one sets container environment variables?

---

*Next file: `1-4-pid1-foreground.md` (PID 1, foreground vs daemon, zombie reaping, subject rules)*
