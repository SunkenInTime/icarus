param(
    [ValidateSet("none", "patch", "minor", "major")]
    [string]$VersionBump = "patch",
    [switch]$Mandatory,
    [string]$ReleaseTitle = "",
    [string]$ChangeMessage = "Local prerelease build for updater testing.",
    [string]$PagesBranch = "gh-pages",
    [string]$PagesRemote = "origin",
    [switch]$SkipPubGet
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$scriptPath = Join-Path $PSScriptRoot "release_desktop.ps1"
$params = @{
    VersionBump = $VersionBump
    Channel = "prerelease"
    PublishPages = $true
    PagesPublishMode = "git-branch"
    PagesBranch = $PagesBranch
    PagesRemote = $PagesRemote
    ReleaseTitle = $ReleaseTitle
    ChangeMessage = $ChangeMessage
}

if ($Mandatory) {
    $params.Mandatory = $true
}

if ($SkipPubGet) {
    $params.SkipPubGet = $true
}

& $scriptPath @params

if ($LASTEXITCODE -ne 0) {
    throw "Local prerelease publish failed."
}
