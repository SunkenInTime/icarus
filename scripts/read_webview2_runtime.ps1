param([string]$ResultPath = "")

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$runtimeRoot = Join-Path ${env:ProgramFiles(x86)} "Microsoft\EdgeWebView\Application"
if (-not (Test-Path $runtimeRoot -PathType Container)) {
    Write-Host "No WebView2 runtime at $runtimeRoot to read ahead."
    return $null
}
$startedAt = (Get-Date).ToUniversalTime().ToString("o")
$clock = [System.Diagnostics.Stopwatch]::StartNew()
$files = @(Get-ChildItem -Path $runtimeRoot -Recurse -File)
$bytes = [long]0
$unread = 0
foreach ($file in $files) {
    try {
        $stream = [System.IO.File]::OpenRead($file.FullName)
        try {
            $stream.CopyTo([System.IO.Stream]::Null)
            $bytes += $stream.Length
        }
        finally {
            $stream.Dispose()
        }
    }
    catch {
        $unread++
    }
}
$seconds = [math]::Round($clock.Elapsed.TotalSeconds, 1)
Write-Host "Read the WebView2 runtime: $($files.Count - $unread) of $($files.Count) files, $([math]::Round($bytes / 1MB)) MB in $seconds s"
$result = [ordered]@{
    startedAt = $startedAt
    finishedAt = (Get-Date).ToUniversalTime().ToString("o")
    files = $files.Count
    unreadFiles = $unread
    megabytes = [math]::Round($bytes / 1MB)
    seconds = $seconds
}
if (-not [string]::IsNullOrWhiteSpace($ResultPath)) {
    $partialPath = "$ResultPath.partial"
    $result | ConvertTo-Json | Set-Content -Path $partialPath -Encoding utf8
    Move-Item -Path $partialPath -Destination $ResultPath -Force
}
return $result
