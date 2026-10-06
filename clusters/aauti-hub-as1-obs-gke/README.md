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
| MinIO, Loki, Mimir, gateway, Alloy, kube-state-metrics (chart [observability-stack](../../charts/observability-stack), hub mode) | `observability` | `observability` | in-cluster only | [observability/](observability/) |

## Observability backends

- **Storage:** in-cluster MinIO (50Gi PVC) holds Loki and Mimir data. No GCS buckets yet.
- **Loki** (SingleBinary, 20Gi) and **Mimir** (1 replica per component, RF 1) are multi-tenant.
  They're reachable only through `observability-gateway` (NGINX, TLS, one basic-auth user per tenant).
  The chart's Service is ClusterIP (used by Grafana); spokes come in through the internal LB below.
- **Tenants:**

  | Tenant | Source | Agent namespace | Grafana folder | Status |
  |---|---|---|---|---|
  | `aauti-hub` | this cluster (self-monitoring; was `platform` until 2026-10-06) | `observability` | — | deployed |
  | `jitsi-nonprod` | [aauti-jitsi-nonprod-gke](../aauti-jitsi-nonprod-gke/README.md) (asia-south1-a) | `observability-agent-jitsinonprod` | Jitsi-nonprod | deployed |
  | `media-nonprod` | [aauti-media-nonprod-as1-gke](../aauti-media-nonprod-as1-gke/README.md) (asia-south1-a) | `observability-agent-medianonprod` | Media-nonprod | deployed |
  | `media-prod` | [aauti-media-prod-as1-gke](../aauti-media-prod-as1-gke/README.md) (asia-south1, regional) | `observability-agent-mediaprod` | Media-prod | deployed |
  | `platform-nonprod` | [aauti-platform-nonprod-as1-gke](../aauti-platform-nonprod-as1-gke/README.md) (asia-south1-a) | `observability-agent-platformnonprod` | Platform-nonprod | deployed |
- **Retention** (`observability/values.yaml`, per tenant):

  | Tenant | Logs (Loki) | Metrics (Mimir) |
  |---|---|---|
  | `jitsi-nonprod` | 7d, all environments | 7d |
  | `media-nonprod` | dev, sandbox, shared 7d; qa, demo 10d (`streamRetention` on `environment`) | 10d (Mimir has one retention per tenant, so qa/demo's 10d applies to all) |
  | `media-prod` | 30d | 30d (own tenant because of this; prod policy) |
  | `platform-nonprod` | dev, sandbox, shared 7d; qa, demo 10d | 10d |
  | `aauti-hub` | 14d | 30d |

- **Spoke ingest (private):** `observability-gateway-internal` ([gateway-internal-lb.yaml](observability/gateway-internal-lb.yaml))
  is an internal LB on 10.40.16.10 (ingest subnet) reached over VPC peering. It's source-ranged to each spoke's node and pod CIDRs
  (jitsi-nonprod 10.16.0.0/24 + 10.17.0.0/17, media-nonprod-as1 10.32.0.0/24 + 10.33.0.0/17,
  platform-nonprod-as1 10.4.0.0/24 + 10.5.0.0/17, media-prod-as1 10.36.0.0/24 + 10.37.0.0/17). Global access is off, so only
  spokes in asia-south1 can reach it; a spoke in another region needs the annotation
  `networking.gke.io/internal-load-balancer-allow-global-access: "true"`.
  Spokes verify TLS with SNI `observability-gateway.observability.svc`, a SAN of the existing gateway certificate.
- **Alloy + kube-state-metrics** collect this whole cluster into tenant `aauti-hub`.
- **Grafana datasources, all tenants:** `Loki` and `Mimir` (the default) log in as the read-only gateway user
  `grafana-reader` (`gateway.reader` in `observability/values.yaml`). The gateway sets its `X-Scope-OrgID` to every tenant
  (`aauti-hub|jitsi-nonprod|media-nonprod|media-prod|platform-nonprod`, Loki `multi_tenant_queries_enabled`, Mimir
  `tenant_federation`) and returns 403 if it tries to push. Results carry `__tenant_id__`; filter with `product` / `env` /
  `cluster` / `namespace` / `app` / `pod` / `container`. A new tenant is included automatically after `observability/deploy.ps1`.
- **No per-tenant datasources** (removed 2026-10-06, so Explore lists only `Loki` and `Mimir`). The folder dashboards
  (*Jitsi-nonprod*, *Media-nonprod*, *Media-prod*, *Platform-nonprod*) use `Loki` / `Mimir` too; `grafana/deploy.ps1`
  limits each folder's *Cluster* variable to its own tenant (`label_values(up{__tenant_id__="<tenant>"}, cluster)`, "All" =
  those clusters only), and every panel filters on `$cluster`, so a folder never shows another tenant's data.
  The datasources connect over HTTPS to `observability-gateway.observability.svc` and verify the gateway CA.
  `grafana/deploy.ps1` copies the `grafana-reader` password and the CA into Secret `grafana-hub-datasource`, so run it again after rotating either.
