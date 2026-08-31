# Viewing the Website

How to actually *see* `https://rmardi.42.fr` in a browser — plus the CLI alternatives.

## 0. Make sure the stack is up

```bash
docker ps          # expect: nginx, wordpress, mariadb — all "Up"
```

If they're missing (e.g. after a reboot), re-run the three `docker run` commands in order (mariadb → wordpress → nginx) — or, once it exists, just `make`.

## 1. Point the domain at the machine (one-time)

The subject requires the domain to resolve to the local IP. The simplest mechanism is `/etc/hosts` — a local DNS override the browser respects:

```bash
echo "127.0.0.1 rmardi.42.fr" | sudo tee -a /etc/hosts
```

Check:

```bash
grep rmardi /etc/hosts
```

Why this matters: the browser sends `Host: rmardi.42.fr` in its request — that's what nginx's `server_name rmardi.42.fr;` matches against. Visiting `https://127.0.0.1` would technically connect, but the Host header would be wrong.

## 2. Bring the GUI back (if you dropped to CLI)

If you earlier ran `sudo systemctl isolate multi-user.target` (GUI off until reboot):

```bash
sudo systemctl isolate graphical.target
```

Or start the display manager directly: `sudo systemctl start lightdm` (Xfce) / `gdm3` (GNOME).

## 3. Open the browser

- URL: **`https://rmardi.42.fr`** (note the **s** — plain `http://` on port 80 is refused by design)
- You'll get a "Your connection is not private / security risk" warning — **normal and expected**: the certificate is self-signed (no CA vouched for it). Click **Advanced → Accept the risk / Proceed**
- WordPress should load, fully installed

## 4. Log in to prove the two users

- `/wp-admin` with `rmardi` (admin — full dashboard)
- same login page with `author` (second user — reduced, author-only dashboard)

Credentials live in the secret files (`secrets/wp_admin_password.txt`, `secrets/wp_user_password.txt`) — never in git.

## 5. CLI alternatives (no GUI needed)

```bash
# The homepage (PHP executing + DB query behind it):
curl -k https://rmardi.42.fr | grep "<title>"

# TLS details:
curl -k -v https://rmardi.42.fr 2>&1 | grep -E "SSL connection|subject:|issuer:"

# Port 80 must fail:
curl http://rmardi.42.fr --max-time 2      # exit 7 = connection refused ✓

# Full HTML to a file, then open it:
curl -k https://rmardi.42.fr -o /tmp/site.html
```

## 6. From the host machine (outside the VM)

If the browser lives on the physical host rather than inside the VM:

1. Find the VM's IP: `ip a | grep inet` (inside the VM)
2. Port-forward in the VM settings (VirtualBox: Network → Advanced → Port Forwarding, host 443 → guest 443) — or use NAT's forwarded port if configured
3. On the host, add the same line to the **host's** `/etc/hosts` (or `C:\Windows\System32\drivers\etc\hosts` on Windows): `<VM-IP> rmardi.42.fr`
4. Browse `https://rmardi.42.fr` from the host

The evaluator will do the same — so know both paths.

## Common traps

| Symptom | Fix |
|---|---|
| `This site can't be reached` | containers not running, or `/etc/hosts` line missing |
| Connection to port 80 refused | correct — only 443 exists |
| Warning about certificate | expected — self-signed, click through |
| `NET::ERR_CERT_COMMON_NAME_INVALID` (Chrome) | cert lacks SAN — check the `-addext` flag in the nginx entrypoint |
| Site loads but styles are broken | curl over plain `http://` instead of `https://` (WordPress builds absolute https URLs) |
