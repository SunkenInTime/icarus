# Puts a picture on the Windows clipboard for the driver's "clipboard" step.
# A .bmp goes on as CF_DIB, the format apps and screenshots use and the one
# Icarus reads. With -File the file itself is copied, as Explorer does.
# scripts\paste-picture.json pastes the paste.bmp in the folder above -Out.
param(
  [Parameter(Mandatory)] [string]$Path,
  [switch]$File
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
$full = (Resolve-Path -LiteralPath $Path).Path
if ($File) {
  $files = [System.Collections.Specialized.StringCollection]::new()
  [void]$files.Add($full)
  [System.Windows.Forms.Clipboard]::SetFileDropList($files)
  exit 0
}
$bytes = [System.IO.File]::ReadAllBytes($full)
# A DIB is the bitmap without its 14-byte file header.
$dib = [byte[]]::new($bytes.Length - 14)
[Array]::Copy($bytes, 14, $dib, 0, $dib.Length)
$data = [System.Windows.Forms.DataObject]::new()
$data.SetData([System.Windows.Forms.DataFormats]::Dib, $false, [System.IO.MemoryStream]::new($dib, $false))
# Other programs hold the clipboard for a moment now and then.
[System.Windows.Forms.Clipboard]::SetDataObject($data, $true, 20, 100)
