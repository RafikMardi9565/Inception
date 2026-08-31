# 1.1 — Questions: Virtualization vs Containerization

## Bare Metal Era

1. What problems did traditional deployment have that created the need for VMs/containers?

> **Answer:** One app per machine → massive hardware waste (~10% CPU utilization). Dependency hell → apps needing different library versions couldn't coexist. Slow deployment → provisioning a new server took weeks. No isolation → a crashing app could bring down the whole system.

## Virtualization

2. What is a hypervisor? Difference between Type 1 and Type 2 — give examples of each.

> **Answer:** A hypervisor is software that creates and manages VMs by partitioning physical hardware. Type 1 (bare metal): sits directly on hardware — VMware ESXi, KVM. Type 2 (hosted): runs on top of a host OS — VirtualBox, VMware Workstation.

3. Walk through how a VM boots and runs, step by step.

> **Answer:**
> 1. Hypervisor partitions physical hardware resources.
> 2. Creating a VM allocates a slice of CPU, RAM, disk.
> 3. A full OS image boots inside: BIOS/UEFI → bootloader → kernel → init system.
> 4. The guest kernel talks to emulated/virtual hardware devices exposed by the hypervisor.
> 5. The guest kernel has no idea it's sharing hardware with other VMs.

4. 3 pros and 3 cons of VMs.

> **Answer:**
> - Pros: strong isolation (kernel panic in VM1 can't crash VM2); can run different OS families (Windows on Linux host); mature ecosystem (snapshots, live migration); hardware-level security.
> - Cons: heavy (~1-4 GB RAM + ~10 GB disk each); slow boot (30s–2min); duplicated kernels/init/cron per VM; limited density (10-50 VMs per host).

## Containers

5. What is the fundamental difference between a container and a VM?

> **Answer:** A VM = virtual hardware + guest kernel. A container = process isolation at the OS level, sharing the host kernel. No guest OS, no hypervisor — the Linux kernel provides the isolation natively.

6. List the namespaces and what each isolates: PID, NET, MNT, UTS, IPC, USER.

> **Answer:**
> - PID — only its own processes (container PID 1 ≠ host PID 1)
> - NET — own network stack (interfaces, routing, iptables)
> - MNT — own filesystem mount points
> - UTS — own hostname
> - IPC — isolated inter-process communication
> - USER — root in container = regular user on host (opt-in)

7. What do cgroups do? What does OverlayFS do?

> **Answer:** cgroups limit how much CPU, RAM, I/O a container can consume. OverlayFS (UnionFS) — layers for images; only changed files are stored in new layers.

8. Walk through `docker run`: Dockerfile → layer → image → run → PID 1. What does "the container does not boot" mean?

> **Answer:**
> 1. Dockerfile (FROM, RUN, COPY…) → each instruction creates a layer (diff on top of previous, stored via OverlayFS).
> 2. Result = image, a read-only stack of layers.
> 3. `docker run` adds a thin writable layer, sets up namespaces + cgroups, starts CMD/ENTRYPOINT.
> 4. That process becomes PID 1 inside the container — sees only itself and its children; no host processes, networks (unless granted), or files (unless mounted).
> 5. "Does not boot" = no init system, no kernel — the app starts directly in ~milliseconds.

## Comparison

9. For each row, who wins and why: RAM overhead, boot time, security, portability, ability to run a different OS?

> **Answer:**
> - RAM overhead: containers (MB vs 1-4 GB)
> - Boot time: containers (<1s vs 30s–2min)
> - Security: VMs (separate kernel = much stronger barrier)
> - Portability: containers (OCI image standard vs hypervisor-dependent formats)
> - Different OS: VMs (containers must share the host kernel)

10. Explain the analogy: apartment building vs condominium vs shared house.

> **Answer:**
> - Physical server = apartment building.
> - VM = condominium: own walls, plumbing (kernel), front door; neighbor's fire won't spread.
> - Container = room in a shared house: shared kitchen/bathroom (kernel); faster to move in, but a roommate flooding the bathroom affects everyone.

## Evaluation Traps

11. If a container runs as root, is it root on the host? (Default vs USER namespaces)

> **Answer:** Yes — by default root in a container IS UID 0 on the host (same kernel, same user table), just with a reduced capability set (Docker drops CAP_SYS_ADMIN, CAP_NET_ADMIN, etc.). Only with the opt-in USER namespace is the container's root mapped to an unprivileged host UID.

12. Can a Linux host's container run a Windows app? Why?

> **Answer:** No — containers share the host kernel, so you can't run a real Windows kernel on a Linux host. Same kernel family required.

13. Why is a kernel exploit more dangerous in a container than in a VM?

> **Answer:** VMs: escaping a process still lands you inside a separate guest kernel — a much harder second barrier. Containers: all containers share one kernel, so a kernel exploit in one container compromises the host and everything on it.

14. In Inception: where does the VM sit, and where do the containers sit — why both?

> **Answer:**
> - The VM (the project VM) wraps the entire project — isolation of the whole environment from your real machine.
> - Inside it, Docker runs containers for each service (NGINX, WordPress, MariaDB) — lightweight, fast, one per service.
> - Why both: the VM gives strong isolation; containers make 3+ services practical (3 full VMs would be absurd on a laptop).

## Extra: History, chroot, and OCI

15. What is chroot, and what is it missing compared to a container?

> **Answer:** chroot changes a process's apparent root directory — filesystem isolation only. No process isolation, no network isolation, no resource limits, and root can escape it. A container = chroot + namespaces + cgroups + capabilities.

16. What was LXC, and what is its relationship to Docker?

> **Answer:** LXC (Linux Containers, 2008) was the first mainstream kernel-level containerization tool. Docker's early versions used LXC as their default execution driver, then replaced it with their own libcontainer in v0.9 (2014), which later evolved into runc.

17. What is the OCI and what does it standardize?

> **Answer:** The Open Container Initiative (Linux Foundation, 2015) standardizes the image format (layers, manifest, config) and the runtime spec (how a runtime launches a container). runc is the reference implementation. It's what makes images portable across Docker, Podman, containerd, CRI-O, and Kubernetes.

18. Why does Docker Desktop run a hidden Linux VM on macOS/Windows?

> **Answer:** Containers share the host kernel, and that kernel must be Linux. macOS/Windows kernels can't run Linux containers natively, so Docker Desktop runs a hidden Linux VM (HyperKit/Apple Virtualization on Mac, WSL2/Hyper-V on Windows) and runs all containers inside it. Inception does the same explicitly: a Linux VM with Docker inside.
