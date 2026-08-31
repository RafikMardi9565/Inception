# 1.2 — Docker Architecture Deep Dive

Docker is a platform, not a single binary. Understanding its internal components is critical
because evaluators will ask you to explain exactly what happens between `docker build` and a running container.

---

## 1. The Docker Engine (Client-Server Architecture)

Docker uses a classic client-server model with three components:

```
                   REST API (UNIX socket or TCP)
┌─────────┐                                         ┌───────────┐
│  CLI    │ ────────── /var/run/docker.sock ──────» │  dockerd  │
│ (client)│                                         │  (daemon) │
└─────────┘                                         └─────┬─────┘
                                                          │
                                          ┌───────────────┼───────────────┐
                                          │               │               │
                                     containerd        buildkit      image pull /
                                    (container    (image build,    registry access
                                     manager)      since 18.09)
                                          │
                                          ├── containerd-shim  ← one per container;
                                          │      stays for the container's lifetime
                                          └── runc  (low-level runtime;
                                                     creates the process, then exits)
```

### 1.1 The Docker CLI (`docker`)

This is the command-line tool you type into. It **does not** run containers, download images, or
build anything. It only:
- Constructs JSON API requests
- Sends them to the daemon via `/var/run/docker.sock` (UNIX socket) or TCP
- Displays the response

```
$ docker run nginx
```

The `docker` binary translated this into: `POST /containers/create { "Image": "nginx", ... }`
then `POST /containers/{id}/start`. The CLI is just a translator from human commands to API calls.

### 1.2 The Docker Daemon (`dockerd`)

This is the long-running background process (started by systemd or manually) that actually:
- Listens for API requests on the socket
- Manages all Docker objects (images, containers, networks, volumes)
- Delegates heavy lifting to `containerd`

The daemon is the **brain**. The CLI is just the keyboard. You can talk to the daemon without
the CLI at all — the Docker SDK (Python, Go) or even `curl --unix-socket` can do it.

### 1.3 containerd

A lower-level daemon that manages the container lifecycle:
- Pulls and pushes images from registries
- Creates, starts, stops, and deletes containers
- Manages container networking
- Spawns a `containerd-shim` per container and delegates the actual process creation to `runc` through it

Docker split `containerd` out of the monolith in 2017. Now it's an independent CNCF graduated project
used by other platforms (Kubernetes via CRI, etc.).

### 1.4 runc

The lowest-level component. It:
- Reads the OCI runtime spec (a JSON config describing namespaces, cgroups, rootfs, capabilities)
- Calls Linux kernel syscalls (`clone()`, `unshare()`, `setns()`, `pivot_root()`, etc.)
- Actually creates the container process

`runc` is the thing that says: "Kernel, give me a PID namespace, a NET namespace, a MNT namespace,
limit this to 256MB RAM, and exec `/usr/sbin/nginx`."

After the process starts, `runc` exits — its job is done. The container process is now
parented by **containerd-shim**, which stays for the container's entire lifetime. The
container itself is just a regular host process.

### 1.5 containerd-shim

One shim process per container (`containerd-shim-runc-v2`). Its jobs:

- **Stays alive** for the container's entire lifetime (runc exits after creating the process)
- **Keeps stdio attached** — container stdout/stderr are piped through the shim to Docker's log driver
- **Reports the exit status** of the container process back to containerd when it dies
- **Survives daemon restarts** — if containerd/dockerd restart, running containers keep running because the shim still holds them

Because of the shim, daemon upgrades don't kill your containers.

**The container's init-analog:** on a real system, systemd keeps daemons alive,
supervises them, reaps orphans, and collects their logs. For a container, the shim
plays that same role — which is why daemons inside containers run "naked" in the
foreground (PID 1) instead of self-daemonizing. The platform already IS the init;
the daemonization ritual has nothing left to do (see 1-4 §3.6 for the full argument).

### 1.6 Complete Flow: `docker run nginx`

