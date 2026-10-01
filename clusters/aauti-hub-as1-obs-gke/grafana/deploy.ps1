# Deploys standalone Grafana to aauti-hub-as1-obs-gke at https://grafana.aauti.ai
# Usage: ./deploy.ps1
param(
  [string] $Project = "aauti-hub",
  [string] $Cluster = "aauti-hub-as1-obs-gke",
  [string] $Zone = "asia-south1-a",
  [string] $Namespace = "grafana"
)
$ErrorActionPreference = "Stop"

gcloud container clusters get-credentials $Cluster --zone $Zone --project $Project
$ctx = kubectl config current-context
Write-Host "Using context $ctx"

# Pre-reserved global static IP used by the Ingress.
$ip = gcloud compute addresses describe aauti-hub-vpc-as1-grafana-ip --global --project $Project --format="value(address)"

kubectl create namespace $Namespace --dry-run=client -o yaml | kubectl apply -f -

# Admin secret: created once, never rotated by re-running this script.
kubectl -n $Namespace get secret grafana-admin *> $null
if ($LASTEXITCODE -ne 0) {
  $pw = -join ((48..57) + (65..90) + (97..122) | Get-Random -Count 24 | ForEach-Object { [char]$_ })
  kubectl -n $Namespace create secret generic grafana-admin --from-literal=admin-user=admin --from-literal=admin-password=$pw
}

# Tenants that have datasources in values.yaml (password key per tenant).
$tenants = @("platform", "jitsi", "media")

# Datasource credentials: copy each tenant password + the gateway CA from the
# observability namespace (Secrets can't be read across namespaces). Re-running
# picks up rotations.
$b64 = { param($s, $k) kubectl -n observability get secret $s -o jsonpath="{.data.$k}" }
$caB64 = & $b64 observability-hub-ca 'ca\.crt'
if (-not $caB64) { throw "observability release not found - deploy ../observability first" }
$data = "  ca.crt: $caB64"
foreach ($t in $tenants) {
  $pwB64 = & $b64 observability-tenant-credentials $t
  if (-not $pwB64) { throw "tenant '$t' has no password yet - add it to ../observability/values.yaml and deploy that first" }
  $data += "`n  ${t}: $pwB64"
}
@"
apiVersion: v1
kind: Secret
metadata: { name: grafana-hub-datasource, namespace: $Namespace }
type: Opaque
data:
$data
"@ | kubectl apply -f -
if ($LASTEXITCODE -ne 0) { throw "creating grafana-hub-datasource failed" }

# Dashboards: ConfigMap grafana-dashboards-<tenant> per provider in values.yaml,
# rendered from the chart's dashboard templates with the tenant's datasource UIDs.
$dashDir = Resolve-Path "$PSScriptRoot/../../../charts/observability-stack/dashboards"
$dashboards = @{
  jitsi = @{ title = "Jitsi-nonprod"; environments = "dev,qa,demo,sandbox,shared"; shared = @("workloads-logs") }   # cluster-health / resource-usage: Jitsi variants in dashboards/tenants/jitsi (+ per-environment rows)
  media = @{ title = "Media-nonprod"; environments = "dev,qa,demo,sandbox,uat,staging"; shared = @("cluster-health", "resource-usage", "workloads-logs") }
}
foreach ($t in $dashboards.Keys) {
  $tmp = Join-Path ([IO.Path]::GetTempPath()) "grafana-dashboards-$t"
  Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
  New-Item -ItemType Directory $tmp | Out-Null
  $files = @($dashboards[$t].shared | ForEach-Object { Get-Item "$dashDir/$_.json" })
  $files += @(Get-ChildItem "$dashDir/tenants/$t" -Filter *.json -ErrorAction SilentlyContinue)
  foreach ($f in $files) {
    $json = [IO.File]::ReadAllText($f.FullName).
      Replace("__METRICS_DS__", "mimir-$t").Replace("__LOGS_DS__", "loki-$t").
      Replace("__TENANT_TITLE__", $dashboards[$t].title).Replace("__TENANT__", $t).
      Replace("__ENVIRONMENTS__", $dashboards[$t].environments)
    [IO.File]::WriteAllText((Join-Path $tmp "$t-$($f.Name)"), $json)
  }
  # Server-side apply: dashboards exceed the client-side last-applied annotation limit.
  $before = kubectl -n $Namespace get configmap "grafana-dashboards-$t" -o jsonpath="{.metadata.resourceVersion}" 2>$null
  kubectl -n $Namespace create configmap "grafana-dashboards-$t" --from-file=$tmp --dry-run=client -o yaml |
    kubectl apply --server-side --force-conflicts -f -
  if ($LASTEXITCODE -ne 0) { throw "creating grafana-dashboards-$t failed" }
  $after = kubectl -n $Namespace get configmap "grafana-dashboards-$t" -o jsonpath="{.metadata.resourceVersion}"
  if ($before -and $before -ne $after) { $dashboardsChanged = $true }
  Remove-Item -Recurse -Force $tmp
}

# Chart is vendored next to this script (github.com is not reachable over the office VPN).
helm upgrade --install grafana "$PSScriptRoot/grafana-10.5.15.tgz" --kube-context $ctx `
  -n $Namespace -f "$PSScriptRoot/values.yaml" --wait --timeout 10m
if ($LASTEXITCODE -ne 0) { throw "helm install failed" }

# Mounted ConfigMap updates reach the pod only after the kubelet sync (~1-2 min);
# restart so changed dashboards show up immediately.
if ($dashboardsChanged) {
  kubectl -n $Namespace rollout restart deploy/grafana
  kubectl -n $Namespace rollout status deploy/grafana --timeout 5m
}

Write-Host ""
Write-Host "Static IP: $ip  -> create Cloudflare A record 'grafana' -> $ip (DNS only / grey cloud)"
Write-Host "Cert status: kubectl -n $Namespace get managedcertificate grafana-cert"
