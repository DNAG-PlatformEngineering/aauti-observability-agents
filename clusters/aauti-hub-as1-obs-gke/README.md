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
  | `platform` | this cluster | `observability` | — | deployed |
  | `jitsi` | [aauti-jitsi-nonprod-gke](../aauti-jitsi-nonprod-gke/README.md) (asia-south1-a) | `observability-agent-jitsinonprod` | Jitsi-nonprod | deployed |
  | `media` | [aauti-media-nonprod-as1-gke](../aauti-media-nonprod-as1-gke/README.md) (asia-south1-a) | `observability-agent-medianonprod` | Media-nonprod | hub + Grafana deployed, agent not installed |
- **Spoke ingest (private):** `observability-gateway-internal` ([gateway-internal-lb.yaml](observability/gateway-internal-lb.yaml))
  is an internal LB on 10.40.16.10 (ingest subnet) reached over VPC peering. It's source-ranged to each spoke's node and pod CIDRs
  (jitsi-nonprod 10.16.0.0/24 + 10.17.0.0/17, media-nonprod-as1 10.32.0.0/24 + 10.33.0.0/17). Global access is off, so only
  spokes in asia-south1 can reach it; a spoke in another region needs the annotation
  `networking.gke.io/internal-load-balancer-allow-global-access: "true"`.
  Spokes verify TLS with SNI `observability-gateway.observability.svc`, a SAN of the existing gateway certificate.
- **Alloy + kube-state-metrics** collect this whole cluster into tenant `platform`.
- **Grafana datasources:** `Loki – Jitsi` / `Mimir – Jitsi` (user `jitsi`, folder *Jitsi-nonprod*) and `Loki – Media` / `Mimir – Media`
  (user `media`, folder *Media-nonprod*) work the same way as the platform pair below. Each pair can only read its own tenant.
  `Loki – Platform` and `Mimir – Platform` (the default) connect over HTTPS to
  `observability-gateway.observability.svc` and verify the gateway CA. They use basic auth `platform` and send `X-Scope-OrgID: platform`.
  `grafana/deploy.ps1` copies the password and CA into Secret `grafana-hub-datasource`, so run it again after rotating either.
- Every pod runs on node pool `observability`. The chart copy adds `scheduling` for its own gateway and bucket Job.
- Tenant passwords are in Secret `observability-tenant-credentials`, and the gateway CA is in `observability-hub-ca`.

Deploy / upgrade:

```powershell
./observability/deploy.ps1
```

## Grafana

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
