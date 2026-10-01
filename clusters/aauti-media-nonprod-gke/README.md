# aauti-media-nonprod-gke

Second **spoke** of the hub observability stack, onboarded like
[aauti-jitsi-nonprod-gke](../aauti-jitsi-nonprod-gke/README.md) (the reference setup).

| | |
|---|---|
| GCP project | `aauti-media-nonprod` |
| Location | us-central1-a (zonal), private nodes |
| Node pools | `system` (e2-standard-4, untainted, 1–3), `apps` (e2-standard-4, taint `workload=apps:NoSchedule`, 1–10) |
| VPC | `aauti-media-nonprod-vpc`: nodes 10.24.0.0/24, pods 10.25.0.0/17, services 10.26.0.0/22 |
| Peering | `media-nonprod-to-hub` ⇄ `hub-to-media-nonprod` (already existed, ACTIVE) |
| Hub | `aauti-hub-as1-obs-gke`, tenant **`media`**, Grafana https://grafana.aauti.ai (folder **Media-nonprod**) |
| Agent namespace / Helm release | `observability-agent-medianonprod` (both). Resources: StatefulSet `observability-agent-medianonprod-alloy`, Deployment `observability-agent-medianonprod-kube-state-metrics`. ConfigMap `observability-agent-medianonprod-config`, Secrets `observability-agent-medianonprod-auth` and `observability-agent-medianonprod-hub-ca`. |
| Labels on all data | `cluster=aauti-media-nonprod-gke`, `tier=nonprod`, `environment` (namespace suffix, else `dev`), `namespace`, `pod`, `container`, `node`, `app`, `job` (+ `log_type` on logs) |
| Status | Hub + Grafana prepared. **Agent not installed yet.** The cluster has no workloads yet (`media-gateway` is empty). |

## Differences from jitsi-nonprod

- **Region.** The cluster is in us-central1, the hub's internal LB (10.40.16.10) in asia-south1.
  The LB has `networking.gke.io/internal-load-balancer-allow-global-access: "true"` so peered
  VPCs in other regions can reach it. It's still internal-only: no public IP, and the
  source ranges and peering still apply.
- **No network script.** The peering already existed.
- **No node-exporter or Prometheus Operator** on this cluster. Node metrics come from kubelet/cAdvisor only.
- **Node pool.** The agent and kube-state-metrics run on the untainted `system` pool (no toleration needed).
- **Namespace and Helm release** are both `observability-agent-medianonprod` (named after the cluster), not `observability-agent`.

## Files

| File | Applies to | What |
|---|---|---|
| [`../aauti-hub-as1-obs-gke/observability/values.yaml`](../aauti-hub-as1-obs-gke/observability/values.yaml) | hub | adds tenant `media` (limits, 14d logs / 30d metrics) |
| [`../aauti-hub-as1-obs-gke/observability/gateway-internal-lb.yaml`](../aauti-hub-as1-obs-gke/observability/gateway-internal-lb.yaml) | hub | media node + pod ranges, global access |
| [`../aauti-hub-as1-obs-gke/grafana/values.yaml`](../aauti-hub-as1-obs-gke/grafana/values.yaml) + `deploy.ps1` | hub | `Loki – Media` / `Mimir – Media`, folder Media-nonprod |
| [`observability-agent/values.yaml`](observability-agent/values.yaml) | this cluster | agent Helm values |
| [`observability-agent/deploy.ps1`](observability-agent/deploy.ps1) | this cluster | copies credentials and CA from the hub, runs `helm upgrade --install` |
| [`observability-agent/verify.ps1`](observability-agent/verify.ps1) | both (read-only) | checks the private path, TLS, auth, and data in Grafana |

## Rollout (run from the office network / VPN, in this order)

```powershell
cd D:\aauti-observability-agents

# 1. Hub: tenant "media" + LB source ranges / global access. The gateway pod restarts once.
./clusters/aauti-hub-as1-obs-gke/observability/deploy.ps1

# 2. Hub Grafana: Media datasources + dashboards (Grafana pod restarts once).
./clusters/aauti-hub-as1-obs-gke/grafana/deploy.ps1

# 3. Spoke (only when approved): agent in the new namespace observability-agent-medianonprod.
./clusters/aauti-media-nonprod-gke/observability-agent/deploy.ps1

# 4. Verify (read-only), after ~2 minutes.
./clusters/aauti-media-nonprod-gke/observability-agent/verify.ps1
```

**Rollback:**
```powershell
helm --kube-context gke_aauti-media-nonprod_us-central1-a_aauti-media-nonprod-gke -n observability-agent-medianonprod uninstall observability-agent-medianonprod
kubectl --context gke_aauti-media-nonprod_us-central1-a_aauti-media-nonprod-gke delete namespace observability-agent-medianonprod
```
Then remove `media` from the hub values, the LB ranges and Grafana, and redeploy observability and Grafana.

## Dashboards (Grafana → folder **Media-nonprod**)

The shared templates *Cluster health*, *Resource usage* and *Workloads & logs*, with
**Environment → Cluster → Namespace** selectors. Add media-specific dashboards to
`charts/observability-stack/dashboards/tenants/media/` once the media workloads exist.

Raw queries: *Explore* → `Loki – Media` (e.g. `{cluster="aauti-media-nonprod-gke"}`)
or `Mimir – Media` (e.g. `up{cluster="aauti-media-nonprod-gke"}`).
