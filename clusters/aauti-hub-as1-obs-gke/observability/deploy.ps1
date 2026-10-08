# Deploys the observability backends (MinIO, Loki, Mimir, gateway, Alloy,
# kube-state-metrics) to aauti-hub-as1-obs-gke, namespace "observability".
# Usage: ./deploy.ps1          (run from the office network / VPN)
param(
  [string] $Project = "aauti-hub",
  [string] $Cluster = "aauti-hub-as1-obs-gke",
  [string] $Zone = "asia-south1-a",
  [string] $Namespace = "observability"
)
$ErrorActionPreference = "Stop"
$chart = Resolve-Path "$PSScriptRoot/../../../charts/observability-stack"

gcloud container clusters get-credentials $Cluster --zone $Zone --project $Project
if ($LASTEXITCODE -ne 0) { throw "get-credentials for $Cluster failed (VPN / gcloud login?)" }
$ctx = kubectl config current-context
Write-Host "Using context $ctx"

# Sub-charts are vendored in $chart/charts (github.com is not reachable over the office VPN).
helm upgrade --install observability $chart --kube-context $ctx -n $Namespace --create-namespace `
  -f "$chart/profiles/hub.yaml" -f "$PSScriptRoot/values.yaml" --wait --timeout 15m
if ($LASTEXITCODE -ne 0) { throw "helm install failed" }

# Private spoke entry point (internal LB on 10.40.16.10). Needs the reserved
# address from ../../../network/*.ps1.
kubectl --context $ctx apply -f "$PSScriptRoot/gateway-internal-lb.yaml"
if ($LASTEXITCODE -ne 0) { throw "applying gateway-internal-lb.yaml failed" }

# The hub agent reads its tenant password only at start-up (tenant rename,
# password rotation), like the spokes.
kubectl --context $ctx -n $Namespace rollout restart statefulset/observability-alloy
if ($LASTEXITCODE -ne 0) { throw "restarting observability-alloy failed" }
kubectl --context $ctx -n $Namespace rollout status statefulset/observability-alloy --timeout 5m
if ($LASTEXITCODE -ne 0) { throw "observability-alloy rollout did not finish within 5m" }

kubectl --context $ctx -n $Namespace get pods
kubectl --context $ctx -n $Namespace get svc observability-gateway-internal
