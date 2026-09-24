param(
    [ValidateSet("all", "build", "package", "stage", "publish")]
    [string]$Phase = "all",
    [ValidateSet("none", "patch", "minor", "major")]
    [string]$VersionBump = "none",
    [ValidateSet("stable", "prerelease")]
    [string]$Channel = "stable",
    [switch]$Mandatory,
    [switch]$PublishPages,
    [ValidateSet("none", "git-branch")]
    [string]$PagesPublishMode = "none",
    [string]$PagesBranch = "gh-pages",
    [string]$PagesRemote = "origin",
    [string]$ReleaseTitle = "",
    [string]$ChangeMessage = "Replace this with the desktop release summary.",
    [string]$PagesStageRoot = "release\out\gh-pages",
    [string]$MetadataDir = "release\metadata",
    [string]$AppArchiveBaseUrl = "",
    [string]$ProductionConvexDeploymentUrl = $env:ICARUS_PRODUCTION_CONVEX_DEPLOYMENT_URL,
    [string]$ProductionConvexClientId = $env:ICARUS_PRODUCTION_CONVEX_CLIENT_ID,
    [switch]$SkipPubGet
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot "common_release.ps1")

$repoRoot = Get-RepoRoot -ScriptDirectory $PSScriptRoot
$releaseTarget = if ($Channel -eq "stable") { "stable-desktop" } else { "prerelease-desktop" }
Assert-ReleaseBranch -RepoRoot $repoRoot -ReleaseTarget $releaseTarget | Out-Null
Resolve-CloudBuildConfiguration `
    -ReleaseTarget $Channel `
    -ProductionConvexDeploymentUrl $ProductionConvexDeploymentUrl `
    -ProductionConvexClientId $ProductionConvexClientId | Out-Null

if ([string]::IsNullOrWhiteSpace($AppArchiveBaseUrl)) {
    $AppArchiveBaseUrl = "https://sunkenintime.github.io/icarus/updates/windows/$Channel"
}

if ($PublishPages -and (@("all", "stage", "publish") -notcontains $Phase)) {
    throw "Pages can only be published during the 'all', 'stage', or 'publish' release phase."
}

if ($VersionBump -ne "none" -and (@("all", "build") -notcontains $Phase)) {
    throw "Version bumps can only be applied during the 'all' or 'build' release phase."
}

if ($VersionBump -ne "none" -and (@("all", "build") -contains $Phase)) {
    Invoke-RepoCommand -WorkingDirectory $repoRoot -Command "powershell" -Arguments @(
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        "scripts/bump_version.ps1",
        "-Bump",
        $VersionBump
    )
}

$buildArgs = @(
    "-ExecutionPolicy",
    "Bypass",
    "-File",
    "scripts/build_desktop_release.ps1",
    "-Phase",
    $Phase,
    "-Channel",
    $Channel,
    "-PagesStageRoot",
    $PagesStageRoot,
    "-MetadataDir",
    $MetadataDir,
    "-AppArchiveBaseUrl",
    $AppArchiveBaseUrl,
    "-InitialChangeMessage",
    $ChangeMessage,
    "-ProductionConvexDeploymentUrl",
    $ProductionConvexDeploymentUrl,
    "-ProductionConvexClientId",
    $ProductionConvexClientId
)

if ($Mandatory) {
    $buildArgs += "-Mandatory"
}

if (-not [string]::IsNullOrWhiteSpace($ReleaseTitle)) {
    $buildArgs += @("-MetadataTitle", $ReleaseTitle)
}

if ($SkipPubGet) {
    $buildArgs += "-SkipPubGet"
}

if ($Phase -ne "publish") {
    Invoke-RepoCommand -WorkingDirectory $repoRoot -Command "powershell" -Arguments $buildArgs
}

if (-not $PublishPages) {
    return
}

switch ($PagesPublishMode) {
    "none" {
        Write-Host "Pages publish requested, but PagesPublishMode is 'none'. Files remain staged locally." -ForegroundColor Yellow
    }
    "git-branch" {
        $versionInfo = Get-VersionInfo -RepoRoot $repoRoot
        $channelPath = "updates/windows/$Channel"
        Assert-PagesFileSizes -Path (Resolve-RepoPath -RepoRoot $repoRoot -RelativePath "$PagesStageRoot/$channelPath")
        # The installer must be available before clients see the new update.
        & (Join-Path $PSScriptRoot "publish_installer_release.ps1") -Channel $Channel -MetadataDir $MetadataDir
        # Keep prior version folders available for downloads already in progress.
        & (Join-Path $PSScriptRoot "publish_pages_branch.ps1") `
            -SourceDir $PagesStageRoot -Branch $PagesBranch -Remote $PagesRemote -SyncPaths @(
                "$channelPath/$($versionInfo.WindowsArchiveFolderName)",
                "$channelPath/app-archive.json"
        )
    }
}
