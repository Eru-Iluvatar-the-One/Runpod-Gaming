# build-and-push.ps1 — Run this ONCE locally to build and push the Docker image.
# Requires Docker Desktop running on Windows.
# Usage: .\build-and-push.ps1

param(
    [string]$Tag = "eruilu/funfunpod:latest"
)

$ErrorActionPreference = "Stop"
$RepoRoot = $PSScriptRoot

Write-Host ">> Building $Tag"
docker build --platform linux/amd64 -t $Tag "$RepoRoot"

Write-Host ">> Pushing $Tag"
docker push $Tag

Write-Host ">> Done. Set this as your RunPod container image: $Tag"
Write-Host ">> Expose port 8080/http in RunPod pod settings."
Write-Host ">> Attach a Network Volume mounted at /workspace."
