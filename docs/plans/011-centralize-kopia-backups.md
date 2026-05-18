# 011: Centralize Kopia backup orchestration in kopia_agent role

## Status: ✅ Done

All implementation steps completed:
- Backup config moved from postgres/defaults/backup.yml to inventory/host_vars/lab1.yml
- Postgres role decoupled (no backup tasks, no kopia references)
- Action templates resolved by convention (`actions/<service>/` in kopia_agent)
- `register_source.yml` loops over `backup_sources` dict
- Documentation updated (`docs/kopia/adding-backup.md`)

## Motivation

Backup configuration is currently embedded inside service roles (Postgres includes `kopia_agent/register_source` from its own tasks). This couples every participating service to Kopia implementation details and scatters backup auditability across N roles. Moving all backup orchestration into the `kopia_agent` role — driven by inventory declarations — separates concerns cleanly: services deploy, Kopia protects.

### Current problems

1. **Backup spread across service roles** — auditing "what gets backed up" requires grepping through every role that participates. No single source of truth for backup topology.
2. **Service roles carry infrastructure knowledge** — Postgres knows about `kopia_override_username`, `kopia_sources` dict shape, retention key names — that's backup implementation detail leaking into a database role.
3. **Duplicate agent setup on shared hosts** — systemd template deployment, directory creation, and reload tasks fire redundantly across whichever service runs first on each host. No single "prepare this host for Kopia" step.
4. **Meta dependency chain over-constrained** — `kopia_server` depends on `traefik`, which means every service touching Kopia implicitly pulls in the full CA+proxy stack. You can't test a service role without the entire infrastructure chain.

### Target principle

> A service role deploys, configures, and runs its application. It does not know about backup software, monitoring agents, or logging pipelines — those are cross-cutting concerns configured from inventory and orchestrated by their own roles.

This is how Prometheus exporters work (declared in inventory, deployed separately), how log forwarding works (Fluent Bit sidecar configured independently), and should be how backups work too.

---

## Current state (audit)

### Backup-aware service roles

| Role | Backup files | What it does | Coupling to Kopia |
|------|-------------|--------------|-------------------|
| `meta/postgres` | (none — moved to inventory) | Declares sources in host_vars, action script in kopia_agent/templates/actions/ | None (decoupled) |
| `services/vaultwarden` | (none — moved to inventory) | Action scripts in kopia_agent/templates/actions/ | None (decoupled) |

All other service roles (qbittorrent, inpx_web, portainer, traefik) have **no backup** — data is either ephemeral, user-generated on disk, or covered by Kopia repository-level snapshots.

### Current flow (servers.yml single play)

```
kopia_server (traefik → step_ca chain)
  └── kopia_agent (runs after kopia_server via meta dep)
        └── postgres (includes backup.yml → register_source)
              ├── kopia connect with override identity
              ├── set retention policy per source
              ├── deploy pre-action script (pg_dump)
              ├── seed first snapshot
              └── start systemd timer
```

The `kopia_agent` role's `deploy.yml` runs once per host, then each service independently calls `register_source`. There is no single "this host has these backup sources" declaration.

---

## Target architecture

### Directory structure (action templates move into kopia_agent)

All backup-related code — orchestration tasks, systemd templates, and per-service action scripts — lives in one role:

```
playbooks/roles/infra/kopia_agent/
  defaults/main.yml              # backup_sources: {} default
  handlers/main.yml               # Reload systemd (unchanged)
  meta/main.yml                   # dependencies: kopia_server (unchanged)
  tasks/
    main.yml                      # deploy.yml + loop over sources → register_source.yml
    deploy.yml                    # install binary, systemd templates (unchanged)
    register_source.yml           # refactored to accept source_def from loop variable
  templates/
    kopia-backup@.timer.j2        # (unchanged)
    kopia-backup@.service.j2      # (unchanged)
    kopia_agent.env.j2            # (unchanged)
    actions/                      # NEW — organized by service
      postgres/                   # moved from meta/postgres/templates/
        before-snapshot-root.sh.j2
      vaultwarden/
        before-snapshot-root.sh.j2
      archive-store/
        before-folder.sh.j2
        after-folder.sh.j2
```

