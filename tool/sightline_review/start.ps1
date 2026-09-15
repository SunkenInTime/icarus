param(
    [string]$Flutter = 'E:/src/flutter/bin/flutter.bat',
    [int]$Port = 8770,
    [string]$OutputDirectory = "$env:LOCALAPPDATA/IcarusSightlineReviews",
    [string]$NativeLibrary = ''
)

$ErrorActionPreference = 'Stop'
$taskRepository = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../..')).Path
if (-not $NativeLibrary) {
    $NativeLibrary = Join-Path $taskRepository 'build/windows/x64/runner/Profile/icarus_height.dll'
}
if (-not (Test-Path -LiteralPath $NativeLibrary)) {
    throw 'Build the desktop native engine first, or pass -NativeLibrary.'
}
$env:ICARUS_REVIEW_PORT = "$Port"
$env:ICARUS_REVIEW_OUTPUT = [IO.Path]::GetFullPath($OutputDirectory)
$env:ICARUS_SVG_NATIVE_LIBRARY = (Resolve-Path -LiteralPath $NativeLibrary).Path
Set-Location -LiteralPath $taskRepository
& $Flutter test --no-pub --reporter expanded tool/serve_sightline_review_test.dart
exit $LASTEXITCODE
