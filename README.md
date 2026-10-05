# aauti-observability

Real (non-POC) observability setup. One folder per cluster under `clusters/`,
named exactly as in GKE. Everything in a cluster folder is deployed to that
cluster and nowhere else.

Secrets (admin passwords, tokens) live only in the cluster, never in this repo.

## Clusters

| Cluster | Project | Zone | What's deployed |
|---|---|---|---|
| [aauti-hub-as1-obs-gke](clusters/aauti-hub-as1-obs-gke/README.md) | Aauti-hub (`aauti-hub`) | asia-south1-a | Hub: Grafana, MinIO, Loki, Mimir, gateway (+ internal LB for spokes), Alloy, kube-state-metrics |
| [aauti-jitsi-nonprod-gke](clusters/aauti-jitsi-nonprod-gke/README.md) | `aauti-jitsi-noprod` | asia-south1-a | Spoke (tenant `jitsi`): Alloy agent + kube-state-metrics in `observability-agent-jitsinonprod`. **Deployed** 2026-09-30, Grafana folder *Jitsi-nonprod*. The README also defines the standard for onboarding the other clusters. |
| [aauti-media-nonprod-as1-gke](clusters/aauti-media-nonprod-as1-gke/README.md) | `aauti-media-nonprod` | asia-south1-a | Spoke (tenant `media`): Alloy agent + kube-state-metrics in `observability-agent-medianonprod`. **Deployed** 2026-10-01, Grafana folder *Media-nonprod*. |
| [aauti-platform-nonprod-as1-gke](clusters/aauti-platform-nonprod-as1-gke/README.md) | `aauti-platform-noprod` | asia-south1-a | Spoke (tenant `platform-app`): Alloy agent + kube-state-metrics in `observability-agent-platformnonprod`. **Deployed** 2026-10-01, Grafana folder *Platform-nonprod*. |

Not onboarded: `aauti-media-nonprod-gke` and `aauti-nonprod-gke` (both us-central1-a, in the same projects as the as1 clusters).

`network/` holds the VPC peering / internal IP scripts, one per spoke VPC. They are idempotent and support `-WhatIf`
(media-nonprod's and platform-nonprod's peerings already existed, so their scripts only check them).

## Charts

`charts/observability-stack` is a copy of the POC chart (`D:\k6s\observability-stack`)
with its sub-charts vendored. Changes, all opt-in (defaults render as before):
- `scheduling`: nodeSelector / tolerations for the gateway and the MinIO bucket Job.
- `agent.tls.serverName`: TLS SNI when `hubUrl` is the internal LB IP.
- `agent.metrics.prometheusOperator`: scrape existing ServiceMonitors / PodMonitors.
- `agent.logs.environmentFromLine`: environment taken from the log line (Jitsi room names).
- `agent.configMapName`, `agent.auth.secretName`, `agent.tls.caSecretName`: names of the agent's
  ConfigMap and Secrets, so every agent object can carry the cluster name.
- Dashboards: an `environment` variable, and a *Jitsi Meet* dashboard (`dashboards/tenants/jitsi/`).
