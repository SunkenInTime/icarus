param(
    # Where ffmpeg.exe should land; the app resolves it at runtime relative to
    # the executable (ffmpeg\ffmpeg.exe next to icarus.exe).
    [string]$DestinationDir = "build\windows\x64\runner\Release\ffmpeg",
    [switch]$Force
)

# Downloads a pinned shared LGPL FFmpeg Windows build for the video export
# feature (ADR 0001/0004). Splitting FFmpeg into its executable and runtime
# DLLs keeps every published file below GitHub Pages' 100 MiB blob limit.
# Update the URL, checksum, and runtime file list together. LGPL build only —
# the GPL variants (with x264) must not be bundled. H.264 encoding uses Media
# Foundation (h264_mf), which needs no GPL component.

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$FfmpegUrl = "https://github.com/BtbN/FFmpeg-Builds/releases/download/autobuild-2026-07-31-14-10/ffmpeg-n8.1.2-34-g9b6c8969e0-win64-lgpl-shared-8.1.zip"
$FfmpegSha256 = "c222a490dde4e7059f45495deef6bfb98dbcacc2b43df5b607546252037aa95c"
$FfmpegRuntimeFiles = @(
    "ffmpeg.exe",
    "avcodec-62.dll",
    "avdevice-62.dll",
    "avfilter-11.dll",
    "avformat-62.dll",
    "avutil-60.dll",
    "swresample-6.dll",
    "swscale-9.dll"
)

$repoRoot = Split-Path -Parent $PSScriptRoot
$cacheDir = Join-Path $repoRoot "windows\.ffmpeg-cache"
$zipName = [System.IO.Path]::GetFileName(([uri]$FfmpegUrl).LocalPath)
$zipPath = Join-Path $cacheDir $zipName
$destinationRoot = if ([System.IO.Path]::IsPathRooted($DestinationDir)) {
    $DestinationDir
} else {
    Join-Path $repoRoot $DestinationDir
}
function Get-FileSha256 {
    param([string]$Path)
    return (Get-FileHash -Path $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

New-Item -ItemType Directory -Force -Path $cacheDir | Out-Null

if ($Force -and (Test-Path -LiteralPath $zipPath)) {
    Remove-Item -LiteralPath $zipPath -Force
}

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

$ffmpegBinDir = Get-ChildItem -Path $extractDir -Recurse -Directory -Filter "bin" | Where-Object {
    Test-Path -LiteralPath (Join-Path $_.FullName "ffmpeg.exe")
} | Select-Object -First 1
if (-not $ffmpegBinDir) {
    throw "FFmpeg bin directory not found inside $zipName"
}

New-Item -ItemType Directory -Force -Path $destinationRoot | Out-Null
Get-ChildItem -LiteralPath $destinationRoot -File -ErrorAction SilentlyContinue | Where-Object {
    $_.Name -ieq "ffmpeg.exe" -or
    $_.Extension -ieq ".dll" -or
    $_.Name -ieq "FFMPEG_LICENSE.txt"
} | Remove-Item -Force
foreach ($runtimeFile in $FfmpegRuntimeFiles) {
    $sourcePath = Join-Path $ffmpegBinDir.FullName $runtimeFile
    if (-not (Test-Path -LiteralPath $sourcePath)) {
        throw "Required FFmpeg runtime file '$runtimeFile' not found inside $zipName"
    }
    Copy-Item -LiteralPath $sourcePath -Destination (Join-Path $destinationRoot $runtimeFile) -Force
}

# Ship the license alongside the binary (LGPL attribution, ADR 0004).
$licenseFile = Get-ChildItem -Path $extractDir -Recurse -File -Include "LICENSE*" | Select-Object -First 1
if ($licenseFile) {
    Copy-Item -Path $licenseFile.FullName -Destination (Join-Path $destinationRoot "FFMPEG_LICENSE.txt") -Force
}

Remove-Item -Path $extractDir -Recurse -Force
Write-Host "FFmpeg shared runtime staged at $destinationRoot" -ForegroundColor Green
