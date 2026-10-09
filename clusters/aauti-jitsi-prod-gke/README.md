# aauti-jitsi-prod-gke

**Prod spoke** for Jitsi (video.aauti.com), onboarded like
[aauti-jitsi-nonprod-gke](../aauti-jitsi-nonprod-gke/README.md) (same Jitsi layout, monitoring stack and agent setup).

| | |
|---|---|
| GCP project | `aauti-jitsi-prod` |
| Location | asia-south1-a (zonal, same region as the hub), private nodes, control plane limited to the office IP |
| Node pools | `jvb` (c2d-standard-16), `jibri` (n2-standard-8), `signalling` (n2-standard-8), `monitoring` (e2-standard-4, taint `workload=monitoring`), `system` (e2-standard-4) |
| VPC | `aauti-jitsi-prod-vpc`: nodes 10.20.0.0/24, pods 10.21.0.0/17, services 10.22.0.0/22 |
| Peering | `jitsi-prod-to-hub` ⇄ `hub-to-jitsi-prod` (**created by this repo**, [`../../network/aauti-jitsi-prod.ps1`](../../network/aauti-jitsi-prod.ps1)) |
| Hub | `aauti-hub-as1-obs-gke`, tenant **`jitsi-prod`**, Grafana https://grafana.aauti.ai (folder **Jitsi-prod**) |
| Workloads | namespace `jitsi`: web, prosody, jicofo, jvb (2), jibri (2), excalidraw; kube-prometheus-stack in `monitoring` |
| Agent namespace / Helm release | `observability-agent-jitsiprod` (both). Every agent object carries that prefix: `-alloy`, `-kube-state-metrics`, `-config`, `-auth`, `-hub-ca`. |
| Labels on all data | `cluster=aauti-jitsi-prod-gke`, `tier=prod`, `product=jitsi`, `environment=prod` / `env=prod` (everything), `namespace`, `pod`, `container`, `node`, `app`, `job` (+ `log_type` on logs) |
| Retention | logs and metrics 30d (tenant `jitsi-prod`) |
| Status | **Deployed** 2026-10-06 (network, hub, Grafana and agent; all `verify.ps1` checks pass). No alert rules yet. |

## Differences from jitsi-nonprod

- **Own tenant `jitsi-prod`** (prod 30d; nonprod is `jitsi-nonprod`). In Grafana, filter the
  shared `Loki` / `Mimir` datasources with `product="jitsi", env="prod"`.
- **No per-line environment.** Prod rooms carry no environment in their name (e.g. `class_<name>-<id>-1@muc.video.aauti.com`),
  so everything is `prod` and `agent.logs.environmentFromLine` is off.
- **Network.** There was no peering at all; `network/aauti-jitsi-prod.ps1` creates `hub-to-jitsi-prod` and
  `jitsi-prod-to-hub` (the gateway IP 10.40.16.10 already exists). Ranges were checked against the hub and every VPC
  peered with it. The LB source ranges get 10.20.0.0/24 and 10.21.0.0/17.
- Same as nonprod: re-uses the existing node-exporter, scrapes Prosody / Jicofo through their ServiceMonitor / PodMonitor and
  JVB through its annotations, agent and kube-state-metrics on the `monitoring` pool (~120m CPU / 340Mi requested).

## Files

| File | Applies to | What |
|---|---|---|
| [`../../network/aauti-jitsi-prod.ps1`](../../network/aauti-jitsi-prod.ps1) | both VPCs | creates both peerings (idempotent, supports `-WhatIf`) |
| [`../aauti-hub-as1-obs-gke/observability/values.yaml`](../aauti-hub-as1-obs-gke/observability/values.yaml) | hub | tenant `jitsi-prod` (limits; logs + metrics 30d) |
| [`../aauti-hub-as1-obs-gke/observability/gateway-internal-lb.yaml`](../aauti-hub-as1-obs-gke/observability/gateway-internal-lb.yaml) | hub | node + pod ranges 10.20.0.0/24, 10.21.0.0/17 |
| [`../aauti-hub-as1-obs-gke/grafana/values.yaml`](../aauti-hub-as1-obs-gke/grafana/values.yaml) + `deploy.ps1` | hub | folder Jitsi-prod (the Jitsi dashboards, `extras = "jitsi-nonprod"`) |
| [`observability-agent/values.yaml`](observability-agent/values.yaml) | this cluster | agent Helm values |
| [`observability-agent/deploy.ps1`](observability-agent/deploy.ps1) | this cluster | copies credentials and CA from the hub, runs `helm upgrade --install` |
| [`observability-agent/verify.ps1`](observability-agent/verify.ps1) | both (read-only) | checks the private path, TLS, auth, and data in Grafana |

## Rollout (run from the office network / VPN, in this order)

```powershell
cd D:\aauti-observability-agents

# Kube contexts for the hub and this cluster (kubectl needs gke-gcloud-auth-plugin:
#    gcloud components install gke-gcloud-auth-plugin). deploy.ps1 / verify.ps1 check both.
gcloud container clusters get-credentials aauti-hub-as1-obs-gke --zone asia-south1-a --project aauti-hub
gcloud container clusters get-credentials aauti-jitsi-prod-gke --zone asia-south1-a --project aauti-jitsi-prod

# 1. Network: both peerings. Dry run first.
./network/aauti-jitsi-prod.ps1 -WhatIf
./network/aauti-jitsi-prod.ps1

# 2. Hub: tenant "jitsi-prod" + LB source ranges. The gateway pod restarts once.
./clusters/aauti-hub-as1-obs-gke/observability/deploy.ps1

# 3. Hub Grafana: folder Jitsi-prod (Grafana pod restarts once).
./clusters/aauti-hub-as1-obs-gke/grafana/deploy.ps1

# 4. Spoke: agent in the new namespace observability-agent-jitsiprod.
./clusters/aauti-jitsi-prod-gke/observability-agent/deploy.ps1

# 5. Verify (read-only), ~10 minutes after step 4 (first-start "timestamp too old" 400s must leave the window).
./clusters/aauti-jitsi-prod-gke/observability-agent/verify.ps1
```

**Rollback** (in reverse order):
```powershell
helm --kube-context gke_aauti-jitsi-prod_asia-south1-a_aauti-jitsi-prod-gke -n observability-agent-jitsiprod uninstall observability-agent-jitsiprod
kubectl --context gke_aauti-jitsi-prod_asia-south1-a_aauti-jitsi-prod-gke delete namespace observability-agent-jitsiprod
gcloud compute networks peerings delete jitsi-prod-to-hub --network aauti-jitsi-prod-vpc --project aauti-jitsi-prod
gcloud compute networks peerings delete hub-to-jitsi-prod --network aauti-hub-vpc --project aauti-hub
```
Then remove `jitsi-prod` from the hub values, the LB ranges and Grafana, and redeploy observability and Grafana.

## Dashboards (Grafana → folder **Jitsi-prod**)

The same four as Jitsi-nonprod (*Cluster health*, *Resource usage*, *Workloads & logs*, *Jitsi Meet*), with the Cluster
selector limited to tenant `jitsi-prod`. Everything is also in the **Explore** dashboard (Product `jitsi`, Env `prod`).

Raw queries: *Explore* → `Loki` / `Mimir`, e.g. Loki `{product="jitsi", env="prod", namespace="jitsi"}`
or Mimir `jitsi_participants{cluster="aauti-jitsi-prod-gke"}`.
