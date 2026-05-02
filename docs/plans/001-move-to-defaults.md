# 001: Move structural vars from inventory to role defaults

## Motivation

Currently, **all** variables — including structural values like image tags, default ports, container options — live in `inventory/group_vars/servers.yml`. This has two problems:

1. **Each role is not independently usable.** If someone clones this repo and tries `ansible-playbook playbooks/services/traefik.yml`, every variable referenced by the traefik role must be defined somewhere in inventory. A missed group_vars file or misnamed host var causes "undefined variable" errors that are hard to debug because there's no documentation of what's required.

2. **No separation of concerns.** `group_vars/servers.yml` mixes environment-specific secrets (passwords, tokens) with structural configuration defaults, making it harder to find either when debugging.

The fix: role `defaults/main.yml` for values that describe *how the role works*; inventory only for *environment overrides* and secrets.

## Affected roles

Not every role needs changes — some already have sensible defaults or their variables are purely environment-specific (passwords, emails). The ones that need work:

| Role | What moves to defaults | Why |
|------|----------------------|-----|
| `step_ca` | `step_ca_port`, `step_ca_name` | Structural config for the step-ca container |
| `traefik` | image tag, default ports, dashboard user | Core Traefik behavior |
| `portainer` | image tag, default port | Container deployment config |
| `vaultwarden` | image tag, default port | Container deployment config |
| `qbittorrent` | image tag, default ports (web + API) | Container deployment config |
| `linkwarden` | image tags, MeiliSearch defaults, DB connection format | Multi-container app config |
| `postgres` | image tag, data dir, port | Database server config |
| `beszel` | hub image/tag, agent image/tag, default ports | Monitoring stack config |
| `inpx_web` | Dockerfile path, supervisord defaults | Custom app config |

**No change needed:** roles whose vars are all secrets or purely environment-specific (e.g., passwords that only exist in vault).

## Implementation steps

### Step 1: Audit each role's variable usage

For each affected role, list every variable referenced in tasks/handlers/templates and categorize:
- **Structural** → goes to `defaults/main.yml`
- **Secret/environment-specific** → stays in inventory/vault (or is removed if it was only ever a structural default)

### Step 2: Create/expand `defaults/main.yml` per role

Each defaults file should have comments explaining what the variable controls. Example structure:

```yaml
# ── step-ca ───────────────────────────────────────────────────────

# Port step-ca listens on (ACME endpoint)
step_ca_port: 8443

# Display name for this CA (shown in cert subjects)
step_ca_name: "Homelab CA"

# Password for the ACME account registered with step-cli
vault_step_ca_password: "{{ vault_main_password }}"
```

Note: even if a variable is currently always overridden in inventory, **define it in defaults** so the role is usable standalone. The inventory override will still take precedence.

### Step 3: Clean up `group_vars/servers.yml`

Remove structural values that now have defaults. Keep only:
- Secrets (passwords, tokens) — these are environment-specific by nature
- Values that differ from defaults in this homelab and need documentation
- References to other inventory vars (`{{ admin_user }}`, etc.)

### Step 4: Update service playbooks if needed

If any `playbooks/services/<service>.yml` sets variables explicitly, move those to the role's defaults or remove them (if they were just overriding inventory).

### Step 5: Verify

Run each service playbook individually and confirm no "undefined variable" errors. The playbooks should work with zero extra-vars beyond what's in vault/secrets.yml.

## Rollback

Each change is a simple variable move — defaults can be removed and values restored to inventory if anything breaks. No structural changes, no logic changes.
