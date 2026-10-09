# Deployment

> **In this repo** the commands below refer to the POC's `scripts/` and `environments/`, which
> aren't copied here. Deploy with `clusters/aauti-hub-as1-obs-gke/{observability,grafana}/deploy.ps1`
> and `clusters/<spoke>/observability-agent/deploy.ps1`. Spoke namespace and release are
> `observability-agent-<cluster>` (e.g. `observability-agent-medianonprod`), not `observability-agent`.
> The *Production (GKE + GCS)* steps aren't done yet: the hub uses MinIO, single replicas, RF 1.
> In the table below, read tenant `aauti-hub` for both `platform` and `loadtest` (`k6.tenant: aauti-hub`),
> and Grafana is standalone with one federated `Loki` / `Mimir` datasource pair, not per-tenant ones.
> There is no CI here (`scripts/ci-check.sh` and `.github/` are POC-only), and the sub-charts are committed
> in `charts/`, so `helm dependency build` isn't needed.

## Values layering

```
values.yaml                      every option + defaults (all components off)
  + profiles/hub.yaml | spoke.yaml     which components run in this mode
  + environments/<env>/<name>.yaml     cluster identity, tenants, sizing, storage
  + --set / --set-file                 secrets only (never commit them)
```

| Release | Namespace | Command |
|---|---|---|
| hub | `observability` | `helm upgrade --install observability . -n observability -f profiles/hub.yaml -f environments/<env>/hub.yaml` |
| each spoke | `observability-agent` | `helm upgrade --install observability-agent . -n observability-agent -f profiles/spoke.yaml -f environments/<env>/spoke-<name>.yaml --set-file agent.tls.caCert=hub-ca.crt` |

Run `helm dependency build` once after cloning (it downloads Loki, Mimir,
Grafana, MinIO, Alloy and kube-state-metrics into `charts/`).

Some Secrets and ConfigMaps have fixed names (`observability-*`), so install
at most one release of this chart per namespace.

## Local (Docker Desktop / kind / minikube)

```powershell
./scripts/local-up.ps1          # hub + spoke-media, spoke-application, spoke-jitsi
./scripts/verify-tenancy.ps1    # auth + isolation checks
./scripts/local-down.ps1 -Purge # tear down (PVCs + kept secrets too)
```

The script refuses to run against non-local kube contexts. Here is what it does:
1. `helm dependency build` if needed.
2. Installs the hub (`profiles/hub.yaml` + `environments/local/hub.yaml`) and waits.
3. Reads the generated hub CA and each tenant password from the hub.
4. For each spoke: creates namespace `spoke-<name>`, the Secret
   `observability-agent-auth`, and installs release
   `observability-agent-<name>` with the CA. Locally the release name must
   differ per spoke because all spokes share one cluster and the agent's
   ClusterRole is named after the release. On real spoke clusters,
   `observability-agent` is fine.

Local specifics: MinIO stands in for GCS; all components run a single
replica with replication factor 1. Each "spoke" agent only collects its own
namespace (`agent.namespaces`), and its node-level metrics are those of the
shared Docker Desktop nodes.

Access:
```powershell
kubectl --context docker-desktop -n observability port-forward svc/grafana 3000:80
# admin password:
kubectl --context docker-desktop -n observability get secret observability-grafana-admin -o jsonpath='{.data.admin-password}' | % { [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($_)) }
```

## Production (GKE + GCS)

1. **Buckets + identity.** Create the GCS buckets listed in
   `environments/prod-example/hub-gcs.yaml` and a GCP service account with
   `roles/storage.objectAdmin` on them. Bind it with Workload Identity to the
   KSAs `observability/loki` and `observability/mimir`.
2. **Certificate.** Pick a host (e.g. `observability.<env>.internal`) and
   either enable cert-manager (`gateway.tls.certManager`) or create a TLS
   Secret (`gateway.tls.existingSecret`). Put the issuing CA in
   `gateway.tls.caCert`.
3. **Exposure.** Use `gateway.service.type: LoadBalancer` (internal) with
   `loadBalancerSourceRanges` limited to the spokes' egress ranges, or an
   ingress with HTTPS backend. The gateway always terminates TLS itself.
4. **Values.** Copy `environments/prod-example/hub-gcs.yaml` to
   `environments/prod/hub.yaml`, add the `tenants` block (copy it from
   `environments/local/hub.yaml` and size it), and set replicas and
   `replication_factor: 3`.
5. **Install the hub**, then onboard each spoke
   ([tenant-onboarding.md](tenant-onboarding.md)).
