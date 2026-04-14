param(
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
    [switch]$SkipPubGet
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot "common_release.ps1")

$repoRoot = Get-RepoRoot -ScriptDirectory $PSScriptRoot

if ([string]::IsNullOrWhiteSpace($AppArchiveBaseUrl)) {
    $AppArchiveBaseUrl = "https://sunkenintime.github.io/icarus/updates/windows/$Channel"
}

if ($VersionBump -ne "none") {
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
    "-Channel",
    $Channel,
    "-PagesStageRoot",
    $PagesStageRoot,
    "-MetadataDir",
    $MetadataDir,
    "-AppArchiveBaseUrl",
    $AppArchiveBaseUrl,
    "-InitialChangeMessage",
    $ChangeMessage
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

Invoke-RepoCommand -WorkingDirectory $repoRoot -Command "powershell" -Arguments $buildArgs

if (-not $PublishPages) {
    return
}

switch ($PagesPublishMode) {
    "none" {
        Write-Host "Pages publish requested, but PagesPublishMode is 'none'. Files remain staged locally." -ForegroundColor Yellow
    }
    "git-branch" {
        Invoke-RepoCommand -WorkingDirectory $repoRoot -Command "powershell" -Arguments @(
            "-ExecutionPolicy",
            "Bypass",
            "-File",
            "scripts/publish_pages_branch.ps1",
            "-SourceDir",
            $PagesStageRoot,
            "-Branch",
            $PagesBranch,
            "-Remote",
            $PagesRemote,
            "-SyncPaths",
            "updates/windows/$Channel"
        )

        Invoke-RepoCommand -WorkingDirectory $repoRoot -Command "powershell" -Arguments @(
            "-ExecutionPolicy",
            "Bypass",
            "-File",
            "scripts/publish_pages_branch.ps1",
            "-SourceDir",
            $PagesStageRoot,
            "-Branch",
            $PagesBranch,
            "-Remote",
            $PagesRemote,
            "-SyncPaths",
            "downloads/windows/$Channel"
        )
    }
}