**Rationale for moving templates:** Eliminates cross-role template path resolution entirely. When `register_source.yml` runs inside kopia_agent's role context, `src: "actions/<service>/<action-type>.sh.j2"` resolves naturally against the role's own `templates/` directory. No `playbook_dir` hacks, no absolute paths, no fragile string references in inventory.

Organizing by service keeps all scripts for one backup target together — you know exactly where to look when debugging "why does postgres backup fail".

### Inventory-driven declarations

```yaml
# inventory/host_vars/lab1.yml (existing file, add section)

# ── Kopia backup sources ────────────────────────────────────────────────

backup_sources:
  postgres:
    hostname: server
    paths:
      "{{ postgres_data_dir }}/backups":
        retention:
          keep_latest: 10
          keep_hourly: 48
          keep_daily: 7
          keep_weekly: 4
          keep_monthly: 24
          keep_annual: 3
    actions:
      before-snapshot-root: true   # → templates/actions/postgres/before-snapshot-root.sh.j2
    schedule: "hourly"

# lab2.yml — no backup_sources key (host skipped by kopia_agent guard)
```

Schema fields:

| Field | Required | Default | Description |
|-------|----------|---------|-------------|
| `hostname` | Yes | — | Kopia override hostname (identity suffix, e.g. `server`) |
| `paths` | Yes | — | Dict of path → config; each entry can define per-path retention and folder actions |
| `actions` | No | None | Snapshot-root action types to enable (`before-snapshot-root`, `after-snapshot-root`) |
| `schedule` | No | Role default (`hourly`) | systemd OnCalendar expression for backup timer |

Retention: per-path in `paths`. If omitted, falls back to **global Kopia server policy** (set by `kopia_server` role).

Action resolution — convention over configuration:

| Action key | Template resolved to | Scope |
|------------|----------------------|-------|
| `actions.before-snapshot-root` | `templates/actions/<source-key>/before-snapshot-root.sh.j2` | Once per snapshot, inherited by all paths |
| `actions.after-snapshot-root` | `templates/actions/<source-key>/after-snapshot-root.sh.j2` | Once per snapshot, inherited by all paths |

Folder-level actions (per path, **not inherited** — must be set on each directory):

```yaml
  archive-store:
    hostname: server
    paths:
      "/srv/docker_data/archive-store":
        retention:
          keep_daily: 7
        before-folder: true   # → templates/actions/archive-store/before-folder.sh.j2
        after-folder: true    # → templates/actions/archive-store/after-folder.sh.j2
```

Folder actions live inside the `paths` dict entry (not a separate key) — the path IS the target folder.

### kopia_agent role iterates over inventory

```yaml
# kopia_agent/tasks/main.yml (new structure)

- name: Deploy Kopia agent base (install binary, systemd templates)
  ansible.builtin.include_tasks: deploy.yml
  when: backup_sources | length > 0

- name: Register all backup sources for this host
  loop: "{{ backup_sources | dict2items }}"
  loop_control:
    loop_var: source_def
    label: "kopia-backup@{{ source_def.key }}"
  ansible.builtin.include_tasks: register_source.yml
```

### Service roles are clean

```yaml
# postgres/tasks/main.yml (after migration)

- include_tasks: deploy.yml
- include_tasks: cname.yml
# ← no backup tasks, no Kopia knowledge, no template files for backup
```

---

## Rationale for design choices

### Why inventory, not a separate backup playbook/role layer?

Inventory (`host_vars/<host>.yml`) is where host-specific configuration belongs. Backup sources are inherently per-host: lab1 backs up Postgres data on `/srv/docker_data/db/postgres`, lab2 might back up different paths. Grouping by host matches the existing pattern for `system_optimize_mounts` and `beszel_smart_devices`.

A separate "backup roles" layer would require yet another playbook, another set of tags, and another dependency chain — over-engineering for a homelab with 2 hosts and ~3 backup targets.

