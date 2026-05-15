# 005b: Kopia agents (lab services, personal devices)

## Motivation

Deploy backup agents for all lab services and personal devices connecting to the central Kopia repository server. See [005a](./005a-kopia-server.md) for server deployment.

### Scope

| Component | Deployment method |
|-----------|-------------------|
| Lab services | Per-service systemd timer + native Kopia binary (apt) per host |
| Personal PC | Windows/Linux agent (Ansible + WinRM/SSH) |
| MacBook | macOS agent (automated via Ansible) |
| Android devices | Kopia app with repo connection instructions |

## Affected files

| File | Change |
|------|--------|
| `playbooks/roles/kopia_agent/` | New — agent deployment role |
| `inventory/group_vars/servers.yml` | Agent vars (repo URL, schedule defaults) |
| `inventory/hosts.yml` | Add `kopia_hosts` group |
| Each service role (`defaults/main.yml`) | Add backup paths and retention policy declarations |
| Each service role (`tasks/main.yml`) | Include `backup.yml` -> `register_source.yml` |
| `docs/kopia/android-setup.md` | New — Android device instructions |

## Architecture (PROBABLE — draft phase)

**Status:** Probable solution, subject to change during implementation. Key assumptions: per-service systemd timers with native processes, host-side pre-action scripts deployed via Ansible templates, env-file passing for service-specific variables.

### Per-service systemd timer + native process

Each service backs up under its own Kopia identity (e.g. `stepca@server`, `traefik@server`) for clean snapshot tree separation and seamless migration between hosts. The backup is triggered by a per-service systemd timer that fires a native process running `/usr/bin/kopia snapshot create`.

**Key components:**

| Component | Location | Managed by |
|-----------|----------|------------|
| Kopia binary | `/usr/bin/kopia` (apt package) | kopia_agent role (host-level, deployed once) |
| Per-service config | `{{ ansible_opt_base }}/kopia/agents/<identity>.config` | Each service role via `register_source.yml` |
| Systemd timer template | `kopia-backup@.timer.j2` | kopia_agent role (deployed once) |
| Timer instance | `kopia-backup@stepca.timer` | Each service role (enabled on first deploy) |

### How it works

1. The systemd timer fires according to its schedule (e.g. hourly, staggered per service)
2. The timer triggers a one-shot service: `/usr/bin/kopia snapshot create --config {{ ansible_opt_base }}/kopia/agents/<identity>.config`
3. Kopia reads config, connects to server as `<identity>`, snapshots declared paths with native filesystem access
4. Process exits, systemd marks unit as inactive (dead)

### Concurrent execution

Multiple service timers may fire in the same time window. Each triggers an independent OS process — they run in parallel with no coordination. This is safe because:

