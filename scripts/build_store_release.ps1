param(
    [string]$OutputDir = "release\out\store",
    [string]$PostHogProjectToken = $env:POSTHOG_PROJECT_TOKEN,
    [string]$PostHogHost = $(if ($env:POSTHOG_HOST) { $env:POSTHOG_HOST } else { "https://us.i.posthog.com" }),
    [string]$ProductionConvexDeploymentUrl = $env:ICARUS_PRODUCTION_CONVEX_DEPLOYMENT_URL,
    [string]$ProductionConvexClientId = $env:ICARUS_PRODUCTION_CONVEX_CLIENT_ID,
    [switch]$SkipPubGet
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot "common_release.ps1")

$repoRoot = Get-RepoRoot -ScriptDirectory $PSScriptRoot
Assert-ReleaseBranch -RepoRoot $repoRoot -ReleaseTarget "store" | Out-Null
$cloudBuildConfiguration = Resolve-CloudBuildConfiguration `
    -ReleaseTarget "store" `
    -ProductionConvexDeploymentUrl $ProductionConvexDeploymentUrl `
    -ProductionConvexClientId $ProductionConvexClientId
$env:FLUTTER_ROOT = Get-FlutterRoot -RepoRoot $repoRoot
$windowsBuildRoot = Resolve-RepoPath -RepoRoot $repoRoot -RelativePath "build\windows"

if (-not $SkipPubGet) {
    Invoke-RepoCommand -WorkingDirectory $repoRoot -Command "fvm" -Arguments @("flutter", "pub", "get")
}

$dartDefinesPath = $null
try {
    if (Test-Path -LiteralPath $windowsBuildRoot) {
        Remove-Item -LiteralPath $windowsBuildRoot -Recurse -Force
    }

    $flutterBuildArguments = @("flutter", "build", "windows", "--release")
    $dartDefines = [ordered]@{
        ICARUS_CLOUD_ENVIRONMENT = $cloudBuildConfiguration.Environment
        ICARUS_CONVEX_DEPLOYMENT_URL = $cloudBuildConfiguration.DeploymentUrl
        ICARUS_CONVEX_CLIENT_ID = $cloudBuildConfiguration.ClientId
    }
    if (-not [string]::IsNullOrWhiteSpace($PostHogProjectToken)) {
        $dartDefines.POSTHOG_PROJECT_TOKEN = $PostHogProjectToken
        $dartDefines.POSTHOG_HOST = $PostHogHost
    }
    $dartDefinesPath = Join-Path ([System.IO.Path]::GetTempPath()) ("icarus-dart-defines-{0}.json" -f [guid]::NewGuid())
    Write-JsonFileUtf8 -Path $dartDefinesPath -Value $dartDefines
    $flutterBuildArguments += "--dart-define-from-file=$dartDefinesPath"
    Invoke-RepoCommand -WorkingDirectory $repoRoot -Command "fvm" -Arguments $flutterBuildArguments
    # Stage the video-export encoder into the build output before packaging.
    Invoke-RepoCommand -WorkingDirectory $repoRoot -Command "powershell" -Arguments @(
        "-ExecutionPolicy", "Bypass", "-File", "scripts/fetch_ffmpeg.ps1"
    )
    Invoke-RepoCommand -WorkingDirectory $repoRoot -Command "fvm" -Arguments @(
        "dart",
        "run",
        "msix:create",
        "--build-windows",
        "false"
    )
}
finally {
    if ($null -ne $dartDefinesPath -and (Test-Path -LiteralPath $dartDefinesPath)) {
        Remove-Item -LiteralPath $dartDefinesPath -Force
    }
}

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

Write-JsonFileUtf8 -Value $packageInfo -Path (Join-Path $outputRoot "package-info.json") -Depth 4

Write-Host "Store package staged at $stagedPackagePath" -ForegroundColor Green
