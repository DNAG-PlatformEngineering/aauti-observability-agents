# aauti-hub-as1-obs-gke

| | |
|---|---|
| GCP project | Aauti-hub (`aauti-hub`) |
| Location | asia-south1-a (zonal, Standard mode) |
| Control plane endpoint | 35.200.183.158 |

## Deployed

| Component | Namespace | Release | URL | Folder |
|---|---|---|---|---|
| Grafana (chart grafana/grafana 10.5.15) | `grafana` | `grafana` | https://grafana.aauti.ai | [grafana/](grafana/) |
| MinIO, Loki, Mimir, gateway, Alloy, kube-state-metrics, k6 (no tests yet) (chart [observability-stack](../../charts/observability-stack), hub mode) | `observability` | `observability` | in-cluster; gateway also on internal LB `10.40.16.10` for the spokes | [observability/](observability/) |

## Observability backends

- **Storage:** in-cluster MinIO (50Gi PVC) holds Loki and Mimir data. No GCS buckets yet.
  On 2026-10-09: 2.9 GB used (6%); expected to level off at ~10-11 GB once prod has 30 days of data (early November).
  About 1.5 GB of that is under the tenant names before the 2026-10-06 rename (`jitsi`, `media`, `platform`,
  `platform-app`); it gets the default 7d retention and should be gone by ~2026-10-13. Retention bounds the size by
  time, not bytes: a jump in log volume, a stuck compactor or failing uploads to MinIO still grow it.
- **Loki** (SingleBinary, 20Gi) and **Mimir** (1 replica per component, RF 1) are multi-tenant.
  They're reachable only through `observability-gateway` (NGINX, TLS, one basic-auth user per tenant).
  The gateway returns 403 on `/loki/api/v1/delete` (since 2026-10-09), so tenant credentials can't delete logs.
- **Rejected old log lines (expected):** every spoke gets a steady ~100-360 log lines per 6h rejected by Loki as
  older than 7 days (`greater_than_max_sample_age`, HTTP 400 in the gateway log, "final error sending batch" in the
  agent log). With `logs.method: api` the agent reopens each pod's log stream about hourly from the last line it saw;
  for quiet `kube-system` pods (netd, node-local-dns, pdcsi-node, konnectivity-agent, kube-dns) that line predates
  onboarding, so it's resent and rejected each time. No current logs are lost; Loki accepts the rest of each push.
  Because of this a spoke's `verify.ps1` can fail its gateway status-code check with a few 400s at any time (seen on
  both Jitsi clusters on 2026-10-13); harmless when the agent log gives "timestamp too old" as the reason.
- **MinIO users:** only the root credentials from Secret `observability-object-storage` (used by Loki, Mimir and the
  bucket Job). The chart sets `minio.users: []` (since 2026-10-13): the MinIO sub-chart's default had created a
  `console` / `console123` user with `consoleAdmin`, removed by hand on 2026-10-16 (`mc admin user remove`, from a temporary
  `pgsty/mc` pod: the MinIO image has no `mc`). `mc admin user list` is now empty.
