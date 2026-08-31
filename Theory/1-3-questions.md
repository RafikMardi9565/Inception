# 1.3 — Questions: docker-compose, Networks, Volumes, Environment

## docker-compose

1. What does docker-compose actually solve?

> **Answer:** Running multiple containers as one declarative stack. Instead of remembering long `docker run` flags for 3+ containers, you write the whole topology (services, networks, volumes, env) in one YAML file and control it with `docker compose up`/`down`. Reproducible, version-controlled, one command.

2. `docker run` vs `docker compose up` — three concrete differences.

> **Answer:** (1) Scope: `docker run` = one container; `up` = the whole stack. (2) Networking: compose auto-creates a network and gives DNS resolution between services; with `run` you manage networks/links by hand. (3) State: compose's YAML IS the config (committed to git); `run` state lives in your shell history.

3. Compose v1 vs v2 — why does it matter for Inception?

> **Answer:** v1 = `docker-compose` (hyphen), a deprecated standalone Python binary. v2 = `docker compose` (space), a Go plugin distributed with Docker Engine. Subject/eval machines expect v2 — a Makefile calling `docker-compose` will fail. Always `docker compose`.

4. Walk through what happens when you run `docker compose up --build` — the phases.

> **Answer:** 1. Parse/validate YAML + interpolate `.env`. 2. Build images for services with `build:` (`docker build` per context, tagged with `image:`). 3. Create the custom network (or a default one). 4. Create volumes. 5. Start services in dependency order (`depends_on` chains). 6. Attach writable layers + volume mounts. 7. Apply restart policies. 8. Attach to the network, DNS records registered.

5. What does `depends_on` guarantee — and NOT guarantee?

> **Answer:** It guarantees *startup order*: mariadb starts before wordpress. It does NOT guarantee mariadb is *ready* (accepting connections) when wordpress starts — mariadb may still be initializing. That gap is covered by our entrypoint wait loops (ping up to 30s), or healthchecks (`condition: service_healthy`).

## Networks

6. What is a Docker bridge network, physically?

> **Answer:** A virtual LAN inside the host kernel: a Linux bridge (virtual switch) + veth pairs (virtual cables) — one end in each container's network namespace, the other on the bridge. No physical hardware involved.

7. How does the nginx container reach `wordpress:9000` with zero port publishing?

> **Answer:** They're on the same bridge network, so they share a virtual LAN — container-to-container traffic needs no `ports:` at all. The name `wordpress` is resolved by Docker's **embedded DNS** (127.0.0.11 inside each container) to the wordpress container's current IP. Ports publishing (`ports:`) is only for host ↔ container traffic.

8. Why are `--link` and `links:` forbidden by the subject?

> **Answer:** They're the obsolete pre-DNS way of wiring containers (injecting env vars + /etc/hosts entries, one direction, brittle). The embedded DNS on user-defined networks does the job automatically and updates on restarts. Using `links:` shows you didn't understand modern networking.

9. Why is `network_mode: host` forbidden?

> **Answer:** It strips the container's network namespace — the container shares the HOST's network stack directly (same interfaces, same ports, no isolation). That defeats container isolation, and it would let wordpress/mariadb bind host ports directly — bypassing the "only 443 exposed" architecture.

10. Does the default bridge network have DNS? Why did our manual test need `wpnet`?

> **Answer:** No — the pre-existing default bridge has NO embedded DNS (containers can only reach each other by IP). Only **user-defined** networks get the DNS service. That's why `docker run` tests needed `docker network create wpnet` + `--network wpnet`. Compose creates a user-defined network automatically — one of its big quality-of-life wins.

11. Explain port publishing vs EXPOSE vs container-to-container.

> **Answer:** `EXPOSE` (Dockerfile) = pure documentation, does nothing. `ports: "443:443"` = real publishing: host's 443 forwards to the container's 443. Container-to-container = nothing needed, same network is enough. Inception publishes exactly one port: nginx's 443.

## Volumes

12. Why do volumes exist — what's the problem they solve?

> **Answer:** Containers are ephemeral by design: delete the container, its writable layer dies with it. Volumes move *state* onto the host (or docker-managed storage) so data survives container death, recreation, and rebuilds. The DB and the site files must survive — hence two volumes.

13. Bind mount vs named volume — and which does the subject demand?

