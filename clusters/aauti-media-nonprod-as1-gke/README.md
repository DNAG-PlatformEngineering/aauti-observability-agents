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
| Hub | `aauti-hub-as1-obs-gke`, tenant **`media-nonprod`** (was `media` until 2026-10-06), Grafana https://grafana.aauti.ai (folder **Media-nonprod**) |
| Workloads | `aauti-media-{api,dashboard,delivery,upload}-{dev,qa,demo,sandbox}`, `aauti-media-events`, `media-gateway` |
| Agent namespace / Helm release | `observability-agent-medianonprod` (both). Every agent object carries that prefix: `-alloy`, `-kube-state-metrics`, `-config`, `-auth`, `-hub-ca`. |
| Labels on all data | `cluster=aauti-media-nonprod-as1-gke`, `tier=nonprod`, `product=media`, `environment` (namespace suffix dev/qa/demo/sandbox, else `shared`), `namespace`, `pod`, `container`, `node`, `app`, `job` (+ `log_type` on logs). `env` = same value as `environment` (since 2026-10-06) |
| Status | **Deployed** 2026-10-01 (hub, Grafana and agent; all `verify.ps1` checks pass). Grafana folder **Media-nonprod**. Alert rules ([media-nonprod.yaml](../aauti-hub-as1-obs-gke/grafana/alerting/media-nonprod.yaml)) deployed 2026-10-08, but no recipients are set yet, so nothing is sent. |

## Differences from jitsi-nonprod

- **Network.** The peering already existed, so [`../../network/aauti-media-nonprod.ps1`](../../network/aauti-media-nonprod.ps1) only checks it
  (it would recreate it if missing). Only the LB source ranges were added.
- **No node-exporter or Prometheus Operator** on this cluster, and no app pod has scrape annotations yet (only GKE's own `kube-system` pods do).
  Node metrics come from kubelet/cAdvisor only; annotated pods are picked up automatically later.
- **GKE 1.36** (control plane `v1.36.4`; the other clusters are on 1.35). Its kube-dns (component version 36.x) has no
  `sidecar` container, so nothing serves the annotated metrics port 10054. Since 2026-10-09 the agent scrapes it on
  9153 (`coredns_*` metrics) instead; before that both kube-dns targets were `up=0`. The other clusters switch to 9153
  by themselves when GKE upgrades them to 1.36.
- **Node pool.** The agent and kube-state-metrics run on `apps` (toleration `workload=apps`), because `system` is reserved for GKE.
  Together they request ~120m CPU / 340Mi memory.

## Files

| File | Applies to | What |
|---|---|---|
| [`../aauti-hub-as1-obs-gke/observability/values.yaml`](../aauti-hub-as1-obs-gke/observability/values.yaml) | hub | tenant `media-nonprod` (limits; logs dev/sandbox/shared 7d, qa/demo 10d; metrics 10d) |
| [`../aauti-hub-as1-obs-gke/observability/gateway-internal-lb.yaml`](../aauti-hub-as1-obs-gke/observability/gateway-internal-lb.yaml) | hub | node + pod ranges 10.32.0.0/24, 10.33.0.0/17 |
| [`../aauti-hub-as1-obs-gke/grafana/values.yaml`](../aauti-hub-as1-obs-gke/grafana/values.yaml) + `deploy.ps1` | hub | folder Media-nonprod |
| [`observability-agent/values.yaml`](observability-agent/values.yaml) | this cluster | agent Helm values |
| [`observability-agent/deploy.ps1`](observability-agent/deploy.ps1) | this cluster | copies credentials and CA from the hub, runs `helm upgrade --install` |
| [`observability-agent/verify.ps1`](observability-agent/verify.ps1) | both (read-only) | checks the private path, TLS, auth, and data in Grafana |

## Rollout (run from the office network / VPN, in this order)

```powershell
cd D:\aauti-observability-agents

# Kube contexts for the hub and this cluster (kubectl needs gke-gcloud-auth-plugin:
#    gcloud components install gke-gcloud-auth-plugin). deploy.ps1 / verify.ps1 check both.
gcloud container clusters get-credentials aauti-hub-as1-obs-gke --zone asia-south1-a --project aauti-hub
gcloud container clusters get-credentials aauti-media-nonprod-as1-gke --zone asia-south1-a --project aauti-media-nonprod

# 1. Hub: tenant "media-nonprod" + LB source ranges. The gateway pod restarts once.
./clusters/aauti-hub-as1-obs-gke/observability/deploy.ps1

# 2. Hub Grafana: Media dashboards (Grafana pod restarts once).
./clusters/aauti-hub-as1-obs-gke/grafana/deploy.ps1

# 3. Spoke: agent in the new namespace observability-agent-medianonprod.
./clusters/aauti-media-nonprod-as1-gke/observability-agent/deploy.ps1

# 4. Verify (read-only), ~10-12 minutes after step 3 (first-start "timestamp too old" 400s must leave the window).
./clusters/aauti-media-nonprod-as1-gke/observability-agent/verify.ps1
```

**Rollback:**
```powershell
helm --kube-context gke_aauti-media-nonprod_asia-south1-a_aauti-media-nonprod-as1-gke -n observability-agent-medianonprod uninstall observability-agent-medianonprod
kubectl --context gke_aauti-media-nonprod_asia-south1-a_aauti-media-nonprod-as1-gke delete namespace observability-agent-medianonprod
```
Nothing else on the cluster is changed by the install. To remove media from the hub too, delete `media-nonprod` from the hub values,
the LB ranges and Grafana, and redeploy observability and Grafana.

## Dashboards (Grafana → folder **Media-nonprod**)

The shared templates *Cluster health*, *Resource usage* and *Workloads & logs*, with
**Environment (dev, qa, demo, sandbox, shared) → Cluster → Namespace** selectors. Add media-specific dashboards to
`charts/observability-stack/dashboards/tenants/media-nonprod/` once the apps expose metrics.

The *Nodes* row of *Resource usage* stays empty: it needs node-exporter, which this cluster does not run.

Everything is also in the **Explore** dashboard (folder *Explore*; Product / Env / Cluster / Namespace / App selectors).

Raw queries: *Explore* → `Loki` / `Mimir` (all tenants), e.g. Loki `{product="media", cluster="aauti-media-nonprod-as1-gke"}` or `{cluster="aauti-media-nonprod-as1-gke", environment="qa"}`
or Mimir `kube_pod_container_status_restarts_total{cluster="aauti-media-nonprod-as1-gke"}`.
