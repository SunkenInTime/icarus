# Runs preview-reupload.mjs against a preview with the preview deploy key,
# which never leaves this machine.
#
#   tool\drive\preview-reupload.ps1 -Name <preview> -Strategy <strategy name> [-Show]
param(
  [Parameter(Mandatory)] [string]$Name,
  [Parameter(Mandatory)] [string]$Strategy,
  [switch]$Show,
  [string]$KeyFile = (Join-Path $HOME '.agents\secrets\icarus\convex-preview.env')
)
$ErrorActionPreference = 'Stop'
Set-Location (Join-Path $PSScriptRoot '..\..')
$keyLine = Get-Content -LiteralPath $KeyFile |
  Where-Object { $_ -match '^CONVEX_PREVIEW_DEPLOY_KEY=' } |
  Select-Object -First 1
if (-not $keyLine) { throw "No CONVEX_PREVIEW_DEPLOY_KEY in $KeyFile" }
$key = $keyLine.Substring('CONVEX_PREVIEW_DEPLOY_KEY='.Length).Trim()
if (-not $key.StartsWith('preview:dara-adedeji:icarus-46d47|')) {
  throw "$KeyFile does not hold a preview deploy key for icarus-46d47."
}
$env:CONVEX_DEPLOY_KEY = $key
$env:NODE_NO_WARNINGS = '1'
if ($Show) {
  node tool\drive\preview-reupload.mjs $Name $Strategy show
} else {
  node tool\drive\preview-reupload.mjs $Name $Strategy
}
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
