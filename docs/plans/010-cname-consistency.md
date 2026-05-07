# 010: CNAME name/target consistency across roles

## Motivation

During plan #007 (docker-compose migration), we discovered inconsistent patterns for DNS CNAME registration and hostname configuration across roles:

1. **Missing `*_cname` vars** — some meta services had no CNAME var in defaults, only hardcoded names in tasks
2. **Inconsistent naming** — hub/agent split used the same variable name (`beszel_cname`) causing ambiguity
3. **No dependency chain for DNS names** — dependent roles hardcoded DNS hostnames instead of pulling from source role via meta deps
4. **CNAME registration scattered** — some services register CNAME in their deploy task, others don't, no standard pattern

The step-ca outage we hit today (CNAME overwritten to lab2) is a direct consequence of this inconsistency — without clear ownership and naming conventions, it's easy for one role's deployment to silently overwrite another's DNS record.

## Current state (audit)

### Roles with CNAME vars in defaults
| Role | Var | Value | Has meta dep? | CNAME registered? |
|------|-----|-------|---------------|-------------------|
| `meta/postgres` | `postgres_cname` | `"db"` | — | ✅ Yes (tasks/main.yml) |
| `meta/meilisearch` | `meilisearch_cname` | `"meili"` | — | ✅ Yes (tasks/main.yml) |
| `services/vaultwarden` | `vaultwarden_cname` | `"vw"` | — | ❌ No |
| `services/qbittorrent` | `qbittorrent_cname` | `"qbit"` | — | ❌ No |
| `services/beszel_hub` | `beszel_hub_cname` | `"beszel"` | — | ❌ No |
| `services/beszel_agent` | `beszel_agent_cname` | `"beszel"` | ✅ beszel_hub | ❌ No |
| `services/linkwarden` | `linkwarden_cname` | `"links"` | ✅ postgres, meilisearch | ✅ Yes (tasks/main.yml) |
| `services/traefik` | `traefik_cname` | `"traefik"` | ✅ step_ca | ❌ No |
| `services/portainer` | `portainer_cname` | `"portainer"` | — | ❌ No |
| `services/inpx_web` | `inpx_web_cname` | `"lib"` | — | ❌ No |

### Roles using CNAME vars from dependencies
| Role | Depends on | Uses dep's cname? | How |
|------|-----------|-------------------|-----|
| linkwarden | postgres, meilisearch | ✅ Yes (SOP-compliant) | `{{ postgres_cname }}`, `{{ meilisearch_cname }}` |
| beszel_agent | beszel_hub | ✅ Yes (fixed in #007-3) | `{{ beszel_hub_cname }}` |
| traefik | step_ca | ❌ No | Uses hardcoded `step-ca.lan_domain` or group_vars |

### Hardcoded DNS references remaining
| File | Reference | Should be? |
|------|-----------|------------|
| linkwarden .env (fixed) | `db.lan_domain`, `meili.lan_domain` | ✅ Now uses dep vars |
| beszel agent HUB_URL (fixed) | `beszel_cname` → own cname | ✅ Now uses `{{ beszel_hub_cname }}` |

## Issues to fix

### 1. Add missing CNAME registration tasks
Services with `*_cname` var but no `register_cname` call:
- vaultwarden
- qbittorrent
- beszel_hub
- beszel_agent (if agent has its own DNS name)
- traefik
- portainer
- inpx_web

### 2. Standardize CNAME registration pattern
All roles should register their CNAME after deploy:
```yaml
- name: Register <service> CNAME
  ansible.builtin.include_role:
    name: common
    tasks_from: register_cname
  vars:
    cname_name: "{{ <role>_cname }}.{{ lan_domain }}"
    cname_target: "{{ <role>_cname_target | default(inventory_hostname + '.' + lan_domain) }}"
```

### 3. Add `*_cname_target` override support for multi-host services
Some services may need to point to a specific host (not the current inventory host):
- `traefik_cname_target: "{{ groups['servers'][0] + '.' + lan_domain }}"` for HA setups
- Default should be `inventory_hostname`

### 4. Audit all dependent roles for hardcoded DNS names
Cross-check every role's meta dependencies and templates for hardcoded `.lan_domain` references that should use dep vars instead.

## Implementation steps

1. **Audit** — scan all compose templates + .env files for hardcoded DNS names (grep `\.{{ lan_domain }}`)
2. **Add registration** — add CNAME register task to every role with a `*_cname` var
3. **Fix cross-references** — update any remaining hardcoded references in dependent roles
4. **Document convention** — add to AGENTS.md: "All services MUST define `<role>_cname` and register it after deploy"

## Difficulty: Medium
- ~7 roles need CNAME registration added
- 1-2 roles may have cross-references that need fixing
- Low risk (DNS changes are idempotent via UCI)
