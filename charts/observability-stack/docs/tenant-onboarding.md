# Onboarding a new spoke / tenant

> **In this repo** follow *Standard for the next clusters* in
> `clusters/aauti-jitsi-nonprod-gke/README.md` instead: it uses the per-cluster `deploy.ps1` /
> `verify.ps1`, the internal LB `gateway-internal-lb.yaml`, and adds a dashboard folder to the
> standalone Grafana. There are no per-tenant datasources: the hub upgrade adds the new tenant to
> `grafana-reader`, so the shared `Loki` / `Mimir` datasources read it automatically. Two steps are easy to
> miss: add the tenant to `$dashboards` in `clusters/aauti-hub-as1-obs-gke/grafana/deploy.ps1`, and add the
> spoke's node + pod ranges to `loadBalancerSourceRanges` in `gateway-internal-lb.yaml` (plus a
> `network/aauti-<product>-<tier>.ps1`). `scripts/onboard-spoke.ps1` and `environments/` are POC-only.

Example: a new **Payments** cluster. Tenant id `payments`, cluster name
`payments-prod`.

## 1. Add the tenant on the hub

In the hub environment file (e.g. `environments/prod/hub.yaml`):

```yaml
tenants:
  payments:
    title: Payments
    dashboards: [cluster-health, resource-usage, workloads-logs]
    logs:
      retention: 336h
      streamRetention:
        - { selector: '{log_type="audit"}', priority: 1, period: 2160h }   # keep audit logs 90d
      limits:
        ingestion_rate_mb: 8
        ingestion_burst_size_mb: 16
        max_global_streams_per_user: 5000
        max_query_series: 1000
    metrics:
      retention: 720h
      limits:
        ingestion_rate: 30000
        ingestion_burst_size: 300000
        max_global_series_per_user: 150000
        max_fetched_series_per_query: 50000

grafanaAccess:
  users:
    - { login: payments-viewer, email: payments-team@example.com, orgRole: Viewer, teams: [payments] }
```

Sizing tips: start with about 2× the spoke's current samples/s and series
(`count({__name__=~".+"})` on the spoke's Prometheus) and adjust using the
**Tenant usage** dashboard.

```bash
helm upgrade --install observability . -n observability \
  -f profiles/hub.yaml -f environments/prod/hub.yaml
```

That single upgrade gives you:

| Created | Name |
|---|---|
| gateway user + password | key `payments` in `observability-tenant-credentials` |
| Loki / Mimir limits + retention | `observability-{loki,mimir}-overrides` (hot-reloaded) |
| Grafana datasources | `Loki – Payments`, `Mimir – Payments` |
| Grafana team, folder, dashboards | team `payments`, folder *Payments* |
| usage alerts | covered automatically (rules are per tenant) |

Optional: tenant-specific dashboards go in
`dashboards/tenants/payments/*.json` (use `__METRICS_DS__` / `__LOGS_DS__` as
datasource UIDs) and are picked up on the next upgrade.

> Steps 2–3 are automated by `scripts/onboard-spoke.ps1`:
> `./scripts/onboard-spoke.ps1 -HubContext <hub> -SpokeContext <spoke> -Tenant payments -ValuesFile environments/prod/spoke-payments.yaml -Yes`

## 2. Hand the credentials to the spoke

```bash
kubectl -n observability get secret observability-tenant-credentials \
  -o jsonpath='{.data.payments}' | base64 -d > payments.password
kubectl -n observability get secret observability-hub-ca \
  -o jsonpath='{.data.ca\.crt}' | base64 -d > hub-ca.crt
```

Store the password in your secret manager. Don't commit it.

## 3. Install the agent on the spoke cluster

Create `environments/prod/spoke-payments.yaml` (copy
`environments/prod-example/spoke-media.yaml`):

```yaml
cluster:
  name: payments-prod
  environment: prod
agent:
  tenant: payments
  hubUrl: https://observability.example.internal
  auth: { existingSecret: true }
```

The Secret name below is the default (`agent.auth.secretName`); the clusters in this repo use
`<release>-auth` with release `observability-agent-<product><tier>`, e.g. `observability-agent-jitsinonprod-auth`
(see `clusters/*/observability-agent/`).

```bash
kubectl --context payments-prod create namespace observability-agent
kubectl --context payments-prod -n observability-agent create secret generic \
  observability-agent-auth --from-file=password=payments.password
helm --kube-context payments-prod upgrade --install observability-agent . \
  -n observability-agent -f profiles/spoke.yaml -f environments/prod/spoke-payments.yaml \
  --set-file agent.tls.caCert=hub-ca.crt
```

Network: the spoke's egress/NAT range must be allowed in
`gateway.service.loadBalancerSourceRanges` (or on the ingress/firewall).

## 4. Verify

```bash
# agent healthy and sending (look for "remote_write" / "loki.write" errors)
kubectl --context payments-prod -n observability-agent logs statefulset/observability-agent-alloy | grep -iE "error|401|403|429" | tail
```

In Grafana, open **Payments / Cluster health** (datasource `Mimir – Payments`)
and check that the `cluster` variable shows `payments-prod`. **Platform /
Tenant usage** should now list `payments`.

| Symptom (agent log / gateway status) | Cause |
|---|---|
| 401 | wrong password / Secret not updated |
| 403 | `agent.tenant` does not match the password's tenant |
| x509 errors | wrong `agent.tls.caCert` or hub host not in the certificate SANs (`gateway.tls.extraDnsNames`) |
| 429 | tenant limits too low, raise them in `tenants.payments.*.limits` |

## Removing a tenant

Delete it from `tenants` and upgrade. Its gateway user, datasources, team
and folder are removed, and the agent starts getting 401. Existing data stays
in the bucket until you delete `<bucket>/payments/`. Retention no longer
applies once the override is gone, so the global default takes over.