```
$ docker run nginx                       ← CLI
         │
         ▼
dockerd receives the request             ← Daemon
         │
         ├── Is the image "nginx" cached locally?
         │   ├── No? Pull from registry (Docker Hub)
         │   └── Yes? Continue
         │
         ▼
containerd creates a container object    ← Manager
          │
          ├── spawns containerd-shim      ← one shim per container
          │
          ├── Prepare the root filesystem:
         │   1. Unpack image layers into a read-only overlay
         │   2. Create a thin writable layer on top
         │   3. Mount volumes (if any)
         │
         ├── Set up the network:
         │   1. Create a veth pair (virtual Ethernet)
         │   2. Connect one end to the container namespace
         │   3. Connect the other end to the Docker bridge
         │
         ├── Generate OCI runtime spec
         │   (namespaces, cgroups, capabilities, rootfs path)
         │
         ▼
runc calls kernel syscalls:              ← Low-level runtime
          │   clone() with namespace flags
          │   pivot_root() to the container rootfs
          │   exec(nginx)
          │
          ▼
runc exits; the shim stays as parent of  ← Shim supervises:
nginx (PID 1 in the container)            stdio + exit status
          │
          ▼
nginx runs as PID 1 inside container     ← Your process
```

**Key takeaway:** The CLI is thin. The daemon orchestrates. containerd manages. runc creates. The shim supervises.

---

## 2. Docker Images

### 2.1 What Is an Image?

An image is a **read-only template** containing:
1. A minimal root filesystem (userland from Debian/Alpine)
2. Your application binaries, libraries, configs
3. Metadata (env vars, default command, exposed ports, volumes, working directory)

An image is **never executed directly**. It's only used as a blueprint to create containers.

### 2.2 Image = Stack of Read-Only Layers

An image is NOT a single large tarball. It's a **linked list of layers**, each layer being
a directory of files that differ from the layer below it.

```
┌─────────────────────────┐
│  RUN apk add php        │  ← Layer 3 (a few MB of PHP binaries)
├─────────────────────────┤
│  RUN apk add nginx      │  ← Layer 2 (~10 MB of NGINX binaries)
├─────────────────────────┤
│  FROM alpine:3.20       │  ← Layer 1 (~7 MB base rootfs)
└─────────────────────────┘
```

Each layer is stored as a directory on the host under `/var/lib/docker/overlay2/`.

### 2.3 How Layers Are Stored: OverlayFS

Docker uses **OverlayFS** (a type of union filesystem built into the Linux kernel) to stack
layers into a single unified filesystem view.

OverlayFS needs three directories:
| Directory | Purpose |
|-----------|---------|
| `lowerdir` | The read-only image layers (ordered, colon-separated) |
| `upperdir` | The writable container layer (starts empty) |
| `merged` | The unified view your container sees |

```
┌───────────────────────────────────┐
│  MERGED (what the container sees)  │
├───────────────────────────────────┤
│  ┌─────────────────────────┐       │
│  │  upperdir (writable)    │       │  ← Container writes go here
│  │  /var/log/nginx/access  │       │
│  ├─────────────────────────┤       │
│  │  lowerdir layer 3 (PHP) │       │
│  ├─────────────────────────┤       │
│  │  lowerdir layer 2 (NGX) │       │
│  ├─────────────────────────┤       │
│  │  lowerdir layer 1 (OS)  │       │
│  └─────────────────────────┘       │
└───────────────────────────────────┘
```

**Copy-on-Write (CoW):** When you modify a file, OverlayFS copies it from the lower layer
into the upper layer first, then modifies the copy. The lower layer always stays untouched.
This means:
- The original image layers can be **shared** across 100 containers
- Only the writes (upperdir) consume new disk space per container
- Deleting a container only removes the thin upperdir

### 2.4 Why Layers Matter for Build Speed

Each instruction in a Dockerfile creates a new layer:

```dockerfile
FROM alpine:3.20                              # Layer 1
RUN apk update && apk add --no-cache nginx     # Layer 2
COPY nginx.conf /etc/nginx/nginx.conf          # Layer 3
COPY entrypoint.sh /entrypoint.sh              # Layer 4
```

