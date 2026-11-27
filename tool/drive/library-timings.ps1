param(
  [Parameter(Mandatory)] [string]$Exe,
  [Parameter(Mandatory)] [string[]]$Library,
  [Parameter(Mandatory)] [string]$Out,
  [int]$Rounds = 2
)
$ErrorActionPreference = 'Stop'
if ((Test-Path -LiteralPath $Out) -and (Get-ChildItem -LiteralPath $Out -Force | Select-Object -First 1)) {
  throw "$Out is not empty; give each run a new -Out"
}
New-Item -ItemType Directory -Force -Path $Out | Out-Null
$script = Join-Path $PSScriptRoot 'scripts\library-timings-local.json'
$run = Join-Path $PSScriptRoot 'run.ps1'
$pattern = 'FIRSTFRAME|STORE move|STORE library|MEMORY|SAVETIME|BACKUPTIME|OPENFRAME summary|FRAMES library-scroll n=|SUMMARY'

function Start-Timed([string]$label, [string]$store, [string]$mode) {
  $runOut = Join-Path $Out $label
  & powershell -NoProfile -ExecutionPolicy Bypass -File $run -Exe $Exe -Script $script `
    -LibraryStore $mode -HiveStore $store -Out $runOut | Out-Null
  $lines = Get-Content -LiteralPath (Join-Path $runOut 'main.log') | Where-Object { $_ -match $pattern }
  "== $label"
  $lines
}

foreach ($library in $Library) {
  $name = Split-Path -Leaf $library
  for ($round = 1; $round -le $Rounds; $round++) {
    Start-Timed "$name-hive-$round" $library 'off'
    Start-Timed "$name-store-copy-$round" $library 'store'
    Start-Timed "$name-store-after-copy-$round" (Join-Path $Out "$name-store-copy-$round\store-main") 'store'
  }
}
