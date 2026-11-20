# Диагностика и инциденты

1. Validate impact: one user/client/ISP/region vs every node; use independent vantage points and user-device measurements.
2. Check desired/observed state, component health, latency, logs by correlation ID, 3X-UI API response, credentials and expiry.
3. Network: route tables, IPv4/v6, DNS leakage, firewall UDP, QUIC handling, cert chain, REALITY settings, port collisions.
4. Telegram gateway: namespace tunnel & API reachability; check failover and off-tunnel leak tests. Admin emergency via SSH/provider console.
5. Mitigations: only safe pre-approved actions; canary changes, rollback, ticket and incident record.
6. Resolution: verify client connection and node reconciliation; log impact, times, cause, prevention.

No automatic compensation or expiry pause (decision 34=A). A manual exceptional extension can be logged separately.
