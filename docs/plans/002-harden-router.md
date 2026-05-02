# 002: Harden router SSH configuration

## Motivation

The router is currently **not hardened** by Ansible — it accepts password auth and allows root login. This is intentional for convenience during initial setup (set a password in the OpenWrt UI, run everything without installing keys). But the router is still a Linux machine exposed to the LAN that should be secured.

## Trade-off considered

- **Servers** get full SSH hardening via `geerlingguy.security` role — keys are provisioned during OS install (e.g., `gh:mktums` import)
- **Router** skips key provisioning for convenience: one-time password set in OpenWrt UI, then automated everything
- This gap is acceptable temporarily but should be closed before the router sees untrusted networks

## Plan

1. Research proper OpenWrt approach:
   - SSH config is managed via uci (`system`, `firewall`), not `/etc/ssh/sshd_config`
   - Need to identify correct UCI sections and keys (likely `system.@system[0].hostname`, `luci-*` packages, etc.)
   - Key provisioning: OpenWrt uses `/etc/dropbear/authorized_keys` (DropBear SSH server), not `/root/.ssh/`
2. Add SSH hardening to `openwrt_base` role (or a new `openwrt_ssh` role)
3. Manage the router's authorized keys via Ansible
4. Update README/manual setup to document SSH key provisioning for the router

## Rollback

Each task is idempotent and reversible. The main risk is locking yourself out if key provisioning fails — mitigated by keeping password auth as a fallback during transition.
