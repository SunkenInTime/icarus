# Keeps the Windows clipboard busy the way a clipboard manager or Deskflow
# does, for checking a paste while something else has it open. Run it beside
# scripts\paste-while-busy.json:
#
#   tool\drive\hold-clipboard.ps1 -HoldMs 600 -EveryMs 600 -Seconds 200
#
# It opens the clipboard with a real window. Two opens with no window don't
# block each other, and the pasteboard plugin opens it with none.
param([int]$HoldMs = 600, [int]$EveryMs = 600, [int]$Seconds = 60)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class HeldClipboard {
  [DllImport("user32.dll", SetLastError = true)] public static extern bool OpenClipboard(IntPtr window);
  [DllImport("user32.dll")] public static extern bool CloseClipboard();
}
'@
$window = [System.Windows.Forms.Form]::new().Handle
$random = [Random]::new()
$end = (Get-Date).AddSeconds($Seconds)
while ((Get-Date) -lt $end) {
  if ([HeldClipboard]::OpenClipboard($window)) {
    Start-Sleep -Milliseconds $HoldMs
    [void][HeldClipboard]::CloseClipboard()
  }
  Start-Sleep -Milliseconds ($random.Next([int]($EveryMs / 2), [int]($EveryMs * 1.5)))
}
