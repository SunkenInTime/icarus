# Runs a driver build (tool\drive\build.ps1) through a script, the way a user
# would use the app, and reports what a user would notice: Flutter errors,
# a canvas whose coordinates something replaced, agents and lineup ends drawn
# away from their saved positions, steps that failed. The steps are listed at
# the top of lib/dev/drive/drive.dart.
#
#   tool\drive\run.ps1 -Exe E:\w\drive-exe -Script tool\drive\scripts\editor-soak.json `
#     -Companion tool\drive\scripts\editor-soak-companion.json -Account <email>
#
# -Companion runs a second instance at the same time, signed in to the same
# account, like a second device; the two wait for each other with the
# signal / waitSignal steps. Each instance gets its own app data and library
# folder under -Out, so nothing touches the installed app or another run.
# The password comes from the test accounts file and only reaches the app's
# environment.
#
# Exits 0 when every instance logged SUMMARY ... CLEAN, 1 otherwise.
param(
  [Parameter(Mandatory)] [string]$Exe,
  [Parameter(Mandatory)] [string]$Script,
  [Parameter(Mandatory)] [string]$Account,
  [string]$Companion,
  [string]$Out,
  [string]$AccountsFile = (Join-Path $HOME '.agents\secrets\icarus\test-accounts.md'),
  [int]$TimeoutSeconds = 900
)
$ErrorActionPreference = 'Stop'
$run = Get-Date -Format 'HHmmss'
if (-not $Out) { $Out = Join-Path (Split-Path -Parent (Resolve-Path $Exe)) "drive-$run" }
New-Item -ItemType Directory -Force -Path (Join-Path $Out 'signals') | Out-Null
$exePath = if ((Get-Item -LiteralPath $Exe).PSIsContainer) { Join-Path $Exe 'icarus.exe' } else { $Exe }

$row = Get-Content -LiteralPath $AccountsFile |
  Where-Object { $_ -match ('^\|\s*' + [regex]::Escape($Account) + '\s*\|') } |
  Select-Object -First 1
if (-not $row) { throw "No row for $Account in $AccountsFile" }
$password = $row.Split('|')[2].Trim()

function Start-Instance([string]$name, [string]$scriptPath) {
  $env:LOCALAPPDATA = Join-Path $Out "appdata-$name"
  $env:ICARUS_DRIVE_SCRIPT = (Resolve-Path $scriptPath).Path
  $env:ICARUS_DRIVE_LOG = Join-Path $Out "$name.log"
  $env:ICARUS_DRIVE_RUN = $run
  $env:ICARUS_DRIVE_OUT = $Out
  $env:ICARUS_DRIVE_SIGNALS = Join-Path $Out 'signals'
  $env:ICARUS_DRIVE_EMAIL = $Account
  $env:ICARUS_DRIVE_PASSWORD = $password
  $process = Start-Process -FilePath $exePath -PassThru `
    -ArgumentList "--hive-store-dir=$(Join-Path $Out "store-$name")" `
    -RedirectStandardOutput (Join-Path $Out "$name-app.out") `
    -RedirectStandardError (Join-Path $Out "$name-app.err")
  $env:ICARUS_DRIVE_PASSWORD = $null
  $process
}

$originalAppData = $env:LOCALAPPDATA
$instances = [ordered]@{ main = Start-Instance 'main' $Script }
if ($Companion) { $instances.companion = Start-Instance 'companion' $Companion }
$env:LOCALAPPDATA = $originalAppData
$password = $null

$clean = $true
foreach ($name in $instances.Keys) {
  $process = $instances[$name]
  Wait-Process -Id $process.Id -Timeout $TimeoutSeconds -ErrorAction SilentlyContinue
  if (-not $process.HasExited) { Stop-Process -Id $process.Id; "$name timed out" }
  $log = Join-Path $Out "$name.log"
  $lines = if (Test-Path -LiteralPath $log) { Get-Content -LiteralPath $log } else { @() }
  $lines | Where-Object { $_ -match ' (FAIL|FLUTTER-ERROR|MISPLACED|NOT SETTLED) ' } | ForEach-Object { "${name}: $_" }
  $summary = $lines | Where-Object { $_ -match ' SUMMARY ' } | Select-Object -Last 1
  "${name}: $(if ($summary) { $summary } else { 'no SUMMARY (the script never finished)' })"
  if (-not ($summary -match 'CLEAN$')) { $clean = $false }
}
"logs and shots: $Out"
exit $(if ($clean) { 0 } else { 1 })
