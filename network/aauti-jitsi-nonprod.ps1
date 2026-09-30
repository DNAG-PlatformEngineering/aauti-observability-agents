# Private network path aauti-jitsi-nonprod-gke -> hub observability gateway.
#
#   spoke VPC aauti-jitsi-nonprod-vpc (project aauti-jitsi-noprod)
#     10.16.0.0/24 nodes, 10.17.0.0/17 pods, 10.18.0.0/22 services
#        |  VPC peering jitsi-nonprod-to-hub <-> hub-to-jitsi-nonprod
#   hub VPC aauti-hub-vpc (project aauti-hub)
#     10.40.16.10  internal LB observability-gateway-internal (ingest subnet)
#
# Same pattern as the existing hub-to-media-* / hub-to-platform-* peerings.
# No public IP, no Cloud NAT, no internet path is involved. Ranges were checked
# for overlap against the hub and every VPC already peered with it.
#
# Idempotent: every step checks first. Needs compute.networkAdmin on both
# projects. Usage: ./aauti-jitsi-nonprod.ps1  [-WhatIf]
[CmdletBinding(SupportsShouldProcess)]
param(
  [string] $HubProject = "aauti-hub",
  [string] $HubNetwork = "aauti-hub-vpc",
  [string] $SpokeProject = "aauti-jitsi-noprod",
  [string] $SpokeNetwork = "aauti-jitsi-nonprod-vpc",
  [string] $Region = "asia-south1",
  [string] $IngestSubnet = "aauti-hub-vpc-as1-ingest-subnet",
  [string] $GatewayIpName = "aauti-hub-vpc-as1-obs-gateway-ilb",
  [string] $GatewayIp = "10.40.16.10"
)
$ErrorActionPreference = "Stop"

function Test-Peering($project, $network, $name) {
  $names = gcloud compute networks peerings list --network $network --project $project --format="value(peerings[].name)"
  return (($names -split "[;,\s]+") -contains $name)
}

# 1. Static internal IP for the gateway's internal load balancer (hub).
$existing = gcloud compute addresses list --project $HubProject --filter="name=$GatewayIpName" --format="value(address)"
if ($existing) {
  if ($existing -ne $GatewayIp) { throw "$GatewayIpName exists with $existing, expected $GatewayIp" }
  Write-Host "ok   address $GatewayIpName = $existing"
} elseif ($PSCmdlet.ShouldProcess("$HubProject/$GatewayIpName", "reserve internal IP $GatewayIp")) {
  gcloud compute addresses create $GatewayIpName --project $HubProject --region $Region `
    --subnet $IngestSubnet --addresses $GatewayIp --purpose GCE_ENDPOINT `
    --description "observability-gateway internal LB (spoke ingest)"
  if ($LASTEXITCODE -ne 0) { throw "reserving $GatewayIp failed" }
}

# 2. Peering, hub side (same flags as hub-to-media-nonprod).
if (Test-Peering $HubProject $HubNetwork "hub-to-jitsi-nonprod") {
  Write-Host "ok   peering hub-to-jitsi-nonprod"
} elseif ($PSCmdlet.ShouldProcess("$HubProject/$HubNetwork", "peer with $SpokeProject/$SpokeNetwork")) {
  gcloud compute networks peerings create hub-to-jitsi-nonprod --project $HubProject `
    --network $HubNetwork --peer-project $SpokeProject --peer-network $SpokeNetwork `
    --export-custom-routes --import-custom-routes
  if ($LASTEXITCODE -ne 0) { throw "creating hub-to-jitsi-nonprod failed" }
}

# 3. Peering, spoke side (same flags as media-nonprod-to-hub). This only adds a
#    peering to the VPC; nothing inside the GKE cluster changes.
if (Test-Peering $SpokeProject $SpokeNetwork "jitsi-nonprod-to-hub") {
  Write-Host "ok   peering jitsi-nonprod-to-hub"
} elseif ($PSCmdlet.ShouldProcess("$SpokeProject/$SpokeNetwork", "peer with $HubProject/$HubNetwork")) {
  gcloud compute networks peerings create jitsi-nonprod-to-hub --project $SpokeProject `
    --network $SpokeNetwork --peer-project $HubProject --peer-network $HubNetwork `
    --export-custom-routes --import-custom-routes
  if ($LASTEXITCODE -ne 0) { throw "creating jitsi-nonprod-to-hub failed" }
}

# 4. Show state. Both peerings must be ACTIVE.
gcloud compute networks peerings list --network $HubNetwork --project $HubProject --format="table(peerings[].name,peerings[].state)"
gcloud compute networks peerings list --network $SpokeNetwork --project $SpokeProject --format="table(peerings[].name,peerings[].state)"

# Firewall: nothing to add by hand. GKE creates the ingress rule for the
# internal LB from loadBalancerSourceRanges in
# clusters/aauti-hub-as1-obs-gke/observability/gateway-internal-lb.yaml
# (10.16.0.0/24, 10.17.0.0/17 -> tcp:443/8443 on the hub obs nodes).
# Spoke egress is allowed by default.
