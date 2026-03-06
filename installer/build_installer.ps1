param(
    [ValidateSet("Release", "Debug")]
    [string]$Configuration = "Release",
    [string]$IsccPath
)

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$pubspecPath = Join-Path $repoRoot "pubspec.yaml"
$issPath = Join-Path $PSScriptRoot "icarus.iss"
$sourceDir = Join-Path $repoRoot "build\windows\x64\runner\$Configuration"
$outputDir = Join-Path $repoRoot "build\installer"

if (-not (Test-Path $pubspecPath)) {
    throw "pubspec.yaml not found at $pubspecPath"
}
if (-not (Test-Path $issPath)) {
    throw "Inno script not found at $issPath"
}
if (-not (Test-Path $sourceDir)) {
    throw "Build output not found at $sourceDir. Run: fvm flutter build windows --release"
}
if (-not (Test-Path (Join-Path $sourceDir "icarus.exe"))) {
    throw "icarus.exe not found in $sourceDir"
}

$pubspec = Get-Content $pubspecPath -Raw
if ($pubspec -notmatch 'version:\s*(\d+\.\d+\.\d+)\+\d+') {
    throw "Could not parse version: X.Y.Z+N from pubspec.yaml"
}
$appVersion = $Matches[1]

if ($IsccPath) {
    if (-not (Test-Path $IsccPath)) {
        throw "Provided -IsccPath does not exist: $IsccPath"
    }
    $isccResolvedPath = $IsccPath
} else {
    $isccCmd = Get-Command ISCC.exe -ErrorAction SilentlyContinue
    if ($null -ne $isccCmd) {
        $isccResolvedPath = $isccCmd.Source
    } else {
        $candidates = @(
            "C:\Program Files (x86)\Inno Setup 6\ISCC.exe",
            "C:\Program Files\Inno Setup 6\ISCC.exe",
            "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe",
            "$env:LOCALAPPDATA\Inno Setup 6\ISCC.exe"
        )

        $isccResolvedPath = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
        if (-not $isccResolvedPath) {
            throw "ISCC.exe not found. Install Inno Setup 6, add ISCC.exe to PATH, or pass -IsccPath."
        }
    }
}

New-Item -ItemType Directory -Force -Path $outputDir | Out-Null

$arguments = @(
    "/DMyAppVersion=$appVersion",
    "/DMySourceDir=$sourceDir",
    "/DMyOutputDir=$outputDir",
    "/DMyAppExeName=icarus.exe",
    $issPath
)

Write-Host "Building installer version $appVersion from $sourceDir"
Write-Host "Using ISCC: $isccResolvedPath"
& $isccResolvedPath @arguments
if ($LASTEXITCODE -ne 0) {
    throw "ISCC.exe failed with exit code $LASTEXITCODE"
}

Write-Host "Installer complete. Output in: $outputDir"
