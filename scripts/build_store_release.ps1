param(
    [string]$OutputDir = "release\out\store",
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

Invoke-RepoCommand -WorkingDirectory $repoRoot -Command "fvm" -Arguments @("dart", "run", "msix:create")

$outputRoot = Resolve-RepoPath -RepoRoot $repoRoot -RelativePath $OutputDir
if (Test-Path $outputRoot) {
    Remove-Item -Path $outputRoot -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $outputRoot | Out-Null

$packageCandidates = Get-ChildItem -Path (Resolve-RepoPath -RepoRoot $repoRoot -RelativePath "build") -Recurse -File -Include *.msix, *.msixupload, *.appxupload |
    Sort-Object LastWriteTimeUtc -Descending

if (-not $packageCandidates) {
    throw "No MSIX or Store upload package was found under build\ after msix:create."
}

$primaryPackage = $packageCandidates[0]
$stagedPackagePath = Join-Path $outputRoot $primaryPackage.Name
Copy-Item -Path $primaryPackage.FullName -Destination $stagedPackagePath -Force

$versionInfo = Get-VersionInfo -RepoRoot $repoRoot
$packageInfo = [ordered]@{
    version = $versionInfo.FullVersion
    versionName = $versionInfo.VersionName
    buildNumber = $versionInfo.BuildNumber
    packageFile = $primaryPackage.Name
    sourcePath = $primaryPackage.FullName
}

$packageInfo | ConvertTo-Json -Depth 4 | Set-Content -Path (Join-Path $outputRoot "package-info.json")

Write-Host "Store package staged at $stagedPackagePath" -ForegroundColor Green
