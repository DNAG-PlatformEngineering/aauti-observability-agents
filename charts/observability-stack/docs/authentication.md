# Authentication, TLS and Grafana access

## 1. Spoke → hub: TLS + per-tenant basic auth

Every write and read against Loki and Mimir goes through
`observability-gateway` (NGINX):

* **TLS** on port 443. The certificate comes from one of:
  * **generated** (default): a private CA plus server cert created by the chart
    and kept across upgrades (`helm.sh/resource-policy: keep`). SANs cover the
    in-cluster service names, `gateway.ingress.host` and
    `gateway.tls.extraDnsNames` / `extraIpAddresses`.
  * **cert-manager**: `gateway.tls.certManager.enabled: true` plus `issuerRef`.
  * **your own Secret**: `gateway.tls.existingSecret: <tls secret>`.

  For the last two, set `gateway.tls.caCert` to the issuing CA's PEM. The CA
  is published as Secret `observability-hub-ca` and mounted into Grafana, k6
  and the hub agent. Spokes receive it as `agent.tls.caCert`.
* **Basic auth**: one user per tenant, with username = tenant id. Passwords
  are generated into Secret `observability-tenant-credentials` (key = tenant),
  or set explicitly with `tenants.<id>.password`. The gateway's htpasswd
  (bcrypt) is rendered from them.
* **Tenant binding**: the gateway derives `X-Scope-OrgID` from the
  authenticated user and returns 403 on any mismatching header (see
  [multi-tenancy.md](multi-tenancy.md)).
* Loki, Mimir and MinIO are reachable only from inside the hub namespace
  (NetworkPolicy `networkPolicy.enabled`).

### Get a tenant's credentials (hub admin)

```bash
kubectl -n observability get secret observability-tenant-credentials -o jsonpath='{.data.media}' | base64 -d
kubectl -n observability get secret observability-hub-ca -o jsonpath='{.data.ca\.crt}' | base64 -d > hub-ca.crt
```

### Rotate a tenant password

1. Set `tenants.<id>.password: <new>` (from your secret store) and run
   `helm upgrade` on the hub. NGINX reads htpasswd per request, so no restart
   is needed.
2. Update `observability-agent-auth` on the spoke and restart its agent:
   `kubectl -n observability-agent rollout restart statefulset/observability-agent-alloy` (or `daemonset/…` in per-node mode).
3. Grafana picks the new password up from the mounted Secret after its
   datasources reload (restart Grafana to force it).

To rotate by regeneration instead, delete the key from
`observability-tenant-credentials` and upgrade.

### Using an existing Prometheus instead of Alloy

Any Prometheus-compatible sender works:

```yaml
remote_write:
  - url: https://<hub>/api/v1/push
    basic_auth: { username: media, password_file: /etc/secrets/media-password }
    headers: { X-Scope-OrgID: media }
    tls_config: { ca_file: /etc/secrets/hub-ca.crt }
    write_relabel_configs: []   # add cluster/environment via external_labels
```

## 2. Grafana datasources

For every tenant the chart provisions:

| Datasource | UID | URL | Auth |
|---|---|---|---|
| `Loki – <Title>` | `loki-<id>` | `https://observability-gateway…` | basic auth `<id>` + `X-Scope-OrgID: <id>` |
| `Mimir – <Title>` | `mimir-<id>` | `https://observability-gateway…/prometheus` | same |

Passwords and the CA are not stored in the provisioning file. They are read
at load time via `$__file{/etc/grafana/tenants/<id>}` and
`$__file{/etc/grafana/hub-ca/ca.crt}`. Datasources are read-only in the UI.

## 3. Grafana users and role-based access

* The admin credentials are in Secret `observability-grafana-admin` (generated).
* Sign-up and anonymous access are disabled, and new users default to Viewer.
* The `observability-grafana-access` Job runs on every install/upgrade and:
  * creates one **team per tenant**,
  * gives each tenant folder (e.g. *Media*) to that tenant's team only, with
    `tenantFolderPermission` = View/Edit/Admin (org Admins always have access),
  * limits the alert folder to Admins,
  * creates the users from `grafanaAccess.users`, sets their org role and
    team membership. Passwords go to Secret `observability-grafana-users`
    (key = login) unless `password` is given.

```yaml
grafanaAccess:
  users:
    - { login: media-viewer, email: media@example.com, orgRole: Viewer, teams: [media] }
    - { login: platform-admin, email: ops@example.com, orgRole: Admin, teams: [platform] }
```

### Strict separation: `grafanaAccess.isolation`

| Mode | What a tenant user can reach |
|---|---|
| `folders` (default) | One Grafana organisation; the user only sees their tenant's dashboard folder. Grafana OSS can't hide datasources, so a determined user could still query another tenant's datasource through the API. |
| `orgs` (used locally, recommended) | Every tenant also gets its **own Grafana organisation** containing only its two datasources and its dashboards. Tenant users are members of their tenant organisation(s) only, so other tenants' datasources don't exist for them. Platform users (team `platform` or `orgRole: Admin`) stay in the main organisation, which still has everything. |

In `orgs` mode the bootstrap Job also creates the organisations, upserts the
tenant datasources (password + CA from the mounted Secrets) and imports the
tenant's dashboards into a folder inside the organisation. It runs on every
upgrade, so dashboards stay in sync with the chart.

Verified locally: `media-viewer` sees only the Media organisation, its two
datasources and three dashboards. `mimir-jitsi` returns 404, and forcing the
main or Jitsi organisation returns 403.

In both modes the gateway still guarantees that each datasource can only reach its own tenant.

### SSO (recommended for production)

Enable an OAuth provider in `grafana.grafana.ini` and map groups to roles, for example Google:

```yaml
grafana:
  grafana.ini:
    auth.google:
      enabled: true
      client_id: $__file{/etc/secrets/google/client_id}
      client_secret: $__file{/etc/secrets/google/client_secret}
      allowed_domains: aauti.com
      allow_sign_up: true
    auth.generic_oauth:     # or Azure AD / Keycloak via generic OAuth
      role_attribute_path: contains(groups[*], 'obs-admins') && 'Admin' || 'Viewer'
  extraSecretMounts:
    - { name: google, secretName: grafana-google-oauth, mountPath: /etc/secrets/google, readOnly: true }
```

When you override `extraSecretMounts`, keep the two default entries
(`tenant-credentials`, `hub-ca`). Helm replaces lists rather than merging them.
Team membership can then be synced by the provider (Enterprise team sync) or
managed with `grafanaAccess.users` for local accounts.