> **Answer:** Bind mount = absolute host path mapped into the container (`-v /host/path:/container/path`). Named volume = a name declared in the compose `volumes:` section, managed by Docker. **The subject forbids bind mounts for the two persistent storages and requires named volumes whose data lives in `/home/<login>/data`.**

14. The subject says "named volumes in /home/rmardi/data" — how is that achieved, exactly?

> **Answer:** A named volume declared with the local driver + options pointing at the host directory:

```yaml
volumes:
  mariadb_data:
    driver: local
    driver_opts:
      type: none
      o: bind
      device: /home/rmardi/data/mariadb
```

The volume has a name (shows in `docker volume ls`, referenced by name in services — no `- /host:/path` under any service), but its data lands directly in the host directory, satisfying the "data visible in /home/<login>/data" check.

15. Why must the Makefile create `/home/rmardi/data/{wordpress,mariadb}` before `up`?

> **Answer:** The `device:` directories must exist and be owned by the right user. If Docker auto-creates them they're root-owned, causing permission pain. The subject says the Makefile must set up the entire application — that includes the host data dirs.

16. What happens on first boot when the volume directory is empty?

> **Answer:** Docker's **copy-up** applies: any real named volume (ours included — it's `Type: volume` even with `o: bind`) mounted over a path that has content in the image gets that content **copied into the empty volume** on first mount. Plain bind mounts (`-v /host:/path`) are exempt. This bit us with MariaDB: the image baked in a virgin datadir (`apt-get install mariadb-server`), copy-up seeded `mysql/` into the fresh volume, and the entrypoint's emptiness check wrongly saw "already initialized" → no wpuser → error 1130. Fix: `rm -rf /var/lib/mysql/*` in the Dockerfile so the image's datadir is empty and the entrypoint detects freshness. For WordPress, `/var/www/html` is empty in the image, so copy-up copies nothing and wp-cli populates it.

17. Why do nginx and wordpress share ONE volume — and why is nginx's mount read-only?

> **Answer:** WordPress writes the site files (wp-cli, uploads); nginx serves them. Same files, two views — the subject's diagram even shows nginx mounting `ro`. Read-only = defense in depth: a compromised nginx cannot deface the site.

## Environment

18. Where does `.env` live, and what are its two totally different jobs (the classic confusion)?

> **Answer:** In `srcs/`, gitignored. Two distinct mechanisms: (1) **Interpolation** — compose CLI reads `.env` and substitutes `${VAR}` placeholders inside docker-compose.yml. (2) `env_file:`/`environment:` — sets variables INSIDE the container's process environment. A bare `.env` does NOT inject anything into containers by itself; `env_file:` does NOT enable interpolation. Both are needed: `.env` for interpolation, and explicit `env_file`/`environment`/`secrets` for what containers see.

19. Trace a password's journey from host to WordPress.

> **Answer:** Password sits in `secrets/db_password.txt` (gitignored, never in image). Compose mounts it read-only at `/run/secrets/db_password` inside the container. The entrypoint reads it with `$(cat /run/secrets/db_password)` into a variable, then passes it to `wp config create --dbpass=...`, which writes it into `wp-config.php` on the volume. So: host file → container memory → volume config. Never in the image, never in git.

20. Why is the `.env` file mandatory even though we also use secrets?

> **Answer:** The subject mandates a `.env` for environment variables. Our split: `.env` = non-secret values (domain, usernames, emails, DB name); `secrets/*.txt` = confidential values (passwords). Usernames/domain need interpolation into compose and containers but aren't secrets — keeping passwords out of `.env` reduces the blast radius if `.env` ever leaks.

21. What does `restart: always` do — and what does it NOT do?

> **Answer:** Restarts the container whenever it stops — crash, `docker stop`, even daemon restart. It does NOT guarantee the *service inside* is healthy (a container can loop restarts with a broken entrypoint), and it does not cover `docker rm` (deleted is deleted).

22. Debugging compose — your five go-to commands?

> **Answer:** `docker compose ps` (status), `docker compose logs -f [svc]` (logs), `docker compose exec <svc> bash` (shell in), `docker compose config` (validate + print interpolated YAML — always run before eval), `docker compose down -v` (full teardown). Plus the nuke button: `docker system prune -af --volumes`.
