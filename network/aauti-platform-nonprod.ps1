# Private network path aauti-platform-nonprod-as1-gke -> hub observability gateway.
#
#   spoke VPC aauti-nonprod-vpc (project aauti-platform-noprod)
#     asia-south1 subnet aauti-nonprod-vpc-as1-gke-subnet:
#     10.4.0.0/24 nodes, 10.5.0.0/17 pods, 10.6.0.0/22 services
#        |  VPC peering platform-nonprod-to-hub <-> hub-to-platform-nonprod
#   hub VPC aauti-hub-vpc (project aauti-hub)
#     10.40.16.10  internal LB observability-gateway-internal (ingest subnet)
#
# The peering existed before the observability setup (it is not created by
# this repo); on the current state every step only prints "ok". Kept so the
# path is documented and can be recreated the same way as jitsi-nonprod's.
# The VPC also holds the us-central1 cluster aauti-nonprod-gke, which is
# not onboarded.
#
# Idempotent: every step checks first. Needs compute.networkAdmin on both
# projects to create anything. Usage: ./aauti-platform-nonprod.ps1  [-WhatIf]
[CmdletBinding(SupportsShouldProcess)]
param(
  [string] $HubProject = "aauti-hub",
  [string] $HubNetwork = "aauti-hub-vpc",
  [string] $SpokeProject = "aauti-platform-noprod",
  [string] $SpokeNetwork = "aauti-nonprod-vpc",
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
if (Test-Peering $HubProject $HubNetwork "hub-to-platform-nonprod") {
  Write-Host "ok   peering hub-to-platform-nonprod"
} elseif ($PSCmdlet.ShouldProcess("$HubProject/$HubNetwork", "peer with $SpokeProject/$SpokeNetwork")) {
  gcloud compute networks peerings create hub-to-platform-nonprod --project $HubProject `
    --network $HubNetwork --peer-project $SpokeProject --peer-network $SpokeNetwork `
    --export-custom-routes --import-custom-routes
  if ($LASTEXITCODE -ne 0) { throw "creating hub-to-platform-nonprod failed" }
}

# 3. Peering, spoke side. This only adds a peering to the VPC; nothing inside
#    the GKE cluster changes.
if (Test-Peering $SpokeProject $SpokeNetwork "platform-nonprod-to-hub") {
  Write-Host "ok   peering platform-nonprod-to-hub"
} elseif ($PSCmdlet.ShouldProcess("$SpokeProject/$SpokeNetwork", "peer with $HubProject/$HubNetwork")) {
  gcloud compute networks peerings create platform-nonprod-to-hub --project $SpokeProject `
    --network $SpokeNetwork --peer-project $HubProject --peer-network $HubNetwork `
    --export-custom-routes --import-custom-routes
  if ($LASTEXITCODE -ne 0) { throw "creating platform-nonprod-to-hub failed" }
}

# 4. Show state. Both peerings must be ACTIVE.
gcloud compute networks peerings list --network $HubNetwork --project $HubProject --format="table(peerings[].name,peerings[].state)"
gcloud compute networks peerings list --network $SpokeNetwork --project $SpokeProject --format="table(peerings[].name,peerings[].state)"

# Firewall: nothing to add by hand. GKE creates the ingress rule for the
# internal LB from loadBalancerSourceRanges in
# clusters/aauti-hub-as1-obs-gke/observability/gateway-internal-lb.yaml
# (10.4.0.0/24, 10.5.0.0/17 -> tcp:443/8443 on the hub obs nodes).
# Same region as the LB (asia-south1), so no global access is needed.
# Spoke egress is allowed by default.
