# 1.4 — Questions: PID 1, Foreground Processes, Zombies

## PID 1 Fundamentals

1. Why is PID 1 special compared to any other PID?

> **Answer:** Three kernel-granted responsibilities: (1) reap orphaned children (any process whose parent dies is reparented to PID 1; if PID 1 never `wait()`s, they become zombies forever); (2) receive SIGCHLD from every orphan; (3) signals with no handler are IGNORED for PID 1 (other processes would die by default action). Plus: when PID 1 dies, the kernel kills the entire PID namespace.

2. What happens when PID 1 exits inside a container — and why?

> **Answer:** The kernel terminates the whole PID namespace — every process in the container is killed and the container stops. The container's *life* IS its PID 1: no init system to keep things alive, no reparenting escape.

3. What is PID 1 in each of our three containers?

> **Answer:** `mysqld --user=mysql` (mariadb), `php-fpm: master process` (wordpress), `nginx: master process` (nginx). Verified with `docker top` — never `/bin/sh`, never `bash`.

4. How do you verify PID 1 is the real daemon, live?

> **Answer:** `docker top <container>` (or `docker exec <c> ps -o pid,comm 1` if ps exists). PID 1 must be mysqld/php-fpm/nginx. Also `docker inspect <c> --format '{{.Config.Entrypoint}}'` shows the entrypoint script — combined with `docker top` showing the daemon, the `exec` pattern is proven (the script replaced itself).

## Daemon vs Foreground

5. What is "daemonizing" — the classic steps?

> **Answer:** The process forks a child, the parent exits, the child detaches from the terminal (`setsid`), closes/redirects stdio, and keeps running in the background. Traditional daemons (nginx, php-fpm, mysqld via init scripts) do this on real servers.

6. Why does a daemonizing process KILL a container?

> **Answer:** `CMD ["nginx"]` → nginx forks to background → the ORIGINAL nginx process (PID 1) exits → kernel sees PID 1 dead → terminates the whole PID namespace → the backgrounded copy dies with it. Container: Exited (0) immediately. That's why every daemon needs a foreground flag.

7. The three foreground flags — name them.

> **Answer:** nginx: `-g "daemon off;"`. php-fpm: `-F` (`--nodaemonize`). mysqld: none needed — it runs foreground when launched directly (we add `--user=mysql`). All launched via `exec` so the daemon itself becomes PID 1.

8. What's the difference between "background" (`&`/`-d`) and "daemonizing" — why is only the second one fatal?

> **Answer:** Background = start without waiting; NOTHING exits; the process keeps running (parent may be the shell, but it lives). Daemonizing = fork + the ORIGINAL exits. If the original is PID 1 → container death. Our mariadb entrypoint legitimately uses `&` for the temp bootstrap mysqld — the script (PID 1) stays alive, and `wait $pid` reaps it later. No fork-exit happens, so no death.

9. `docker run -d` vs foreground `docker run` — what's the difference, and is `-d` a subject violation?

> **Answer:** `-d` detaches the container from YOUR terminal (you see no output, just the ID) — it has nothing to do with PID 1 inside the container. Not a violation. The subject's "foreground" rule is about the process INSIDE the container (no daemonizing, no keepalive hacks), not about your terminal.

## The Forbidden Hacks

10. Why are `tail -f /dev/null`, `sleep infinity`, `while true` forbidden? Give ALL the reasons.

> **Answer:** (1) PID 1 becomes `/bin/sh`, not the real daemon — SIGTERM from `docker stop` hits the shell, which doesn't forward it → 10s timeout → SIGKILL (unclean). (2) The keepalive process, not the service, is what keeps the container alive — if the service crashes, the container looks "up" while the site is dead. (3) The shell doesn't reap children → zombie accumulation. (4) Pure resource waste — a process doing nothing. (5) It's exactly what the subject forbids, and evaluators check `docker inspect` Cmd for it.

11. What is the ONE legitimate use of a shell script as entrypoint — and what makes it legitimate?

> **Answer:** Setup-then-`exec`: the script does init work (generate certs, wait for DB, install), then ends with `exec <real daemon> ...`. The `exec` syscall REPLACES the shell with the daemon — the shell ceases to exist, no wrapper remains between Docker and the process, PID 1 IS the daemon. Missing `exec` (running the daemon as a child instead) = the forbidden pattern in disguise.

