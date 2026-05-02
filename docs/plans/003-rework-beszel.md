# 003: Rework Beszel playbooks

## Motivation

Current Beszel playbooks have fundamental issues that need addressing before committing more effort to them.

### Issues

1. **`register.yml` doesn't generate KEY/TOKEN** — only creates system records on Hub UI. Credentials are static vault secrets shared across all hosts.
2. **Static `beszel_token` per host** — if Beszel expects unique tokens per system, multi-host setup is broken.
3. **No use of official tooling** — Ansible's `community.beszel` collection exists with dedicated Hub and Agent roles.

## Affected files

| File | Change |
|------|--------|
| `requirements.yml` | Add `community.beszel` collection |
| `playbooks/roles/beszel/tasks/main.yml` | Replace Hub role with official collection's |
| `playbooks/roles/beszel_agent/tasks/main.yml` | Replace Agent role with official collection's |
| `playbooks/roles/beszel/tasks/register.yml` | Remove (collection handles registration) |
| `inventory/group_vars/servers.yml` | Clean up Beszel-specific vars |
| `vault/secrets.yml` | Review token/key structure — ensure unique per-host if needed |

## Implementation steps

### Step 1: Add official collection to requirements.yml

```yaml
collections:
  - name: community.beszel
    version: >=1.0.0
```

Run: `ansible-galaxy collection install -r requirements.yml`

### Step 2: Replace beszel role with Hub role from collection

Use `community.beszel.hub` for the hub container deployment. This handles:
- Container image management
- Initial setup (email, password)
- System registration via API

### Step 3: Replace beszel_agent role with Agent role from collection

Use `community.beszel.agent` for agent deployment on each host. This handles:
- KEY/TOKEN generation and distribution
- Container deployment
- Health checks

### Step 4: Clean up inventory and vault

- Remove custom Beszel vars that the collection manages
- Review if tokens need to be unique per-host (check official role docs)
- Update service playbook to use collection roles

### Step 5: Verify

- Run beszel playbooks against lab1/lab2
- Confirm Hub UI shows both agents
- Test agent health reporting

## Rollback

Collection is a galaxy install/uninstall away. Playbooks can be reverted by restoring from git.
