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
# signal / waitSignal steps. Each instance keeps its library and its sign-in
# under -Out, a new folder each run, so a run never signs the installed app
# in or out, and driver builds leave icarus: links with the installed app.
# The password comes from the test accounts file and only reaches the app's
# environment.
#
# Exits 0 when every instance finished its script with SUMMARY ... CLEAN and
# quit, 1 otherwise: a script without an exit step runs until
# -TimeoutSeconds, which fails it.
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
# New every run: the server refuses an item id another strategy holds.
$run = [guid]::NewGuid().ToString('N').Substring(0, 8)
if (-not $Out) { $Out = Join-Path (Split-Path -Parent (Resolve-Path $Exe)) "drive-$run" }
$Out = [System.IO.Path]::GetFullPath($Out)
# Signals and logs from an earlier run would pass for this one's.
if ((Test-Path -LiteralPath $Out) -and (Get-ChildItem -LiteralPath $Out -Force | Select-Object -First 1)) {
  throw "$Out is not empty; give each run a new -Out"
}
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
  $env:ICARUS_DRIVE_SESSION = Join-Path $Out "session-$name.json"
  $env:ICARUS_DRIVE_EMAIL = $Account
  $env:ICARUS_DRIVE_PASSWORD = $password
  try {
    $process = Start-Process -FilePath $exePath -PassThru `
      -ArgumentList ('"--hive-store-dir={0}"' -f (Join-Path $Out "store-$name")) `
      -RedirectStandardOutput (Join-Path $Out "$name-app.out") `
      -RedirectStandardError (Join-Path $Out "$name-app.err")
    $process
  } finally {
    $env:ICARUS_DRIVE_PASSWORD = $null
  }
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
  if (-not $process.HasExited) {
    Stop-Process -Id $process.Id
    "${name}: timed out after $TimeoutSeconds s"
    $clean = $false
  }
  # The exit code says nothing: Dart's exit() tears the app down with native
  # plugins still running, and Windows reports an access violation. A crash
  # before the end leaves no SUMMARY, which fails the run below.
  $log = Join-Path $Out "$name.log"
  $lines = if (Test-Path -LiteralPath $log) { Get-Content -LiteralPath $log } else { @() }
  $lines | Where-Object { $_ -match ' (FAIL|FLUTTER-ERROR|MISPLACED) ' } | ForEach-Object { "${name}: $_" }
  $summary = $lines | Where-Object { $_ -match ' SUMMARY ' } | Select-Object -Last 1
  "${name}: $(if ($summary) { $summary } else { 'no SUMMARY (the script never finished)' })"
  if (-not ($summary -match 'CLEAN$')) { $clean = $false }
}
"logs and shots: $Out"
exit $(if ($clean) { 0 } else { 1 })