Docker caches every layer. If you rebuild and only `entrypoint.sh` changed, layers 1-3 are fetched
from cache. Only layer 4 is rebuilt. This turns a 60-second rebuild into 0.5 seconds.

**Rule of thumb:** Put infrequently changed instructions first (OS installs, package managers),
and frequently changed instructions last (COPYing your own code). This maximizes cache hits.

---

## 3. Docker Containers

### 3.1 What Is a Container?

A container is **a running instance of an image** — plus one additional writable layer on top
for runtime modifications.

| Concept | Role |
|---------|------|
| **Image** | Blueprint; read-only; a stack of immutable layers |
| **Container** | The actual running thing; image + writable layer + process |
| **Image → Container relationship** | You can run N containers from 1 image, just like you can instantiate N objects from 1 class |

### 3.2 What Happens When a Container Starts

1. Docker unpacks the image layers into an OverlayFS mount (lowerdir)
2. Creates an empty upperdir (writable layer)
3. Creates the `merged` view combining both
4. Sets up namespaces (PID, NET, MNT, UTS, IPC) via `clone()` and `unshare()`
5. Applies cgroup limits (CPU, RAM, I/O)
6. Mounts volumes if specified
7. Drops Linux capabilities (setuid, loading kernel modules, binding ports < 1024, etc.)
8. `exec()`s the CMD or ENTRYPOINT as PID 1

### 3.3 Container Lifecycle

```
   [pull]     [create]     [start]      [die/stop]     [rm]
(registry) ────→ Image ────→ Created ────→ Running ────→ Exited ────→ Deleted
                   │              ▲                        │
                   │              └──── [start] ───────────┘
                   │
              [build]
              (Dockerfile + context)
```

- **Created:** Container exists but process hasn't started
- **Running:** Process is executing
- **Paused:** Process frozen (SIGSTOP equivalent)
- **Exited:** Process terminated (exit code 0 = success, non-zero = error)
- **Deleted:** Container removed via `docker rm`

---

## 4. Dockerfile and `docker build`

### 4.1 What Is a Dockerfile?

A Dockerfile is a **declarative script** — a list of instructions that describe how to assemble
an image. It is NOT a shell script (even though it looks like one). Each instruction produces exactly
one layer.

### 4.2 Key Instructions (Inception Essentials)

| Instruction | What it does | Example |
|-------------|--------------|---------|
| `FROM` | Sets the base image (must be first) | `FROM alpine:3.20` |
| `RUN` | Executes a command **during build** (creates a layer) | `RUN apk add --no-cache nginx` |
| `COPY` | Copies files from host into the image | `COPY nginx.conf /etc/nginx/` |
| `ADD` | Like COPY but can extract tarballs and fetch URLs | `ADD xxx.tar.gz /tmp/` |
| `WORKDIR` | Sets working directory for subsequent instructions | `WORKDIR /var/www/html` |
| `EXPOSE` | Documents which port the container listens on (does NOT publish!) | `EXPOSE 443` |
| `ENV` | Sets an environment variable | `ENV DOMAIN_NAME=example.com` |
| `ARG` | Build-time variable (not persisted in image) | `ARG VERSION=1.0` |
| `VOLUME` | Creates a mount point for external volumes | `VOLUME /var/lib/mysql` |
| `ENTRYPOINT` | Defines the main process (hard to override) | `ENTRYPOINT ["nginx"]` |
| `CMD` | Default arguments to ENTRYPOINT (easy to override) | `CMD ["-g", "daemon off;"]` |
| `USER` | Switches to a non-root user | `USER www-data` |
| `HEALTHCHECK` | Defines a command whose exit status marks the container healthy or unhealthy | `HEALTHCHECK CMD curl -f http://localhost || exit 1` |
| `STOPSIGNAL` | Overrides the signal Docker sends first on `docker stop` (default: SIGTERM) | `STOPSIGNAL SIGQUIT` |

### 4.3 Shell Form vs Exec Form

