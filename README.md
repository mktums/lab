# Homelab Ansible

Provisioning and configuration for an OpenWrt router and Ubuntu servers.

## Requirements

- Ansible 2.18+
- Python 3.10+
- `sshpass` (required for password-based SSH to the router)

```bash
sudo apt install sshpass
ansible-galaxy collection install -r requirements.yml
ansible-galaxy role install -r requirements.yml
```

Galaxy roles install to `~/.ansible/roles` (global, not committed).
Project roles live in `playbooks/roles/`.

---

## Network topology

```
Internet
    │
    │ WAN (DHCP from ISP)
    │
┌───┴─────────────────────────────────────┐
│  router (Cudy WR3000S)  10.10.10.1      │
│  OpenWrt                                │
│  DNS: unbound (127.0.0.1:5335)          │
│       dnsmasq → unbound → DoT           │
│       upstreams: Cloudflare + Google    │
│  adblock-lean (medium preset)           │
└───┬─────────────────┬───────────────────┘
    │ LAN             │ IoT
    │ 10.10.10.0/24   │ 10.10.30.0/24
    │                 │ (isolated, WAN only)
    │
    ├── lab1  10.10.10.10  (MAC 70:85:c2:63:58:59)
    │   Ubuntu Server 24.04
    │   Docker host
    │   ├── step-ca       :8443   (ACME CA, not behind Traefik)
    │   ├── traefik        :80/:443
    │   │   └── traefik.lab1.lan  (dashboard, basic auth)
    │   ├── portainer      (via Traefik)
    │   │   └── portainer.lan
    │   ├── vaultwarden    (via Traefik)
    │   │   └── vw.lan
    │   ├── postgres       :5432
    │   │   └── db.lan
    │   ├── linkwarden     (via Traefik)
    │   │   └── links.lan
    │   ├── beszel         :8090 (via Traefik)
    │   │   └── beszel.lan
    │   └── qbittorrent    (via Traefik)
    │       └── qbit1.lan
    │
    └── lab2  10.10.10.11  (MAC 2c:56:dc:7b:69:d1)
        Ubuntu Server 24.04
        Docker host
        ├── traefik        :80/:443
        │   └── traefik.lab2.lan  (dashboard, basic auth)
        ├── portainer edge agent  (connects to portainer.lan:8000)
        ├── qbittorrent    (via Traefik)
        │   └── qbit2.lan
        └── inpx-web       (via Traefik)
            └── lib.lan

Wi-Fi:
  Main (2.4 + 5 GHz, WPA3/WPA2, hidden) → LAN
  IoT  (2.4 GHz, WPA2)                  → IoT

DNS (*.lan resolved by dnsmasq):
  lab1.lan            → 10.10.10.10  (DHCP reservation by MAC)
  lab2.lan            → 10.10.10.11  (DHCP reservation by MAC)
  step-ca.lan         → lab1.lan     (CNAME)
  traefik.lab1.lan    → lab1.lan     (CNAME)
  traefik.lab2.lan    → lab2.lan     (CNAME)
  portainer.lan       → lab1.lan     (CNAME)
  vw.lan              → lab1.lan     (CNAME)
  qbit1.lan           → lab1.lan     (CNAME)
  qbit2.lan           → lab2.lan     (CNAME)
  lib.lan             → lab2.lan     (CNAME)
  db.lan              → lab1.lan     (CNAME)
  links.lan           → lab1.lan     (CNAME)
  beszel.lan          → lab1.lan     (CNAME)
```

---

## Manual setup — do these in order

These are one-time steps that must be done by hand. Ansible assumes they are already complete before it runs.

### 1. Router — set root password

```bash
ssh root@192.168.1.1
passwd
```

### 2. Router — change LAN IP to 10.10.10.1

```bash
uci set network.lan.ipaddr='10.10.10.1'
uci commit network
service network restart
```

> On OpenWrt 25.12+, `network.lan.ipaddr` requires CIDR notation: `10.10.10.1/24`

Your SSH session will drop. Reconnect:

```bash
ssh root@10.10.10.1
```

### 3. Vault — add all secrets

```bash
ansible-vault edit vault/secrets.yml
```

