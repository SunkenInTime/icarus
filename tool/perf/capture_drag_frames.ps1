# Capture Icarus's presented frames with Intel PresentMon and summarise them
# against a refresh budget. PresentMon needs an elevated ETW session, so this
# script relaunches itself as administrator (one UAC prompt).
#
#   powershell -ExecutionPolicy Bypass -File tool/perf/capture_drag_frames.ps1 -Seconds 45 -Hz 165
#
# Start the release app first, then run this, then drag agents with view
# cones for the whole capture. The summary prints frame time and GPU busy
# percentiles and how many frames overran the budget.
param([int]$Seconds = 45, [double]$Hz = 165, [string]$Process = 'icarus.exe')
$ErrorActionPreference = 'Stop'
$root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$tools = Join-Path $root 'work\tools'
New-Item -ItemType Directory -Force $tools | Out-Null
$exe = Join-Path $tools 'PresentMon.exe'
if (-not (Test-Path $exe)) {
  Invoke-WebRequest -Uri 'https://github.com/GameTechDev/PresentMon/releases/download/v2.5.1/PresentMon-2.5.1-x64.exe' -OutFile $exe
}
$csv = Join-Path $root 'work\presentmon-drag.csv'
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  $args = "-ExecutionPolicy Bypass -File `"$PSCommandPath`" -Seconds $Seconds -Hz $Hz -Process $Process"
  Start-Process powershell -Verb RunAs -ArgumentList $args -Wait
  Write-Host "capture finished; summary:"
  python (Join-Path $PSScriptRoot 'analyze_presentmon.py') $csv (1000 / $Hz)
  exit
}
if (Test-Path $csv) { Remove-Item $csv }
Write-Host "Recording $Process for $Seconds s. Drag view-cone agents now."
& $exe --process_name $Process --output_file $csv --no_console_stats --timed $Seconds --terminate_after_timed --stop_existing_session
