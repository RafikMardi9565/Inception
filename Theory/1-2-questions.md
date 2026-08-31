# 1.2 — Questions: Docker Architecture Deep Dive

## The Docker Engine

1. What three components make up the Docker engine, and what does each one do?

> **Answer:** CLI (thin client — translates your commands into JSON API requests, sends them, displays the response), dockerd (the daemon — the brain, listens on the socket, manages all Docker objects: images, containers, networks, volumes), containerd (manages the container lifecycle — pull images, create/start/stop containers, spawns a shim per container).

2. What does the CLI actually NOT do?

> **Answer:** It does not run containers, download images, or build anything. `docker run nginx` is translated into `POST /containers/create` + `POST /containers/{id}/start` sent to the daemon. The CLI is just a keyboard; you could use curl against the socket or the Docker SDK instead.

3. Walk through the full chain of responsibility: dockerd → containerd → runc → shim.

> **Answer:**
> - dockerd: orchestrates everything, delegates heavy lifting.
> - containerd: manages the container lifecycle, spawns one containerd-shim per container.
> - runc: the low-level runtime — reads the OCI spec and makes the actual kernel syscalls (clone, unshare, setns, pivot_root) to create the process. Then exits.
> - containerd-shim: stays alive for the container's entire lifetime; keeps stdio attached, reports exit status, survives daemon restarts.

4. Why does runc exit after creating the container, and what replaces it as the parent of the container process?

> **Answer:** runc's job is only creation — one shot. After the process starts, runc exits, and the container process is parented by containerd-shim, which supervises it for its whole life. Because the shim holds the container, daemon (containerd/dockerd) restarts don't kill running containers.

5. Why does containerd-shim exist — list its four jobs.

> **Answer:**
> 1. Stays alive for the container's entire lifetime (runc exits after creating the process).
> 2. Keeps stdio attached — stdout/stderr piped through the shim to Docker's log driver.
> 3. Reports the container's exit status back to containerd when it dies.
> 4. Survives daemon restarts — containers keep running because the shim still holds them.

6. Walk through `docker run nginx` end to end: what happens at each level (CLI → daemon → containerd → runc → shim)?

> **Answer:**
> 1. CLI sends the request to dockerd.
> 2. dockerd checks if nginx is cached locally; if not, pulls it from the registry.
> 3. containerd creates a container object and spawns a containerd-shim.
> 4. Root filesystem prepared: unpack image layers into a read-only overlay, add a thin writable layer, mount volumes.
> 5. Network: veth pair created — one end in the container namespace, one end on the Docker bridge.
> 6. OCI runtime spec generated (namespaces, cgroups, capabilities, rootfs path).
> 7. runc calls kernel syscalls: clone() with namespace flags, pivot_root() into the rootfs, exec(nginx). Then runc exits.
> 8. nginx runs as PID 1; the shim supervises stdio and exit status.

## Docker Images

7. What is an image, and why can it never be executed directly?

> **Answer:** An image is a read-only template: a minimal root filesystem + app binaries/libraries/configs + metadata (env vars, default command, exposed ports, volumes, workdir). It's never executed — it's only a blueprint used to create containers.

8. An image is NOT one big tarball — what is it?

> **Answer:** A linked list of read-only layers, each layer being a directory of files that differ from the layer below it. Each Dockerfile instruction produces one layer, stored as directories under /var/lib/docker/overlay2/.

9. Explain OverlayFS: what are lowerdir, upperdir, merged?

> **Answer:**
> - lowerdir: the read-only image layers, ordered, colon-separated.
> - upperdir: the writable container layer, starts empty — all container writes go here.
> - merged: the unified view the container sees (lower + upper stacked).

10. What is copy-on-write, and what three practical benefits does it give?

> **Answer:** When a container modifies a file, OverlayFS first copies it from the lower layer into the upper layer, then modifies the copy — the original layer is never touched. Benefits: (1) the same image layers are shared across 100 containers, (2) only the writes consume new disk per container, (3) deleting a container only removes the thin upperdir.

11. Why do layers matter for build speed — and what is the ordering rule of thumb?

> **Answer:** Docker caches every layer. On rebuild, unchanged layers come from cache — only the first changed layer and everything after it is rebuilt. Rule: put infrequently changed instructions first (OS installs, package installs), frequently changed ones last (COPYing your own code) to maximize cache hits.

## Docker Containers

12. What is a container, and how does the image/container relationship work?

> **Answer:** A container is a running instance of an image plus one writable layer on top for runtime modifications. Image = blueprint, read-only; container = the running thing (image + writable layer + process). You can run N containers from one image, like N objects from one class.

13. List the 8 steps that happen when a container starts.

> **Answer:**
> 1. Unpack image layers into an OverlayFS mount (lowerdir).
> 2. Create an empty upperdir (writable layer).
> 3. Create the merged view.
> 4. Set up namespaces (PID, NET, MNT, UTS, IPC) via clone()/unshare().
> 5. Apply cgroup limits (CPU, RAM, I/O).
> 6. Mount volumes if specified.
> 7. Drop Linux capabilities.
> 8. exec() the CMD/ENTRYPOINT as PID 1.

14. What are the container lifecycle states?

> **Answer:** Created (exists, process not started) → Running → Paused (frozen) / Exited (exit 0 = success, non-zero = error) → Deleted (docker rm).

## Dockerfile and docker build

15. What is a Dockerfile, and why is it NOT a shell script?

> **Answer:** A declarative script — a list of instructions describing how to assemble an image. It only looks like a shell script; each instruction produces exactly one layer.

