# aauti-observability

Real (non-POC) observability setup. One folder per cluster under `clusters/`,
named exactly as in GKE. Everything in a cluster folder is deployed to that
cluster and nowhere else.

Secrets (admin passwords, tokens) live only in the cluster, never in this repo.

## Clusters

| Cluster | Project | Zone | What's deployed |
|---|---|---|---|
| [aauti-hub-as1-obs-gke](clusters/aauti-hub-as1-obs-gke/README.md) | Aauti-hub (`aauti-hub`) | asia-south1-a | Hub: Grafana, MinIO, Loki, Mimir, gateway (+ internal LB for spokes), Alloy, kube-state-metrics |
| [aauti-jitsi-nonprod-gke](clusters/aauti-jitsi-nonprod-gke/README.md) | `aauti-jitsi-noprod` | asia-south1-a | Spoke (tenant `jitsi-nonprod`): Alloy agent + kube-state-metrics in `observability-agent-jitsinonprod`. **Deployed** 2026-09-30, Grafana folder *Jitsi-nonprod*. The README also defines the standard for onboarding the other clusters. |
| [aauti-media-nonprod-as1-gke](clusters/aauti-media-nonprod-as1-gke/README.md) | `aauti-media-nonprod` | asia-south1-a | Spoke (tenant `media-nonprod`): Alloy agent + kube-state-metrics in `observability-agent-medianonprod`. **Deployed** 2026-10-01, Grafana folder *Media-nonprod*. |
| [aauti-platform-nonprod-as1-gke](clusters/aauti-platform-nonprod-as1-gke/README.md) | `aauti-platform-noprod` | asia-south1-a | Spoke (tenant `platform-nonprod`): Alloy agent + kube-state-metrics in `observability-agent-platformnonprod`. **Deployed** 2026-10-01, Grafana folder *Platform-nonprod*. |
| [aauti-media-prod-as1-gke](clusters/aauti-media-prod-as1-gke/README.md) | `aauti-media-prod` | asia-south1 (regional) | Spoke (tenant `media-prod`): Alloy agent + kube-state-metrics in `observability-agent-mediaprod`. **Deployed** 2026-10-06, Grafana folder *Media-prod*. |
| [aauti-jitsi-prod-gke](clusters/aauti-jitsi-prod-gke/README.md) | `aauti-jitsi-prod` | asia-south1-a | Spoke (tenant `jitsi-prod`): Alloy agent + kube-state-metrics in `observability-agent-jitsiprod`. **Deployed** 2026-10-06, Grafana folder *Jitsi-prod*. |
| [aauti-platform-prod-as1-gke](clusters/aauti-platform-prod-as1-gke/README.md) | `aauti-platform-prod` | asia-south1 (regional) | Spoke (tenant `platform-prod`): Alloy agent + kube-state-metrics in `observability-agent-platformprod`. **Deployed** 2026-10-08, Grafana folder *Platform-prod*. |

All seven clusters are in asia-south1.

`network/` holds the VPC peering / internal IP scripts, one per spoke VPC. They are idempotent and support `-WhatIf`
(media-nonprod's, platform-nonprod's, media-prod's and platform-prod's peerings already existed, so their scripts only check them;
jitsi-nonprod's and jitsi-prod's create them).

Retention policy: dev and sandbox 7 days, qa and demo 10 days, prod 30 days. Tenants are per product and tier:
`<product>-nonprod` (`media-nonprod`, `platform-nonprod`, `jitsi-nonprod`) and `<product>-prod` (`media-prod`, `jitsi-prod`, `platform-prod`), because Mimir
has only one metrics retention per tenant. The hub monitors itself as `aauti-hub`. Per-tenant values: [hub README](clusters/aauti-hub-as1-obs-gke/README.md).

**Explore in Grafana:** one `Loki` and one `Mimir` datasource (the default) read all tenants at once. Filter with labels:

```
product     media | jitsi | platform | aauti-hub
  env       dev | qa | demo | sandbox | shared | prod     (same values as `environment`)
    cluster → namespace → app / pod / container
```
e.g. `{product="media", env="qa"} |= "error"` (Loki), `kube_pod_container_status_restarts_total{product="platform", env="dev"}` (Mimir).
`product` / `env` exist on data sent since 2026-10-06; for older data filter on `cluster` / `environment`. There are no
per-tenant datasources; the folder dashboards use `Loki` / `Mimir`, each folder limited to its tenant's clusters.

The same as fixed fields: dashboard **Explore** (folder *Explore*, [source](clusters/aauti-hub-as1-obs-gke/grafana/dashboards/explore.json)):
Product → Env → Cluster → Namespace → App → Pod → Container (+ a search regex), each listing only values under the ones
before it; panels: log volume, log levels, logs, CPU / memory by pod, restarts, pods not ready, Kubernetes warning events.

**Alerts:** Grafana-managed rules as code in [`grafana/alerting/`](clusters/aauti-hub-as1-obs-gke/grafana/alerting/),
one file per cluster, sent by email (Outlook SMTP). Only Media-nonprod has rules so far. They were **deployed 2026-10-08 without recipients**, so nothing is sent yet;
set them with `grafana/deploy.ps1 -AlertEmails ...`. Setup and recipients: [hub README → Alerts](clusters/aauti-hub-as1-obs-gke/README.md#alerts).

## Charts

`charts/observability-stack` is a copy of the POC chart (`D:\k6s\observability-stack`)
with its sub-charts vendored. Changes, all opt-in (defaults render as before):
- `scheduling`: nodeSelector / tolerations for the gateway and the MinIO bucket Job.
- `agent.tls.serverName`: TLS SNI when `hubUrl` is the internal LB IP.
- `agent.metrics.prometheusOperator`: scrape existing ServiceMonitors / PodMonitors.
- `agent.logs.environmentFromLine`: environment taken from the log line (Jitsi room names).
- `agent.configMapName`, `agent.auth.secretName`, `agent.tls.caSecretName`: names of the agent's
  ConfigMap and Secrets, so every agent object can carry the cluster name.
- Dashboards: an `environment` variable, and a *Jitsi Meet* dashboard (`dashboards/tenants/jitsi-nonprod/`).
- `cluster.product`: `product` label on all data; `agent.envLabel`: `env` alias of the final `environment`.
- `gateway.reader`: a read-only gateway user pinned to all tenants (Loki / Mimir tenant federation) for Grafana's
  single `Loki` / `Mimir` datasources; push returns 403 for it.
