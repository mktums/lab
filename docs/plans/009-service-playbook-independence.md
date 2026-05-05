# 009: Reconsider service playbook independence

## Motivation

During plan #001 (move vars to defaults), we introduced cross-role fallback defaults to allow running individual service playbooks independently:

- `traefik/defaults`: `step_ca_port` (synced with step-ca role)
- `linkwarden/defaults`: `postgres_port` (synced with postgres role)
- `beszel_agent/defaults`: `beszel_cname`, `beszel_port` (synced with beszel hub role)

**Problem:** This creates duplication and drift risk. If a port changes in the source role, it must be updated in every dependent fallback default — easy to miss, hard to detect.

## Current state

Roles have implicit dependencies:
- traefik → step-ca (ACME CA server URL)
- linkwarden → postgres (DATABASE_URL)
- beszel-agent → beszel-hub (HUB_URL, port)

Fallback defaults mask these dependencies until runtime failures occur.

## Options

### Option A: Keep independence (current path)
- Accept fallback duplication in dependent roles
- Document cross-role sync requirements clearly
- Risk: drift, silent misconfiguration if values diverge

### Option B: Drop independence, require `servers.yml`
- Remove all fallback defaults from roles
- All service deployments run via `playbooks/servers.yml` only
- Dependencies resolved by playbook ordering (already documented)
- Benefit: single source of truth per variable
- Cost: can't easily redeploy one service without running full chain

### Option C: Explicit dependency injection
- Playbooks pass required cross-role vars as explicit parameters
- `playbooks/services/traefik.yml` sets `step_ca_port: 8443` via `vars:`
- Roles declare required external vars in documentation
- Benefit: dependencies are visible, no hidden fallbacks
- Cost: more playbook boilerplate

## Status: ✅ DONE (2026-05-05)

Kept `import_playbook` structure (not fully consolidated inline) because Ansible's vault decryption timing requires it — each imported playbook loads its `vars_files` at parse time, before group_vars evaluation. Inline plays in one file don't trigger early enough.

Tried dependency injection via `tasks_from: _no_op` but discovered play-level roles ignore `tasks_from` and run full role tasks anyway (tested, confirmed). Switched to explicit vars — simpler, more reliable.

### Extra changes beyond plan

- Added tags to all service playbooks for selective deployment (`--tags`/`--skip-tags`)
- Updated servers.yml header with tag usage documentation
- Fixed inpx_web image tag: `latest` → `local` (matches actual built image)
- Created missing install_ca_cert handler (`update-ca-certificates`)

## Affected files

| File | Fallback to remove/change |
|------|--------------------------|
| `traefik/defaults/main.yml` | `step_ca_port` |
| `linkwarden/defaults/main.yml` | `postgres_port` |
| `beszel_agent/defaults/main.yml` | `beszel_cname`, `beszel_port` |
