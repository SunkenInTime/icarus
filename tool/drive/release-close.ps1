param(
  [Parameter(Mandatory)] [string]$Exe,
  [Parameter(Mandatory)] [string]$Out,
  [string]$Library,
  [int]$WindowSeconds = 30,
  [int]$WaitSeconds = 20,
  [int]$WaitMinutes = 20
)
$ErrorActionPreference = 'Stop'
if ((Test-Path -LiteralPath $Out) -and (Get-ChildItem -LiteralPath $Out -Force | Select-Object -First 1)) {
  throw "$Out is not empty; give each check a new -Out"
}
$exePath = Join-Path (Resolve-Path -LiteralPath $Exe) 'icarus.exe'
$store = Join-Path $Out 'store'
New-Item -ItemType Directory -Force -Path $store | Out-Null
if ($Library) {
  Copy-Item -Path (Join-Path (Resolve-Path -LiteralPath $Library) '*') -Destination $store -Recurse
}
$result = Join-Path $Out 'result.txt'
function Note([string]$text) { $text; Add-Content -Path $result -Value "$(Get-Date -Format HH:mm:ss.fff) $text" }

$started = Get-Date
$process = Start-Process -FilePath $exePath -PassThru -ArgumentList @("`"--hive-store-dir=$store`"")
$null = $process.Handle
Note "started pid $($process.Id) as a separate instance at $store$(if (-not $Library) { ' on an empty library' })"

$window = 0
for ($second = 0; $second -lt $WindowSeconds -and -not $process.HasExited; $second++) {
  Start-Sleep -Seconds 1
  $process.Refresh()
  if ($process.MainWindowHandle -ne 0) { $window = $process.MainWindowHandle; break }
}
if ($window -eq 0) {
  if ($process.HasExited) {
    Note "exited with $($process.ExitCode) before showing a window"
  } else {
    Note "no window after $WindowSeconds s; stopping it"
    Stop-Process -Id $process.Id
    $process.WaitForExit()
  }
  Note 'CHECK DONE: the build never showed a window, so nothing was closed'
  exit 2
}
Note "window '$($process.MainWindowTitle)' after $([int]((Get-Date) - $started).TotalSeconds) s"
Start-Sleep -Seconds $WaitSeconds
Note "closing it as its X does, $WaitSeconds s after its window showed"
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
