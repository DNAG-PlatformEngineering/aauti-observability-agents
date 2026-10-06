# Multi-tenancy, limits and retention

> **In this repo** the tenants are `aauti-hub` (hub self-monitoring, instead of `platform`), `jitsi-nonprod`, `jitsi-prod`, `media-nonprod`, `media-prod` and `platform-nonprod` (not
> `application` / `loadtest`); their limits and retention are in
> `clusters/aauti-hub-as1-obs-gke/observability/values.yaml`. `alerting` is disabled on the hub and
> the standalone Grafana doesn't provision the *Tenant usage* dashboard, so the usage alerts and
> dashboard described below aren't active. `scripts/verify-tenancy.ps1` is POC-only; each spoke's
> `verify.ps1` checks its own tenant.

## Model

* **One tenant per spoke cluster** (`media`, `application`, `jitsi`, …), plus
  `platform` (the hub's own telemetry) and `loadtest` (k6 results).
* The tenant id is used as the Loki/Mimir `X-Scope-OrgID`, the gateway
  username, the Grafana team name and in datasource/dashboard UIDs, so it must
  match `^[a-z0-9][a-z0-9_-]*$`.
* Inside a tenant, every series and stream carries `cluster` and
  `environment` labels (set per release in `cluster.*`). That means several
  clusters can share a tenant, for example `media-prod` and `media-nonprod` in
  tenant `media`, and still be filtered apart.

## How isolation is enforced

1. The spoke agent sends `X-Scope-OrgID: <tenant>` and basic auth
   `<tenant>:<password>` over TLS to the gateway.
2. The gateway (`templates/hub/gateway-config.yaml`) checks the password
   against its htpasswd and then **overwrites** `X-Scope-OrgID` with the
   authenticated username.
3. If the client sends an `X-Scope-OrgID` that differs from its own tenant
   (including federated `a|b` reads), the gateway returns **403**.
4. NetworkPolicies allow traffic into Loki, Mimir and MinIO only from pods in
   the hub namespace. Anything outside has to go through the gateway.
5. Loki and Mimir store every tenant under its own prefix in the bucket
   (`<bucket>/<tenant>/…`), so data is logically separated in object storage.

`scripts/verify-tenancy.ps1` checks points 2 and 3 end to end.

## Tenant definition (hub values)

```yaml
tenants:
  media:
    title: Media                     # used in "Loki – Media", folder name
    password: ""                     # empty = generated once, then kept
    dashboards: [cluster-health, resource-usage, workloads-logs]
    logs:
      retention: 72h                 # default for this tenant
      streamRetention:               # per log type / selector (highest priority wins)
        - { selector: '{log_type="access"}', priority: 1, period: 24h }
      limits:                        # any Loki limits_config key
        ingestion_rate_mb: 20
        ingestion_burst_size_mb: 40
        max_global_streams_per_user: 10000
        max_query_series: 1000
    metrics:
      retention: 168h                # compactor_blocks_retention_period
      limits:                        # any Mimir limits key
        ingestion_rate: 40000
        ingestion_burst_size: 400000
        max_global_series_per_user: 200000
        max_fetched_series_per_query: 50000
```

The chart renders these into the runtime-config ConfigMaps
`observability-loki-overrides` and `observability-mimir-overrides`. Loki and
Mimir reload them every 10 s, so **limit and retention changes need no
restart**: run `helm upgrade` and wait about a minute for the kubelet to sync
the ConfigMap.

Tenants without an entry get the global defaults from
`loki.loki.limits_config` and `mimir.mimir.structuredConfig.limits`.

## Retention

| Signal | Mechanism | Granularity |
|---|---|---|
| Logs | Loki compactor (`retention_enabled: true`) | per tenant (`retention_period`) and per stream selector (`retention_stream`) |
| Metrics | Mimir compactor | per tenant (`compactor_blocks_retention_period`) |

**Log types.** The agent adds a `log_type` label to every log stream. It
defaults to `agent.logs.defaultLogType` (`application`), can be overridden per
pod with the annotation `observability.aauti.com/log-type: <type>`, and is set
to `k8s-event` for Kubernetes events. Use it in `streamRetention` selectors,
for example to keep media access logs for 1 day while other media logs stay
for 3.

Notes:
* Loki deletes data in whole index periods (24 h), after
  `retention_delete_delay` (2 h). Retention below 24 h is not meaningful.
* Mimir retention applies to blocks in object storage. Data still in the
  ingesters (≈ last 2–13 h) is not affected.
* Retention is enforced by deleting objects. Don't also set a shorter
  bucket lifecycle rule on GCS, or you'll get gaps.

## Object storage

* **Local:** MinIO (`minio.enabled: true`) with buckets `loki-chunks`,
  `loki-ruler`, `loki-admin`, `mimir-blocks`, `mimir-ruler` and
  `mimir-alertmanager`. Credentials are generated into
  `observability-object-storage`.
* **Production:** GCS with Workload Identity. See
  `environments/prod-example/hub-gcs.yaml`: set `minio.enabled: false`, switch
  `loki.loki.storage.type` and the schema `object_store` to `gcs`, set
  `mimir…common.storage.backend: gcs` plus a bucket per component, and
  annotate the `loki` and `mimir` service accounts with the GCP service
  account.

## Monitoring tenant usage

The hub agent (tenant `platform`) scrapes Loki, Mimir (including the
**overrides-exporter**, which publishes every tenant's limits as
`cortex_limits_overrides`) and the gateway logs.

* Dashboard **Platform / Tenant usage** shows, per tenant: samples/s and
  active series against their limits, discarded samples and logs by reason,
  log bytes/s, streams, query rate, gateway requests and rejections
  (401/403/429), and blocks in storage.
* Alert rules (Grafana-managed, folder `alerting.folder`):

| Rule | Fires when |
|---|---|
| Mimir tenant near active-series limit | usage > `alerting.usageThreshold` (0.8) of `max_global_series_per_user` |
| Mimir tenant near ingestion-rate limit | samples/s > 80 % of `ingestion_rate` |
| Mimir tenant samples discarded | any `cortex_discarded_samples_total` increase |
| Loki tenant near ingestion-rate limit | bytes/s > 80 % of `ingestion_rate_mb` |
| Loki tenant logs discarded | any `loki_discarded_bytes_total` increase |
| Tenant stopped sending metrics / logs | no data for 10 min (except the k6 tenant) |

Where alerts go:

```yaml
alerting:
  webhook:
    url: https://hooks.slack.com/services/...   # one webhook for everything (Slack/Teams/Chat/PagerDuty bridges)
  # or full Grafana provisioning format for email, per-tenant routing, ...
  contactPoints: []
  policies: []
  pendingPeriod: ""        # e.g. 2m to override every rule's "for" (local testing)
```

Locally, `demoAlertSink` is a tiny receiver that prints each notification:
`kubectl -n observability logs deploy/alert-sink -f`.

**Noisy-neighbour protection** comes from the limits themselves. A tenant
that exceeds `ingestion_rate` or `max_global_series_per_user` gets HTTP 429
for its own writes only, and the alerts above tell you before and when that
happens.