Add all required variables — see the [Vault](#vault) section for the full list.

### 4. Run site playbook

```bash
ansible-playbook playbooks/site.yml
```

This runs both `router.yml` (OpenWrt configuration) and `servers.yml` (step-ca init, all services). You can also run them separately:

```bash
ansible-playbook playbooks/router.yml    # router only
ansible-playbook playbooks/servers.yml   # servers only
```

> The router playbook does not support `--check` mode.

### 5. Install root CA on your devices

Copy the root certificate from lab1: `scp lab1:/data/docker/step-ca/certs/root_ca.crt .`

| Device | How to install |
|--------|----------------|
| Linux | `sudo cp homelab-ca.crt /usr/local/share/ca-certificates/ && sudo update-ca-certificates` |
| macOS | `sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain homelab-ca.crt` |
| Windows | Double-click `homelab-ca.crt` → Install Certificate → **Local Machine** → **Trusted Root Certification Authorities** → Finish. Restart Chrome/Edge (`chrome://restart`). |
| Android | Settings → Security → install certificate |
| iOS | AirDrop or email the file → tap to install → Settings → General → VPN & Device Management → trust it |

Do this once per device. After this, all `*.lan` HTTPS services will show a green padlock with no warnings.

> After deployment, visit `https://beszel.lan`, log in, then:
>
> 1. Settings → Tokens → create a token → add to `vault_beszel_token`
> 2. Add System → copy the public key → add to `vault_beszel_hub_key`
> 3. Re-run `ansible-playbook playbooks/services/beszel.yml` to deploy agents
>
> **S.M.A.R.T. monitoring**: The Beszel agent is configured with S.M.A.R.T. device mappings and capabilities (`SYS_RAWIO`, `SYS_ADMIN`) for disk health monitoring. Additional filesystems can be monitored by adding extra volume mounts in `inventory/host_vars/<host>.yml`:
> ```yaml
> beszel_smart_devices:
>   - /dev/sda:/dev/sda
>   - /dev/nvme0n1:/dev/nvme0n1
> beszel_smart_cap_add:
>   - SYS_RAWIO
>   - SYS_ADMIN
> beszel_extra_volumes:
>   - /data/.beszel:/extra-filesystems/sda1:ro
> ```
>
> **Note**: `beszel.yml` deploys the hub container on lab1 and agent containers on both lab1 and lab2. The hub token and hub key are configured separately from the agent credentials.

---

## Vault

Secrets live in `vault/secrets.yml`. Encrypt before committing:

```bash
ansible-vault encrypt vault/secrets.yml
```

Store the vault password in `.vault_pass` (gitignored) for passwordless runs:

```bash
echo "your-vault-password" > .vault_pass && chmod 600 .vault_pass
```

Expected vault variables:

```yaml
# ── Common ──────────────────────────────────────────────────────────────────

# bcrypt salt for password hashing (exactly 22 chars of [./A-Za-z0-9])
# generate: python3 -c "import bcrypt; print(bcrypt.gensalt()[7:].decode())"
vault_bcrypt_salt: ".................."

# Admin user credentials
vault_admin_user: "..."
vault_admin_ssh_pubkey: "ssh-ed25519 AAAA..."

# ── Router (openwrt_base) ──────────────────────────────────────────────────

# SSH password for router root user
vault_router_ssh_pass: "..."

# Wi-Fi passwords
vault_wifi_main_password: "..."    # Main network (WPA3/WPA2)
vault_wifi_iot_password: "..."     # IoT network (WPA2)

# ── step-ca ────────────────────────────────────────────────────────────────

# Password for step-ca ACME account
vault_step_ca_password: "..."

# ── Traefik ────────────────────────────────────────────────────────────────

# Password for Traefik dashboard (basic auth)
vault_traefik_dashboard_password: "..."

# ── Beszel ─────────────────────────────────────────────────────────────────

# Admin user credentials
vault_beszel_admin_email: "..."
vault_beszel_admin_password: "..."

# Hub token (from Beszel UI: Settings → Tokens)
vault_beszel_token: ""

# Hub public key (from Beszel UI: Add System → public key)
vault_beszel_hub_key: ""

# ── Portainer ──────────────────────────────────────────────────────────────

# Admin password for Portainer
vault_portainer_admin_password: "..."

# ── Vaultwarden ────────────────────────────────────────────────────────────

# Admin emergency token (set via Vaultwarden web UI after first login)
vault_vaultwarden_admin_token: "..."

# ── qBittorrent ────────────────────────────────────────────────────────────

# Admin password for qBittorrent
vault_qbittorrent_password: "..."

# ── Postgres ───────────────────────────────────────────────────────────────

# Password for the default database user
vault_postgres_password: "..."

# ── Linkwarden ─────────────────────────────────────────────────────────────

# NextAuth secret (generate: openssl rand -hex 32)
vault_linkwarden_nextauth_secret: ""

# MeiliSearch master key (generate: openssl rand -hex 32)
vault_linkwarden_meili_master_key: ""

# Database password for Linkwarden
vault_linkwarden_db_password: "..."
```

---

## Running playbooks

```bash
# Router only
ansible-playbook playbooks/router.yml

# Base server setup (server_base + docker)
ansible-playbook playbooks/server_base.yml
ansible-playbook playbooks/docker.yml

# Single services
ansible-playbook playbooks/services/traefik.yml
ansible-playbook playbooks/services/beszel.yml      # hub + agents
ansible-playbook playbooks/services/portainer.yml
ansible-playbook playbooks/services/vaultwarden.yml
ansible-playbook playbooks/services/qbittorrent.yml
ansible-playbook playbooks/services/inpx_web.yml
ansible-playbook playbooks/services/postgres.yml
ansible-playbook playbooks/services/linkwarden.yml
ansible-playbook playbooks/services/step_ca.yml
ansible-playbook playbooks/services/portainer_edge.yml

# All servers (base + all services)
ansible-playbook playbooks/servers.yml

# Everything (router + servers)
ansible-playbook playbooks/site.yml
```

Add `--ask-vault-pass` if not using `.vault_pass`.

The router playbook does not support `--check` mode.

---

## Locale

Each server generates and activates three locales: `en_US.UTF-8`, `en_DK.UTF-8`, `ru_RU.UTF-8`.

`en_DK.UTF-8` is used as `LANG` — it's English language with ISO 8601 conventions (YYYY-MM-DD dates, 24h clock, dot decimal separator, Monday-first weeks). Denmark locale is the traditional Linux choice for "international English" — same as `en_US` for language, but sane date/number formats.

`LC_MESSAGES` is pinned to `en_US.UTF-8` because `en_DK` message catalogs are sparse and some tools fall back to untranslated output.

`LC_COLLATE` and `LC_CTYPE` use `ru_RU.UTF-8` so Cyrillic filenames (e.g. book archives) sort alphabetically rather than by raw Unicode codepoint.

```
LANG=en_DK.UTF-8        # ISO dates/numbers, English language
LC_MESSAGES=en_US.UTF-8 # guaranteed English tool output
LC_COLLATE=ru_RU.UTF-8  # Cyrillic sorts alphabetically
LC_CTYPE=ru_RU.UTF-8    # Cyrillic recognized as valid letters
```

---

## Adding a service

### To an existing lab

1. Add the host to the service's inventory group in `inventory/hosts.yml`
2. Run `ansible-playbook playbooks/servers.yml`

### New service

1. Create `playbooks/roles/<service>/` with `tasks/main.yml` (and `tasks/deploy.yml` if needed), `handlers/main.yml`
2. Add CNAME registration in `tasks/main.yml` using `include_role: common` with `tasks_from: register_cname`
3. Add a group under `children` in `inventory/hosts.yml`
4. Add a play to `playbooks/servers.yml`
5. Add any secrets to `vault/secrets.yml` and vars to `inventory/group_vars/servers.yml`
6. Run `ansible-playbook playbooks/servers.yml`

Minimal Traefik labels for a new container:

```yaml
labels:
  traefik.enable: "true"
  traefik.http.routers.myapp.rule: "Host(`myapp.lan`)"
  traefik.http.routers.myapp.entrypoints: "websecure"
  traefik.http.routers.myapp.tls: "true"
  traefik.http.routers.myapp.tls.certresolver: "step-ca"
  traefik.http.services.myapp.loadbalancer.server.port: "8080"
```

---

## Troubleshooting

**`DNS_PROBE_FINISHED_NXDOMAIN` for `*.lan` in Chrome/Edge**

Chromium-based browsers have a "Use secure DNS" (DoH) setting that bypasses the system resolver and sends queries to a public DNS provider, which has no knowledge of your local `.lan` domain.

Disable it: `chrome://settings/security` → "Use secure DNS" → off. Same for Edge: `edge://settings/privacy` → "Use secure DNS" → off.

**ACME cert not issuing / Traefik serving default cert**

step-ca needs to reach the Traefik host on port 443 to complete the TLS-ALPN-01 challenge. Make sure:

- step-ca container uses the router (`{{ lan_dns }}`) as its DNS server, not `172.17.0.1` (Docker bridge DNS doesn't resolve `.lan`)
- Port 443 is reachable on the Traefik host from lab1
- `acme.json` has `600` permissions — if corrupt, delete it and restart Traefik

**Portainer Edge agent disconnects immediately**

The edge agent connects to `portainer.lan:8000`. Ensure:

- Port `8000` is published on the Portainer container
- The CA cert is installed on the edge host (`update-ca-certificates --fresh`)
- Traefik has a valid cert (edge tunnel uses WSS)

**Verify DNS-over-TLS is working**

On the router:

```bash
# Should show ESTABLISHED connections to port 853
netstat -n | grep 853

# Should resolve without errors
drill @127.0.0.1 -p 5335 google.com
```