- **MinIO updates:** `deploymentUpdate: Recreate` (since 2026-10-13). Its 50Gi PVC is ReadWriteOnce, so the sub-chart's
  RollingUpdate deadlocked (the new pod can't attach the disk while the old one holds it). Any MinIO pod change now means
  ~1-2 minutes without object storage: Loki / Mimir retry writes, queries over older data may fail meanwhile.
- **Gateway CPU:** requests 500m (`gateway.resources` in `observability/values.yaml`, since 2026-10-13; chart default
  50m). It used ~0.5 core with 6 spokes: nginx checks the bcrypt basic-auth hash on every push and query.
  The chart's Service is ClusterIP (used by Grafana); spokes come in through the internal LB below.
- **Tenants:**

  | Tenant | Source | Agent namespace | Grafana folder | Status |
  |---|---|---|---|---|
  | `aauti-hub` | this cluster (self-monitoring; was `platform` until 2026-10-06) | `observability` | — | deployed |
  | `jitsi-nonprod` | [aauti-jitsi-nonprod-gke](../aauti-jitsi-nonprod-gke/README.md) (asia-south1-a) | `observability-agent-jitsinonprod` | Jitsi-nonprod | deployed |
  | `media-nonprod` | [aauti-media-nonprod-as1-gke](../aauti-media-nonprod-as1-gke/README.md) (asia-south1-a) | `observability-agent-medianonprod` | Media-nonprod | deployed |
  | `media-prod` | [aauti-media-prod-as1-gke](../aauti-media-prod-as1-gke/README.md) (asia-south1, regional) | `observability-agent-mediaprod` | Media-prod | deployed |
  | `jitsi-prod` | [aauti-jitsi-prod-gke](../aauti-jitsi-prod-gke/README.md) (asia-south1-a) | `observability-agent-jitsiprod` | Jitsi-prod | deployed |
  | `platform-nonprod` | [aauti-platform-nonprod-as1-gke](../aauti-platform-nonprod-as1-gke/README.md) (asia-south1-a) | `observability-agent-platformnonprod` | Platform-nonprod | deployed |
  | `platform-prod` | [aauti-platform-prod-as1-gke](../aauti-platform-prod-as1-gke/README.md) (asia-south1, regional) | `observability-agent-platformprod` | Platform-prod | deployed |
- **Retention** (`observability/values.yaml`, per tenant):

  | Tenant | Logs (Loki) | Metrics (Mimir) |
  |---|---|---|
  | `jitsi-nonprod` | 7d, all environments | 7d |
  | `media-nonprod` | dev, sandbox, shared 7d; qa, demo 10d (`streamRetention` on `environment`) | 10d (Mimir has one retention per tenant, so qa/demo's 10d applies to all) |
  | `media-prod` | 30d | 30d (own tenant because of this; prod policy) |
  | `jitsi-prod` | 30d | 30d (prod policy) |
  | `platform-nonprod` | dev, sandbox, shared 7d; qa, demo 10d | 10d |
  | `platform-prod` | 30d | 30d (prod policy) |
  | `aauti-hub` | 14d | 30d |

- **Spoke ingest (private):** `observability-gateway-internal` ([gateway-internal-lb.yaml](observability/gateway-internal-lb.yaml))
  is an internal LB on 10.40.16.10 (ingest subnet) reached over VPC peering. It's source-ranged to each spoke's node and pod CIDRs
  (jitsi-nonprod 10.16.0.0/24 + 10.17.0.0/17, media-nonprod-as1 10.32.0.0/24 + 10.33.0.0/17,
  platform-nonprod-as1 10.4.0.0/24 + 10.5.0.0/17, media-prod-as1 10.36.0.0/24 + 10.37.0.0/17, jitsi-prod 10.20.0.0/24 + 10.21.0.0/17,
  platform-prod-as1 10.12.0.0/24 + 10.13.0.0/17). Global access is off, so only
  spokes in asia-south1 can reach it; a spoke in another region needs the annotation
  `networking.gke.io/internal-load-balancer-allow-global-access: "true"`.
  Spokes verify TLS with SNI `observability-gateway.observability.svc`, a SAN of the existing gateway certificate.
- **Alloy + kube-state-metrics** collect this whole cluster into tenant `aauti-hub`.
- **Grafana datasources, all tenants:** `Loki` and `Mimir` (the default) log in as the read-only gateway user
  `grafana-reader` (`gateway.reader` in `observability/values.yaml`). The gateway sets its `X-Scope-OrgID` to every tenant
  (`aauti-hub|jitsi-nonprod|jitsi-prod|media-nonprod|media-prod|platform-nonprod|platform-prod`, Loki `multi_tenant_queries_enabled`, Mimir
  `tenant_federation`) and returns 403 if it tries to push. Results carry `__tenant_id__`; filter with `product` / `env` /
  `cluster` / `namespace` / `app` / `pod` / `container`. A new tenant is included automatically after `observability/deploy.ps1`.
- **Grafana datasources per tier** (deployed 2026-10-16; checked: each sees only its tier's three tenants): `Loki – Prod` / `Mimir – Prod` (uids `loki-prod` / `mimir-prod`) read only
  `jitsi-prod|media-prod|platform-prod`, as read-only user `grafana-reader-prod`; `Loki – Nonprod` / `Mimir – Nonprod`
  (`loki-nonprod` / `mimir-nonprod`) read only `jitsi-nonprod|media-nonprod|platform-nonprod`, as `grafana-reader-nonprod`.
  The gateway pins them (`gateway.extraReaders` in `observability/values.yaml`), so even a query without filters can't see the
  other tier; push returns 403. `aauti-hub` is in neither (use `Loki` / `Mimir`). A new tenant must be added to its tier's
  `extraReaders` list by hand.
- **Dashboard Explore** (folder *Explore*, `grafana/dashboards/explore.json`, loaded by `grafana/deploy.ps1` as ConfigMap
  `grafana-dashboards-explore`): fields Product → Env → Cluster → Namespace → App → Pod → Container (Loki label values, each
  narrowed by the ones before it) over `Loki` / `Mimir`, i.e. all products.
- **No per-tenant datasources** (removed 2026-10-06; Explore lists `Loki` / `Mimir` plus the per-tier pairs). The folder dashboards
  (*Jitsi-nonprod*, *Jitsi-prod*, *Media-nonprod*, *Media-prod*, *Platform-nonprod*, *Platform-prod*) use `Loki` / `Mimir` too; `grafana/deploy.ps1`
  limits each folder's *Cluster* variable to its own tenant (`label_values(up{__tenant_id__="<tenant>"}, cluster)`, "All" =
  those clusters only), and every panel filters on `$cluster`, so a folder never shows another tenant's data.
  The datasources connect over HTTPS to `observability-gateway.observability.svc` and verify the gateway CA.
  `grafana/deploy.ps1` copies the `grafana-reader`, `grafana-reader-prod` and `grafana-reader-nonprod` passwords and the CA into
  Secret `grafana-hub-datasource`, so run it again after rotating any of them.
- Every pod runs on node pool `observability`. The chart copy adds `scheduling` for its own gateway, bucket Job,
  k6 CronJobs and grafana-access Job.
- Tenant passwords are in Secret `observability-tenant-credentials`, and the gateway CA is in `observability-hub-ca`.

Deploy / upgrade:

```powershell
./observability/deploy.ps1
```

It also restarts the hub's Alloy, which reads its tenant password only at start-up. After adding or renaming a
tenant, redeploy the affected spokes' agents too (their `deploy.ps1` copies the password and restarts Alloy).

## Grafana

- Grafana 12.3.1 (OSS). Local accounts only: sign-up and anonymous access are off, new users get Viewer
  (the *Explore* page needs Editor or Admin; the *Explore* dashboard works for Viewers). The chart's `grafana`, `grafanaAccess` and `alerting` are disabled in
  `observability/values.yaml`, so there are no tenant teams, no *Tenant usage* dashboard and no usage alerts yet.
- Exposed with GKE Ingress on the global static IP `aauti-hub-vpc-as1-grafana-ip` (8.233.134.60) and a
  Google-managed certificate (`grafana-cert`); HTTP redirects to HTTPS.
- DNS: Cloudflare A record `grafana.aauti.ai` → 8.233.134.60.
- Runs on node pool `observability` (taint `workload=observability:NoSchedule`),
  10Gi PVC on `standard-rwo`. The PVC is ReadWriteOnce, so the Deployment uses `strategy: Recreate` (since 2026-10-08):
  every Grafana restart or upgrade has a ~30-60s gap (alerts aren't evaluated during it).
- Chart is vendored as `grafana/grafana-10.5.15.tgz` because github.com is not
  reachable over the office VPN.
- The control plane only accepts the office IP (183.82.114.188), so deploy from
  the office network / VPN.
- Admin login: Secret `grafana-admin` in namespace `grafana`:

```powershell
kubectl -n grafana get secret grafana-admin -o jsonpath='{.data.admin-password}' | % { [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($_)) }
```

Deploy / upgrade:

```powershell
./grafana/deploy.ps1
```

Both hub scripts stop with an error if `get-credentials` fails (VPN / gcloud login) or a rollout doesn't finish
within 5 minutes, and pass the hub context to every `kubectl` / `helm` call (`grafana/deploy.ps1` since 2026-10-13),
so switching the current kube context in another shell mid-run can't send changes to another cluster.

## Alerts

Grafana-managed rules as code, folder **Alerts**, one rule group per cluster.
Dashboard **Alerts overview** (folder *Alerts*, next to the rules, [source](grafana/dashboards/alerts/alerts-overview.json)): counts per state for
prod / nonprod / hub, then everything firing, pending, no data or erroring, grouped by cluster, plus a critical-only list.
It reads the rules directly (built-in *Alert list* panels split by the `tenant` / `severity` labels), so new rule groups show up without editing it.
Filters: Tier (prod / nonprod / hub) → Cluster → Environment → Namespace → Severity, matched against the alerts' labels.
Environment and Namespace only narrow workload alerts (node, agent and hub alerts carry neither), so keep them on *All* to see everything.
(The HPA, memory-near-limit and PVC rules keep `environment` through `on (...) group_left` since 2026-10-13; before that
their alerts had no `environment`, so picking an Environment hid them.)
The panels follow *Tier*: each Summary / Needs-attention panel repeats once per selected tier, so *prod* shows only prod,
*nonprod* only nonprod, *All* all three. *Jump to a cluster* is a live table of the spoke clusters matching Tier and Cluster;
clicking a cluster name opens its Cluster health, Workloads & logs, Resource usage, all its dashboards (incl. Jitsi Meet) or
its alert rules, with that cluster selected. The hub's rules and Explore view are linked under the table.

**Status (2026-10-16):** all 7 groups are deployed (Media-nonprod since 2026-10-08, the rest 2026-10-12): 85 rules,
all healthy. The only alert is Platform-prod's "HPA at max replicas" for `aauti-marketplace` (expected, see the table);
everything else is normal. **Email is live since 2026-10-16:** every alert, prod and nonprod, goes to `ops@aauti.com`,
sent from `info@aauti.com` (Grafana Helm revision 31). The first send (the marketplace HPA alert, 06:13 UTC) was accepted
by Office 365 with no error (Alerting → Contact points → `email-nonprod` shows the last delivery attempt); arrival in the
inbox not yet confirmed. It repeats every 4h while the alert fires.
All prod and nonprod alerts share one notification policy (contact point `email-nonprod`) and go to the same recipients
(chosen on 2026-10-15); a separate prod list would need its own contact point. Grafana's built-in contact point
`grafana-default-email` (`<example@email.com>`) still exists but nothing routes to it; `deploy.ps1` refuses `-SmtpUser`
without recipients (since 2026-10-13), so it can't become the fallback again.

| Group | File | Rules |
|---|---|---|
| Media-nonprod | [grafana/alerting/media-nonprod.yaml](grafana/alerting/media-nonprod.yaml) | crash loop, image pull, OOMKilled, frequent restarts, deployment unavailable, pod Pending/Unknown, HPA at max, memory > 90% of limit, PVC > 85%, node NotReady (critical), node pressure, error-log spike, metrics / logs stopped (critical) |
| Jitsi-nonprod | [grafana/alerting/jitsi-nonprod.yaml](grafana/alerting/jitsi-nonprod.yaml) | same 14 rules as Media-nonprod; error-log spike on namespace `jitsi`; HPA rule covers JVB (4-20) and Jibri (4-10). Deployed 2026-10-12 |
| Platform-nonprod | [grafana/alerting/platform-nonprod.yaml](grafana/alerting/platform-nonprod.yaml) | same as Media-nonprod **without** "HPA at max" (19 of 44 nonprod HPAs sit at max permanently: capped at 2, or min = max); error-log spike on `aauti-<app>-<env>`. Deployed 2026-10-12 |
| Media-prod | [grafana/alerting/media-prod.yaml](grafana/alerting/media-prod.yaml) | same 14 rules as Media-nonprod; HPA rule skips HPAs with min = max. Deployed 2026-10-12 |
| Jitsi-prod | [grafana/alerting/jitsi-prod.yaml](grafana/alerting/jitsi-prod.yaml) | same 14 rules; error-log spike on namespace `jitsi`; HPA rule covers JVB (2-20) and Jibri (2-10). Deployed 2026-10-12 |
| Platform-prod | [grafana/alerting/platform-prod.yaml](grafana/alerting/platform-prod.yaml) | same 14 rules; HPA rule skips min = max (aauti-scheduler). `aauti-marketplace` fires on it: pinned at 5/5 by its memory target (70% of a 512Mi request). Deployed 2026-10-12 |
| Aauti-hub | [grafana/alerting/aauti-hub.yaml](grafana/alerting/aauti-hub.yaml) | hub volume > 75% for 15m (warning), > 90% for 5m (critical); namespaces `observability` and `grafana`. Deployed 2026-10-12 |

- Notifications go by **email (Outlook)**. `deploy.ps1` loads `grafana/alerting/*.yaml` into ConfigMap
  `grafana-alerting-rules`, and renders the email contact point `email-nonprod` plus the notification policy
  (group by grafana_folder, alertname, cluster, environment, namespace; repeat 4h) into Secret `grafana-alerting-notify`.
  Both are mounted into `/etc/grafana/provisioning/alerting`; Grafana restarts when either changes.
- Sending: `grafana.ini` `smtp` in `grafana/values.yaml` (host `smtp.office365.com:587`, STARTTLS). The sending
  mailbox and its password live only in Secret `grafana-smtp` (env `GF_SMTP_USER` / `GF_SMTP_PASSWORD` /
  `GF_SMTP_FROM_ADDRESS`). The mailbox needs **SMTP AUTH enabled in Microsoft 365**; if the tenant blocks it,
  change `smtp.host` to an SMTP relay on port 587 (GCP blocks outbound port 25).
- Recipients and mailbox are defaults in `grafana/deploy.ps1`: `ops@aauti.com` and `info@aauti.com` (override with
  `-AlertEmails "a@aauti.com;b@aauti.com"` / `-SmtpUser …`, or `$env:ALERT_EMAILS` / `SMTP_USER`). The mailbox password is
  **never** in the repo: set `$env:SMTP_PASSWORD` (or type it at the prompt) for the first run and after it changes; later
  runs reuse the copy stored in Secret `grafana-smtp`.
  Grafana restarts (~1 min) whenever the recipients or the SMTP login are created or changed, since the SMTP
  login is only read at start-up. A different `-SmtpUser` than the stored one always needs its password again.
- The *Alert rules* page shows a red "Errors loading rules … 404 from rule state endpoint. Perhaps ruler API is not
  enabled?" banner. Expected and harmless: Grafana also asks the `Mimir` datasource for data source-managed rules,
  and Mimir's ruler isn't served through the gateway. All rules here are Grafana-managed. (`manageAlerts: false` on
  the datasources would hide it; deliberately not set.)
  Without recipients the rules would still load but no one would be notified.
- Provisioned rules are read-only in the UI. To add a cluster, copy `media-nonprod.yaml` and change the
  `cluster` matcher, group name, `uid` prefix, the `tenant` label on every rule, the namespace filter of the
  error-log rule (`aauti-media-.+`), and the agent namespace / GCP project named in the descriptions
  (datasources stay `mimir` / `loki`; every query must filter on `cluster`).
