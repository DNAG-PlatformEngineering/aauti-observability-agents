# aauti-platform-nonprod-as1-gke

Third **spoke** of the hub observability stack, onboarded like
[aauti-media-nonprod-as1-gke](../aauti-media-nonprod-as1-gke/README.md) (same pattern as the
reference setup [aauti-jitsi-nonprod-gke](../aauti-jitsi-nonprod-gke/README.md)).

| | |
|---|---|
| GCP project | `aauti-platform-noprod` |
| Location | asia-south1-a (zonal, same region as the hub), private nodes, control plane limited to the office IP and hub NAT |
| Node pools | `apps` (n2d-standard-4, taint `workload=apps:NoSchedule`, 1–6, currently 4), `system` (n2d-standard-2, reserved for GKE components) |
| VPC | `aauti-nonprod-vpc`: nodes 10.4.0.0/24, pods 10.5.0.0/17, services 10.6.0.0/22 |
| Peering | `platform-nonprod-to-hub` ⇄ `hub-to-platform-nonprod` (already existed, ACTIVE) |
| Hub | `aauti-hub-as1-obs-gke`, tenant **`platform-app`** (`platform` is the hub's own monitoring), Grafana https://grafana.aauti.ai (folder **Platform-nonprod**) |
| Workloads | `aauti-{ai,api,chat,discovery,marketplace,notification,scheduler,studio,whiteboard-api,whiteboard-ui,worker}-{dev,qa,demo,sandbox}` (~65 pods), `platform-gateway` (empty) |
| Data services | Cloud SQL PostgreSQL 17 `aauti-nonprod-pg-devsbx-as1` (dev, sandbox) and `aauti-nonprod-pg-qademo-as1` (qa, demo); not monitored by this agent |
| Agent namespace / Helm release | `observability-agent-platformnonprod` (both). Every agent object carries that prefix: `-alloy`, `-kube-state-metrics`, `-config`, `-auth`, `-hub-ca`. |
| Labels on all data | `cluster=aauti-platform-nonprod-as1-gke`, `tier=nonprod`, `environment` (namespace suffix dev/qa/demo/sandbox, else `shared`), `namespace`, `pod`, `container`, `node`, `app`, `job` (+ `log_type` on logs) |
| Retention | logs: dev, sandbox, shared 7d; qa, demo 10d. Metrics: 10d (one retention per tenant in Mimir) |
| Status | **Deployed** 2026-10-01 (hub, Grafana and agent). Grafana folder **Platform-nonprod**. |

The other cluster in this project, `aauti-nonprod-gke` (us-central1, also runs ArgoCD), is out of scope.

## Differences from media-nonprod-as1

- **Tenant name** `platform-app` instead of the product name, because `platform` already exists on the hub.
- **Limits** are higher (10 MB/s logs, 10k streams, 300k series): more apps and namespaces than media.
- Otherwise identical: same region, peering already existed, no node-exporter / Prometheus Operator,
  agent on the `apps` pool (toleration `workload=apps`; ~120m CPU / 340Mi requested).

## Files

| File | Applies to | What |
|---|---|---|
| [`../../network/aauti-platform-nonprod.ps1`](../../network/aauti-platform-nonprod.ps1) | both VPCs | checks the existing peering and gateway IP (recreates the peering if missing; `-WhatIf`) |
| [`../aauti-hub-as1-obs-gke/observability/values.yaml`](../aauti-hub-as1-obs-gke/observability/values.yaml) | hub | tenant `platform-app` (limits, retention) |
| [`../aauti-hub-as1-obs-gke/observability/gateway-internal-lb.yaml`](../aauti-hub-as1-obs-gke/observability/gateway-internal-lb.yaml) | hub | node + pod ranges 10.4.0.0/24, 10.5.0.0/17 |
| [`../aauti-hub-as1-obs-gke/grafana/values.yaml`](../aauti-hub-as1-obs-gke/grafana/values.yaml) + `deploy.ps1` | hub | `Loki – Platform-app` / `Mimir – Platform-app`, folder Platform-nonprod |
| [`observability-agent/values.yaml`](observability-agent/values.yaml) | this cluster | agent Helm values |
| [`observability-agent/deploy.ps1`](observability-agent/deploy.ps1) | this cluster | copies credentials and CA from the hub, runs `helm upgrade --install` |
| [`observability-agent/verify.ps1`](observability-agent/verify.ps1) | both (read-only) | checks the private path, TLS, auth, and data in Grafana |

## Rollout (run from the office network / VPN, in this order)

```powershell
cd D:\aauti-observability-agents

# 0. Network check (changes nothing on the current state).
./network/aauti-platform-nonprod.ps1 -WhatIf

# 1. Hub: tenant "platform-app" + LB source ranges.
./clusters/aauti-hub-as1-obs-gke/observability/deploy.ps1

# 2. Hub Grafana: Platform-app datasources + dashboards (Grafana pod restarts once).
./clusters/aauti-hub-as1-obs-gke/grafana/deploy.ps1

# 3. Spoke: agent in the new namespace observability-agent-platformnonprod.
./clusters/aauti-platform-nonprod-as1-gke/observability-agent/deploy.ps1

# 4. Verify (read-only), after ~2 minutes.
./clusters/aauti-platform-nonprod-as1-gke/observability-agent/verify.ps1
```

**Rollback:**
```powershell
helm --kube-context gke_aauti-platform-noprod_asia-south1-a_aauti-platform-nonprod-as1-gke -n observability-agent-platformnonprod uninstall observability-agent-platformnonprod
kubectl --context gke_aauti-platform-noprod_asia-south1-a_aauti-platform-nonprod-as1-gke delete namespace observability-agent-platformnonprod
```
Nothing else on the cluster is changed by the install. To remove it from the hub too, delete `platform-app` from the hub values,
the LB ranges and Grafana, and redeploy observability and Grafana.

## Dashboards (Grafana → folder **Platform-nonprod**)

The shared templates *Cluster health*, *Resource usage* and *Workloads & logs*, with
**Environment (dev, qa, demo, sandbox, shared) → Cluster → Namespace** selectors.

Raw queries: *Explore* → `Loki – Platform-app` (e.g. `{cluster="aauti-platform-nonprod-as1-gke", namespace="aauti-api-qa"}`)
or `Mimir – Platform-app` (e.g. `kube_deployment_status_replicas_unavailable{cluster="aauti-platform-nonprod-as1-gke"}`).
