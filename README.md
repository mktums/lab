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
│       dnsmasq → unbound                 │
│  adblock-lean (medium preset)           │
└───┬─────────────────┬───────────────────┘
    │ LAN             │ IoT
    │ 10.10.10.0/24   │ 10.10.30.0/24
    │                 │ (isolated, WAN only)
    │
    ├── lab1  10.10.10.10
    │   Ubuntu Server 24.04
    │   Docker host
    │   ├── step-ca     :8443  (ACME CA, not behind Traefik)
    │   ├── traefik     :80/:443
    │   │   └── traefik.lab1.lan  (dashboard)
    │   └── portainer   (via Traefik)
    │       └── portainer.lan
    │
    └── ... (future servers)

Wi-Fi:
  Main (2.4 + 5 GHz, WPA3/WPA2, hidden) → LAN
  IoT  (2.4 GHz, WPA2)                  → IoT

DNS (*.lan resolved by dnsmasq):
  lab1.lan          → 10.10.10.10  (DHCP reservation by MAC)
  step-ca.lan       → lab1.lan     (CNAME)
  traefik.lab1.lan  → lab1.lan     (CNAME)
  portainer.lan     → lab1.lan     (CNAME)
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
/etc/init.d/network reload
```

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

### 6. Install Ubuntu Server 24.04 on lab1

- Assign static DHCP via MAC `70:85:c2:63:58:59` → `10.10.10.10`
  (already configured by the router playbook)
- Create a non-root sudo user matching `vault_admin_user`
- Enable SSH key auth, paste in `vault_admin_ssh_pubkey`

### 7. Vault — add Traefik dashboard password

Generate a bcrypt htpasswd entry:

```bash
htpasswd -nB admin
# or without apache2-utils:
docker run --rm httpd:2.4-alpine htpasswd -nbB admin "your-password"
```

```bash
ansible-vault edit vault/secrets.yml
# add: vault_traefik_dashboard_user: "admin:$2y$..."
```

### 8. Vault — add Portainer admin password hash

Portainer uses the same password as the router admin. Generate a bcrypt hash of it:

```bash
htpasswd -nbB admin "your-router-password" | cut -d: -f2
# or without apache2-utils:
docker run --rm httpd:2.4-alpine htpasswd -nbB admin "your-router-password" | cut -d: -f2
```

```bash
ansible-vault edit vault/secrets.yml
# add: vault_portainer_admin_hash: "$2y$..."
```

### 9. Vault — add step-ca password

Pick any strong password for the CA key encryption:

```bash
ansible-vault edit vault/secrets.yml
# add: vault_step_ca_password: "..."
```

### 10. Run servers playbook (first time — step-ca init)

```bash
ansible-playbook playbooks/servers.yml
```

This will start step-ca and print its root fingerprint. The Traefik play will
be skipped on this run because `vault_step_ca_root_cert` is not yet set.

### 11. Vault — add step-ca fingerprint and root cert

step-ca data is bind-mounted to `/data/docker/step-ca` on lab1. Read directly from there:

```bash
# Get the root cert
scp lab1:/data/docker/step-ca/certs/root_ca.crt homelab-ca.crt

# Get the fingerprint
ssh lab1 "openssl x509 -in /data/docker/step-ca/certs/root_ca.crt -noout -fingerprint -sha256 \
  | cut -d= -f2 | tr -d ':' | tr '[:upper:]' '[:lower:]'"
```

```bash
ansible-vault edit vault/secrets.yml
# add:
#   vault_step_ca_fingerprint: "<fingerprint from above>"
#   vault_step_ca_root_cert: |
#     -----BEGIN CERTIFICATE-----
#     ...
#     -----END CERTIFICATE-----
```

### 12. Install root CA on your devices

You already have `homelab-ca.crt` locally from the previous step.

| Device | How to install |
|--------|---------------|
| Linux | `sudo cp homelab-ca.crt /usr/local/share/ca-certificates/ && sudo update-ca-certificates` |
| macOS | `sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain homelab-ca.crt` |
| Windows | Double-click → Install → Trusted Root Certification Authorities |
| Android | Settings → Security → Install certificate |
| iOS | AirDrop or email the file → tap to install → Settings → General → VPN & Device Management → trust it |

Do this once per device. After this, all `*.lan` HTTPS services will show a
green padlock with no warnings.

### 13. Run servers playbook (second time — Traefik)

```bash
ansible-playbook playbooks/servers.yml
```

Traefik starts, requests its dashboard cert from step-ca, and
`https://traefik.lab1.lan` becomes available.

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

# Servers (common + docker + step-ca + traefik)
ansible-playbook playbooks/servers.yml

# Everything
ansible-playbook playbooks/site.yml
```

Add `--ask-vault-pass` if not using `.vault_pass`.

The router playbook does not support `--check` mode.

---

## Troubleshooting

**`DNS_PROBE_FINISHED_NXDOMAIN` for `*.lan` in Chrome/Edge**

Chromium-based browsers have a "Use secure DNS" (DoH) setting that bypasses the system resolver and sends queries to a public DNS provider, which has no knowledge of your local `.lan` domain.

Disable it: `chrome://settings/security` → "Use secure DNS" → off.

Same applies to Edge: `edge://settings/privacy` → "Use secure DNS" → off.

---

## Adding a service behind Traefik

Any container on a docker host gets picked up by Traefik automatically via
Docker labels. Traefik requests a cert from step-ca on first use.

Minimal labels for a new service:

```yaml
services:
  myapp:
    image: myapp:latest
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.myapp.rule=Host(`myapp.lan`)"
      - "traefik.http.routers.myapp.entrypoints=websecure"
      - "traefik.http.routers.myapp.tls=true"
      - "traefik.http.routers.myapp.tls.certresolver=step-ca"
```

If the container exposes multiple ports, specify which one Traefik should use:

```yaml
      - "traefik.http.services.myapp.loadbalancer.server.port=8080"
```

Then add a CNAME in `inventory/group_vars/routers.yml`:

```yaml
dns_cnames:
  - { cname: "myapp.lan", target: "lab1.lan" }
```

And re-run the router playbook:

```bash
ansible-playbook playbooks/router.yml
```

Or, if the service is deployed by its own Ansible role, call `register_cname`
from within that role:

```yaml
- ansible.builtin.include_role:
    name: common
    tasks_from: register_cname
  vars:
    cname_name: "myapp.lan"
    cname_target: "{{ inventory_hostname }}.{{ lan_domain }}"
```