### Why move action templates into kopia_agent instead of keeping them in service role dirs?

The previous design kept `postgres_before-snapshot-root.sh.j2` in `meta/postgres/templates/` and referenced it from inventory via a relative path string like `"roles/meta/postgres/templates/postgres_before-snapshot-root.sh.j2"`. This has two problems:

1. **Template resolution breaks** — Ansible resolves `template.src` relative to the *executing role's* templates directory (kopia_agent), not the playbook root. The reference would silently fail at runtime.
2. **Cross-role string references are fragile** — a typo in the path produces no lint error, only a runtime failure. Moving everything into kopia_agent eliminates this class of bug entirely.

The tradeoff is that the pg_dump script moves out of the Postgres role directory. But it's backup infrastructure (dumping data for Kopia to snapshot), not database logic — so `kopia_agent/templates/actions/postgres/` is the correct home. The script still references Ansible vars (`postgres_data_dir`, etc.) which are available through normal variable precedence from group_vars and role defaults.

Organizing by service means all backup scripts for one target live together:
```
templates/actions/
  postgres/           # everything related to postgres backups, in one place
    before-snapshot-root.sh.j2
  vaultwarden/
    before-snapshot-root.sh.j2
```
Inventory just declares `actions.before-snapshot-root: true` — the template path resolves by convention (`actions/<source-key>/<action-type>.sh.j2`). No filename to type, no naming convention to memorize.

### Why `backup_sources` as a dict keyed by service name, not a list?

Dict keys provide natural uniqueness — you can't accidentally declare the same source twice. The key is also the Kopia override username (identity), so `postgres` → `override_username: postgres`. A list would require an explicit `name` field and dedup logic.

### Why move config from role defaults to inventory?

The current approach (`postgres/defaults/backup.yml`) scatters backup configuration across N role directories. Finding "what gets backed up" requires searching through every service role's files. Central inventory puts all backup declarations in one place per host — `host_vars/lab1.yml` is the single file you open to audit or modify backup topology.

---

## Affected files

| File | Change |
|------|--------|
| `inventory/group_vars/servers.yml` | Add `kopia_global_retention` + `kopia_global_parallelism` (migrate from kopia_server/defaults/main.yml) |
| `inventory/host_vars/lab1.yml` | Add `backup_sources` dict (migrate from postgres/defaults/backup.yml) |
| `playbooks/roles/meta/postgres/defaults/backup.yml` | **Delete** — content moved to inventory |
| `playbooks/roles/meta/postgres/tasks/backup.yml` | **Delete** — orchestration moves to kopia_agent |
| `playbooks/roles/meta/postgres/templates/postgres_before-snapshot-root.sh.j2` | **Move** → `kopia_agent/templates/actions/postgres/before-snapshot-root.sh.j2` |
| `playbooks/roles/meta/postgres/tasks/main.yml` | Remove `- include_tasks: backup.yml` line |
| `playbooks/roles/infra/kopia_server/defaults/main.yml` | Remove retention + parallelism vars (moved to group_vars) |
| `playbooks/roles/infra/kopia_server/tasks/deploy.yml` | Read global policy from `kopia_global_retention` dict instead of individual vars |
| `playbooks/roles/infra/kopia_agent/defaults/main.yml` | Add `backup_sources: {}` default |
| `playbooks/roles/infra/kopia_agent/tasks/main.yml` | Restructure to iterate over inventory `backup_sources` |
| `playbooks/roles/infra/kopia_agent/tasks/register_source.yml` | Refactor to accept source config from loop variable (`source_def`) |
| `docs/kopia/adding-backup.md` | Update documentation to reflect new pattern |

**Unaffected (no changes needed):**
- `playbooks/servers.yml` — kopia roles stay in same position, tag `kopia` covers both
- `postgres/templates/docker-compose.yml.j2` — compose template unchanged
- `kopia_server/defaults/main.yml` still keeps image name/tag, paths, network config (only retention + parallelism move to inventory)

---

## Implementation steps

### Step 0: Move Kopia server global config to group_vars

