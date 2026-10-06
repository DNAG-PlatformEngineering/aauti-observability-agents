# aauti-media-nonprod-as1-gke

Second **spoke** of the hub observability stack, onboarded like
[aauti-jitsi-nonprod-gke](../aauti-jitsi-nonprod-gke/README.md) (the reference setup).

| | |
|---|---|
| GCP project | `aauti-media-nonprod` |
| Location | asia-south1-a (zonal, same region as the hub), private nodes, control plane limited to the office IP and hub NAT |
| Node pools | `apps` (n2d-standard-4, taint `workload=apps:NoSchedule`, 1–15, currently 10), `system` (n2d-standard-2, reserved for GKE components) |
| VPC | `aauti-media-nonprod-vpc`: nodes 10.32.0.0/24, pods 10.33.0.0/17, services 10.34.0.0/22 |
| Peering | `media-nonprod-to-hub` ⇄ `hub-to-media-nonprod` (already existed, ACTIVE) |
| Hub | `aauti-hub-as1-obs-gke`, tenant **`media`**, Grafana https://grafana.aauti.ai (folder **Media-nonprod**) |
| Workloads | `aauti-media-{api,dashboard,delivery,upload}-{dev,qa,demo,sandbox}`, `aauti-media-events`, `media-gateway` |
| Agent namespace / Helm release | `observability-agent-medianonprod` (both). Every agent object carries that prefix: `-alloy`, `-kube-state-metrics`, `-config`, `-auth`, `-hub-ca`. |
| Labels on all data | `cluster=aauti-media-nonprod-as1-gke`, `tier=nonprod`, `environment` (namespace suffix dev/qa/demo/sandbox, else `shared`), `namespace`, `pod`, `container`, `node`, `app`, `job` (+ `log_type` on logs) |
| Status | **Deployed** 2026-10-01 (hub, Grafana and agent; all `verify.ps1` checks pass). Grafana folder **Media-nonprod**. |

## Differences from jitsi-nonprod

- **Network.** The peering already existed, so [`../../network/aauti-media-nonprod.ps1`](../../network/aauti-media-nonprod.ps1) only checks it
  (it would recreate it if missing). Only the LB source ranges were added.
- **No node-exporter or Prometheus Operator** on this cluster, and no app pod has scrape annotations yet.
  Node metrics come from kubelet/cAdvisor only; annotated pods are picked up automatically later.
- **Node pool.** The agent and kube-state-metrics run on `apps` (toleration `workload=apps`), because `system` is reserved for GKE.
  Together they request ~120m CPU / 340Mi memory.

## Files

| File | Applies to | What |
|---|---|---|
| [`../aauti-hub-as1-obs-gke/observability/values.yaml`](../aauti-hub-as1-obs-gke/observability/values.yaml) | hub | tenant `media` (limits; logs dev/sandbox/shared 7d, qa/demo 10d; metrics 10d) |
| [`../aauti-hub-as1-obs-gke/observability/gateway-internal-lb.yaml`](../aauti-hub-as1-obs-gke/observability/gateway-internal-lb.yaml) | hub | node + pod ranges 10.32.0.0/24, 10.33.0.0/17 |
| [`../aauti-hub-as1-obs-gke/grafana/values.yaml`](../aauti-hub-as1-obs-gke/grafana/values.yaml) + `deploy.ps1` | hub | `Loki – Media` / `Mimir – Media`, folder Media-nonprod |
| [`observability-agent/values.yaml`](observability-agent/values.yaml) | this cluster | agent Helm values |
| [`observability-agent/deploy.ps1`](observability-agent/deploy.ps1) | this cluster | copies credentials and CA from the hub, runs `helm upgrade --install` |
| [`observability-agent/verify.ps1`](observability-agent/verify.ps1) | both (read-only) | checks the private path, TLS, auth, and data in Grafana |

## Rollout (run from the office network / VPN, in this order)

```powershell
cd D:\aauti-observability-agents

# 1. Hub: tenant "media" + LB source ranges. The gateway pod restarts once.
./clusters/aauti-hub-as1-obs-gke/observability/deploy.ps1

# 2. Hub Grafana: Media datasources + dashboards (Grafana pod restarts once).
./clusters/aauti-hub-as1-obs-gke/grafana/deploy.ps1

# 3. Spoke: agent in the new namespace observability-agent-medianonprod.
./clusters/aauti-media-nonprod-as1-gke/observability-agent/deploy.ps1

# 4. Verify (read-only), after ~2 minutes.
./clusters/aauti-media-nonprod-as1-gke/observability-agent/verify.ps1
```

**Rollback:**
```powershell
helm --kube-context gke_aauti-media-nonprod_asia-south1-a_aauti-media-nonprod-as1-gke -n observability-agent-medianonprod uninstall observability-agent-medianonprod
kubectl --context gke_aauti-media-nonprod_asia-south1-a_aauti-media-nonprod-as1-gke delete namespace observability-agent-medianonprod
```
Nothing else on the cluster is changed by the install. To remove media from the hub too, delete `media` from the hub values,
the LB ranges and Grafana, and redeploy observability and Grafana.

## Dashboards (Grafana → folder **Media-nonprod**)

The shared templates *Cluster health*, *Resource usage* and *Workloads & logs*, with
**Environment (dev, qa, demo, sandbox, shared) → Cluster → Namespace** selectors. Add media-specific dashboards to
`charts/observability-stack/dashboards/tenants/media/` once the apps expose metrics.

Raw queries: *Explore* → `Loki – Media` (e.g. `{cluster="aauti-media-nonprod-as1-gke", environment="qa"}`)
or `Mimir – Media` (e.g. `kube_pod_container_status_restarts_total{cluster="aauti-media-nonprod-as1-gke"}`).
