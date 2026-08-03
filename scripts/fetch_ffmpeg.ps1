param(
    # Where ffmpeg.exe should land; the app resolves it at runtime relative to
    # the executable (ffmpeg\ffmpeg.exe next to icarus.exe).
    [string]$DestinationDir = "build\windows\x64\runner\Release\ffmpeg",
    [switch]$Force
)

# Downloads a pinned LGPL FFmpeg Windows build for the video export feature
# (ADR 0001/0004). The pin is a dated BtbN autobuild: update the URL *and*
# checksum together. LGPL build only — the GPL variants (with x264) must not
# be bundled. H.264 encoding uses Media Foundation (h264_mf), which needs no
# GPL component.

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$FfmpegUrl = "https://github.com/BtbN/FFmpeg-Builds/releases/download/autobuild-2026-07-31-14-10/ffmpeg-n8.1.2-34-g9b6c8969e0-win64-lgpl-8.1.zip"
$FfmpegSha256 = "089e4169e93b2b3f3acbfced3c0704d24276a225641bdda04d796d28b07a2a38"

$repoRoot = Split-Path -Parent $PSScriptRoot
$cacheDir = Join-Path $repoRoot "windows\.ffmpeg-cache"
$zipName = [System.IO.Path]::GetFileName(([uri]$FfmpegUrl).LocalPath)
$zipPath = Join-Path $cacheDir $zipName
$destinationRoot = if ([System.IO.Path]::IsPathRooted($DestinationDir)) {
    $DestinationDir
} else {
    Join-Path $repoRoot $DestinationDir
}
$destinationExe = Join-Path $destinationRoot "ffmpeg.exe"

function Get-FileSha256 {
    param([string]$Path)
    return (Get-FileHash -Path $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

if ((Test-Path $destinationExe) -and -not $Force) {
    Write-Host "ffmpeg.exe already present at $destinationExe" -ForegroundColor Green
    exit 0
}

New-Item -ItemType Directory -Force -Path $cacheDir | Out-Null

$needsDownload = $true
if (Test-Path $zipPath) {
    if ((Get-FileSha256 -Path $zipPath) -eq $FfmpegSha256) {
        $needsDownload = $false
        Write-Host "Using cached $zipName" -ForegroundColor Cyan
    } else {
        Write-Host "Cached archive failed checksum; re-downloading." -ForegroundColor Yellow
        Remove-Item -LiteralPath $zipPath -Force
    }
}

if ($needsDownload) {
    Write-Host "Downloading $FfmpegUrl" -ForegroundColor Cyan
    Invoke-WebRequest -Uri $FfmpegUrl -OutFile $zipPath -UseBasicParsing
}

$actualHash = Get-FileSha256 -Path $zipPath
if ($actualHash -ne $FfmpegSha256) {
    Remove-Item -LiteralPath $zipPath -Force
    throw "ffmpeg archive checksum mismatch: expected $FfmpegSha256, got $actualHash"
}

$extractDir = Join-Path $cacheDir "extracted"
if (Test-Path $extractDir) {
    Remove-Item -Path $extractDir -Recurse -Force
}
Expand-Archive -Path $zipPath -DestinationPath $extractDir

$ffmpegExe = Get-ChildItem -Path $extractDir -Recurse -File -Filter "ffmpeg.exe" | Select-Object -First 1
if (-not $ffmpegExe) {
    throw "ffmpeg.exe not found inside $zipName"
}

New-Item -ItemType Directory -Force -Path $destinationRoot | Out-Null
Copy-Item -Path $ffmpegExe.FullName -Destination $destinationExe -Force

# Ship the license alongside the binary (LGPL attribution, ADR 0004).
$licenseFile = Get-ChildItem -Path $extractDir -Recurse -File -Include "LICENSE*" | Select-Object -First 1
if ($licenseFile) {
    Copy-Item -Path $licenseFile.FullName -Destination (Join-Path $destinationRoot "FFMPEG_LICENSE.txt") -Force
}

Remove-Item -Path $extractDir -Recurse -Force
Write-Host "ffmpeg.exe staged at $destinationExe" -ForegroundColor Green
