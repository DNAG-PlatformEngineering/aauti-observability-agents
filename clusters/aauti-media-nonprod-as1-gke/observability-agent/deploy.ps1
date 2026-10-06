# Installs the observability agent (Alloy + kube-state-metrics) on
# aauti-media-nonprod-as1-gke, namespace "observability-agent-medianonprod",
# shipping logs and metrics to the hub (tenant "media-nonprod") over the private VPC
# peering.
#
# Prerequisites, in order (see ../README.md):
#   1. VPC peering media-nonprod-to-hub / hub-to-media-nonprod (already ACTIVE)
#   2. ../../aauti-hub-as1-obs-gke/observability/deploy.ps1  (tenant media-nonprod + internal LB)
#   3. ../../aauti-hub-as1-obs-gke/grafana/deploy.ps1        (datasources + dashboards)
#
# Only creates new objects in the new namespace observability-agent-medianonprod
# (plus the agent's ClusterRole/Binding for read access). Existing workloads
# are not modified.
# Usage: ./deploy.ps1          (run from the office network / VPN)
param(
  [string] $HubContext = "gke_aauti-hub_asia-south1-a_aauti-hub-as1-obs-gke",
  [string] $SpokeContext = "gke_aauti-media-nonprod_asia-south1-a_aauti-media-nonprod-as1-gke",
  [string] $Namespace = "observability-agent-medianonprod",
  [string] $Release = "observability-agent-medianonprod",
  [string] $Tenant = "media-nonprod",
  [string] $GatewayIp = "10.40.16.10"
)
$ErrorActionPreference = "Stop"
$chart = Resolve-Path "$PSScriptRoot/../../../charts/observability-stack"

# --- preflight: private path must exist before anything is installed --------
$peer = gcloud compute networks peerings list --network aauti-media-nonprod-vpc --project aauti-media-nonprod `
  --format="csv[no-heading](peerings[].name,peerings[].state)" | Out-String
if ($peer -notmatch "media-nonprod-to-hub") { throw "VPC peering media-nonprod-to-hub missing" }
$lbIp = kubectl --context $HubContext -n observability get svc observability-gateway-internal -o jsonpath="{.status.loadBalancer.ingress[0].ip}"
if ($lbIp -ne $GatewayIp) { throw "hub internal LB not ready (got '$lbIp', want $GatewayIp) - deploy hub observability first" }
$ranges = kubectl --context $HubContext -n observability get svc observability-gateway-internal -o jsonpath="{.spec.loadBalancerSourceRanges}"
if ($ranges -notmatch "10\.33\.0\.0/17") { throw "hub internal LB does not allow this cluster's pod range - deploy hub observability first" }

# --- credentials from the hub (never written to the repo) -------------------
$pwB64 = kubectl --context $HubContext -n observability get secret observability-tenant-credentials -o jsonpath="{.data.$Tenant}"
$caB64 = kubectl --context $HubContext -n observability get secret observability-hub-ca -o jsonpath="{.data.ca\.crt}"
if (-not $pwB64) { throw "tenant '$Tenant' not found on the hub - deploy hub observability first" }
if (-not $caB64) { throw "hub CA not found" }

# Forward slashes: helm --set-file treats backslashes as escapes.
$tmp = (Join-Path ([IO.Path]::GetTempPath()) "obs-agent-$([guid]::NewGuid())") -replace '\\', '/'
New-Item -ItemType Directory $tmp | Out-Null
try {
  [IO.File]::WriteAllBytes("$tmp/password", [Convert]::FromBase64String($pwB64))
  [IO.File]::WriteAllBytes("$tmp/hub-ca.crt", [Convert]::FromBase64String($caB64))

  kubectl --context $SpokeContext create namespace $Namespace --dry-run=client -o yaml |
    kubectl --context $SpokeContext apply -f -
  kubectl --context $SpokeContext -n $Namespace create secret generic $Release-auth `
    --from-file=password="$tmp/password" --dry-run=client -o yaml |
    kubectl --context $SpokeContext apply -f -
  if ($LASTEXITCODE -ne 0) { throw "creating $Release-auth failed" }

  # Sub-charts are vendored in $chart/charts (github.com is not reachable over the office VPN).
  helm upgrade --install $Release $chart --kube-context $SpokeContext -n $Namespace `
    -f "$chart/profiles/spoke.yaml" -f "$PSScriptRoot/values.yaml" `
    --set-file agent.tls.caCert="$tmp/hub-ca.crt" --wait --timeout 10m
  if ($LASTEXITCODE -ne 0) { throw "helm install failed" }
} finally {
  Remove-Item -Recurse -Force $tmp
}

# Password changes (rotation) are only read at start-up.
kubectl --context $SpokeContext -n $Namespace rollout restart statefulset/$Release-alloy
kubectl --context $SpokeContext -n $Namespace rollout status statefulset/$Release-alloy --timeout 5m
kubectl --context $SpokeContext -n $Namespace get pods -o wide
Write-Host "`nNext: ./verify.ps1"
