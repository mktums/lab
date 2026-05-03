# 006: Service documentation generator — approach TBD

## To figure out

We want a playbook (`playbooks/docs.yml`) that generates per-service markdown docs under `docs/services/` with:
- Host assignments, FQDNs, ports, volume mounts, Docker images, description

Core challenge: **single source of truth** for both docs and role config. Options on the table:

| Option | Idea | Pros | Cons |
|--------|------|------|------|
| A — Metadata vars per role | `_service_meta` dict in each `defaults/main.yml`, referenced by tasks + docs generator | True single source of truth | Requires updating all 17 roles; `set_stats` in check mode unreliable |
| B — Template parsing | Parse compose templates for volumes/ports, traefik labels for FQDNs, inventory groups for hosts | Zero changes to existing roles; captures actual runtime config | Regex against Jinja2 templates is fragile; dynamic values won't resolve |
| C — Hybrid (recommended) | Structured vars for cross-cutting info + template parsing for compose details | Minimal migration burden; accurate volume/port data | Potential drift between metadata and parsed template |
| D — Callback plugin | Hook into task execution, capture actual runtime state | Perfect accuracy | Requires running playbooks for docs; adds complexity to no-tooling project |

## Decision needed

- [ ] Choose an approach (leaning C)
- [ ] If A or C: define metadata var schema and conventions
- [ ] If B or C: decide what regex patterns to use against templates
- [ ] Implement `playbooks/docs.yml` with sub-plays for hw collection, service docs generation
