# 004: Remove `lab_index` — use inventory_hostname directly

## Motivation

The `lab_index` variable (1 for lab1, 2 for lab2) is manually maintained in two places and only used by the qBittorrent role. If hosts are renamed or added, it requires manual updates everywhere and can drift out of sync with actual hostnames.

Replace all references with `inventory_hostname`, which is always available and self-consistent.

## Affected files

| File | Change |
|------|--------|
| `inventory/hosts.yml` | Remove `lab_index: 1/2` from lab1/lab2 hosts |
| `playbooks/roles/qbittorrent/tasks/main.yml` | CNAME target → `qbit.{{ inventory_hostname }}.{{ lan_domain }}` |
| `playbooks/roles/qbittorrent/tasks/deploy.yml` | Traefik rule → `Host(\`qbit.{{ inventory_hostname }}.{{ lan_domain }}\`)` |

## Implementation steps

### Step 1: Update qBittorrent CNAME target

In `playbooks/roles/qbittorrent/tasks/main.yml`, replace:
```yaml
cname_name: "{{ qbittorrent_cname_name | default('qbit' + (lab_index | string) + '.' + lan_domain) }}"
```
with:
```yaml
cname_name: "{{ qbittorrent_cname_name | default('qbit.' + inventory_hostname + '.' + lan_domain) }}"
```

### Step 2: Update Traefik router rule

In `playbooks/roles/qbittorrent/tasks/deploy.yml`, replace:
```yaml
traefik.http.routers.qbittorrent.rule: "Host(`qbit{{ lab_index }}.{{ lan_domain }}`)"
```
with:
```yaml
traefik.http.routers.qbittorrent.rule: "Host(`qbit.{{ inventory_hostname }}.{{ lan_domain }}`)"
```

### Step 3: Remove lab_index from inventory

In `inventory/hosts.yml`, remove these lines:
```yaml
lab1:
  ansible_host: lab1.lan
  lab_index: 1    # ← delete this line
lab2:
  ansible_host: lab2.lan
  lab_index: 2    # ← delete this line
```

### Step 4: Verify no other references

Run `grep -rn 'lab_index' . --include='*.yml'` to confirm zero remaining references.

## Status: ✅ DONE (2026-05-03)

Implemented as part of plan #001 role refactoring. DNS migrated from `qbit1.lan`/`qbit2.lan` → `qbit.lab1.lan`/`qbit.lab2.lan`.

### Extra changes beyond plan

| Change | Detail |
|---|---|
| `.lan` domain decoupled globally | All hosts use `hostname.{{ lan_domain }}`, no hardcoded domains in inventory |
| Redundant `ansible_host` removed | Group vars no longer override what's already in hostname |
| OpenWrt timezone restored | Lost during earlier refactor, added back to `group_vars/routers.yml` |

### Lessons learned

- `inventory_hostname` is always available — no need for manual index variables
- Hardcoded domains in inventory create drift risk when infrastructure changes
- Domain centralization (`lan_domain` in `all.yml`) makes future multi-domain setups easier

## Rollback

Each change is a simple text substitution — revert the CNAME/rule back to lab_index-based and restore the inventory lines if anything breaks.
