# 005: Kopia backup server + agents (labs, personal PC, MacBook)

## Motivation

Add centralized backup infrastructure using [Kopia](https://kopia.io/) — a fast, encrypted, deduplicated backup tool with CLI clients and Android app support.

### Scope

| Component | Role |
|-----------|------|
| Backup server | Kopia repository on one lab (lab1 or lab2) |
| Lab agents | Docker container agents on lab1 + lab2 |
| Personal PC | Windows/Linux agent (Ansible + WinRM/SSH) |
| MacBook | macOS agent (automated via Ansible) |
| Android devices | Kopia app with repo connection instructions |

## Affected files

| File | Change |
|------|--------|
| `playbooks/roles/kopia_server/` | New — repository server role |
| `playbooks/roles/kopia_agent/` | New — agent deployment role |
| `inventory/group_vars/servers.yml` | Kopia vars (repo path, retention policy) |
| `inventory/hosts.yml` | Add `kopia_hosts`, update group assignments |
| `playbooks/services/kopia_server.yml` | New — service playbook |
| `docs/kopia/android-setup.md` | New — Android device instructions |

## Implementation steps

### Step 1: Deploy Kopia repository server

- Create dedicated Docker container on selected lab host
- Configure encrypted repository (local or cloud storage backend)
- Set retention policies and access credentials
- Test backup/restore cycle from one agent

### Step 2: Create kopia_agent role

- Deploy Kopia agent as a managed service on each host
- Connect to central repository server
- Schedule periodic backups with retention policy
- Handle health checks and failure notifications

### Step 3: Configure non-homelab agents

- **Personal PC**: Ansible via WinRM (Windows) or SSH (Linux)
- **MacBook**: Ansible-managed agent deployment
- **Android devices**: Kopia app setup with repository URL, credentials, and WiFi-only sync instructions

### Step 4: Document restore procedures

- Per-host recovery steps
- File-level vs full-system restore
- Emergency bootable media considerations

## Implementation options for backup storage backend

| Backend | Pros | Cons |
|---------|------|------|
| Local disk (lab1) | Simple, no external dependency | Single point of failure if lab1 dies |
| S3-compatible (Cloudflare R2, Backblaze B2) | Off-site redundancy | Monthly egress costs, network dependency |
| WebDAV (nextcloud, owncloud) | Self-hosted off-site | Requires separate server setup |

## Rollback

All components are additive — remove roles/groups and stop agents without affecting other services.
