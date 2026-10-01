# aauti-observability

Real (non-POC) observability setup. One folder per cluster under `clusters/`,
named exactly as in GKE. Everything in a cluster folder is deployed to that
cluster and nowhere else.

Secrets (admin passwords, tokens) live only in the cluster, never in this repo.

## Clusters

| Cluster | Project | Zone | What's deployed |
|---|---|---|---|
| [aauti-hub-as1-obs-gke](clusters/aauti-hub-as1-obs-gke/README.md) | Aauti-hub (`aauti-hub`) | asia-south1-a | Hub: Grafana, MinIO, Loki, Mimir, gateway (+ internal LB for spokes), Alloy, kube-state-metrics |
| [aauti-jitsi-nonprod-gke](clusters/aauti-jitsi-nonprod-gke/README.md) | `aauti-jitsi-noprod` | asia-south1-a | Spoke (tenant `jitsi`): Alloy agent + kube-state-metrics in `observability-agent-jitsinonprod`. **Deployed**, Grafana folder *Jitsi-nonprod*. The README also defines the standard for onboarding the other clusters. |
| [aauti-media-nonprod-as1-gke](clusters/aauti-media-nonprod-as1-gke/README.md) | `aauti-media-nonprod` | asia-south1-a | Spoke (tenant `media`): Alloy agent + kube-state-metrics in `observability-agent-medianonprod`. Hub side and Grafana folder *Media-nonprod* deployed; **agent not installed yet**. |

The same project's `aauti-media-nonprod-gke` (us-central1-a) is not onboarded.

`network/` holds the VPC peering / internal IP scripts, one per spoke that needed a new peering
(media-nonprod was already peered with the hub).

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
