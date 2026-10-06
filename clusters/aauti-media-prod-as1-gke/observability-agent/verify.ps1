# Read-only checks after deploy.ps1: private path, TLS, auth, data in Grafana.
# Changes nothing on either cluster. Usage: ./verify.ps1
param(
  [string] $HubContext = "gke_aauti-hub_asia-south1-a_aauti-hub-as1-obs-gke",
  [string] $SpokeContext = "gke_aauti-media-prod_asia-south1_aauti-media-prod-as1-gke",
  [string] $Namespace = "observability-agent-mediaprod",
  [string] $Release = "observability-agent-mediaprod",
  [string] $Tenant = "media-prod",
  [string] $Cluster = "aauti-media-prod-as1-gke",
  [string] $GatewayIp = "10.40.16.10",
  [string] $GrafanaUrl = "https://grafana.aauti.ai"
)
$fail = 0
function Check($ok, $msg) {
  if ($ok) { Write-Host "PASS  $msg" -ForegroundColor Green } else { Write-Host "FAIL  $msg" -ForegroundColor Red; $script:fail++ }
}
function In-Cidr($ip, $cidr) {
  $net, $bits = $cidr -split "/"
  $toInt = { param($a) $b = ([Net.IPAddress]$a).GetAddressBytes(); [Array]::Reverse($b); [BitConverter]::ToUInt32($b, 0) }
  $mask = [uint32]([math]::Pow(2, 32) - [math]::Pow(2, 32 - [int]$bits))
  return ((& $toInt $ip) -band $mask) -eq ((& $toInt $net) -band $mask)
}

Write-Host "== Private network path"
foreach ($p in @(@("aauti-hub", "aauti-hub-vpc", "hub-to-media-prod"), @("aauti-media-prod", "aauti-media-prod-vpc", "media-prod-to-hub"))) {
  $state = (gcloud compute networks peerings list --network $p[1] --project $p[0] --format=json | ConvertFrom-Json).peerings |
    Where-Object name -eq $p[2] | ForEach-Object state
  Check ($state -eq "ACTIVE") "VPC peering $($p[2]) is ACTIVE ($state)"
}
$fr = gcloud compute forwarding-rules list --project aauti-hub --filter="IPAddress=$GatewayIp" --format=json | ConvertFrom-Json
Check ($fr -and $fr[0].loadBalancingScheme -eq "INTERNAL") "gateway LB $GatewayIp is INTERNAL (scheme: $($fr[0].loadBalancingScheme))"
$pub = gcloud compute forwarding-rules list --project aauti-hub --format="value(IPAddress,target)" | Select-String "observability-gateway"
Check (-not $pub) "no external forwarding rule exposes the gateway"
$cfg = kubectl --context $SpokeContext -n $Namespace get configmap $Release-config -o jsonpath="{.data.config\.alloy}"
$urls = [regex]::Matches($cfg, 'url\s*=\s*"([^"]+)"') | ForEach-Object { $_.Groups[1].Value }
Check ($urls.Count -ge 2 -and -not ($urls | Where-Object { $_ -notlike "https://$GatewayIp/*" })) "agent sends only to https://$GatewayIp ($($urls -join ', '))"

Write-Host "`n== TLS + authentication"
Check ($cfg -notmatch "insecure_skip_verify\s*=\s*true") "agent verifies the hub certificate (no insecure_skip_verify)"
Check ($cfg -match 'server_name\s*=\s*"observability-gateway.observability.svc"' -and $cfg -match "ca_file") "agent pins hub CA + SNI observability-gateway.observability.svc"
$agentLog = kubectl --context $SpokeContext -n $Namespace logs statefulset/$Release-alloy --since=15m 2>&1 | Out-String
foreach ($pat in @("x509", "certificate", "status=401", "status=403", "status=429", "connection refused", "i/o timeout")) {
  $n = ([regex]::Matches($agentLog, [regex]::Escape($pat))).Count
  Check ($n -eq 0) "agent log (15m) has no '$pat' errors ($n)"
}
$gw = kubectl --context $HubContext -n observability logs deploy/observability-gateway --since=10m 2>&1 |
  Select-String "tenant=`"$Tenant`".*path=`"[^`"]*/push`""   # ingest only; Grafana's queries come from the hub's own pods
Check ($gw.Count -gt 0) "hub gateway received $($gw.Count) authenticated '$Tenant' push requests in 10m (TLS listener 8443)"
$clients = $gw | ForEach-Object { if ($_ -match "client=(\S+)") { $Matches[1] } } | Sort-Object -Unique
$foreign = $clients | Where-Object { -not ((In-Cidr $_ "10.36.0.0/24") -or (In-Cidr $_ "10.37.0.0/17")) }
Check ($clients -and -not $foreign) "all '$Tenant' requests come from media-prod private ranges ($($clients -join ', '))"
$codes = $gw | ForEach-Object { if ($_ -match "status=(\d+)") { $Matches[1] } } | Group-Object | ForEach-Object { "$($_.Name)x$($_.Count)" }
Check (-not ($codes -match "^(4|5)")) "gateway status codes for '$Tenant': $($codes -join ' ')"

Write-Host "`n== Data in Grafana ($GrafanaUrl)"
$pw = kubectl --context $HubContext -n grafana get secret grafana-admin -o jsonpath="{.data.admin-password}"
$cred = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("admin:" + [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($pw))))
$h = @{ Authorization = "Basic $cred" }
$q = { param($uid, $path, $query) Invoke-RestMethod -Headers $h -Uri "$GrafanaUrl/api/datasources/proxy/uid/$uid/$path`?query=$([uri]::EscapeDataString($query))" }
try {
  $m = & $q "mimir-$Tenant" "api/v1/query" "count by (environment, namespace) ({cluster=`"$Cluster`"})"
  $ns = $m.data.result | ForEach-Object { "$($_.metric.namespace)=$($_.value[1])" }
  Check ($m.data.result.Count -gt 0) "metrics: series per namespace: $($ns -join ' ')"
  Check (($m.data.result.metric.environment | Sort-Object -Unique) -contains "prod") "metrics carry environment=prod (all: $(($m.data.result.metric.environment | Sort-Object -Unique) -join ','))"
  $t = & $q "mimir-$Tenant" "api/v1/query" "count({cluster=`"$Cluster`", tier=`"prod`"})"
  Check ($t.data.result.Count -gt 0) "metrics carry tier=prod"
  $l = & $q "loki-$Tenant" "loki/api/v1/query" "sum by (environment, namespace) (count_over_time({cluster=`"$Cluster`"}[10m]))"
  $lns = $l.data.result | ForEach-Object { "$($_.metric.namespace)=$($_.value[1])" }
  Check ($l.data.result.Count -gt 0) "logs: lines per namespace (10m): $($lns -join ' ')"
  Check (($l.data.result.metric.environment | Sort-Object -Unique) -contains "prod") "logs carry environment=prod (all: $(($l.data.result.metric.environment | Sort-Object -Unique) -join ','))"
} catch { Check $false "Grafana query failed: $($_.Exception.Message)" }

Write-Host ""
if ($fail) { Write-Host "$fail check(s) failed" -ForegroundColor Red; exit 1 } else { Write-Host "all checks passed" -ForegroundColor Green }