- Every pod runs on node pool `observability`. The chart copy adds `scheduling` for its own gateway and bucket Job.
- Tenant passwords are in Secret `observability-tenant-credentials`, and the gateway CA is in `observability-hub-ca`.

Deploy / upgrade:

```powershell
./observability/deploy.ps1
```

It also restarts the hub's Alloy, which reads its tenant password only at start-up. After adding or renaming a
tenant, redeploy the affected spokes' agents too (their `deploy.ps1` copies the password and restarts Alloy).

## Grafana

- Grafana 12.3.1 (OSS). Local accounts only: sign-up and anonymous access are off, new users get Viewer
  (Explore needs Editor or Admin). The chart's `grafana`, `grafanaAccess` and `alerting` are disabled in
  `observability/values.yaml`, so there are no tenant teams, no *Tenant usage* dashboard and no usage alerts yet.
- Exposed with GKE Ingress on the global static IP `aauti-hub-vpc-as1-grafana-ip` (8.233.134.60) and a
  Google-managed certificate (`grafana-cert`); HTTP redirects to HTTPS.
- DNS: Cloudflare A record `grafana.aauti.ai` → 8.233.134.60.
- Runs on node pool `observability` (taint `workload=observability:NoSchedule`),
  10Gi PVC on `standard-rwo`.
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

## Alerts

Grafana-managed rules as code, folder **Alerts**, one rule group per cluster.

**Status: in the repo, not deployed yet.** The last Grafana deploys (2026-10-06: Media-prod, then the tenant renames to `aauti-hub` / `*-nonprod`) were run from a checkout
without the alerting / SMTP change, so the live Grafana has no alert rules, contact point or SMTP settings. The next
`./grafana/deploy.ps1` from `main` deploys them. No rules for Media-prod yet.


| Group | File | Rules |
|---|---|---|
| Media-nonprod | [grafana/alerting/media-nonprod.yaml](grafana/alerting/media-nonprod.yaml) | crash loop, image pull, OOMKilled, frequent restarts, deployment unavailable, pod Pending/Unknown, HPA at max, memory > 90% of limit, PVC > 85%, node NotReady (critical), node pressure, error-log spike, metrics / logs stopped (critical) |

- Notifications go by **email (Outlook)**. `deploy.ps1` loads `grafana/alerting/*.yaml` into ConfigMap
  `grafana-alerting-rules`, and renders the email contact point `email-nonprod` plus the notification policy
  (group by alertname, cluster, environment, namespace; repeat 4h) into Secret `grafana-alerting-notify`.
  Both are mounted into `/etc/grafana/provisioning/alerting`; Grafana restarts when either changes.
- Sending: `grafana.ini` `smtp` in `grafana/values.yaml` (host `smtp.office365.com:587`, STARTTLS). The sending
  mailbox and its password live only in Secret `grafana-smtp` (env `GF_SMTP_USER` / `GF_SMTP_PASSWORD` /
  `GF_SMTP_FROM_ADDRESS`). The mailbox needs **SMTP AUTH enabled in Microsoft 365**; if the tenant blocks it,
  change `smtp.host` to an SMTP relay on port 587 (GCP blocks outbound port 25).
- Recipients, mailbox and password are never stored in the repo. Pass them once with
  `./grafana/deploy.ps1 -AlertEmails "a@aauti.com;b@aauti.com" -SmtpUser alerts@aauti.com` (it prompts for the
  password; or `$env:ALERT_EMAILS` / `SMTP_USER` / `SMTP_PASSWORD`); later runs keep the stored values.
  Without recipients the rules still load but nothing is sent.
- Provisioned rules are read-only in the UI. To add a cluster, copy `media-nonprod.yaml`, change the
  `cluster` matcher, group name and `uid` prefix (datasources stay `mimir` / `loki`; every query must filter on `cluster`).