```dockerfile
# SHELL FORM: runs inside /bin/sh -c "..."
# PID 1 will be /bin/sh, not your process (BAD)
CMD nginx -g "daemon off;"

# EXEC FORM: runs directly, no shell wrapper
# Your process IS PID 1 (CORRECT for Inception)
CMD ["nginx", "-g", "daemon off;"]
```

**ALWAYS use exec form.** If you use shell form, `/bin/sh` becomes PID 1, and your real process
runs as a child. SIGTERM goes to `/bin/sh`, which may not forward it — meaning `docker stop`
takes 10 seconds timeout instead of cleanly shutting down.

### 4.4 `docker build` Step-by-Step

```
$ docker build -t inception_nginx .
```

1. Docker CLI packs the **build context** (everything in `.` — the current directory, except `.dockerignore`) into a tar and sends it to the daemon
2. Daemon reads the Dockerfile line by line
3. For each instruction:
   a. Spins up a temporary container from the previous image state
   b. Runs the instruction inside it
   c. Commits the result as a new image (a new layer)
   d. Removes the temporary container
4. Tags the final image as `inception_nginx`

**Note:** Modern Docker (23+) builds with **BuildKit** by default (`DOCKER_BUILDKIT=1`).
BuildKit compiles the Dockerfile into a dependency graph and executes instructions as
parallelizable steps rather than literally spawning an intermediate container per line —
but the layer-per-instruction result is identical, so the mental model above still holds.

### 4.5 Build Context and `.dockerignore`

- The **build context** is the directory you specify (usually `.`)
- **Everything** in it gets sent to the daemon. If you have a 1GB `node_modules/`, the daemon receives all 1GB.
- Use `.dockerignore` to exclude files (like `.git`, `node_modules`, etc.) — saves bandwidth and protects `.env` from leaking into the image.

```
# .dockerignore
.git
.env
*.md
Dockerfile
docker-compose.yml
```

### 4.6 ENTRYPOINT vs CMD (Interview Favorite)

```dockerfile
ENTRYPOINT ["nginx"]
CMD ["-g", "daemon off;"]
```

When the container starts, these are concatenated: `nginx -g "daemon off;"`

| | ENTRYPOINT | CMD |
|---|-----------|-----|
| **Purpose** | The fixed command to run | Default arguments |
| **Overridable?** | Only with `--entrypoint` flag | Easily — `docker run nginx echo hello` replaces CMD |
| **Use case** | "This container IS an nginx server" | "Run nginx with these default flags" |

If the Dockerfile only has `CMD`, that CMD becomes the full command (and is easily overridable).
If the Dockerfile has both, CMD becomes args to ENTRYPOINT.

### 4.7 Multi-Stage Builds

One Dockerfile can contain several `FROM` instructions. Each starts a new build stage; the
final image contains **only the last stage**. Intermediate stages are used as scratchpads
and referenced with `COPY --from=`.

```dockerfile
# ── Stage 1: builder (never ships) ───────────────────────
FROM debian:bookworm AS builder
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential libpcre3-dev zlib1g-dev libssl-dev wget \
 && rm -rf /var/lib/apt/lists/*
RUN wget https://nginx.org/download/nginx-1.24.0.tar.gz -O /tmp/nginx.tar.gz \
 && tar -xzf /tmp/nginx.tar.gz -C /tmp
WORKDIR /tmp/nginx-1.24.0
RUN ./configure --prefix=/usr/local/nginx --with-http_ssl_module \
 && make -j"$(nproc)" && make install

# ── Stage 2: runtime (this is your image) ────────────────
FROM debian:bookworm
COPY --from=builder /usr/local/nginx /usr/local/nginx
COPY conf/nginx.conf /usr/local/nginx/conf/nginx.conf
CMD ["/usr/local/nginx/sbin/nginx", "-g", "daemon off;"]
```

Why it matters:
- The final image contains **no compiler, no headers, no source code** — smaller, with a
  much smaller attack surface
- Only the last stage's layers end up in the image
- Perfect for Inception if you compile NGINX or PHP extensions from source

Not required by the subject, but a strong talking point at evaluation if you use it.

---