12. What does `exec` actually do?

> **Answer:** Replaces the current process image with a new program — same PID, new code. No fork, no parent/child. The script's PID 1 slot is taken over by mysqld/php-fpm/nginx. After `exec`, the shell is gone from the process table entirely.

## Signals

13. Walk through `docker stop <container>` — the full signal story.

> **Answer:** Docker sends SIGTERM to PID 1. If the daemon handles it (all three of ours do) → graceful shutdown (finish requests, flush buffers) → exit 0 → container stops in ~2s. If PID 1 ignores it (or it's a shell wrapper) → Docker waits 10 seconds (configurable: `stop_grace_period`, or `docker stop -t 30`) → sends SIGKILL → instant, uncatchable death → exit code 137 (128+9).

14. Why does `docker exec mariadb kill -9 1` NOT kill mysqld, while `docker kill mariadb` does?

> **Answer:** Signal delivery to PID 1 is judged per PID namespace: inside the same namespace, the kernel ignores signals PID 1 has no handler for — including SIGKILL. `docker kill` is sent by the daemon from the HOST namespace — it bypasses that protection and kills the container's PID 1, taking the whole namespace down.

15. Exit codes — what do 0 and 137 mean?

> **Answer:** 0 = PID 1 exited cleanly (SIGTERM handled, graceful shutdown). 137 = killed by SIGKILL (128+9) — the process ignored/never got SIGTERM and Docker ran out of patience. 137 is the tell-tale sign of a signal-handling problem.

16. What are STOPSIGNAL and stop_grace_period for?

> **Answer:** STOPSIGNAL (Dockerfile) changes which signal `docker stop` sends first (default SIGTERM — e.g. SIGQUIT for some apps). `stop_grace_period` (compose) changes the 10s window before SIGKILL. The correct way to handle a slow-but-legit shutdown is raising the grace period — never "just let it be SIGKILLed".

## Zombies

17. What is a zombie process, exactly?

> **Answer:** A process that has finished executing (called `_exit()` or was killed) but whose process-table entry (PCB) still exists because its parent hasn't called `wait()`. It consumes zero CPU/RAM — only a PID slot and a few hundred kernel bytes. But PIDs are finite (~32768 by default): enough zombies → `fork()` fails → no new processes → system effectively dead.

18. Who reaps orphans on a normal Linux box? In a container?

> **Answer:** Normal box: systemd (PID 1) — reparented orphans get `waitpid()`ed automatically; its whole job is reaping. Container: PID 1 is your daemon (nginx/php-fpm/mysqld) — they handle their OWN direct children correctly (workers etc.), but unexpected orphans (helper processes, shell invocations) may not be reaped. Our entrypoints minimize this by exec-ing the daemon as PID 1 and `wait`-ing background jobs (`wait $pid || true` in mariadb).

19. How do you check for zombie accumulation in a container?

> **Answer:** `docker top <container>` and look for `Z`/defunct state, or `docker exec <c> ps aux | grep defunct` if ps exists. Should return nothing.

20. What is tini / `docker run --init`, and why don't we need it?

> **Answer:** A minimal init for containers: registers signal handlers, reaps zombies, forwards signals to the child. Useful for apps that don't do these things. nginx/php-fpm/mysqld all manage their children and signals fine, so our PID 1 can be the daemon itself — no extra init layer required.

## ENTRYPOINT vs CMD

21. ENTRYPOINT vs CMD — what happens when both exist? How do you override each?

> **Answer:** Concatenated: ENTRYPOINT is the fixed command, CMD becomes its default arguments. `docker run img args` replaces CMD only; ENTRYPOINT needs `--entrypoint`. Only-CMD = fully overridable; that's why we use ENTRYPOINT (the container's identity: "this container IS mysqld/php-fpm/nginx").

22. Shell form vs exec form — the difference that matters for PID 1?

> **Answer:** Shell form (`CMD nginx -g ...`) runs inside `/bin/sh -c "..."` → `/bin/sh` becomes PID 1, your daemon is a child → broken signals, no reaping. Exec form (`CMD ["nginx","-g","daemon off;"]` / ENTRYPOINT `["..."]`) runs the program directly → the daemon IS PID 1. Always exec form.
