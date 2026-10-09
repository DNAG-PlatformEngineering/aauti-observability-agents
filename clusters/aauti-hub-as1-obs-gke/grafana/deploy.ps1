# Deploys standalone Grafana to aauti-hub-as1-obs-gke at https://grafana.aauti.ai
# Usage: ./deploy.ps1
#        ./deploy.ps1 -AlertEmails "a@aauti.com;b@aauti.com" -SmtpUser alerts@aauti.com
#          (first time, or to change recipients / sender; prompts for the SMTP password)
param(
  [string] $Project = "aauti-hub",
  [string] $Cluster = "aauti-hub-as1-obs-gke",
  [string] $Zone = "asia-south1-a",
  [string] $Namespace = "grafana",
  # Recipients of non-prod alert emails (Outlook), ";"-separated. Kept only in
  # Secret grafana-alerting-notify; empty = keep the list already stored there.
  [string] $AlertEmails = $env:ALERT_EMAILS,
  # Mailbox Grafana sends from (SMTP login and From address; host is
  # grafana.ini smtp.host in values.yaml). Kept only in Secret grafana-smtp;
  # empty = keep what is stored there.
  [string] $SmtpUser = $env:SMTP_USER,
  [string] $SmtpPassword = $env:SMTP_PASSWORD
)
$ErrorActionPreference = "Stop"

gcloud container clusters get-credentials $Cluster --zone $Zone --project $Project
if ($LASTEXITCODE -ne 0) { throw "get-credentials for $Cluster failed (VPN / gcloud login?)" }
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

# Gateway users whose password the datasources need: only the read-only
# federated user of the "Loki" / "Mimir" datasources (all tenants).
$tenants = @("grafana-reader")

