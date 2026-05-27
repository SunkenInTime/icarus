param(
    [ValidateSet("stable")]
    [string]$Channel = "stable",
    [switch]$Mandatory,
    [string]$ReleaseDate = (Get-Date -Format "yyyy-MM-dd"),
    [string]$MetadataDir = "release\metadata",
    [string]$PagesStageRoot = "release\out\gh-pages",
    [string]$AppArchiveBaseUrl = "https://sunkenintime.github.io/icarus/updates/windows/stable",
    [string]$MetadataTitle,
    [string]$InitialChangeMessage = "Describe this release before publishing.",
    [switch]$SkipPubGet
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot "common_release.ps1")

$repoRoot = Get-RepoRoot -ScriptDirectory $PSScriptRoot
$env:FLUTTER_ROOT = Get-FlutterRoot -RepoRoot $repoRoot

if (-not $SkipPubGet) {
    Invoke-RepoCommand -WorkingDirectory $repoRoot -Command "fvm" -Arguments @("flutter", "pub", "get")
}

Invoke-RepoCommand -WorkingDirectory $repoRoot -Command "fvm" -Arguments @("dart", "run", "desktop_updater:release", "windows", "--release")
Invoke-RepoCommand -WorkingDirectory $repoRoot -Command "fvm" -Arguments @("dart", "run", "desktop_updater:archive", "windows")
Invoke-RepoCommand -WorkingDirectory $repoRoot -Command "powershell" -Arguments @("-ExecutionPolicy", "Bypass", "-File", "installer/build_installer.ps1", "-Configuration", "Release")

$versionInfo = Get-VersionInfo -RepoRoot $repoRoot
$distArchivePath = Resolve-RepoPath -RepoRoot $repoRoot -RelativePath ("dist\{0}\{1}" -f $versionInfo.BuildNumber, $versionInfo.WindowsArchiveFolderName)
if (-not (Test-Path $distArchivePath)) {
    throw "Desktop Updater archive folder not found at $distArchivePath"
}

$metadataRoot = Resolve-RepoPath -RepoRoot $repoRoot -RelativePath $MetadataDir
New-Item -ItemType Directory -Force -Path $metadataRoot | Out-Null

$metadataPath = Join-Path $metadataRoot ("{0}.json" -f $versionInfo.FullVersion)
if (-not (Test-Path $metadataPath)) {
    $metadata = [ordered]@{
        version = $versionInfo.FullVersion
        shortVersion = $versionInfo.BuildNumber
        title = if ([string]::IsNullOrWhiteSpace($MetadataTitle)) { "$($versionInfo.VersionName) Release" } else { $MetadataTitle }
        description = "Desktop release metadata for Icarus."
        date = $ReleaseDate
        mandatory = [bool]$Mandatory
        channels = @("desktop", $Channel)
        platforms = @("windows")
        changes = @(
            @{
                type = "other"
                message = $InitialChangeMessage
            }
        )
    }

    $metadata | ConvertTo-Json -Depth 6 | Set-Content -Path $metadataPath
    Write-Host "Created release metadata at $metadataPath"
}

$channelRoot = Resolve-RepoPath -RepoRoot $repoRoot -RelativePath ("{0}\updates\windows\{1}" -f $PagesStageRoot, $Channel)
New-Item -ItemType Directory -Force -Path $channelRoot | Out-Null

$stagedArchivePath = Join-Path $channelRoot $versionInfo.WindowsArchiveFolderName
if (Test-Path $stagedArchivePath) {
    Remove-Item -Path $stagedArchivePath -Recurse -Force
}
Copy-Item -Path $distArchivePath -Destination $stagedArchivePath -Recurse

$manifestOutputPath = Join-Path $channelRoot "app-archive.json"
Invoke-RepoCommand -WorkingDirectory $repoRoot -Command "powershell" -Arguments @(
    "-ExecutionPolicy", "Bypass",
    "-File", "scripts/generate_update_manifest.ps1",
    "-MetadataDir", $MetadataDir,
    "-OutputPath", $manifestOutputPath,
    "-BaseUrl", $AppArchiveBaseUrl,
    "-Platform", "windows",
    "-Channel", $Channel
)

$installerOutputDir = Resolve-RepoPath -RepoRoot $repoRoot -RelativePath "build\installer"
if (Test-Path $installerOutputDir) {
    $desktopArtifactDir = Resolve-RepoPath -RepoRoot $repoRoot -RelativePath ("release\out\desktop\{0}" -f $versionInfo.FullVersion)
    New-Item -ItemType Directory -Force -Path $desktopArtifactDir | Out-Null
    Copy-Item -Path (Join-Path $installerOutputDir "*") -Destination $desktopArtifactDir -Recurse -Force

    $installerFileName = "icarus-setup-{0}.exe" -f $versionInfo.VersionName
    $installerSourcePath = Join-Path $installerOutputDir $installerFileName
    if (-not (Test-Path $installerSourcePath)) {
        throw "Expected installer not found at $installerSourcePath"
    }

    $downloadsRoot = Resolve-RepoPath -RepoRoot $repoRoot -RelativePath ("{0}\downloads\windows\{1}" -f $PagesStageRoot, $Channel)
    New-Item -ItemType Directory -Force -Path $downloadsRoot | Out-Null

    $versionedInstallerPath = Join-Path $downloadsRoot $installerFileName
    $latestInstallerPath = Join-Path $downloadsRoot "icarus-setup-latest.exe"
    Copy-Item -Path $installerSourcePath -Destination $versionedInstallerPath -Force
    Copy-Item -Path $installerSourcePath -Destination $latestInstallerPath -Force

    Write-Host ("Published installer downloads to {0}" -f $downloadsRoot) -ForegroundColor Green
    Write-Host ("Latest installer URL path: /downloads/windows/{0}/icarus-setup-latest.exe" -f $Channel) -ForegroundColor Green
}

Write-Host "Desktop release staging complete for $($versionInfo.FullVersion)." -ForegroundColor Green
Write-Host "Pages output: $channelRoot"