16. Give each instruction and what it does: FROM, RUN, COPY, ADD, WORKDIR, EXPOSE, ENV, ARG, VOLUME, ENTRYPOINT, CMD, USER, HEALTHCHECK, STOPSIGNAL.

> **Answer:**
> - FROM — base image, must be first.
> - RUN — executes a command during build, creates a layer.
> - COPY — copies files from the build context into the image.
> - ADD — like COPY but can extract tarballs and fetch URLs.
> - WORKDIR — sets the working directory for subsequent instructions.
> - EXPOSE — documents the listening port. Does NOT publish anything.
> - ENV — sets an environment variable (persisted in the image).
> - ARG — build-time variable, not persisted in the image.
> - VOLUME — creates a mount point for external volumes.
> - ENTRYPOINT — the fixed main command, hard to override.
> - CMD — default arguments to ENTRYPOINT, easy to override.
> - USER — switches to a non-root user.
> - HEALTHCHECK — command whose exit status marks healthy/unhealthy.
> - STOPSIGNAL — overrides the first signal docker stop sends (default SIGTERM).

17. What is the difference between shell form and exec form? Which one do you use in Inception, and why exactly?

> **Answer:** Shell form runs inside `/bin/sh -c "..."`, so /bin/sh becomes PID 1 and your process is a child — SIGTERM goes to /bin/sh, which may not forward it, so docker stop falls back to the 10-second SIGKILL timeout. Exec form runs your process directly — your process IS PID 1 and receives signals cleanly. Always exec form in Inception.

18. Walk through `docker build -t inception_nginx .` step by step (the legacy mental model).

> **Answer:**
> 1. CLI packs the build context (everything in the directory except .dockerignore) into a tar and sends it to the daemon.
> 2. Daemon reads the Dockerfile line by line.
> 3. For each instruction: (a) spins up a temporary container from the previous image state, (b) runs the instruction inside it, (c) commits the result as a new layer, (d) removes the temporary container.
> 4. Tags the final image.

19. Does every instruction go through the temp-container cycle? Which ones don't, and why?

> **Answer:** No — only filesystem-changing instructions (RUN, COPY, ADD) go through the cycle. FROM just selects a base image. ENV, ARG, LABEL, WORKDIR, EXPOSE, CMD, ENTRYPOINT are pure metadata, written directly into the image config — no container spun up, no layer created. ENV/WORKDIR do affect later steps, but produce no layer themselves.

20. How does BuildKit differ from the legacy builder, and why does the layer mental model still hold?

> **Answer:** BuildKit (default since Docker 23) compiles the Dockerfile into a dependency graph and executes independent instructions in parallel in sandboxed workers instead of literally spawning an intermediate container per line. But the output is identical — same layers, same count, same order — because every filesystem instruction still produces exactly one layer. Parallelization changes timing, not results.

21. What is the build context? What exactly gets sent, and what does the tar contain — names or content?

> **Answer:** The build context is the directory you pass (usually .). The CLI packs it — full file contents, bytes, names, permissions — into a tar streamed to the daemon. The daemon unpacks it into a temp dir and deletes it after the build. Deletion is plain cleanup, not CoW.

22. Where does COPY actually copy FROM — your machine or the daemon's copy?

> **Answer:** From the daemon's copy — the unpacked context on the daemon side. Your original directory is invisible to the build. A file not sent (or .dockerignore'd) doesn't exist for COPY; editing a file after the build starts changes nothing.

23. Why does .dockerignore exist? Is it automatically created? What does it auto-exclude?

> **Answer:** It excludes files from the context to save transfer time/bandwidth and prevent secrets (.env) leaking into the image via COPY. It's optional, created manually; nothing is excluded if it's absent — everything ships, .env included. The only thing Docker auto-ignores is .dockerignore itself.

24. ENTRYPOINT vs CMD: what happens when both exist? Which one is easily overridable, and how?

> **Answer:** When both exist, they're concatenated: ENTRYPOINT is the fixed command, CMD becomes its default arguments. `docker run nginx echo hello` replaces CMD only; ENTRYPOINT requires --entrypoint to override. If only CMD exists, it's the full command (and easily overridable).

25. What is a multi-stage build, and what does it buy you?

> **Answer:** One Dockerfile with several FROM instructions — each starts a new stage, and the final image contains only the last stage. Intermediate stages are scratchpads referenced with COPY --from=. Benefit: no compiler, headers, or source code in the final image — smaller size, smaller attack surface.

## Build Cache

26. What three inputs does Docker hash for each instruction to decide cache reuse?

> **Answer:** (1) the instruction text itself, (2) the hash of the parent layer, (3) for COPY/ADD, the hash of the files being copied.

27. What is the cache invalidation cascade, and why does ordering matter?

> **Answer:** If layer N is busted (e.g., source code changed), layers N and everything after are ALL rebuilt. That's why dependencies must be copied and installed BEFORE the code: COPY requirements.txt → RUN install → COPY . . means code changes don't reinstall dependencies.

28. What does EXPOSE 443 actually do? (Trick question.)

> **Answer:** Almost nothing — it's documentation. It does NOT publish the port. Real publishing happens with `docker run -p` or compose `ports:`.

## Evaluation Traps

29. Which component(s) actually download an image on `docker pull` — the CLI or something else?

> **Answer:** The CLI only sends the request. The daemon checks the local cache, and containerd (via the daemon) does the actual pulling from the registry.

30. Why does a docker daemon upgrade NOT kill your running containers?

> **Answer:** Because each container is held by its containerd-shim, which survives daemon restarts — the shim stays alive and keeps the container process running even while dockerd/containerd restart.
