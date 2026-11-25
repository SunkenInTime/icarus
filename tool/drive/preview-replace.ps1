[CmdletBinding(PositionalBinding = $false)]
param(
  [Parameter(Mandatory = $true)] [string]$Name,
  [Parameter(Mandatory = $true, ValueFromRemainingArguments = $true)] [string[]]$Rest,
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
$env:ICARUS_PREVIEW_NAME = $Name
$env:NODE_NO_WARNINGS = '1'
node tool\drive\preview-replace.mjs @Rest
exit $LASTEXITCODE
