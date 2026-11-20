# Резервное копирование и восстановление

Scope: VPN Control PostgreSQL, 3X-UI panel/node state, secret store encrypted exports and keys, configs, release/migration manifests, DNS/certificate metadata. Exclude ephemeral logs when legally/operationally justified.
Daily encrypted offsite snapshot; ~30-day version window initially, plus before destructive operations; checksum; independent encryption key escrow; provider/snapshot lock where feasible. A backup isn't accepted until isolated restore drill succeeds.

Restore workflow: authenticate principal admin and step-up; choose recovery point and dependencies; freeze writes where possible; validate backup integrity; restore into isolated staging; run migrations only if compatible; smoke test expiry, node sync and credential decryption; approve production recovery; record audit and reconciliation. Never disclose master encryption keys in Telegram messages.

Document measurable RPO/RTO only after testing, and maintain break-glass recovery via provider console when Telegram is unavailable.
