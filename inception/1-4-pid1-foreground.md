# 1.4 — PID 1, Foreground Processes, and Why Hacky Keepalives Are Forbidden

This is the most frequently missed concept in Inception evaluations. Students
ship containers that "work" but fail the evaluation because they violate the
PID 1 principle. This file explains everything from kernel ground up.

---

## 1. What Is PID 1?

### 1.1 PID 1 in a Traditional Linux System

When a Linux system boots, the kernel starts exactly one process: the init system.
Its PID is 1. Its name is usually `systemd`, `SysV init`, or `OpenRC`.

```
Kernel boots → spawns PID 1 (init/systemd) → fork/exec everything else
```

PID 1 has **special responsibilities** that no other process has:

| Responsibility | Why Only PID 1 Can Do It |
|---------------|---------------------------|
| **Reap orphaned children** | When a parent dies, the kernel reparents the orphan to PID 1. PID 1 must call `wait()` on these orphans or they become permanent zombies. |
| **Receive signals no one else gets** | SIGCHLD from every orphaned process on the system arrives at PID 1. |
| **Protected from signals** | Signals that PID 1 has no handler for are ignored by the kernel — including SIGKILL sent from *inside* the same PID namespace. SIGKILL from the *host* side works and kills the whole container. (A kernel panic only happens if the **host's global init** — the real PID 1 of the host — dies.) |
| **Process tree root** | All processes descend from PID 1. When it dies, everything dies. |

### 1.2 PID 1 Inside a Container

Inside a container, the kernel also designates exactly one process as PID 1 — the
entrypoint or CMD. Everything works the same way as on a real system, except:

- There are far fewer children to manage (just the app's own children)
- There is no `systemd` — the app IS the init system
- The app probably wasn't designed to be an init system

This is the core tension of containers: **applications are written expecting systemd
to exist, but inside a container, there is no systemd.** If your app doesn't handle
the responsibilities of PID 1, things break subtly.

One nuance matters at evaluation time: the protection above is judged **per PID namespace**.
`docker exec nginx kill -9 1` does nothing — the kill comes from inside the same namespace,
so the kernel ignores it. `docker kill nginx` (sent by the daemon from the host namespace)
does kill PID 1 — and when a namespace's PID 1 dies, the kernel terminates the whole
namespace: every process in the container is killed and the container stops. That is the
"life" of PID 1 referred to throughout this file.

```
Traditional Linux                    Inside a Container
─────────────────                    ───────────────────
PID 1: systemd                       PID 1: nginx (or php-fpm, or mysqld)
  ├── sshd                             ├── nginx worker
  ├── cron                             └── nginx worker
  ├── nginx
  │   ├── worker                    That's it. No systemd. No cron.
  │   └── worker                    No login manager. No syslog daemon.
  └── ...                            nginx IS the init system.
```

---

## 2. The Three Special Responsibilities of PID 1

### 2.1 Responsibility 1: Signal Handling

Normal processes: upon receiving an unhandled signal (like SIGTERM), the kernel's default
action is to terminate them.

PID 1: signals with no registered handler are **ignored** by the kernel. This means if your
nginx doesn't explicitly install a handler for SIGTERM (or if the signal reaches the wrong
process due to shell-form CMD), `docker stop` sends SIGTERM and... nothing happens.

```
$ docker stop mycontainer

Docker sends SIGTERM → PID 1 (nginx)

If nginx has a SIGTERM handler:
  nginx catches it → graceful shutdown → workers finish → exit 0 → container stops
  Time: ~2 seconds. Clean.

If nginx does NOT have a SIGTERM handler:
  The kernel ignores SIGTERM for PID 1.
  nginx keeps running.
  Docker waits 10 seconds.
  Docker sends SIGKILL (uncatchable).
  nginx dies violently. Workers may have been mid-request.
  Time: 10 seconds + data loss.
```

### 2.2 Responsibility 2: Orphan Reaping

When a parent process dies before its child, the kernel reparents the orphan to PID 1.
PID 1 must call one of the `wait()` family of syscalls to collect the exit status and
free the child's PCB. If PID 1 doesn't reap, the orphan becomes a **zombie** — it
consumes a PID table slot forever.

```
Container process tree:

PID 1: nginx master
  ├── PID 2: nginx worker (child of master)
  │   └── PID 5: some plugin helper
  └── PID 3: nginx worker
```

If PID 2's plugin helper (PID 5) is orphaned (parent PID 2 dies), it gets reparented to
PID 1. nginx master **must** reap it via `waitpid()`. If it doesn't, PID 5 becomes a
zombie. Over weeks of operation, zombies accumulate. The PID table fills up. fork() fails.
The container can no longer create new processes.

nginx master (correctly) handles this. Most daemons do. But if you use a hacky wrapper
script as PID 1 that doesn't reap, you get a zombie graveyard.

### 2.3 Responsibility 3: SIGCHLD Handling

Whenever any child of PID 1 changes state (exits, is killed, is stopped), the kernel
sends SIGCHLD to PID 1. A proper init process handles SIGCHLD by calling `waitpid(-1, ...)`
in a loop to reap ALL terminated children, not just one.

A simple shell script as PID 1 often catches only one child exit and ignores the rest.
This creates zombies.

---

## 3. Daemon vs Foreground — The Container Killer

### 3.1 How Traditional Daemons Work

Most server software is designed to run as a **daemon** (background process). The pattern:

```
1. Start the program
2. The program forks a child
3. The parent exits
4. The child disassociates from the terminal (setsid, closes stdin/stdout/stderr)
5. The child changes working directory to /
6. The child runs in the background
```

When you run `nginx` on a real server:

```bash
$ nginx            # starts, daemonizes, returns you to shell
$ ps aux | grep nginx
root   1234  nginx: master process
nginx  1235  nginx: worker process
```

The initial command exits immediately after forking. The real nginx runs in the background.

### 3.2 Why Daemons Kill Containers

Inside a container, PID 1 is the container's **life**. When PID 1 exits, the kernel
terminates the entire PID namespace. The container dies.

```dockerfile
CMD ["nginx"]   # default: daemonizes → PID 1 exits → container DIES immediately
```

```
Sequence:
1. Docker exec's nginx as PID 1
2. nginx forks to background (daemon mode)
3. The original nginx process (PID 1) exits
4. Kernel: "PID 1 exited. Terminating the PID namespace."
5. The forked nginx (now PID ? but not PID 1) is killed.
6. Container status: Exited (0)
7. "docker ps" shows nothing.
```

This is why every daemon in Inception must be forced to run in the **foreground**:

```
| Service   | Foreground flag(s)                 |
|-----------|-------------------------------------|
| NGINX     | `-g "daemon off;"`                |
| php-fpm   | `-F` (or `--nodaemonize`)          |
| MariaDB   | `mysqld` (runs foreground by default; or use `--user=mysql`) |
```

```dockerfile
# NGINX — foreground
CMD ["nginx", "-g", "daemon off;"]

# php-fpm — foreground
CMD ["php-fpm", "-F"]

# MariaDB — foreground already, but explicit:
CMD ["mysqld", "--user=mysql"]
```

When these run in the foreground, the process stays PID 1, the container stays alive,
and `docker stop` sends SIGTERM directly to the right process.

### 3.3 How `daemon off;` Actually Works Internally

`daemon off;` is an NGINX configuration directive that:

1. Prevents the master process from calling `fork()` and exiting.
2. Keeps the process attached to stdout/stderr (logs go to Docker's log driver).
3. Makes the master process stay in the foreground as PID 1.

Without it, NGINX would fork, the original PID 1 would exit, and the container would
instantly terminate as described above.

### 3.4 php-fpm -F (or --nodaemonize)

`-F` forces php-fpm to stay in the foreground. Without it, php-fpm:

1. Forks to background.
2. The original PID 1 exits (daemonizes).
3. Container dies.

With `-F`:
- php-fpm master stays foreground
- Children (workers) are spawned but the master never exits
- PID 1 = php-fpm master
- Container stays alive until `docker stop`

### 3.5 mysqld — No Special Flag Needed

MariaDB's `mysqld` runs foreground by default when you invoke it directly (not through
a service manager systemd script). Some configurations may require explicit foreground,
but Debian's/Alpine's packages typically run in foreground when called as `mysqld`.

To be safe and explicit:
```dockerfile
CMD ["mysqld", "--user=mysql", "--skip-log-error"]
```

Skip-log-error prevents mysqld from trying to write to `/var/log/mysql/error.log`
(which may not exist in a minimal container).

---

## 4. The Forbidden Hacks — Why They Must NOT Be Used

### 4.1 `tail -f /dev/null`

```dockerfile
CMD ["sh", "-c", "nginx && tail -f /dev/null"]
```

What happens:
1. `/bin/sh` becomes PID 1.
2. `/bin/sh` starts nginx (nginx daemonizes to background).
3. `/bin/sh` starts `tail -f /dev/null` — an infinite read on `/dev/null` that never produces output.
4. `tail -f /dev/null` runs forever.
5. Container stays up.

**Why it's forbidden:**
- PID 1 is `/bin/sh`, not nginx. SIGTERM from `docker stop` goes to `/bin/sh`, which doesn't forward it to nginx. Nginx is killed by SIGKILL after 10 seconds, uncleanly.
- `tail -f /dev/null` is a pure resource waste. It's a process that does nothing.
- nginx is not the process maintaining the container's life. A useless command is.
- If nginx crashes, `tail -f` keeps running — Docker thinks the container is alive but your website is dead.
- PID 1 (`/bin/sh`) does NOT reap children. Orphans become zombies.

### 4.2 `sleep infinity`

```dockerfile
CMD ["sh", "-c", "php-fpm && sleep infinity"]
```

Identical problems: PID 1 is `/bin/sh`, not php-fpm. If php-fpm dies, the container
stays alive doing nothing. Same zombie problem.

### 4.3 `while true; do ...; done`

```bash
#!/bin/sh
nginx
while true; do sleep 1; done
```

PID 1 is `/bin/sh` (or the shell running the script). nginx is a child process.
Side-effects are the same as above: broken signal forwarding, zombies, meaningless
keepalive.

### 4.4 The Subject's Rule

From the 42 Inception subject PDF (paraphrased):

> The container should not run any infinite-loop hack like `tail -f`, `sleep infinity`,
> or `while true` just to keep it alive. The main process must be the actual daemon
> running in the foreground.

**The evaluator WILL ask:** "What is PID 1 in your container? How do you know it's not
a shell? Why didn't you use `sleep infinity`?"

### 4.5 How to Verify You're Clean

```bash
# Is PID 1 actually nginx and not /bin/sh?
$ docker exec nginx ps aux
USER  PID  %CPU %MEM  VSZ  RSS TTY  STAT  START  TIME COMMAND
root    1   0.0  0.1  1056  456 ?    Ss   10:00   0:00 nginx: master process nginx -g daemon off;
www     2   0.0  0.2  1100  532 ?    S    10:00   0:00 nginx: worker process
```

PID 1 = `nginx`. Good. If you see PID 1 = `/bin/sh` or `bash`, fix your CMD.

```bash
# Does the container survive a crash of the main process?
# NOTE: `docker exec nginx kill -9 1` does NOT work — the kernel ignores
# SIGKILL sent to PID 1 from inside the same PID namespace.
$ docker kill -s KILL nginx   # daemon sends it from the host side → works
$ docker ps                   # Container should restart (restart: always)
```

### 4.6 The One Legitimate Use Case for Shell Wrappers

Sometimes you genuinely need a shell script as your entrypoint — to generate a config
file, generate certificates, or run initialization. This is acceptable **only if**:

```bash
#!/bin/sh
# entrypoint.sh — valid pattern

# Do setup work
openssl req -x509 -nodes ...

# Then exec the REAL process using exec
exec nginx -g "daemon off;"
```

The `exec` keyword replaces the shell with nginx. The shell's PID 1 becomes nginx.
The shell no longer exists. There is no wrapper between Docker and nginx.

```
Before exec:  PID 1 = /bin/sh (running entrypoint.sh)
After exec:   PID 1 = nginx (shell replaced, no trace left)
```

This is the **only** acceptable use of a shell in your CMD/ENTRYPOINT. The final
process running as PID 1 must be the service itself.

```bash
# WRONG (no exec): PID 1 stays /bin/sh, child is nginx
nginx -g "daemon off;"

# CORRECT: PID 1 becomes nginx
exec nginx -g "daemon off;"
```

---

## 5. Zombie Processes — The Deep Dive

### 5.1 What Is a Zombie, Exactly?

A zombie is a process that has **finished executing** (called `_exit()` or was killed)
but whose **PCB still exists** in the kernel's process table because its parent hasn't
called `wait()`.

```
                    │
Child calls exit()  │  "I'm done."
                    ▼
                 ┌──────────┐
                 │  ZOMBIE  │  ← Dead process, but PCB not freed.
                 └──────────┘     Waiting for parent to call wait().
                    │
Parent calls wait() │  "I acknowledge the death."
                    ▼
                 ┌──────────┐
                 │  REAPED  │  ← PCB removed. PID freed. Process truly gone.
                 └──────────┘
```

A zombie consumes:
- A PID (int, 4 bytes)
- A process table entry (a few hundred bytes in kernel memory)

It consumes **zero** CPU and **zero** userspace RAM (no code, no stack, no heap).
Zombies are small, but PIDs are finite. On a typical Linux system, `/proc/sys/kernel/pid_max`
is 32768. When you run out of PIDs, `fork()` returns `EAGAIN`. New processes cannot
be created. System is effectively dead.

### 5.2 Why Containers Are Especially Vulnerable

```
On a real server with systemd:
  Parent dies → orphan → reparented to PID 1 (systemd)
  systemd's job IS to reap → it does, automatically → no zombies

Inside a container without a proper init:
  Parent dies → orphan → reparented to PID 1 (your app)
  Your app is a web server, not an init system.
  It does NOT call wait() on unexpected children.
  Zombies accumulate.
```

### 5.3 How to Create a Zombie (Demonstration)

```bash
#!/bin/sh
# zombie_maker.sh — don't use this in your project!
python3 -c "
import os, time
pid = os.fork()
if pid == 0:
    # Child: exit immediately
    os._exit(0)
else:
    # Parent: sleep forever, never calls wait()
    time.sleep(3600)
" &
exec nginx -g "daemon off;"
```

This creates a child process that exits immediately. The parent (Python script) never
reaps it. One zombie. Do this 100 times — 100 zombies.

### 5.4 How Proper Init Systems Handle This

systemd (and other inits) run a main loop that includes:

```c
// Simplified — what every init does in its event loop
while (1) {
    int status;
    pid_t pid = waitpid(-1, &status, WNOHANG);  // reap any child
    if (pid > 0) {
        // child reaped, log it
    }
    // ... handle other events (signals, timers, service management)
}
```

A proper PID 1 is **always** calling `waitpid()` with `WNOHANG` (don't block if no children),
ensuring every terminated child gets cleaned up immediately.

nginx master does this internally for its workers. php-fpm master does this for its children.
mysqld does this for its threads/helper processes. These daemons handle their own direct
children correctly. The problem arises when orphaned children appear from unexpected places
(plugins, external commands, temporary shell invocations).

---

## 6. ENTRYPOINT vs CMD for Inception

### 6.1 The Correct Pattern

```dockerfile
# NGINX
ENTRYPOINT ["nginx"]
CMD ["-g", "daemon off;"]

# WordPress (php-fpm)
ENTRYPOINT ["php-fpm"]
CMD ["-F"]

# MariaDB
ENTRYPOINT ["mysqld"]
CMD ["--user=mysql"]
```

### 6.2 Why Not Just CMD?

```dockerfile
# This also works:
CMD ["nginx", "-g", "daemon off;"]
```

It's valid. The container starts and stays up. But ENTRYPOINT + CMD communicates intent:
"This container IS an nginx server." Without ENTRYPOINT, a `docker run myimage bash`
overrides the entire CMD — you get an interactive shell where nginx never starts. With
ENTRYPOINT set to nginx, the same `docker run myimage bash` makes bash become the
argument to nginx: `nginx bash` — which is an error, but proves the intent that this
container should always run nginx.

For Inception, either pattern works. The critical thing is the **foreground flag** and
the use of **exec form** (no shell wrapping PID 1).

### 6.3 Exec Form with Environment Variable Substitution

```dockerfile
# WRONG: Exec form doesn't expand $VARIABLE
CMD ["nginx", "-g", "daemon off;", "-c", "/etc/nginx/$ENV.conf"]

# WRONG: Shell form gives you /bin/sh as PID 1
CMD nginx -g "daemon off;" -c /etc/nginx/$ENV.conf

# CORRECT: Use shell form but exec inside → PID 1 still becomes nginx
CMD sh -c "exec nginx -g 'daemon off;' -c /etc/nginx/$ENV.conf"
```

Or better: handle variable expansion in the config before starting nginx, using
an entrypoint script that calls `exec nginx -g "daemon off;"` at the end.

---

## 7. Signal Flow in Docker — Complete Diagram

```
$ docker stop nginx

Docker Client → Docker Daemon
                         │
                         ├─→ containerd
                         │       │
                         │       └─→ runc (or containerd-shim)
                         │               │
                         │       Sends SIGTERM to PID 1
                         │       in the container namespace
                         │               │
                         │               ▼
                         │      ┌────────────────────┐
                         │      │ PID 1: nginx       │
                         │      │                    │
                         │      │ SIGTERM received    │
                         │      │   → graceful shutdown
                         │      │   → stop accepting  │
                         │      │   → finish requests │
                         │      │   → cleanup         │
                         │      │   → exit(0)         │
                         │      └────────────────────┘
                         │               │
                         │       10 second timeout
                         │       If PID 1 still alive:
                         │               │
                         │               ▼
                         │      Sends SIGKILL
                         │      (uncatchable, immediate death)
                         │               │
                         │               ▼
                         │           Container dies
                         │
                         └──→ Container status: Exited (137 if SIGKILL'd)
```

Exit code 0: PID 1 handled SIGTERM and exited cleanly (graceful shutdown worked).
Exit code 137: PID 1 was killed by SIGKILL (128 + 9 = 137). Either your process ignores
SIGTERM and Docker ran out of patience (10 seconds by default), or something SIGKILLed
it directly. 137 means you have a signal-handling problem.

### 7.1 Tuning the Stop Sequence: `STOPSIGNAL` and `stop_grace_period`

Two knobs you control:

- **Which signal:** `STOPSIGNAL SIGQUIT` in the Dockerfile changes the first signal sent
  by `docker stop` (default: SIGTERM).
- **How long to wait:** `docker stop -t 30 nginx` — or `stop_grace_period: 30s` under the
  service in docker-compose.yml — changes the 10-second grace period before SIGKILL.

If your application legitimately needs more than 10 seconds to drain connections or flush
buffers, raise `stop_grace_period`. That is the correct way. Ignoring SIGTERM and relying
on SIGKILL is never correct.

---

## 8. tini / dumb-init — The "Init for Containers"

If your application genuinely struggles with PID 1 responsibilities (doesn't handle
signals, doesn't reap children), you can use a minimal init system as PID 1:

```dockerfile
RUN apk add --no-cache tini
ENTRYPOINT ["/sbin/tini", "--"]
CMD ["nginx", "-g", "daemon off;"]
```

tini:
- Registers signal handlers as PID 1
- Reaps zombies
- Runs CMD as a child process
- Forwards signals to the child

This is a legitimate solution in some environments. For Inception, nginx, php-fpm,
and mysqld all handle their responsibilities fine. You don't need an extra init.
But it's good to know the option exists and why.

**Built-in alternative:** `docker run --init` (or `init: true` for the service in compose)
does exactly this without installing anything — the daemon runs its bundled init (tini)
as PID 1 and execs your CMD as its child.

---

## 9. The complete Inception PID 1 Verification Checklist

Before submitting for evaluation, verify each container:

```bash
# 1. Check PID 1 for each container
for container in nginx wordpress mariadb; do
    echo "=== $container ==="
    docker exec $container ps -o pid,comm 1
done
```

Expected output:
```
=== nginx ===
  PID COMMAND
    1 nginx

=== wordpress ===
  PID COMMAND
    1 php-fpm

=== mariadb ===
  PID COMMAND
    1 mysqld
```

Not `/bin/sh`. Not `bash`. Not `sleep`. Not `tail`.

```bash
# 2. Test graceful shutdown (SIGTERM)
docker stop nginx
# Observe: stops in < 2 seconds. Exit code 0.

# 3. Test crash recovery
docker exec nginx kill -9 1
# Observe: container restarts (restart: always)
# docker ps shows it back up after a few seconds

# 4. Check no zombie accumulation
docker exec wordpress ps aux | grep defunct
# Should return nothing.

# 5. Verify no hacky keepalive
docker inspect nginx | jq '.[0].Config.Cmd'
# Should be: ["nginx", "-g", "daemon off;"]
# NOT: ["sh", "-c", "nginx && tail -f /dev/null"]
```

---

## 10. Check Your Understanding

1. Why is PID 1 special compared to any other PID?
2. What happens when PID 1 exits inside a container? Why?
3. Why does `CMD ["nginx"]` (without `daemon off;`) cause the container to die immediately?
4. What's the difference between `CMD nginx` (shell form) and `CMD ["nginx"]` (exec form) for PID 1?
5. Why are `sleep infinity`, `tail -f /dev/null`, and `while true` forbidden by the subject?
6. What is a zombie process? Why is it a problem?
7. Who reaps orphan processes in a traditional Linux system? Who reaps them in a container without an init system?
8. When `docker stop` is called, what signal is sent to PID 1? What happens if PID 1 ignores it?
9. What does `exec` do in a shell script entrypoint, and why is it critical?
10. In the Inception project, how does php-fpm run in the foreground? What flag enforces this?
11. How do you verify that PID 1 is the actual daemon and not a shell wrapper?
12. What exit code indicates a container was killed by SIGKILL?
13. Why does `docker exec nginx kill -9 1` NOT kill nginx, while `docker kill nginx` does? What would you change if your app needs more than 10 seconds to shut down gracefully?

---

*Next file: `1-5-the-stack.md` (NGINX, TLS/SSL, WordPress + php-fpm, MariaDB, FastCGI)*
