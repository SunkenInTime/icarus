param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("stable-desktop", "prerelease-desktop", "store", "production-backend")]
    [string]$ReleaseTarget,
    [string]$ProductionConvexDeploymentUrl = $env:ICARUS_PRODUCTION_CONVEX_DEPLOYMENT_URL,
    [string]$ProductionConvexClientId = $env:ICARUS_PRODUCTION_CONVEX_CLIENT_ID,
    [string]$BranchName = ""
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot "common_release.ps1")

$repoRoot = Get-RepoRoot -ScriptDirectory $PSScriptRoot
Assert-ReleaseBranch -RepoRoot $repoRoot -ReleaseTarget $ReleaseTarget -BranchName $BranchName | Out-Null

$cloudReleaseTarget = switch ($ReleaseTarget) {
    "stable-desktop" { "stable" }
    "prerelease-desktop" { "prerelease" }
    "store" { "store" }
    default { $null }
}

if ($null -ne $cloudReleaseTarget) {
    Resolve-CloudBuildConfiguration `
        -ReleaseTarget $cloudReleaseTarget `
        -ProductionConvexDeploymentUrl $ProductionConvexDeploymentUrl `
        -ProductionConvexClientId $ProductionConvexClientId | Out-Null
}
