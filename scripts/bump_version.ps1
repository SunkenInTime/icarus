<#
.SYNOPSIS
    Bumps the app version across pubspec.yaml and lib/const/settings.dart, then runs msix:create.

.DESCRIPTION
    Accepts a bump type (major, minor, or patch), increments the appropriate version segment,
    always increments the build number by 1, updates all version locations, and builds the MSIX.

.PARAMETER Bump
    The type of version bump: major, minor, or patch.

.EXAMPLE
    .\bump_version.ps1 -Bump patch
    .\bump_version.ps1 -Bump minor
    .\bump_version.ps1 -Bump major
#>

param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("major", "minor", "patch")]
    [string]$Bump
)

$ErrorActionPreference = "Stop"

# File paths (relative to repo root)
$repoRoot = Split-Path -Parent $PSScriptRoot
$pubspecPath = Join-Path $repoRoot "pubspec.yaml"
$settingsPath = Join-Path $repoRoot "lib\const\settings.dart"

# --- Read files ---
if (-not (Test-Path $pubspecPath)) {
    Write-Error "pubspec.yaml not found at $pubspecPath"
    exit 1
}
if (-not (Test-Path $settingsPath)) {
    Write-Error "settings.dart not found at $settingsPath"
    exit 1
}

$pubspecContent = Get-Content $pubspecPath -Raw
$settingsContent = Get-Content $settingsPath -Raw

# --- Parse pubspec version: X.Y.Z+N ---
if ($pubspecContent -notmatch 'version:\s*(\d+)\.(\d+)\.(\d+)\+(\d+)') {
    Write-Error "Could not parse 'version: X.Y.Z+N' in pubspec.yaml"
    exit 1
}
$pubMajor = [int]$Matches[1]
$pubMinor = [int]$Matches[2]
$pubPatch = [int]$Matches[3]
$pubBuild = [int]$Matches[4]

# --- Parse pubspec msix_version: X.Y.Z.0 ---
if ($pubspecContent -notmatch 'msix_version:\s*(\d+)\.(\d+)\.(\d+)\.(\d+)') {
    Write-Error "Could not parse 'msix_version: X.Y.Z.0' in pubspec.yaml"
    exit 1
}
$msixMajor = [int]$Matches[1]
$msixMinor = [int]$Matches[2]
$msixPatch = [int]$Matches[3]
$msixFourth = [int]$Matches[4]

if ($msixFourth -ne 0) {
    Write-Warning "msix_version fourth segment is $msixFourth (expected 0). It will remain as .0 after bump."
}

# --- Parse settings.dart versionNumber and versionName ---
if ($settingsContent -notmatch 'static\s+const\s+int\s+versionNumber\s*=\s*(\d+)\s*;') {
    Write-Error "Could not parse 'versionNumber' in settings.dart"
    exit 1
}
$settingsBuild = [int]$Matches[1]

if ($settingsContent -notmatch 'static\s+const\s+String\s+versionName\s*=\s*"(\d+)\.(\d+)\.(\d+)"') {
    Write-Error "Could not parse 'versionName' in settings.dart"
    exit 1
}
$settingsMajor = [int]$Matches[1]
$settingsMinor = [int]$Matches[2]
$settingsPatch = [int]$Matches[3]

# --- Validate consistency ---
$pubVersion = "$pubMajor.$pubMinor.$pubPatch"
$msixVersion = "$msixMajor.$msixMinor.$msixPatch"
$settingsVersion = "$settingsMajor.$settingsMinor.$settingsPatch"

if ($pubVersion -ne $msixVersion -or $pubVersion -ne $settingsVersion) {
    Write-Error "Version mismatch detected!`n  pubspec version: $pubVersion`n  msix_version:    $msixVersion`n  settings.dart:   $settingsVersion`nPlease fix manually before running this script."
    exit 1
}

if ($pubBuild -ne $settingsBuild) {
    Write-Error "Build number mismatch!`n  pubspec build: $pubBuild`n  settings.dart versionNumber: $settingsBuild`nPlease fix manually before running this script."
    exit 1
}

# --- Compute new version ---
$oldMajor = $pubMajor
$oldMinor = $pubMinor
$oldPatch = $pubPatch
$oldBuild = $pubBuild

switch ($Bump) {
    "major" {
        $newMajor = $oldMajor + 1
        $newMinor = 0
        $newPatch = 0
    }
    "minor" {
        $newMajor = $oldMajor
        $newMinor = $oldMinor + 1
        $newPatch = 0
    }
    "patch" {
        $newMajor = $oldMajor
        $newMinor = $oldMinor
        $newPatch = $oldPatch + 1
    }
}
$newBuild = $oldBuild + 1

$oldVersionFull = "$oldMajor.$oldMinor.$oldPatch+$oldBuild"
$newVersionFull = "$newMajor.$newMinor.$newPatch+$newBuild"
$newVersionBase = "$newMajor.$newMinor.$newPatch"

Write-Host ""
Write-Host "=== Version Bump ===" -ForegroundColor Cyan
Write-Host "  Bump type:    $Bump"
Write-Host "  Old version:  $oldVersionFull"
Write-Host "  New version:  $newVersionFull"
Write-Host ""

# --- Update pubspec.yaml ---
# Replace version: line (preserve trailing comment)
$pubspecContent = $pubspecContent -replace `
    '(version:\s*)\d+\.\d+\.\d+\+\d+', `
    "`${1}$newMajor.$newMinor.$newPatch+$newBuild"

# Replace msix_version: line (preserve trailing comment, keep .0 as fourth segment)
$pubspecContent = $pubspecContent -replace `
    '(msix_version:\s*)\d+\.\d+\.\d+\.\d+', `
    "`${1}$newMajor.$newMinor.$newPatch.0"

Set-Content -Path $pubspecPath -Value $pubspecContent -NoNewline

# --- Update settings.dart ---
# Replace versionNumber
$settingsContent = $settingsContent -replace `
    '(static\s+const\s+int\s+versionNumber\s*=\s*)\d+(\s*;)', `
    "`${1}$newBuild`${2}"

# Replace versionName
$settingsContent = $settingsContent -replace `
    '(static\s+const\s+String\s+versionName\s*=\s*")\d+\.\d+\.\d+(")', `
    "`${1}$newVersionBase`${2}"

Set-Content -Path $settingsPath -Value $settingsContent -NoNewline

Write-Host "Updated files:" -ForegroundColor Green
Write-Host "  - pubspec.yaml (version + msix_version)"
Write-Host "  - lib/const/settings.dart (versionNumber + versionName)"
Write-Host ""

# --- Run msix:create ---
Write-Host "Running: dart run msix:create" -ForegroundColor Cyan
Write-Host ""

Push-Location $repoRoot
try {
    dart run msix:create
    if ($LASTEXITCODE -ne 0) {
        Write-Error "dart run msix:create failed with exit code $LASTEXITCODE"
        exit $LASTEXITCODE
    }
}
finally {
    Pop-Location
}

Write-Host ""
Write-Host "=== Done ===" -ForegroundColor Green
Write-Host "  Version bumped to $newVersionFull"
Write-Host "  MSIX created successfully."
Write-Host ""

# --- Open output folder ---
$msixFolder = Join-Path $repoRoot "build\windows\x64\runner\Release"
if (Test-Path $msixFolder) {
    Write-Host "Opening output folder..." -ForegroundColor Cyan
    Invoke-Item $msixFolder
}