- Processes are isolated (separate config files, separate cache dirs via `KOPIA_CACHE_DIR`, separate identities)
- Kopia server handles concurrent clients natively (per-source `sourceManager` goroutines, repository-level locking at blob layer)
- Source reads are independent (`/srv/docker_data/postgres` and `/srv/docker_data/traefik` don't conflict)

If I/O burst on the backup server is a concern, timer schedules can be staggered per service (different `OnCalendar` values so they spread across the hour).

### Secret management in actions

Kopia logs action commands, so passwords must never be passed as environment variables. Use credential files instead:

- **PostgreSQL**: `.pgpass` file (mode 0600) at `{{ ansible_opt_base }}/kopia/agents/<svc>.pgpass`, mounted into dump container via `-v`
- **MySQL**: `--defaults-file=/path/to/.my.cnf` with credentials in host-mounted file
- **API tokens** (Vaultwarden): `.env` file is acceptable for non-password tokens, loaded via systemd `EnvironmentFile=`

Ansible deploys these files via `template:` module with `mode: '0600'`, sourced from vault secrets.

### Pre-action scripts on host

Pre-action scripts are deployed to the host (not persisted in Kopia repo) via Ansible `template:` module. This avoids script sync issues — changes are unconditionally overwritten on each playbook run, and the script path registered with Kopia policy remains constant.

### Full chain examples

#### Scenario 1: Simple service (no action needed) — step-ca

**Service role `defaults/main.yml`:**
```yaml
kopia_backup_paths:
  - "{{ docker_data_base }}/step-ca"
kopia_retention_policy:
  keep_latest: 7
  keep_daily: 30
  keep_weekly: 4
```

**Service role `tasks/main.yml` (after deploy):**
```yaml
- name: Register Kopia backup source
  ansible.builtin.include_role:
    name: kopia_agent
    tasks_from: register_source
  vars:
    kopia_service_name: stepca
    kopia_override_username: "{{ kopia_service_name }}"
    kopia_override_hostname: server
```

**Backup execution chain:**
1. Timer `kopia-backup@stepca.timer` fires at `*:0/60`
2. Service runs: `/usr/bin/kopia snapshot create --config {{ ansible_opt_base }}/kopia/agents/stepca@server.config`
3. Kopia reads config, connects to server as `stepca@server`, snapshots `/srv/docker_data/step-ca`
4. Process exits, systemd marks unit as inactive

#### Scenario 2: Database with container invocation — PostgreSQL

**Service role `defaults/main.yml`:**
```yaml
kopia_backup_paths:
  - "{{ docker_data_base }}/postgres"
kopia_retention_policy:
  keep_latest: 7
  keep_daily: 14
  keep_weekly: 4
kopia_pre_action_env:
  PG_IMAGE: "postgres:{{ postgres_image_version | default('16') }}"
  PG_USER: "{{ vault_postgres_user }}"
  PG_DB: "{{ postgres_database }}"
kopia_secrets_file: ".pgpass"  # Ansible deploys to {{ ansible_opt_base }}/kopia/agents/postgres.pgpass (mode 0600)
```

**`.pgpass` file deployed by Ansible (template, mode 0600):**
```
127.0.0.1:5432:{{ postgres_database }}:{{ vault_postgres_user }}:{{ vault_postgres_password }}
```

**Backup execution chain:**
1. Timer `kopia-backup@postgres.timer` fires at `*:0/60`
2. Service runs: `/usr/bin/kopia snapshot create --config {{ ansible_opt_base }}/kopia/agents/postgres@server.config` (loads env from `EnvironmentFile=` in systemd unit)
3. Kopia finds before action for `/srv/docker_data/postgres`, executes (script on host):
   ```sh
   mkdir -p /tmp/kopia-dumps/postgres && chmod 700 /tmp/kopia-dumps/postgres
   docker run --rm --network host \
     -v {{ ansible_opt_base }}/kopia/agents/postgres.pgpass:/root/.pgpass:ro \
     "$PG_IMAGE" pg_dump -h 127.0.0.1 -U "$PG_USER" "$PG_DB" > /tmp/kopia-dumps/postgres/pg-dump-$$.sql
   echo KOPIA_SNAPSHOT_PATH=/tmp/kopia-dumps/postgres
   ```
4. Kopia snapshots `/tmp/kopia-dumps/postgres` (the dump file) under `postgres@server:/srv/docker_data/postgres`
5. After action runs: `rm -rf /tmp/kopia-dumps/postgres/pg-dump-$$.sql`
6. Process exits, systemd marks unit as inactive

#### Scenario 3: Script-based backup — Vaultwarden (curl + sops)

**Service role `defaults/main.yml`:**
```yaml
kopia_backup_paths:
  - "{{ docker_data_base }}/vaultwarden"
kopia_retention_policy:
  keep_latest: 7
  keep_daily: 30
  keep_weekly: 4
kopia_pre_action_env:
  VW_URL: "http://localhost:8229/api/v1"
  VW_ADMIN_TOKEN: "{{ vault_vaultwarden_admin_token }}"
```

**Backup execution chain:**
1. Timer `kopia-backup@vaultwarden.timer` fires at `*:0/60`
2. Service runs: `/usr/bin/kopia snapshot create --config {{ ansible_opt_base }}/kopia/agents/vaultwarden@server.config` (loads env from `EnvironmentFile=` in systemd unit)
3. Kopia finds before action, executes (curl dumps API data into source dir):
   ```sh
   curl -sH "Authorization: ${VW_ADMIN_TOKEN}" "${VW_URL}/admin/export?format=csv" > "$KOPIA_SOURCE_PATH/vaultwarden-export.csv"
   ```
4. Kopia snapshots `/srv/docker_data/vaultwarden` (data dir + export CSV)
5. Process exits, systemd marks unit as inactive

### Shared infrastructure (deployed once by kopia_agent host-level role)

**Systemd timer template `kopia-backup@.timer`:**
```ini
[Unit]
Description=Kopia backup for %I

[Timer]
OnCalendar=*:0/60
RandomizedDelaySec=300
Persistent=true

[Install]
WantedBy=timers.target
```

**Systemd service template `kopia-backup@.service`:**
```ini
[Unit]
Description=Kopia backup for %I
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
EnvironmentFile=-{{ ansible_opt_base }}/kopia/agents/%I.env
Environment=KOPIA_CACHE_DIR={{ ansible_opt_base }}/kopia/cache/%I
ExecStartPre=/usr/bin/nc -z -w 3 {{ kopia_server_host }} 51514
ExecStart=/usr/bin/kopia snapshot create --config {{ ansible_opt_base }}/kopia/agents/%I@server.config

[Install]
WantedBy=multi-user.target
```

### Repository verification (scheduled on server only)

**Important:** `kopia repository verify` must run on the Kopia server host under admin credentials, not from client configs. Client tokens have limited ACL scope (own snapshots only) and cannot perform full repository integrity checks.

Deployed as part of kopia_server role:

| Timer | Schedule | Command |
|-------|----------|---------|
| `kopia-verify.timer` | daily (RandomizedDelaySec=7200) | `docker compose exec kopia-server kopia snapshot verify --verify-files-percent=5 --file-parallelism=4 --parallel=4` |
| `kopia-verify-full.timer` | monthly (RandomizedDelaySec=43200) | same with `--verify-files-percent=100` |

### First deploy flow (register_source.yml)

Idempotent task file included by each service role:

1. **Provision user on Kopia server** via `delegate_to` — password passed via `args.stdin` in Ansible shell module (never as CLI arg or echo), skip if exists (`failed_when: false`)
2. **Check if config exists** — `stat` on agent config path, register result
3. **Connect agent with override identity** — only runs when `not kopia_config_stat.stat.exists`, passes password via Ansible `args.stdin` (never as CLI arg or echo) to avoid leaking into `ps aux` and Ansible logs, writes config file with `--enable-actions` flag
4. **Set retention policy** — always runs, marked `changed_when: false` (Kopia returns exit code 0 regardless of whether values changed)
5. **Deploy .env file** — template rendered if `kopia_pre_action_env` is defined and non-empty
6. **Deploy pre-action script to host** — writes script file via `template:` (mode 0755) if `kopia_pre_action_path` is defined; unconditionally overwrites to sync changes
7. **Register before/after actions in Kopia policy** — points to host script path, always runs, marked `changed_when: false` (Kopia returns exit code 0 regardless of whether path changed)
8. **Enable systemd timer instance** — `systemd: name=kopia-backup@{{ kopia_service_name }}, enabled=yes`

## Implementation steps

### Step 1: Create kopia_agent role (host-level setup)

- Install Kopia binary via apt package (`apt: name=kopia state=present`) or official repo
- Deploy systemd timer template (`kopia-backup@.timer.j2`) and service unit (`kopia-backup@.service.j2`)
- Create agent config directory (`{{ ansible_opt_base }}/kopia/agents/`)

### Step 2: Create register_source.yml task file

Each service role includes this via `include_role: name:kopia_agent tasks_from:register_source`. The task file handles idempotently as described in "First deploy flow" above.

### Step 3: Integrate into service roles

Each service declares in `defaults/main.yml`:
- `kopia_backup_paths` — list of directories to snapshot
- `kopia_retention_policy` — retention tiers (keep_latest, keep_daily, etc.)
- Optional: `kopia_pre_action_env` — env vars for pre-action scripts
- Optional: `kopia_pre_action_path` — path to host-side pre-action script template (deployed via Ansible `template:`)

Each service `tasks/main.yml` includes after deployment:
```yaml
- name: Register Kopia backup source
  ansible.builtin.include_role:
    name: kopia_agent
    tasks_from: register_source
  vars:
    kopia_service_name: <service>
    kopia_override_username: "{{ kopia_service_name }}"
    kopia_override_hostname: server
```

### Step 4: Configure non-homelab agents

#### Windows (Personal PC)
- Deploy via Ansible over WinRM under administrative account
- **Recommended: Windows Task Scheduler** running under real user account — avoids SYSTEM permission issues on profile directories, allows access to network drives and user environment variables. Check "Run with highest privileges" flag for VSS support on locked files.
- **Alternative (not recommended)**: Service as `NT AUTHORITY\SYSTEM` — requires explicit read permissions on user profile directories (`C:\Users\mktum\Documents`, etc.), complicates network drive access
- **Blocked files**: Browser caches, game saves remain locked. VSS available via Task Scheduler with highest privileges flag.

#### macOS (MacBook)
- Deploy via Ansible over SSH using custom LaunchAgent (`~/Library/LaunchAgents/com.kopia.backup.plist`) — runs in user's graphical session context, not as daemon
- **TCC (Transparency, Consent, and Control)**: Kopia binary requires **Full Disk Access** permission to read `Desktop`, `Documents`, `Downloads`. Cannot be automated via Ansible — manual step required in System Settings → Privacy & Security. Document this explicitly.
- **Binary path**: Must use absolute path in `ProgramArguments` (launchd has no user `$PATH`). Homebrew installs to `/opt/homebrew/bin/kopia` (Apple Silicon) or `/usr/local/bin/kopia` (Intel). Detect architecture at deploy time and template accordingly.
- Schedule via LaunchAgent `StartInterval` or cron-like `RunAtLoad` + periodic trigger

#### Android devices
- Kopia official app connects to repository server over network
- **Availability**: Server is behind local homelab subnet — unreachable outside home. Requires split-tunnel VPN (Tailscale or WireGuard) for remote access.
- Configure app to sync only when: VPN tunnel active AND/OR connected to known WiFi SSID

### Step 5: Document restore procedures

#### Standard recovery
- Per-host file-level restore via `kopia snapshot restore` with service identity filter
- **Scenario 2 (PostgreSQL) specific**: Restore requires logical dump `.sql` file from snapshot, not raw live directory. Procedure: (1) recover snapshot tree to identify dump file, (2) deploy clean PostgreSQL container, (3) pipe `.sql` into `psql`, (4) start service. Restoring raw `{{ docker_data_base }}/postgres` files is emergency-only fallback when logical dumps are unavailable.

#### Emergency recovery (host completely dead)
- **Cold cache problem**: Kopia depends on local metadata cache. Full index download from remote server can be slow.
- Use `kopia snapshot restore --no-cache` to bypass local cache for emergency restores
- Keep pre-compiled Kopia binary on bootable USB/LiveCD media for disaster scenarios
- Each service identity (`postgres@server`, `vaultwarden@server`) must be specified explicitly during restore — admin token cannot transparently browse all subtrees without explicit source filter

## Rollback

Disable systemd timer instances, remove agent config files. Server-side user accounts can be cleaned up via `kopia server user delete`. Existing snapshots remain in the repository until retention expires them.
