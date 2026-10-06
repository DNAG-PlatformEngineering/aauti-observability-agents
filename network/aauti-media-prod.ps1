# Private network path aauti-media-prod-as1-gke -> hub observability gateway.
#
#   spoke VPC aauti-media-prod-vpc (project aauti-media-prod)
#     asia-south1 subnet (regional cluster) aauti-media-prod-vpc-as1-gke-subnet:
#     10.36.0.0/24 nodes, 10.37.0.0/17 pods, 10.38.0.0/22 services
#        |  VPC peering media-prod-to-hub <-> hub-to-media-prod
#   hub VPC aauti-hub-vpc (project aauti-hub)
#     10.40.16.10  internal LB observability-gateway-internal (ingest subnet)
#
# The peering existed before the observability setup (it is not created by
# this repo); on the current state every step only prints "ok". Kept so the
# path is documented and can be recreated the same way as jitsi-nonprod's.
#
# Idempotent: every step checks first. Needs compute.networkAdmin on both
# projects to create anything. Usage: ./aauti-media-prod.ps1  [-WhatIf]
[CmdletBinding(SupportsShouldProcess)]
param(
  [string] $HubProject = "aauti-hub",
  [string] $HubNetwork = "aauti-hub-vpc",
  [string] $SpokeProject = "aauti-media-prod",
  [string] $SpokeNetwork = "aauti-media-prod-vpc",
  [string] $GatewayIpName = "aauti-hub-vpc-as1-obs-gateway-ilb",
  [string] $GatewayIp = "10.40.16.10"
)
$ErrorActionPreference = "Stop"

function Test-Peering($project, $network, $name) {
  $names = gcloud compute networks peerings list --network $network --project $project --format="value(peerings[].name)"
  return (($names -split "[;,\s]+") -contains $name)
}

# 1. Static internal IP of the gateway's internal load balancer (hub). Shared by
#    all spokes; reserved by ./aauti-jitsi-nonprod.ps1.
$existing = gcloud compute addresses list --project $HubProject --filter="name=$GatewayIpName" --format="value(address)"
if ($existing -ne $GatewayIp) { throw "$GatewayIpName missing or not $GatewayIp (got '$existing') - run ./aauti-jitsi-nonprod.ps1 first" }
Write-Host "ok   address $GatewayIpName = $existing"

# 2. Peering, hub side.
if (Test-Peering $HubProject $HubNetwork "hub-to-media-prod") {
  Write-Host "ok   peering hub-to-media-prod"
} elseif ($PSCmdlet.ShouldProcess("$HubProject/$HubNetwork", "peer with $SpokeProject/$SpokeNetwork")) {
  gcloud compute networks peerings create hub-to-media-prod --project $HubProject `
    --network $HubNetwork --peer-project $SpokeProject --peer-network $SpokeNetwork `
    --export-custom-routes --import-custom-routes
  if ($LASTEXITCODE -ne 0) { throw "creating hub-to-media-prod failed" }
}

# 3. Peering, spoke side. This only adds a peering to the VPC; nothing inside
#    the GKE cluster changes.
if (Test-Peering $SpokeProject $SpokeNetwork "media-prod-to-hub") {
  Write-Host "ok   peering media-prod-to-hub"
} elseif ($PSCmdlet.ShouldProcess("$SpokeProject/$SpokeNetwork", "peer with $HubProject/$HubNetwork")) {
  gcloud compute networks peerings create media-prod-to-hub --project $SpokeProject `
    --network $SpokeNetwork --peer-project $HubProject --peer-network $HubNetwork `
    --export-custom-routes --import-custom-routes
  if ($LASTEXITCODE -ne 0) { throw "creating media-prod-to-hub failed" }
}

# 4. Show state. Both peerings must be ACTIVE.
gcloud compute networks peerings list --network $HubNetwork --project $HubProject --format="table(peerings[].name,peerings[].state)"
gcloud compute networks peerings list --network $SpokeNetwork --project $SpokeProject --format="table(peerings[].name,peerings[].state)"

# Firewall: nothing to add by hand. GKE creates the ingress rule for the
# internal LB from loadBalancerSourceRanges in
# clusters/aauti-hub-as1-obs-gke/observability/gateway-internal-lb.yaml
# (10.36.0.0/24, 10.37.0.0/17 -> tcp:443/8443 on the hub obs nodes).
# Same region as the LB (asia-south1), so no global access is needed.
# Spoke egress is allowed by default.