# Datasource credentials: copy the reader password + the gateway CA from the
# observability namespace (Secrets can't be read across namespaces). Re-running
# picks up rotations.
$b64 = { param($s, $k) kubectl -n observability get secret $s -o jsonpath="{.data.$k}" }
$caB64 = & $b64 observability-hub-ca 'ca\.crt'
if (-not $caB64) { throw "observability release not found - deploy ../observability first" }
$data = "  ca.crt: $caB64"
foreach ($t in $tenants) {
  $pwB64 = & $b64 observability-tenant-credentials $t
  if (-not $pwB64) { throw "'$t' has no password yet - add it to ../observability/values.yaml (tenants / gateway.reader) and deploy that first" }
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
# rendered from the chart's dashboard templates on the "Loki" / "Mimir"
# datasources (all tenants). Each folder's Cluster variable lists only its own
# tenant's clusters (__tenant_id__), and "All" means exactly those clusters
# (no ".+" all-value), so every panel stays within the folder's tenant.
$dashDir = Resolve-Path "$PSScriptRoot/../../../charts/observability-stack/dashboards"
$dashboards = @{
  "jitsi-nonprod" = @{ title = "Jitsi-nonprod"; environments = "dev,qa,demo,sandbox,shared"; shared = @("workloads-logs") }   # cluster-health / resource-usage: Jitsi variants in dashboards/tenants/jitsi-nonprod (+ per-environment rows)
  # extras: tenant-specific dashboards from dashboards/tenants/<extras> (default: the tenant itself)
  "jitsi-prod" = @{ title = "Jitsi-prod"; environments = "prod"; shared = @("workloads-logs"); extras = "jitsi-nonprod" }
  "media-nonprod" = @{ title = "Media-nonprod"; environments = "dev,qa,demo,sandbox,shared"; shared = @("cluster-health", "resource-usage", "workloads-logs") }
  "media-prod" = @{ title = "Media-prod"; environments = "prod"; shared = @("cluster-health", "resource-usage", "workloads-logs") }
  "platform-nonprod" = @{ title = "Platform-nonprod"; environments = "dev,qa,demo,sandbox,shared"; shared = @("cluster-health", "resource-usage", "workloads-logs") }
  "platform-prod" = @{ title = "Platform-prod"; environments = "prod"; shared = @("cluster-health", "resource-usage", "workloads-logs") }
}
foreach ($t in $dashboards.Keys) {
  $tmp = Join-Path ([IO.Path]::GetTempPath()) "grafana-dashboards-$t"
  Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
  New-Item -ItemType Directory $tmp | Out-Null
  $files = @($dashboards[$t].shared | ForEach-Object { Get-Item "$dashDir/$_.json" })
  $extras = if ($dashboards[$t].extras) { $dashboards[$t].extras } else { $t }
  $files += @(Get-ChildItem "$dashDir/tenants/$extras" -Filter *.json -ErrorAction SilentlyContinue)
  foreach ($f in $files) {
    $json = [IO.File]::ReadAllText($f.FullName).
      Replace("__METRICS_DS__", "mimir").Replace("__LOGS_DS__", "loki").
      Replace("__TENANT_TITLE__", $dashboards[$t].title).Replace("__TENANT__", $t).
      Replace("__ENVIRONMENTS__", $dashboards[$t].environments).
      Replace('label_values(up, cluster)', "label_values(up{__tenant_id__=\`"$t\`"}, cluster)")
    $json = [regex]::Replace($json, '(?s)(label_values\(up\{__tenant_id__=[^}]*\}, cluster\)".*?)"allValue": "\.\+",\s*', '$1')
    if ($json -match 'label_values\(up, cluster\)') { throw "$($f.Name): Cluster variable not restricted to tenant $t" }
    [IO.File]::WriteAllText((Join-Path $tmp "$t-$($f.Name)"), $json)
  }
  # Server-side apply: dashboards exceed the client-side last-applied annotation limit.
  $before = kubectl -n $Namespace get configmap "grafana-dashboards-$t" -o jsonpath="{.metadata.resourceVersion}" 2>$null
  kubectl -n $Namespace create configmap "grafana-dashboards-$t" --from-file=$tmp --dry-run=client -o yaml |
    kubectl apply --server-side --force-conflicts -f -
  if ($LASTEXITCODE -ne 0) { throw "creating grafana-dashboards-$t failed" }
  $after = kubectl -n $Namespace get configmap "grafana-dashboards-$t" -o jsonpath="{.metadata.resourceVersion}"
  if ($before -and $before -ne $after) { $provisioningChanged = $true }
  Remove-Item -Recurse -Force $tmp
}

# Explore dashboard (folder Explore): dashboards/*.json as is (already on the
# "Loki" / "Mimir" datasources, all products).
$before = kubectl -n $Namespace get configmap grafana-dashboards-explore -o jsonpath="{.metadata.resourceVersion}" 2>$null
kubectl -n $Namespace create configmap grafana-dashboards-explore --from-file="$PSScriptRoot/dashboards" --dry-run=client -o yaml |
  kubectl apply --server-side --force-conflicts -f -
if ($LASTEXITCODE -ne 0) { throw "creating grafana-dashboards-explore failed" }
$after = kubectl -n $Namespace get configmap grafana-dashboards-explore -o jsonpath="{.metadata.resourceVersion}"
if ($before -and $before -ne $after) { $provisioningChanged = $true }

# Alert rules: ConfigMap grafana-alerting-rules from alerting/*.yaml.
$before = kubectl -n $Namespace get configmap grafana-alerting-rules -o jsonpath="{.metadata.resourceVersion}" 2>$null
kubectl -n $Namespace create configmap grafana-alerting-rules --from-file="$PSScriptRoot/alerting" --dry-run=client -o yaml |
  kubectl apply --server-side --force-conflicts -f -
if ($LASTEXITCODE -ne 0) { throw "creating grafana-alerting-rules failed" }
$after = kubectl -n $Namespace get configmap grafana-alerting-rules -o jsonpath="{.metadata.resourceVersion}"
if ($before -and $before -ne $after) { $provisioningChanged = $true }

# Email contact point + notification policy: Secret grafana-alerting-notify. Only
# notify.yaml is mounted; the recipients are also kept as their own key so
# re-running without -AlertEmails keeps them.
$stored = { param($secret, $key)
  $v = kubectl -n $Namespace get secret $secret -o jsonpath="{.data.$key}" 2>$null
  if ($v) { [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($v)) } }
if (-not $AlertEmails) { $AlertEmails = & $stored grafana-alerting-notify alert-emails }
$AlertEmails = (($AlertEmails -split '[;,\s]+') | Where-Object { $_ }) -join ';'
if ($AlertEmails -match '\$') { throw "alert email list must not contain '$'" }
if ($AlertEmails) {
  $notify = @"
apiVersion: 1
contactPoints:
  - orgId: 1
    name: email-nonprod
    receivers:
      - uid: email-nonprod
        type: email
        settings:
          addresses: "$AlertEmails"
          singleEmail: true
policies:
  - orgId: 1
    receiver: email-nonprod
    group_by: [grafana_folder, alertname, cluster, environment, namespace]
    group_wait: 30s
    group_interval: 5m
    repeat_interval: 4h
"@
} else {
  Write-Warning "No alert recipients (-AlertEmails or ALERT_EMAILS): alert rules are loaded but notifications go nowhere."
  $notify = "apiVersion: 1`n"
}

# SMTP login: Secret grafana-smtp, read by Grafana as GF_SMTP_USER /
# GF_SMTP_PASSWORD / GF_SMTP_FROM_ADDRESS (values.yaml envValueFrom).
$storedSmtpUser = & $stored grafana-smtp user
if (-not $SmtpUser) { $SmtpUser = $storedSmtpUser }
# Reuse the stored password only for the same mailbox; a new mailbox prompts below.
if ($SmtpUser -and -not $SmtpPassword -and $SmtpUser -eq $storedSmtpUser) { $SmtpPassword = & $stored grafana-smtp password }
if ($SmtpUser -and -not $SmtpPassword) {
  $sec = Read-Host "SMTP password for $SmtpUser" -AsSecureString
  $SmtpPassword = [Net.NetworkCredential]::new("", $sec).Password
}
if ($AlertEmails -and -not $SmtpUser) { Write-Warning "No SMTP mailbox (-SmtpUser): Grafana can't send the alert emails yet." }

$tmp = Join-Path ([IO.Path]::GetTempPath()) "grafana-alerting-$([guid]::NewGuid())"
New-Item -ItemType Directory $tmp | Out-Null
try {
  [IO.File]::WriteAllText("$tmp/notify.yaml", $notify)
  [IO.File]::WriteAllText("$tmp/alert-emails", $AlertEmails)
  $before = kubectl -n $Namespace get secret grafana-alerting-notify -o jsonpath="{.metadata.resourceVersion}" 2>$null
  kubectl -n $Namespace create secret generic grafana-alerting-notify --from-file="$tmp/notify.yaml" `
    --from-file="$tmp/alert-emails" --dry-run=client -o yaml | kubectl apply -f -
  if ($LASTEXITCODE -ne 0) { throw "creating grafana-alerting-notify failed" }
  $after = kubectl -n $Namespace get secret grafana-alerting-notify -o jsonpath="{.metadata.resourceVersion}"
  if ($before -and $before -ne $after) { $provisioningChanged = $true }

  if ($SmtpUser) {
    [IO.File]::WriteAllText("$tmp/user", $SmtpUser)
    [IO.File]::WriteAllText("$tmp/password", $SmtpPassword)
    $before = kubectl -n $Namespace get secret grafana-smtp -o jsonpath="{.metadata.resourceVersion}" 2>$null
    kubectl -n $Namespace create secret generic grafana-smtp --from-file="$tmp/user" --from-file="$tmp/password" `
      --dry-run=client -o yaml | kubectl apply -f -
    if ($LASTEXITCODE -ne 0) { throw "creating grafana-smtp failed" }
    $after = kubectl -n $Namespace get secret grafana-smtp -o jsonpath="{.metadata.resourceVersion}"
    # env vars are only read at start-up: restart on a change and on first creation
    if ($before -ne $after) { $provisioningChanged = $true }
  }
} finally {
  Remove-Item -Recurse -Force $tmp
}

# Chart is vendored next to this script (github.com is not reachable over the office VPN).
helm upgrade --install grafana "$PSScriptRoot/grafana-10.5.15.tgz" --kube-context $ctx `
  -n $Namespace -f "$PSScriptRoot/values.yaml" --wait --timeout 10m
if ($LASTEXITCODE -ne 0) { throw "helm install failed" }

# Mounted ConfigMap updates reach the pod only after the kubelet sync (~1-2 min),
# and alerting provisioning is only read at start-up: restart so changed
# dashboards / alert rules / contact points take effect immediately.
if ($provisioningChanged) {
  kubectl -n $Namespace rollout restart deploy/grafana
  if ($LASTEXITCODE -ne 0) { throw "restarting grafana failed" }
  kubectl -n $Namespace rollout status deploy/grafana --timeout 5m
  if ($LASTEXITCODE -ne 0) { throw "grafana rollout did not finish within 5m" }
}

Write-Host ""
Write-Host "Static IP: $ip  -> create Cloudflare A record 'grafana' -> $ip (DNS only / grey cloud)"
Write-Host "Cert status: kubectl -n $Namespace get managedcertificate grafana-cert"
