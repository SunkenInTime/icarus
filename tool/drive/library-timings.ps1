param(
  [Parameter(Mandatory)] [string]$Exe,
  [Parameter(Mandatory)] [string[]]$Library,
  [Parameter(Mandatory)] [string]$Out,
  [int]$Rounds = 2
)
$ErrorActionPreference = 'Stop'
$Library = @($Library | ForEach-Object { $_ -split ',' } | Where-Object { $_ })
if ((Test-Path -LiteralPath $Out) -and (Get-ChildItem -LiteralPath $Out -Force | Select-Object -First 1)) {
  throw "$Out is not empty; give each run a new -Out"
}
New-Item -ItemType Directory -Force -Path $Out | Out-Null
$timings = Join-Path $PSScriptRoot 'scripts\library-timings-local.json'
$copyOnly = Join-Path $PSScriptRoot 'scripts\library-copy-only-local.json'
$run = Join-Path $PSScriptRoot 'run.ps1'
$pattern = 'FIRSTFRAME|STORE move|STORE library|MEMORY|SAVETIME|BACKUPTIME|OPENFRAME summary|FRAMES library-scroll n=|SUMMARY'
$failed = @()

function Start-Run([string]$label, [string]$script, [string]$store, [string]$mode) {
  $runOut = Join-Path $Out $label
  $said = & powershell -NoProfile -ExecutionPolicy Bypass -File $run -Exe $Exe -Script $script `
    -LibraryStore $mode -HiveStore $store -Out $runOut
  $exit = $LASTEXITCODE
  if ($exit -ne 0) {
    "== $label FAILED (run.ps1 exited $exit); its numbers do not count"
    $said
    $script:failed += $label
    return
  }
  "== $label"
  Get-Content -LiteralPath (Join-Path $runOut 'main.log') | Where-Object { $_ -match $pattern }
}

foreach ($library in $Library) {
  $name = Split-Path -Leaf $library
  $migrated = Join-Path $Out "$name-migrated\store-main"
  Start-Run "$name-migrated" $copyOnly $library 'store'
  for ($round = 1; $round -le $Rounds; $round++) {
    Start-Run "$name-hive-$round" $timings $library 'off'
    Start-Run "$name-store-copy-$round" $timings $library 'store'
    if ($failed -notcontains "$name-migrated") {
      Start-Run "$name-store-after-copy-$round" $timings $migrated 'store'
    }
  }
}
if ($failed.Count -gt 0) {
  "failed runs: $($failed -join ', ')"
  exit 1
}
