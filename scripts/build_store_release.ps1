param(
    [string]$OutputDir = "release\out\store",
    [string]$PostHogProjectToken = $env:POSTHOG_PROJECT_TOKEN,
    [string]$PostHogHost = $(if ($env:POSTHOG_HOST) { $env:POSTHOG_HOST } else { "https://us.i.posthog.com" }),
    [switch]$SkipPubGet
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot "common_release.ps1")

$repoRoot = Get-RepoRoot -ScriptDirectory $PSScriptRoot
$env:FLUTTER_ROOT = Get-FlutterRoot -RepoRoot $repoRoot
$windowsBuildRoot = Resolve-RepoPath -RepoRoot $repoRoot -RelativePath "build\windows"

Invoke-RepoCommand -WorkingDirectory $repoRoot -Command "fvm" -Arguments @("dart", "run", "tool/check_bundled_wall_heights.dart")

if (-not $SkipPubGet) {
    Invoke-RepoCommand -WorkingDirectory $repoRoot -Command "fvm" -Arguments @("flutter", "pub", "get")
}

# Gameplay expectations must pass against the exact bundled assets before packaging.
Invoke-RepoCommand -WorkingDirectory $repoRoot -Command "fvm" -Arguments @(
    "flutter", "test", "--no-pub", "--dart-define=ICARUS_VERIFY_BUNDLED_GAMEPLAY=true",
    "test/reported_sightlines_test.dart",
    "test/haven_tactical_sightlines_test.dart",
    "test/breeze_gameplay_sightlines_test.dart",
    "test/breeze_covered_openings_test.dart",
    "test/systematic_map_gameplay_test.dart",
    "test/fracture_covered_interiors_test.dart",
    "test/fracture_reported_walls_test.dart",
    "test/fracture_small_crate_test.dart",
    "test/fracture_platform_end_test.dart",
    "test/abyss_tower_opening_test.dart",
    "test/lotus_stepwell_opening_test.dart",
    "test/fracture_container_opening_test.dart",
    "test/pearl_low_brick_test.dart",
    "test/pearl_metro_opening_test.dart",
    "test/pearl_ramp_brick_profile_test.dart",
    "test/pearl_remaining_families_test.dart",
    "test/split_legacy_sightlines_test.dart",
    "test/split_regional_standing_test.dart",
    "test/icebox_front_window_test.dart",
    "test/covered_interior_gameplay_test.dart",
    "test/collision_roof_defaults_test.dart",
    "test/all_map_confirmed_walls_test.dart",
    "test/five_map_false_block_gaps_test.dart",
    "test/remaining_ownership_sightlines_test.dart",
    "test/lotus_low_crate_test.dart",
    "test/lotus_remaining_families_test.dart",
    "test/pearl_industrial_wall_test.dart",
    "test/reviewed_wall_assemblies_test.dart",
    "test/standing_source_integrity_test.dart",
    "test/svg_wall_footprint_integrity_test.dart"
)

$dartDefinesPath = $null
try {
    if (Test-Path -LiteralPath $windowsBuildRoot) {
        Remove-Item -LiteralPath $windowsBuildRoot -Recurse -Force
    }

    $flutterBuildArguments = @("flutter", "build", "windows", "--release")
    if (-not [string]::IsNullOrWhiteSpace($PostHogProjectToken)) {
        $dartDefinesPath = Join-Path ([System.IO.Path]::GetTempPath()) ("icarus-dart-defines-{0}.json" -f [guid]::NewGuid())
        Write-JsonFileUtf8 -Path $dartDefinesPath -Value @{
            POSTHOG_PROJECT_TOKEN = $PostHogProjectToken
            POSTHOG_HOST = $PostHogHost
        }
        $flutterBuildArguments += "--dart-define-from-file=$dartDefinesPath"
    }
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