## 5. Docker Registries

### 5.1 What Is a Registry?

A registry is a **storage and distribution system** for Docker images. It's like GitHub for images.

```
$ docker pull nginx:1.25
```

1. CLI → daemon: "Get nginx:1.25"
2. Daemon checks local cache (`docker images`) — not found
3. Daemon calls registry (Docker Hub by default) → `GET /v2/library/nginx/manifests/1.25`
4. Registry returns a **manifest** (JSON listing all layers by content-hash SHA256)
5. Daemon downloads each layer that isn't already cached locally
6. Daemon verifies each layer's hash against the manifest (integrity check)
7. Daemon assembles the layers into an image

### 5.2 Common Registries

| Registry | URL | Notes |
|----------|-----|-------|
| Docker Hub | `docker.io` | Default if no host specified |
| GitHub Container Registry | `ghcr.io` | Tied to GitHub repos |
| Google Artifact Registry | `*.pkg.dev` | GCP-native |
| AWS ECR | `*.dkr.ecr.*.amazonaws.com` | AWS-native |
| Self-hosted | Any domain | Run your own with Harbor, Nexus, or the `registry:2` image |

### 5.3 Image Naming Convention

```
docker.io/library/nginx:1.25.3@sha256:abc123...
^^^^^^^^^^^^ ^^^^^^^ ^^^^^ ^^^^^^ ^^^^^^^^^^^^^^^
 registry     namespace repo  tag    digest (optional)
 └────────────┘ └───────────────┘
     host          path
```

- `docker.io/library/nginx:1.25` → official image from Docker Hub
- `ghcr.io/myorg/myapp:v1.0` → custom org image on GHCR
- If no tag is specified: defaults to `:latest`

**Important for Inception:** The subject forbids the `latest` tag. Always pin a specific version
(e.g., `alpine:3.20`, `debian:bookworm`).

---

## 6. Build Cache Deep Dive

### 6.1 How Cache Works

For each instruction, Docker computes a hash from:
- The instruction text itself
- The hash of the parent layer (previous instruction's image)
- For COPY/ADD: the hash of the files being copied

If the hash matches a previously built layer, Docker skips execution and reuses the cached layer.

```dockerfile
FROM alpine:3.20                    ← Cached (base image unchanged)
RUN apk add --no-cache nginx        ← Cached (same command + same parent hash)
COPY nginx.conf /etc/nginx/         ← Cached (same command + same file hash)
COPY . /var/www/                    ← NOT cached (source code changed)
RUN chmod +x /var/www/entrypoint.sh ← NOT cached (parent hash changed)
```

**Cache invalidation cascade:** If layer 3 is busted, layers 3, 4, 5, N are ALL rebuilt.
This is why ordering matters.

### 6.2 Cache-Busting Techniques

```dockerfile
# BAD: any source change busts the cache → dependencies reinstalled on every build
COPY . .
RUN pip install -r requirements.txt

# GOOD: dependencies are only reinstalled when requirements.txt itself changes
COPY requirements.txt .
RUN pip install -r requirements.txt
COPY . .
```

---

## 7. Check Your Understanding

Answer these without looking:

1. What three components make up the Docker engine? What does each do?
2. When you type `docker pull alpine:3.20`, which component(s) actually download the image?
3. What is an image? What is a container? How are they related?
4. Why does changing line 5 of a 10-line Dockerfile invalidate the cache for lines 5 through 10?
5. What filesystem does Docker use to stack layers? What is copy-on-write?
6. What's the difference between shell form CMD and exec form CMD? Why does it matter for PID 1?
7. What's the difference between ENTRYPOINT and CMD?
8. What does `EXPOSE 443` **actually** do? (Hint: almost nothing — it's documentation)
9. Why should you put `COPY . .` last in a Dockerfile?
10. How does a Docker registry store and distribute images? What is a manifest?
11. What is containerd-shim, and why does it exist?
12. What is a multi-stage build, and what does it buy you?

---

*Next file: `1-3-docker-compose-networks.md` (docker-compose, networks, volumes, env files)*
