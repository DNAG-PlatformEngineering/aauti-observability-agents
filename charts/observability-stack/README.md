# observability-stack

A Helm chart that deploys a centralized, multi-tenant Grafana observability
stack on the **hub** cluster and a lightweight collection agent on every
**spoke** cluster (Media, Application, Jitsi, …).

```
 spoke: media ──┐        HTTPS + basic auth (tenant = user)        ┌──────────── hub ────────────┐
  Alloy agent   │                                                  │  observability-gateway     │
 spoke: app  ───┼──────▶ /api/v1/push  /loki/api/v1/push ─────────▶│  (NGINX, TLS, htpasswd,    │
  Alloy agent   │                                                  │   sets X-Scope-OrgID)      │
 spoke: jitsi ──┘                                                  │     │              │        │
  Alloy agent                                                      │   Mimir          Loki       │
                                                                   │  (multi-tenant, per-tenant │
                                                                   │   limits + retention)      │
                                                                   │     └── GCS / MinIO ──┘     │
                                                                   │  Grafana: "Mimir – Media", │
                                                                   │  "Loki – Media", … per     │
                                                                   │  tenant, dashboards, alerts│
                                                                   │  k6 CronJobs ─▶ Mimir      │
                                                                   └────────────────────────────┘
```

| Requirement | Where it lives |
|---|---|
| Hub stack + spoke agents, one chart | `mode: hub` / `mode: spoke` (`profiles/`) |
| `cluster` + `environment` labels on all data | `cluster.*` → Alloy `external_labels` |
| Loki logs, per-tenant and per-log-type retention | `tenants.<id>.logs.retention`, `.streamRetention` |
| Mimir metrics, per-tenant retention | `tenants.<id>.metrics.retention` |
| Multi-tenancy (X-Scope-OrgID) | Loki `auth_enabled`, Mimir (always multi-tenant), agent `tenant_id` / header |
| Per-tenant limits (runtime overrides) | `tenants.<id>.logs.limits`, `.metrics.limits` → `observability-{loki,mimir}-overrides` ConfigMaps |
| Auth gateway, tenants isolated | `templates/hub/gateway*.yaml` |
| One Grafana datasource per tenant | `templates/hub/grafana-datasources.yaml` |
| Object storage (GCS; MinIO locally) | `loki.loki.storage`, `mimir.mimir.structuredConfig.common.storage` |
| Per-tenant usage monitoring + alerts | `tenant-usage` dashboard, `templates/hub/grafana-alerts.yaml` |
| TLS spoke → hub | gateway TLS (generated CA, cert-manager or your Secret) |
| Grafana users / RBAC | `grafanaAccess.users`; `grafanaAccess.isolation: orgs` gives each tenant its own Grafana organisation |
| Alert routing | `alerting.webhook.url` or `alerting.contactPoints` / `policies` |
| Dashboards as code | `dashboards/src/generate.py` → `dashboards/*.json` |
| k6 load tests → Mimir → Grafana | `k6.tests`, `files/k6/*.js`, `k6-load-testing` dashboard |

## Quick start (local, Docker Desktop)

Requirements: Docker Desktop Kubernetes (or kind/minikube), `helm` ≥ 3.14,
`kubectl`, ~4 GB free memory.

```powershell
cd observability-stack
./scripts/local-up.ps1               # hub + spokes media, application, jitsi
kubectl --context docker-desktop -n observability port-forward svc/grafana 3000:80
# http://localhost:3000  (admin password is printed by the script)
./scripts/verify-tenancy.ps1         # proves tenant isolation at the gateway
kubectl --context docker-desktop -n observability create job --from=cronjob/k6-application-http k6-now
./scripts/local-down.ps1 -Purge      # remove everything
bash scripts/ci-check.sh             # static checks (also run in CI)
```

Connect a real cluster later with `scripts/onboard-spoke.ps1` (see docs/tenant-onboarding.md).

Locally every spoke is a namespace (`spoke-media`, `spoke-application`,
`spoke-jitsi`) in the same cluster, with its own agent, credentials and tenant,
talking to the hub over the same TLS gateway a remote cluster would use.

## Layout

```
Chart.yaml / values.yaml         chart + every option, documented
profiles/hub.yaml | spoke.yaml   which components each mode runs
environments/local/*.yaml        local hub + 3 spokes
environments/prod-example/*.yaml GKE + GCS + Workload Identity templates
templates/hub/                   gateway, TLS, secrets, overrides, Grafana provisioning, k6
templates/agent/                 Alloy pipeline (both modes)
dashboards/                      dashboard JSON (generated from dashboards/src)
files/                           k6 scripts, Grafana access bootstrap
scripts/                         local up / down / verify
docs/                            deployment, multi-tenancy, auth, onboarding
```

## Documentation

* [docs/deployment.md](docs/deployment.md) – local and production deployment, upgrades
* [docs/multi-tenancy.md](docs/multi-tenancy.md) – tenants, limits, retention, storage, usage alerts
* [docs/authentication.md](docs/authentication.md) – gateway auth, TLS, Grafana users/SSO/RBAC
* [docs/tenant-onboarding.md](docs/tenant-onboarding.md) – adding a new spoke / tenant
* [docs/load-testing.md](docs/load-testing.md) – k6 tests and results