Move retention and parallelism settings from `kopia_server/defaults/main.yml` into `inventory/group_vars/servers.yml`:

```yaml
# group_vars/servers.yml (append)

# ── Kopia global repository policy ──────────────────────────────────────
kopia_global_retention:
  keep_latest: 10
  keep_hourly: 48
  keep_daily: 7
  keep_weekly: 4
  keep_monthly: 24
  keep_annual: 3
kopia_global_parallelism:
  max_file_reads: 8     # Conservative for 16GB RAM with concurrent backups
  max_snapshots: 4      # Staggered service backups without saturating mirror I/O
```

Update `kopia_server/tasks/deploy.yml` to read from dict instead of individual vars:
```yaml
# Before (individual defaults vars):
--keep-latest={{ kopia_retention_keep_latest }} \
--keep-hourly={{ kopia_retention_keep_hourly }} \
...
--max-parallel-file-reads={{ kopia_global_max_parallel_file_reads }} \
--max-parallel-snapshots={{ kopia_global_max_parallel_snapshots }} \

# After (dict from group_vars):
--keep-latest={{ kopia_global_retention.keep_latest }} \
--keep-hourly={{ kopia_global_retention.keep_hourly }} \
...
--max-parallel-file-reads={{ kopia_global_parallelism.max_file_reads }} \
--max-parallel-snapshots={{ kopia_global_parallelism.max_snapshots }} \
```

**Rationale:** Global policy is infrastructure configuration — belongs in inventory alongside per-host backup sources, not hidden inside a role's defaults. Makes it visible and changeable without touching playbook code.

### Step 1: Move action templates into kopia_agent

Create per-service actions directories and move existing templates:

```bash
mkdir -p playbooks/roles/infra/kopia_agent/templates/actions/postgres/
mv playbooks/roles/meta/postgres/templates/postgres_before-snapshot-root.sh.j2 \
   playbooks/roles/infra/kopia_agent/templates/actions/postgres/before-snapshot-root.sh.j2
```

**Rationale:** This is a pure file move — no content changes. The template references Ansible vars (`postgres_data_dir`, `postgres_opt_dir`, `postgres_user`) which are resolved through normal variable precedence regardless of which role's templates directory the file lives in. No template content modification needed.

### Step 2: Migrate Postgres backup config to inventory

Move content from `postgres/defaults/backup.yml` into `inventory/host_vars/lab1.yml`:

```yaml
# inventory/host_vars/lab1.yml (append)

backup_sources:
  postgres:
    hostname: server
    paths:
      "{{ postgres_data_dir }}/backups":
        retention:
          keep_latest: 10
          keep_hourly: 48
          keep_daily: 7
          keep_weekly: 4
          keep_monthly: 24
          keep_annual: 3
    actions:
      before-snapshot-root: true   # → templates/actions/postgres/before-snapshot-root.sh.j2
```

**Rationale:** Values are identical to `postgres/defaults/backup.yml`, just relocated. Path uses Ansible var reference (`{{ postgres_data_dir }}`) so it survives base directory changes without touching inventory. Retention is per-path (same as current `kopia_sources` dict). Action template resolves by convention — no explicit path needed.

### Step 3: Add default to kopia_agent role defaults

```yaml
# kopia_agent/defaults/main.yml (append)

# Backup sources declared in host_vars, keyed by service name.
# Each entry defines a separate Kopia identity with its own timer and retention.
backup_sources: {}
```

**Rationale:** Provides empty default so `backup_sources | length > 0` guard works without `is defined` checks or `| default({})` filters. Hosts without backups (lab2) simply get the empty dict — no conditional logic needed beyond the length check.

### Step 4: Refactor kopia_agent/tasks/main.yml

```yaml
# kopia_agent/tasks/main.yml (new structure)

- name: Deploy Kopia agent base (install binary, systemd templates)
  ansible.builtin.include_tasks: deploy.yml
  when: backup_sources | length > 0

- name: Register all backup sources for this host
  loop: "{{ backup_sources | dict2items }}"
  loop_control:
    loop_var: source_def
    label: "kopia-backup@{{ source_def.key }}"
  ansible.builtin.include_tasks: register_source.yml
```

