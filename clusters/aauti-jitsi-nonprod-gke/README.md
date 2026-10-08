# aauti-jitsi-nonprod-gke

First **spoke** of the hub observability stack. It's the reference setup: the other
clusters are onboarded the same way (see [Standard](#standard-for-the-next-clusters)).

| | |
|---|---|
| GCP project | `aauti-jitsi-noprod` |
| Location | asia-south1-a (zonal) |
| VPC | `aauti-jitsi-nonprod-vpc`: nodes 10.16.0.0/24, pods 10.17.0.0/17, services 10.18.0.0/22 |
| Hub | `aauti-hub-as1-obs-gke`, tenant **`jitsi-nonprod`** (was `jitsi` until 2026-10-06), Grafana https://grafana.aauti.ai (folder **Jitsi-nonprod**) |
| Labels on all data | `cluster=aauti-jitsi-nonprod-gke`, `tier=nonprod`, `product=jitsi`, `environment`, `namespace`, `pod`, `container`, `node`, `app`, `job` (+ `log_type` on logs). **environment:** one Jitsi (`devvideo.aauti.com`) serves **dev, qa, demo and sandbox**, chosen per meeting by the room name (`<title>-<id>-aauti-<env>`, recordings `…-recording-<env>`). Infrastructure (pods, nodes, JVB load, all metrics) = `shared`. Log lines naming a room (web, prosody, jicofo, jvb, jibri `[finalize][<env>]`) = that meeting's env. `env` = same value as `environment` (since 2026-10-06) |
| Status | **Deployed** 2026-09-30. Grafana folder **Jitsi-nonprod**. No alert rules yet. |
| Agent namespace / Helm release | `observability-agent-jitsinonprod` (both). Every agent object carries that prefix: `-alloy`, `-kube-state-metrics`, `-config`, `-auth`, `-hub-ca`. Renamed from `observability-agent` on 2026-10-01. |

## What gets deployed

```
aauti-jitsi-nonprod-gke                                      aauti-hub-as1-obs-gke
 ns observability-agent-jitsinonprod (new)                     ns observability
 ┌───────────────────────────────┐   VPC peering (private)   ┌──────────────────────────────────┐
 │ Alloy (StatefulSet, 1 replica,│   HTTPS 443, TLS 1.2/1.3  │ observability-gateway-internal   │
 │  monitoring node pool)        │──────────────────────────▶│  internal LB 10.40.16.10         │
 │  • pod logs, all namespaces   │   user "jitsi-nonprod"    │  (ingest subnet, source-ranged)  │
 │  • k8s events                 │   CA-pinned, SNI          │        │                         │
 │  • kubelet / cAdvisor         │   observability-gateway.  │  NGINX gateway ── Loki  (logs)   │
 │  • kube-state-metrics (own)   │   observability.svc       │   X-Scope-OrgID ─ Mimir (metrics)│
 │  • node-exporter (existing)   │                           │                                  │
 │  • JVB (pod annotations)      │                           │ ns grafana: Grafana              │
 │  • Prosody, Jicofo (existing  │                           │  "Loki" / "Mimir" (all tenants)  │
 │    ServiceMonitor/PodMonitor) │                           │  folder Jitsi-nonprod: 4 dashbds │
 └───────────────────────────────┘                           └──────────────────────────────────┘
```

The existing kube-prometheus-stack (namespace `monitoring`), its local Grafana and the
Jitsi release are **not modified**. The agent only *reads*:
- the node-exporter pods
- the `jitsi-*` ServiceMonitor/PodMonitor objects, to find Prosody and Jicofo targets

## Security

| Requirement | How |
|---|---|
| Private only | The agent's only destination is `https://10.40.16.10` (RFC 1918). That IP belongs to an **internal** passthrough LB in the hub VPC, reachable only over the peering `jitsi-nonprod-to-hub` ⇄ `hub-to-jitsi-nonprod`. There's no public IP, public DNS or internet path. The LB's firewall rule (created by GKE) only allows the peered spokes' node and pod ranges listed in `gateway-internal-lb.yaml` (this cluster: `10.16.0.0/24`, `10.17.0.0/17`). |
| TLS | Gateway listens only on TLS (8443 → LB 443, TLSv1.2/1.3). The agent verifies the certificate against the hub's private CA (`ca_file`) with `server_name = observability-gateway.observability.svc`. `insecure_skip_verify` is off. |
| Authentication | Basic auth per tenant (`jitsi-nonprod`, bcrypt htpasswd on the gateway). The gateway derives `X-Scope-OrgID` from the user and returns 403 on a mismatch, so this cluster can only write or read tenant `jitsi-nonprod`. The password lives only in Secrets: hub `observability-tenant-credentials`, spoke `observability-agent-jitsinonprod-auth`. |
| Least privilege | Agent RBAC is read-only (get/list/watch; pods/log; nodes/metrics). The agent's credential can only write tenant `jitsi-nonprod`. Grafana reads through the federated read-only user `grafana-reader` (all tenants, pushes get 403). |

## Files

| File | Applies to | What |
|---|---|---|
| [`../../network/aauti-jitsi-nonprod.ps1`](../../network/aauti-jitsi-nonprod.ps1) | both VPCs | reserves 10.40.16.10, creates both peerings (idempotent, supports `-WhatIf`) |
| [`../aauti-hub-as1-obs-gke/observability/values.yaml`](../aauti-hub-as1-obs-gke/observability/values.yaml) | hub | adds tenant `jitsi-nonprod` (limits; retention 7d logs + metrics, all environments) |
| [`../aauti-hub-as1-obs-gke/observability/gateway-internal-lb.yaml`](../aauti-hub-as1-obs-gke/observability/gateway-internal-lb.yaml) | hub | new internal LB Service (existing ClusterIP Service untouched) |
| [`../aauti-hub-as1-obs-gke/grafana/values.yaml`](../aauti-hub-as1-obs-gke/grafana/values.yaml) + `deploy.ps1` | hub | Jitsi dashboard folder |
| [`observability-agent/values.yaml`](observability-agent/values.yaml) | this cluster | agent Helm values |
| [`observability-agent/deploy.ps1`](observability-agent/deploy.ps1) | this cluster | copies credentials and CA from the hub, runs `helm upgrade --install` |
| [`observability-agent/verify.ps1`](observability-agent/verify.ps1) | both (read-only) | checks the private path, TLS, auth, and data in Grafana |
| `charts/observability-stack` | — | two opt-in chart options: `agent.tls.serverName` and `agent.metrics.prometheusOperator` (both off by default, so the hub render is unchanged). The dashboards get an `environment` variable, and there's a new *Jitsi Meet* dashboard (`dashboards/tenants/jitsi-nonprod/`). |

## Rollout (run from the office network / VPN, in this order)

```powershell
cd D:\aauti-observability-agents

# 1. Network: static internal IP + VPC peering (both projects). Dry run first.
./network/aauti-jitsi-nonprod.ps1 -WhatIf
./network/aauti-jitsi-nonprod.ps1

# 2. Hub: tenant "jitsi-nonprod" + internal LB. The gateway pod restarts once (config change).
./clusters/aauti-hub-as1-obs-gke/observability/deploy.ps1

# 3. Hub Grafana: Jitsi dashboards (Grafana pod restarts once).
./clusters/aauti-hub-as1-obs-gke/grafana/deploy.ps1

# 4. Spoke: agent in the new namespace observability-agent-jitsinonprod.
./clusters/aauti-jitsi-nonprod-gke/observability-agent/deploy.ps1

# 5. Verify (read-only), ~10-12 minutes after step 4 (first-start "timestamp too old" 400s must leave the window).
./clusters/aauti-jitsi-nonprod-gke/observability-agent/verify.ps1
```

**Rollback** (in reverse order):
```powershell
helm --kube-context gke_aauti-jitsi-noprod_asia-south1-a_aauti-jitsi-nonprod-gke -n observability-agent-jitsinonprod uninstall observability-agent-jitsinonprod
kubectl --context gke_aauti-jitsi-noprod_asia-south1-a_aauti-jitsi-nonprod-gke delete namespace observability-agent-jitsinonprod
gcloud compute networks peerings delete jitsi-nonprod-to-hub --network aauti-jitsi-nonprod-vpc --project aauti-jitsi-noprod
gcloud compute networks peerings delete hub-to-jitsi-nonprod --network aauti-hub-vpc --project aauti-hub
```
Then remove `jitsi-nonprod` from the hub values, its two ranges from `gateway-internal-lb.yaml` and Grafana, and
redeploy observability and Grafana. Don't delete the internal LB `observability-gateway-internal`: every spoke sends through it.

## Dashboards (Grafana → folder **Jitsi-nonprod**)

Every dashboard has **Environment → Cluster → Namespace** selectors. Namespace-level panels and
logs follow the Environment selector. Node-level panels are per cluster, because nodes are shared
by all environments of a cluster.

- **Jitsi-nonprod / Cluster health**: nodes, pods, restarts, degraded deployments, warning events
- **Jitsi-nonprod / Resource usage**: CPU, memory and network by namespace, pod and node; PVC usage
- **Jitsi-nonprod / Workloads & logs**: log volume, errors by app, log search across all namespaces
- **Jitsi-nonprod / Jitsi Meet**:
  - JVB: conferences, participants, stress, bitrate, loss, RTT, ICE
  - Jicofo: bridges, Jibri availability, recordings
  - Prosody: sessions, token auth
  - `jitsi` namespace logs

Raw queries: *Explore* → `Loki` / `Mimir` (all tenants), e.g. Loki `{product="jitsi", cluster="aauti-jitsi-nonprod-gke"}` or `{cluster="aauti-jitsi-nonprod-gke", namespace="jitsi"}`
or Mimir `jitsi_participants{tier="nonprod"}`.

## Standard for the next clusters

For each new cluster:

0. **Labels.** Every cluster sets `cluster.name`, `cluster.tier` (`prod` / `nonprod`), `cluster.product`
   (`media`, `jitsi`, `platform`, …; the `product` filter of the single `Loki` / `Mimir` datasources) and
   `cluster.environment`, and enables `agent.environmentFromNamespace` and `agent.envLabel` (`env` = `environment`).
   - Namespaces ending in `-dev`, `-qa`, `-demo`, `-sandbox`, `-uat` or `-staging` get that environment. For example, `aauti-api-qa` becomes `environment=qa` on platform-nonprod.
   - Every other namespace, and the node metrics, get `cluster.environment`. Use the single environment for one-env clusters (media-prod-as1: `prod`; `-prod` is not a namespace suffix, so it falls through to this), and `shared` for multi-env clusters (jitsi-nonprod; media-nonprod-as1: `aauti-media-events`, `media-gateway`; platform-nonprod: `argocd`, `platform-gateway`).
1. **Tenant.** Use one per product and tier: `<product>-nonprod` (`jitsi-nonprod`, `media-nonprod`, `platform-nonprod`, …) and `<product>-prod` (e.g. `media-prod`), not one per cluster. Prod is separate because it's kept 30d (dev/sandbox 7d, qa/demo 10d) and Mimir has only one metrics retention per tenant. Clusters within a tenant are separated by `environment` and `cluster` labels. Add the tenant to the hub `observability/values.yaml`, plus a dashboard provider in `grafana/values.yaml` and an entry in `$dashboards` in `deploy.ps1` (no datasources: `Loki` / `Mimir` read every tenant).
2. **Network.**
   - Hub side: copy `network/aauti-jitsi-nonprod.ps1` and change the spoke project, VPC and peering names. Media and platform VPCs are already peered with the hub; for those, the script only checks the peering (see `network/aauti-media-nonprod.ps1`).
   - Spoke side: check the spoke's ranges don't overlap the hub or any VPC already peered with it.
   - Add the spoke's node and pod ranges to `loadBalancerSourceRanges` in `gateway-internal-lb.yaml`.
   - The LB is in asia-south1 without global access. For a spoke in another region, add
     `networking.gke.io/internal-load-balancer-allow-global-access: "true"` to that Service.
3. **Agent.** Copy `clusters/aauti-jitsi-nonprod-gke/observability-agent/` to `clusters/<gke-cluster-name>/observability-agent/`.
   - In `values.yaml`, change `cluster.name`, `cluster.environment` and `agent.tenant`, plus the node pool and tolerations.
     Don't use a pool tainted `components.gke.io/gke-managed-components` (reserved for GKE).
   - In `verify.ps1`, change the contexts, peering names, node / pod ranges and the expected `environment`.
   - Namespace **and** Helm release = `observability-agent-<cluster without -gke and dashes>` (e.g. `observability-agent-jitsinonprod`; `aauti-media-nonprod-as1-gke` uses `observability-agent-medianonprod`, the only media nonprod cluster with an agent; `aauti-media-prod-as1-gke` uses `observability-agent-mediaprod`). Set `$Namespace` / `$Release` in `deploy.ps1` and `verify.ps1`, and `agent.configMapName`, `agent.auth.secretName`, `agent.tls.caSecretName` plus the matching `alloy` entries in `values.yaml`, to that prefix.
   - Keep `hubUrl` / `serverName` as they are.
   - Enable `prometheusOperator` only if the app ships ServiceMonitors.
   - If the cluster has no node-exporter, set `agent.metrics.nodeExporter.enabled=false` or install one.
   - For very high log volume, switch to `alloy.controller.type: daemonset` with `logs.method: file` (example: `D:\k6s\observability-stack\environments\prod-example\spoke-media.yaml`).
4. **Roll out** in the same order: network → hub → Grafana → agent → `verify.ps1`.
   On a cluster whose pods are older than 7 days, the agent's first minutes replay old pod logs that Loki rejects
   (HTTP 400 "timestamp too old"); the gateway status check fails until those leave its 10-minute window, so run `verify.ps1` ~10-12 minutes after the agent install.
5. **Docs.** Add the cluster to the tables in the root `README.md` and the hub README.
