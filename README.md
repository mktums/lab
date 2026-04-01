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
│  OpenWrt 24.10                          │
│  DNS: unbound (127.0.0.1:5335)          │
│       dnsmasq → unbound → DoT          │
│       upstreams: Cloudflare + Google   │
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

These are one-time steps that must be done by hand. Ansible assumes they are
already complete before it runs.

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

### 3. Vault — add router SSH password

```bash
ansible-vault edit vault/secrets.yml
# add: vault_router_ssh_pass: "your-root-password"
```

### 4. Vault — add admin credentials

```bash
ansible-vault edit vault/secrets.yml
# add:
#   vault_admin_user: "your-username"
#   vault_admin_ssh_pubkey: "ssh-ed25519 AAAA..."
```

### 5. Run router playbook

```bash
ansible-playbook playbooks/router.yml
```

### 6. Vault — add service passwords

```bash
ansible-vault edit vault/secrets.yml
# add (all default to vault_main_password, override individually if needed):
#   vault_traefik_dashboard_password: "{{ vault_main_password }}"
#   vault_portainer_admin_password: "{{ vault_main_password }}"
#   vault_vaultwarden_admin_token: "{{ vault_main_password }}"
#   vault_qbittorrent_password: "{{ vault_main_password }}"
#   vault_step_ca_password: "{{ vault_main_password }}"
```

### 7. Run servers playbook (first time — step-ca init)

```bash
ansible-playbook playbooks/servers.yml
```

step-ca starts and initialises. All plays that require a CA cert are skipped
on this run because `vault_step_ca_root_cert_pem` is not yet set.

### 8. Vault — add step-ca fingerprint and root cert

```bash
# Get the root cert (also saves it locally for device trust)
scp lab1:/data/docker/step-ca/certs/root_ca.crt homelab-ca.crt

# Get the fingerprint
ssh lab1 "openssl x509 -in /data/docker/step-ca/certs/root_ca.crt \
  -noout -fingerprint -sha256 | cut -d= -f2 | tr -d ':' | tr '[:upper:]' '[:lower:]'"
```

```bash
ansible-vault edit vault/secrets.yml
# add:
#   vault_step_ca_fingerprint: "<fingerprint from above>"
#   vault_step_ca_root_cert_pem: |
#     -----BEGIN CERTIFICATE-----
#     ...
#     -----END CERTIFICATE-----
```

### 9. Install root CA on your devices

You already have `homelab-ca.crt` locally from the previous step.

| Device | How to install |
|--------|----------------|
| Linux | `sudo cp homelab-ca.crt /usr/local/share/ca-certificates/ && sudo update-ca-certificates` |
| macOS | `sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain homelab-ca.crt` |
| Windows | Double-click `homelab-ca.crt` → Install Certificate → **Local Machine** → **Trusted Root Certification Authorities** → Finish. Restart Chrome/Edge (`chrome://restart`). |
| Android | Settings → Security → Install certificate |
| iOS | AirDrop or email the file → tap to install → Settings → General → VPN & Device Management → trust it |

Do this once per device. After this, all `*.lan` HTTPS services will show a
green padlock with no warnings.

### 10. Run servers playbook (second time — full deploy)

```bash
ansible-playbook playbooks/servers.yml
```

Traefik starts on each docker host, requests certs from step-ca, and all
services come up behind HTTPS.

> After first deploy, visit `https://beszel.lan`, log in, then:
> 1. Settings → Tokens → create a token → add to `vault_beszel_token`
> 2. Add System → copy the public key → add to `vault_beszel_hub_key`
> 3. Re-run `ansible-playbook playbooks/services/beszel.yml` to deploy agents
>
> **S.M.A.R.T. monitoring**: The Beszel agent is configured with S.M.A.R.T. device mappings
> and capabilities (`SYS_RAWIO`, `SYS_ADMIN`) for disk health monitoring. Additional filesystems
> can be monitored by adding extra volume mounts in `inventory/host_vars/<host>.yml`:
>
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

Expected vault structure:

```yaml
vault_main_password: "..."          # master password, reused by default everywhere
vault_bcrypt_salt: "....................."  # exactly 22 chars of [./A-Za-z0-9]
                                           # generate: python3 -c "import bcrypt; print(bcrypt.gensalt()[7:].decode())"

vault_admin_user: "..."
vault_admin_ssh_pubkey: "ssh-ed25519 AAAA..."

vault_router_ssh_pass: "{{ vault_main_password }}"

vault_wifi_main_password: "..."
vault_wifi_iot_password: "..."

vault_step_ca_password: "{{ vault_main_password }}"
vault_step_ca_fingerprint: ""        # populated after first run
vault_step_ca_root_cert_pem: |       # populated after first run
  -----BEGIN CERTIFICATE-----
  ...
  -----END CERTIFICATE-----

vault_traefik_dashboard_password: "{{ vault_main_password }}"
vault_portainer_admin_password: "{{ vault_main_password }}"
vault_vaultwarden_admin_token: "{{ vault_main_password }}"
vault_qbittorrent_password: "{{ vault_main_password }}"
vault_postgres_password: "{{ vault_main_password }}"
vault_linkwarden_nextauth_secret: ""   # generate: openssl rand -hex 32
vault_linkwarden_meili_master_key: ""  # generate: openssl rand -hex 32
vault_linkwarden_db_password: "{{ vault_main_password }}"
vault_beszel_admin_email: "..."        # email for Beszel admin user
vault_beszel_admin_password: "{{ vault_main_password }}"
vault_beszel_token: ""                 # from Beszel UI: Settings → Tokens
vault_beszel_hub_key: ""               # from Beszel UI: Add System → public key
```

Common commands:

```bash
ansible-vault edit vault/secrets.yml
ansible-vault view vault/secrets.yml
ansible-vault rekey vault/secrets.yml
```

---

## Running playbooks

```bash
# Router only
ansible-playbook playbooks/router.yml

# Base server setup (server_base + docker)
ansible-playbook playbooks/server_base.yml
ansible-playbook playbooks/docker.yml

# Single service
ansible-playbook playbooks/services/traefik.yml
ansible-playbook playbooks/services/inpx_web.yml
# ... etc

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

`en_DK.UTF-8` is used as `LANG` — it's English language with ISO 8601 conventions (YYYY-MM-DD dates,
24h clock, dot decimal separator, Monday-first weeks). Denmark locale is the traditional Linux choice
for "international English" — same as `en_US` for language, but sane date/number formats.

`LC_MESSAGES` is pinned to `en_US.UTF-8` because `en_DK` message catalogs are sparse and some tools
fall back to untranslated output.

`LC_COLLATE` and `LC_CTYPE` use `ru_RU.UTF-8` so Cyrillic filenames (e.g. book archives) sort
alphabetically rather than by raw Unicode codepoint.

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

1. Create `playbooks/roles/<service>/` with `tasks/main.yml`, `tasks/deploy.yml`,
   `tasks/cname.yml`, `handlers/main.yml`
2. Add a group under `children` in `inventory/hosts.yml`
3. Add a play to `playbooks/servers.yml`
4. Add any secrets to `vault/secrets.yml` and vars to `inventory/group_vars/servers.yml`
5. Run `ansible-playbook playbooks/servers.yml`

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

Chromium-based browsers have a "Use secure DNS" (DoH) setting that bypasses
the system resolver and sends queries to a public DNS provider, which has no
knowledge of your local `.lan` domain.

Disable it: `chrome://settings/security` → "Use secure DNS" → off.
Same for Edge: `edge://settings/privacy` → "Use secure DNS" → off.

**ACME cert not issuing / Traefik serving default cert**

step-ca needs to reach the Traefik host on port 443 to complete the
TLS-ALPN-01 challenge. Make sure:

- step-ca container uses the router (`{{ lan_dns }}`) as its DNS server,
  not `172.17.0.1` (Docker bridge DNS doesn't resolve `.lan`)
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
