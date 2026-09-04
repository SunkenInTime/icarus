$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot "common_release.ps1")

$repoRoot = Get-RepoRoot -ScriptDirectory $PSScriptRoot

function Assert-ThrowsContaining {
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock]$Action,
        [Parameter(Mandatory = $true)]
        [string]$ExpectedMessage
    )

    try {
        & $Action
    }
    catch {
        if ($_.Exception.Message -notlike "*$ExpectedMessage*") {
            throw "Expected an error containing '$ExpectedMessage', got: $($_.Exception.Message)"
        }
        return
    }

    throw "Expected an error containing '$ExpectedMessage', but the action succeeded."
}

function Assert-TextAppearsBefore {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text,
        [Parameter(Mandatory = $true)]
        [string]$First,
        [Parameter(Mandatory = $true)]
        [string]$Second
    )

    $firstIndex = $Text.IndexOf($First)
    $secondIndex = $Text.IndexOf($Second)
    if ($firstIndex -lt 0 -or $secondIndex -lt 0 -or $firstIndex -gt $secondIndex) {
        throw "Expected '$First' to appear before '$Second'."
    }
}

Assert-ReleaseBranch -RepoRoot $repoRoot -ReleaseTarget "stable-desktop" -BranchName "main" | Out-Null
Assert-ReleaseBranch -RepoRoot $repoRoot -ReleaseTarget "store" -BranchName "main" | Out-Null
Assert-ReleaseBranch -RepoRoot $repoRoot -ReleaseTarget "production-backend" -BranchName "main" | Out-Null
Assert-ReleaseBranch -RepoRoot $repoRoot -ReleaseTarget "prerelease-desktop" -BranchName "icarus-cloud" | Out-Null
Assert-ThrowsContaining -ExpectedMessage "only run from branch 'main'" -Action {
    Assert-ReleaseBranch -RepoRoot $repoRoot -ReleaseTarget "stable-desktop" -BranchName "icarus-cloud"
}
Assert-ThrowsContaining -ExpectedMessage "only run from branch 'main'" -Action {
    Assert-ReleaseBranch -RepoRoot $repoRoot -ReleaseTarget "store" -BranchName "feature/cloud"
}

if (-not (Test-PublishesStablePages -SourceDirectory $repoRoot -SyncPaths "updates/windows/stable")) {
    throw "An explicit stable updater path must require the stable branch guard."
}
if (Test-PublishesStablePages -SourceDirectory $repoRoot -SyncPaths "updates/windows/prerelease") {
    throw "An explicit prerelease updater path must remain available on feature branches."
}

$pagesFixtureRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("icarus-release-safety-" + [guid]::NewGuid().ToString("N"))
try {
    New-Item -ItemType Directory -Force -Path (Join-Path $pagesFixtureRoot "downloads\windows\stable") | Out-Null
    if (-not (Test-PublishesStablePages -SourceDirectory $pagesFixtureRoot)) {
        throw "A full-directory publish containing stable downloads must require the stable branch guard."
    }
}
finally {
    if (Test-Path -LiteralPath $pagesFixtureRoot) {
        Remove-Item -LiteralPath $pagesFixtureRoot -Recurse -Force
    }
}

$prereleaseConfig = Resolve-CloudBuildConfiguration -ReleaseTarget "prerelease"
if ($prereleaseConfig.Environment -ne "development") {
    throw "Prerelease builds must select the development cloud environment."
}
if (-not [string]::IsNullOrWhiteSpace($prereleaseConfig.DeploymentUrl) -or
    -not [string]::IsNullOrWhiteSpace($prereleaseConfig.ClientId)) {
    throw "Prerelease builds must use the app's named development defaults."
}

Assert-ThrowsContaining -ExpectedMessage "Production cloud configuration is missing" -Action {
    Resolve-CloudBuildConfiguration -ReleaseTarget "stable"
}
Assert-ThrowsContaining -ExpectedMessage "Production cloud configuration is missing" -Action {
    Resolve-CloudBuildConfiguration -ReleaseTarget "store" `
        -ProductionConvexDeploymentUrl "https://production-example.convex.cloud"
}
Assert-ThrowsContaining -ExpectedMessage "absolute HTTPS URL" -Action {
    Resolve-CloudBuildConfiguration -ReleaseTarget "stable" `
        -ProductionConvexDeploymentUrl "https:production-example" `
        -ProductionConvexClientId "icarus-production"
}
Assert-ThrowsContaining -ExpectedMessage "development Convex deployment" -Action {
    Resolve-CloudBuildConfiguration -ReleaseTarget "stable" `
        -ProductionConvexDeploymentUrl "https://majestic-eel-413.convex.cloud/" `
        -ProductionConvexClientId "icarus-production"
}
Assert-ThrowsContaining -ExpectedMessage "development Convex deployment" -Action {
    Resolve-CloudBuildConfiguration -ReleaseTarget "store" `
        -ProductionConvexDeploymentUrl "https://production-example.convex.cloud" `
        -ProductionConvexClientId "dev:majestic-eel-413"
}

$productionConfig = Resolve-CloudBuildConfiguration -ReleaseTarget "stable" `
    -ProductionConvexDeploymentUrl "https://production-example.convex.cloud" `
    -ProductionConvexClientId "icarus-production"
if ($productionConfig.Environment -ne "production" -or
    $productionConfig.DeploymentUrl -ne "https://production-example.convex.cloud" -or
    $productionConfig.ClientId -ne "icarus-production") {
    throw "A complete production cloud configuration was not preserved."
}

$desktopWorkflow = Get-Content (Join-Path $repoRoot ".github\workflows\release-desktop.yml") -Raw
$storeWorkflow = Get-Content (Join-Path $repoRoot ".github\workflows\release-store.yml") -Raw
$productionWorkflow = Get-Content (Join-Path $repoRoot ".github\workflows\deploy-convex-production.yml") -Raw

Assert-TextAppearsBefore -Text $desktopWorkflow -First "Run Release Preflight" -Second "Install FVM"
if ($desktopWorkflow -notmatch 'production-approval:[\s\S]*environment:\s*Production' -or
    $desktopWorkflow -notmatch 'needs:\s*production-approval') {
    throw "Stable desktop publishing must pass the GitHub Production environment before the build job."
}
Assert-TextAppearsBefore -Text $storeWorkflow -First "Run Store Release Preflight" -Second "Bump Version"
if ($productionWorkflow -notmatch 'environment:\s*Production') {
    throw "The production Convex deployment job must use the GitHub Production environment."
}
if ($productionWorkflow -notmatch 'secrets\.CONVEX_PRODUCTION_DEPLOY_KEY') {
    throw "The production Convex deployment must read CONVEX_PRODUCTION_DEPLOY_KEY."
}
if ($productionWorkflow -match 'CONVEX_PREVIEW_DEPLOY_KEY') {
    throw "The production Convex deployment must never reference the preview deploy key."
}
Assert-TextAppearsBefore -Text $productionWorkflow -First "Check Convex Types" -Second "Deploy Convex Production Backend"
Assert-TextAppearsBefore -Text $productionWorkflow -First "Run Convex Tests" -Second "Deploy Convex Production Backend"

$currentMetadata = Get-Content (Join-Path $repoRoot "release\metadata\4.6.1+97.json") -Raw | ConvertFrom-Json
if (@($currentMetadata.channels) -contains "stable") {
    throw "The current online-beta metadata must not claim the stable channel."
}
if (@($currentMetadata.channels) -notcontains "prerelease") {
    throw "The current online-beta metadata must include the prerelease channel."
}

Write-Host "Release safety checks passed." -ForegroundColor Green
