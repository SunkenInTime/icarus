param(
  [Parameter(Mandatory)] [string]$Exe,
  [Parameter(Mandatory)] [string]$Library,
  [Parameter(Mandatory)] [string]$Out,
  [int]$WaitSeconds = 20,
  [int]$WaitMinutes = 20
)
$ErrorActionPreference = 'Stop'
if ((Test-Path -LiteralPath $Out) -and (Get-ChildItem -LiteralPath $Out -Force | Select-Object -First 1)) {
  throw "$Out is not empty; give each check a new -Out"
}
$exePath = Join-Path (Resolve-Path -LiteralPath $Exe) 'icarus.exe'
$store = Join-Path $Out 'store'
$appData = Join-Path $Out 'appdata'
New-Item -ItemType Directory -Force -Path $store, $appData | Out-Null
Copy-Item -Path (Join-Path (Resolve-Path -LiteralPath $Library) '*') -Destination $store -Recurse
$result = Join-Path $Out 'result.txt'
function Note([string]$text) { $text; Add-Content -Path $result -Value "$(Get-Date -Format HH:mm:ss.fff) $text" }

$env:LOCALAPPDATA = $appData
$started = Get-Date
$process = Start-Process -FilePath $exePath -PassThru -ArgumentList @("`"--hive-store-dir=$store`"")
$null = $process.Handle
Note "started pid $($process.Id) on $store, LOCALAPPDATA $appData"

Start-Sleep -Seconds $WaitSeconds
$process.Refresh()
if ($process.MainWindowHandle -eq 0) {
  Note "no window after $WaitSeconds s; stopping it"
  Stop-Process -Id $process.Id
  $process.WaitForExit()
  Note 'CHECK DONE: the build never showed a window, so nothing was closed'
  exit 2
}
Note "window '$($process.MainWindowTitle)'; closing it as its X does"
$null = $process.CloseMainWindow()

if (-not $process.WaitForExit($WaitMinutes * 60 * 1000)) {
  Note "still running $WaitMinutes minutes after the close; stopping it"
  Stop-Process -Id $process.Id
  $process.WaitForExit()
}
Note "exited with $($process.ExitCode) (0x$('{0:X8}' -f $process.ExitCode))"
Start-Sleep -Seconds 5
$faults = Get-WinEvent -FilterHashtable @{ LogName = 'Application'; Id = 1000; StartTime = $started } -ErrorAction SilentlyContinue |
  Where-Object { $_.Message -match [regex]::Escape($exePath) }
foreach ($fault in $faults) {
  $lines = ($fault.Message -split [Environment]::NewLine) | Where-Object { $_ -match 'Faulting module name|Exception code|Fault offset|Faulting process id' }
  Note "crash event $($fault.TimeCreated.ToString('HH:mm:ss')): $($lines -join ' / ')"
}
if (-not $faults) { Note 'no application error event for this build since it started' }
$clean = $process.ExitCode -eq 0 -and -not $faults
Note "CHECK DONE: $(if ($clean) { 'exited cleanly' } else { 'did not exit cleanly' })"
exit $(if ($clean) { 0 } else { 1 })