**Rationale:** `deploy.yml` runs once per host (idempotent). Then each entry in `backup_sources` triggers `register_source.yml`. The loop variable `source_def` carries the full source definition (`source_def.key` = service name / override_username, `source_def.value` = config dict).

### Step 5: Refactor register_source.yml to accept loop variable

Current file expects caller-provided vars (`kopia_override_username`, `kopia_sources`, etc.). Refactor to read from the loop variable. Key replacements:

| Current | New |
|---------|-----|
| `{{ kopia_override_username }}` | `{{ source_def.key }}` |
| `{{ kopia_override_hostname }}` | `{{ source_def.value.hostname }}` |
| `kopia_sources \| dict2items` loop | Direct iteration over `source_def.value.paths \| dict2items` (dict, per-path config) |
| Per-source retention from nested dict | `item.value.retention` (per-path), or **global Kopia server policy** if omitted |
| `kopia_before_snapshot_root_action_path` | Convention: `actions/{{ source_def.key }}/before-snapshot-root.sh.j2`, deployed when `source_def.value.actions.before-snapshot-root` is truthy |
| `kopia_after_snapshot_root_action_path` | Convention: `actions/{{ source_def.key }}/after-snapshot-root.sh.j2`, deployed when `source_def.value.actions.after-snapshot-root` is truthy |
| Per-path folder actions | Convention: `actions/{{ source_def.key }}/<type>.sh.j2`, deployed when `item.value.<type>` (inside paths dict) is truthy |
| Timer schedule from role defaults | `source_def.value.schedule \| default(kopia_timer_on_calendar)` |

Template resolution convention:
```yaml
# register_source.yml logic (pseudo-template)
{% for action_type in ['before-snapshot-root', 'after-snapshot-root'] %}
  {% if source_def.value.actions[action_type] | default(false) %}
    # → templates/actions/{{ source_def.key }}/{{ action_type }}.sh.j2
  {% endif %}
{% endfor %}
```

The structural change: `kopia_sources` dict shape is preserved (path → config), just moved from role defaults into inventory. No flattening — per-path retention and folder actions are first-class in the schema.

### Step 6: Drop backup tasks from Postgres role

```diff
# postgres/tasks/main.yml
---
- name: Deploy Postgres (lab1 only)
  block:
    - ansible.builtin.include_tasks: deploy.yml
    - ansible.builtin.include_tasks: cname.yml
-   - ansible.builtin.include_tasks: backup.yml
  when: inventory_hostname in groups.get('postgres_hosts', [])
```

Delete files:
- `playbooks/roles/meta/postgres/defaults/backup.yml`
- `playbooks/roles/meta/postgres/tasks/backup.yml`

**Rationale:** Postgres role is now purely about deploying and running PostgreSQL. Backup is orthogonal — configured from inventory, orchestrated by kopia_agent.

### Step 7: Update documentation

Rewrite `docs/kopia/adding-backup.md` to reflect the new pattern:

```markdown
# Adding Kopia Backup to a Service (updated)

## Quick start (1 file + inventory entry)

### 1. Add source declaration to host_vars

Edit `inventory/host_vars/<host>.yml`:

```yaml
backup_sources:
  myservicename:
    hostname: server
    paths:
      "/srv/docker_data/my-service":
        retention:
          keep_latest: 10
          keep_daily: 7
```

### 2. Add action script template (if needed)

Create `playbooks/roles/infra/kopia_agent/templates/actions/<service>/before-snapshot-root.sh.j2`:

```sh
#!/bin/sh
set -e
# Script runs before each snapshot. Paths and vars available through Ansible precedence.
mkdir -p "/srv/docker_data/my-service/backups"
echo "Pre-backup complete"
```

Then declare the action in inventory (enables convention-based template resolution):

```yaml
backup_sources:
  myservicename:
    # ... paths, retention ...
    actions:
      before-snapshot-root: true   # → templates/actions/myservicename/before-snapshot-root.sh.j2
