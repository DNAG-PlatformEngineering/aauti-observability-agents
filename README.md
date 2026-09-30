# aauti-observability

Real (non-POC) observability setup. One folder per cluster under `clusters/`,
named exactly as in GKE. Everything in a cluster folder is deployed to that
cluster and nowhere else.

Secrets (admin passwords, tokens) live only in the cluster, never in this repo.

## Clusters

| Cluster | Project | Zone | What's deployed |
|---|---|---|---|
| [aauti-hub-as1-obs-gke](clusters/aauti-hub-as1-obs-gke/README.md) | Aauti-hub (`aauti-hub`) | asia-south1-a | Hub: Grafana, MinIO, Loki, Mimir, gateway (+ internal LB for spokes), Alloy, kube-state-metrics |
| [aauti-jitsi-nonprod-gke](clusters/aauti-jitsi-nonprod-gke/README.md) | `aauti-jitsi-noprod` | asia-south1-a | Spoke (tenant `jitsi`): Alloy agent + kube-state-metrics. **Prepared, not deployed yet.** The README also defines the standard for onboarding the other clusters. |

`network/` holds the VPC peering / internal IP scripts, one per spoke.

## Charts

`charts/observability-stack` is a copy of the POC chart (`D:\k6s\observability-stack`)
with its sub-charts vendored. The only change is a `scheduling` value (nodeSelector /
tolerations) for the gateway and the MinIO bucket Job.