6. **Test in non-production first.** Deploy the same files to the nonprod hub
   and spokes (e.g. `environments/nonprod/*`), then run
   `scripts/verify-tenancy.ps1 -Context <nonprod-hub>` (it only needs curl
   inside the cluster) and check the dashboards and alerts before promoting
   the same chart version to prod.

### Spoke agent modes

| Mode | Values | Use for |
|---|---|---|
| StatefulSet + Kubernetes API log tailing (default) | `alloy.controller.type: statefulset` (1 replica, 1 Gi volume for read positions + metrics WAL), `agent.logs.method: api` | small and medium clusters; includes Kubernetes events |
| DaemonSet + node log files | `controller.type: daemonset`, `alloy.mounts.varlog: true`, `alloy.clustering.enabled: true`, `logs.method: file`, `logs.events: false`, `controller.tolerations: [{operator: Exists}]`, state on a hostPath (`/var/lib/observability-agent`) | high log volume (media). One agent per node, each handling only its own node. Clustering makes kube-state-metrics scraped exactly once, and the toleration covers tainted node pools |

Local `spoke-media` runs the DaemonSet mode (verified: one series per pod and per node, no duplicated log lines).

### Onboarding a real spoke

`scripts/onboard-spoke.ps1` copies the tenant password and the hub CA from the
hub's kube context, creates the Secret on the spoke's context, installs the
agent and checks its log for 401/403/TLS errors. It refuses non-local spoke
contexts unless `-Yes` is passed.

```powershell
./scripts/onboard-spoke.ps1 -HubContext <hub-ctx> -SpokeContext <spoke-ctx> `
  -Tenant media -ValuesFile environments/nonprod/spoke-media.yaml -Yes
```

### CI

`scripts/ci-check.sh` (run by `.github/workflows/ci.yaml`, or locally with
`bash scripts/ci-check.sh`):
* lints the chart and renders every environment file;
* checks that bad input is rejected;
* runs `alloy fmt` on every generated agent pipeline and `nginx -t` on the gateway config;
* fails if `dashboards/*.json` differ from `dashboards/src/generate.py`.

### Upgrades

* `helm upgrade` with the same files. Tenant limits and retention reload
  without restarts.
* Generated credentials, CA and MinIO keys are looked up from the cluster and
  reused, so upgrades never rotate them. `helm template` / `--dry-run` without
  cluster access shows fresh random values; that's expected.
* Upstream chart versions are pinned in `Chart.yaml`. Bump them one at a time
  and read their upgrade notes (especially Loki and Mimir).

### Sizing notes

| Scale | Loki | Mimir |
|---|---|---|
| local / small (< 50k series, < 5 MB/s logs) | `SingleBinary` | 1 replica per component, RF 1 |
| production | `SimpleScalable` (write/read/backend × 3), caches on | RF 3, ≥ 3 ingesters, caches on; consider `ingest_storage` + Kafka for large scale |

## What gets deployed

**Hub** (`mode: hub`)

| Component | Purpose |
|---|---|
| `observability-gateway` | NGINX, TLS, per-tenant basic auth, `X-Scope-OrgID` enforcement |
| Loki (`loki`) | logs, `auth_enabled: true`, compactor retention |
| Mimir (`mimir-*`) | metrics, per-tenant limits, overrides-exporter |
| MinIO (local only) | S3-compatible object storage |
| Grafana | per-tenant datasources, dashboards, alerting, RBAC bootstrap Job |
| Alloy + kube-state-metrics | hub self-monitoring into tenant `platform` |
| k6 CronJobs | load tests, results into tenant `loadtest` |

**Spoke** (`mode: spoke`)

| Component | Purpose |
|---|---|
| Alloy | pod logs, Kubernetes events, kubelet/cAdvisor, KSM, node-exporter, annotated pods; ships to the hub |
| kube-state-metrics | cluster-state metrics |

### Collected signals (per spoke)

* **Logs:** every container (Kubernetes API or `/var/log/pods`), labels
  `cluster, environment, namespace, pod, container, app, node, job, log_type`, plus
  `env`, `product` and `tier` when `agent.envLabel`, `cluster.product` and `cluster.tier` are set.
  Loki adds `detected_level`.
* **Events:** Kubernetes events as logs (`log_type="k8s-event"`).
* **Metrics:** cAdvisor (allow-listed), kubelet, kube-state-metrics,
  node-exporter (if present), and any pod annotated
  `prometheus.io/scrape: "true"`.