```

### Folder-level actions (per-path, not inherited)

Add `before-folder` / `after-folder` keys inside the path entry:

```yaml
backup_sources:
  archive-store:
    hostname: server
    paths:
      "/srv/docker_data/archive-store":
        before-folder: true   # → templates/actions/archive-store/before-folder.sh.j2
        after-folder: true    # → templates/actions/archive-store/after-folder.sh.j2
```

Folder actions are registered via `kopia policy set <path>` on each target directory — not inherited from parent.

### 3. Re-run kopia agent role

```bash
ansible-playbook playbooks/servers.yml --tags kopia_server,kopia_agent
```

Meta dependency ensures server runs before agent. The agent role iterates over `backup_sources` and registers everything automatically. No service role changes needed.
```

### Step 8: Verify

1. Run `ansible-playbook playbooks/servers.yml --tags kopia_server,kopia_agent --limit lab1` — should produce identical state to current deployment (same Kopia user, same sources, same timer). Meta dependency ensures proper ordering.
2. Check `systemctl status kopia-backup@postgres.timer` on lab1 — active
3. Run manual snapshot: `ssh lab1 "kopia snapshot create --all --config-file /opt/ansible/kopia/agents/postgres.config"` — succeeds with pg_dump pre-action
4. Verify Postgres role deploys independently: `ansible-playbook playbooks/servers.yml --tags postgres --limit lab1` — no Kopia tasks fire, backup unaffected

---

## Risks and mitigations

| Risk | Likelihood | Mitigation |
|------|-----------|------------|
| Existing snapshots break during migration | Low | Source paths, retention, identity (username@hostname), and timer schedule remain identical. Only orchestration location changes — no state mutation on the target host beyond idempotent re-registration. |
| Template move breaks pg_dump script content | Low | Pure file move — template content unchanged. Ansible vars (`postgres_data_dir`, etc.) resolved through normal precedence regardless of physical location. Verify with `--check` first. |
| Timer schedule changes accidentally | Low | Explicit `schedule: "hourly"` in inventory preserves current behavior. Role default is fallback only. |
| Lab2 (no backups) fails due to missing var | Low | Role defaults provide `backup_sources: {}`. Guard `when: backup_sources | length > 0` skips all tasks for hosts with empty dict — no errors, clean skip. |

---

## Rollback

1. Restore deleted files from git (`postgres/defaults/backup.yml`, `postgres/tasks/backup.yml`)
2. Move template back: `mv kopia_agent/templates/actions/postgres/before-snapshot-root.sh.j2 postgres/templates/postgres_before-snapshot-root.sh.j2`
3. Re-add `- include_tasks: backup.yml` to `postgres/tasks/main.yml`
4. Remove `backup_sources` from `inventory/host_vars/lab1.yml`
5. Revert `kopia_agent/tasks/main.yml`, `register_source.yml`, and `defaults/main.yml` to pre-migration versions

All changes are idempotent — no state mutation that can't be reversed by re-running the old playbooks. The Kopia server repository, snapshots, systemd timers, and agent configs on target hosts remain untouched regardless of which orchestration model is active.

---

## Future extensions (not in scope)

Once this pattern is established, adding backup to other services is trivial:

```yaml
# inventory/host_vars/lab1.yml — example future additions

backup_sources:
  postgres:
    # ... existing config
  vaultwarden:
    hostname: server
    paths:
      "/srv/docker_data/vaultwarden":
        retention:
          keep_daily: 30
          keep_monthly: 12
    schedule: "daily"
  step_ca:
    hostname: server
    paths:
      "{{ step_ca_data_dir }}/certs": {}   # no per-path retention → uses global Kopia policy
    schedule: "weekly"
```

No role changes needed — just inventory entries and optional action templates in `kopia_agent/templates/actions/`. The kopia_agent role handles everything generically.

### Known limitations (acceptable for current scale)

- **One systemd timer per identity** — all paths under one source snapshot together. Matches current behavior and keeps timer management simple.
