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

## Status: ✅ DONE (2026-05-09)

Issues #1 and #4 were already resolved during plan #007 (docker-compose migration). This plan addressed the remaining gaps.

### Changes applied

| Change | Detail |
|---|---|
| `install_ca_cert` hardcoded hostname | Uses `{{ step_ca_cname }}` instead of literal `step-ca` — survives CNAME renames |
| Unused `*_cname_target` overrides removed | All 10 roles simplified to bare default (`inventory_hostname + '.' + lan_domain`) handled by `register_cname.yml` itself — no role-level override needed in this homelab |
| CNAME registration extracted to `tasks/cname.yml` | Every role with a `_cname` var now imports a dedicated task file instead of inlining the call in `main.yml` — keeps main tasks focused on deployment logic |
| `meilisearch_hosts` group created | Meilisearch guard changed from `linkwarden_hosts` → own `meilisearch_hosts` group (`lab1`) — decouples dependency targeting for future flexibility |

### Final state (audit)

**Roles with CNAME registration:** 10/10 ✅

| Role | cname_name | Guard | File |
|------|-----------|-------|-----|
| beszel_hub | `beszel.lan` | `beszel_hosts` | `tasks/cname.yml` |
| inpx_web | `lib.lan` | — (inventory) | `tasks/cname.yml` |
| linkwarden | `links.lan` | — (inventory) | `tasks/cname.yml` |
| portainer | `portainer.lan` | — (inventory) | `tasks/cname.yml` |
| qbittorrent | `qbit.<host>.lan` | — (inventory) | `tasks/cname.yml` |
| step_ca | `step-ca.lan` | `step_ca_hosts` | `tasks/cname.yml` |
| traefik | `traefik.<host>.lan` | — (inventory) | `tasks/cname.yml` |
| vaultwarden | `vw.lan` | — (inventory) | `tasks/cname.yml` |
| postgres (meta) | `db.lan` | `postgres_hosts` | `tasks/cname.yml` |
| meilisearch (meta) | `meili.lan` | `meilisearch_hosts` | `tasks/cname.yml` |

**Roles correctly without CNAME:** beszel_agent (outbound-only), portainer_edge (registers with Portainer main)

### Rollback

All changes are idempotent DNS + task restructuring. Revert the commit to restore inline registration and hardcoded hostname.
