# aauti-platform-prod-as1-gke

Platform **prod spoke** of the hub observability stack, onboarded like
[aauti-media-prod-as1-gke](../aauti-media-prod-as1-gke/README.md) (regional prod cluster, own tenant) and
[aauti-platform-nonprod-as1-gke](../aauti-platform-nonprod-as1-gke/README.md) (same apps, nonprod).

| | |
|---|---|
| GCP project | `aauti-platform-prod` |
| Location | asia-south1 (**regional**, nodes in a/b/c, same region as the hub), private nodes, control plane limited to the office IP and hub NAT |
| Node pools | `apps` (n2d-standard-4, taint `workload=apps:NoSchedule`, 1–8 per zone), `system` (n2d-standard-2, reserved for GKE components); 6 nodes in total on 2026-10-07 |
| VPC | `aauti-prod-vpc`: nodes 10.12.0.0/24, pods 10.13.0.0/17, services 10.14.0.0/22 (subnet `aauti-prod-vpc-as1-gke-subnet`) |
| Peering | `platform-prod-to-hub` ⇄ `hub-to-platform-prod` (already existed, ACTIVE) |
| Hub | `aauti-hub-as1-obs-gke`, tenant **`platform-prod`**, Grafana https://grafana.aauti.ai (folder **Platform-prod**) |
| Workloads | `aauti-{ai,api,chat,discovery,marketplace,notification,scheduler,studio,whiteboard-api,whiteboard-ui,worker}`, `pgbouncer`, `platform-gateway-prod` (~76 pods incl. system; 14 pods have `prometheus.io/scrape` annotations) |
| Agent namespace / Helm release | `observability-agent-platformprod` (both). Every agent object carries that prefix: `-alloy`, `-kube-state-metrics`, `-config`, `-auth`, `-hub-ca`. |
| Labels on all data | `cluster=aauti-platform-prod-as1-gke`, `tier=prod`, `product=platform`, `environment=prod` (single-environment cluster, so every namespace and the nodes), `namespace`, `pod`, `container`, `node`, `app`, `job` (+ `log_type` on logs). `env` = same value as `environment` |
| Retention | logs and metrics 30d (tenant `platform-prod`) |
| Status | **In the repo, not deployed yet.** No alert rules. |

## Differences from media-prod

- **Limits** are platform-nonprod's (10 MB/s logs, 10k streams, 300k series): more apps than media.
- **App namespaces have no environment suffix** (`aauti-api`, not `aauti-api-prod`), so every namespace
  falls through to `cluster.environment: prod`.
- Otherwise identical: own prod tenant (30d), regional cluster (kube context
  `gke_aauti-platform-prod_asia-south1_aauti-platform-prod-as1-gke`; Alloy's zonal 2Gi PVC pins it to its first zone),
  peering already existed, no node-exporter / Prometheus Operator, agent and kube-state-metrics on `apps`.

## Files

| File | Applies to | What |
|---|---|---|
| [`../../network/aauti-platform-prod.ps1`](../../network/aauti-platform-prod.ps1) | both VPCs | checks the existing peering and gateway IP (recreates the peering if missing; `-WhatIf`) |
| [`../aauti-hub-as1-obs-gke/observability/values.yaml`](../aauti-hub-as1-obs-gke/observability/values.yaml) | hub | tenant `platform-prod` (limits; logs + metrics 30d) |
| [`../aauti-hub-as1-obs-gke/observability/gateway-internal-lb.yaml`](../aauti-hub-as1-obs-gke/observability/gateway-internal-lb.yaml) | hub | node + pod ranges 10.12.0.0/24, 10.13.0.0/17 |
| [`../aauti-hub-as1-obs-gke/grafana/values.yaml`](../aauti-hub-as1-obs-gke/grafana/values.yaml) + `deploy.ps1` | hub | folder Platform-prod |
| [`observability-agent/values.yaml`](observability-agent/values.yaml) | this cluster | agent Helm values |
| [`observability-agent/deploy.ps1`](observability-agent/deploy.ps1) | this cluster | copies credentials and CA from the hub, runs `helm upgrade --install` |
| [`observability-agent/verify.ps1`](observability-agent/verify.ps1) | both (read-only) | checks the private path, TLS, auth, and data in Grafana |

## Rollout (run from the office network / VPN, in this order)

```powershell
cd D:\aauti-observability-agents

# 0. Network check (read-only on the current state).
./network/aauti-platform-prod.ps1 -WhatIf

# 1. Hub: tenant "platform-prod" + LB source ranges. The gateway pod restarts once.
./clusters/aauti-hub-as1-obs-gke/observability/deploy.ps1

# 2. Hub Grafana: Platform-prod dashboards (Grafana pod restarts once).
#    Note: grafana/deploy.ps1 on main also deploys the email alerting + SMTP (see the hub README, Alerts).
./clusters/aauti-hub-as1-obs-gke/grafana/deploy.ps1

# 3. Spoke: agent in the new namespace observability-agent-platformprod.
gcloud container clusters get-credentials aauti-platform-prod-as1-gke --region asia-south1 --project aauti-platform-prod
./clusters/aauti-platform-prod-as1-gke/observability-agent/deploy.ps1

# 4. Verify (read-only), after ~2 minutes.
./clusters/aauti-platform-prod-as1-gke/observability-agent/verify.ps1
```

**Rollback:**
```powershell
helm --kube-context gke_aauti-platform-prod_asia-south1_aauti-platform-prod-as1-gke -n observability-agent-platformprod uninstall observability-agent-platformprod
kubectl --context gke_aauti-platform-prod_asia-south1_aauti-platform-prod-as1-gke delete namespace observability-agent-platformprod
```
Nothing else on the cluster is changed by the install. To remove it from the hub too, delete `platform-prod` from the hub values,
the LB ranges and Grafana, and redeploy observability and Grafana.

## Dashboards (Grafana → folder **Platform-prod**)

The shared templates *Cluster health*, *Resource usage* and *Workloads & logs*, with
**Environment (prod) → Cluster → Namespace** selectors.

Raw queries: *Explore* → `Loki` / `Mimir` (all tenants), e.g. Loki `{product="platform", env="prod"}` or `{cluster="aauti-platform-prod-as1-gke", namespace="aauti-api"}`
or Mimir `kube_deployment_status_replicas_unavailable{cluster="aauti-platform-prod-as1-gke"}`.
