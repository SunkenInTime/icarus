# Gives a ground-truth run its own Convex deployment: a preview named after
# the current branch, running this checkout's convex/, with the dev
# deployment's environment variables. Dev is shared and CI doesn't deploy it,
# so it can lag main or hold another branch's functions; a preview always
# runs exactly the code you are testing.
#
#   $url = tool\drive\preview.ps1
#   tool\drive\build.ps1 -Out E:\w\x -Convex $url        # desktop driver build
#   tool\drive\build.ps1 -Out E:\w\x-web -Convex $url -Web
#   tool\drive\run.ps1 -Exe E:\w\x -Script ... -Account <email>
#   tool\drive\preview.ps1 -Delete                       # when you are done
#
# Running it again redeploys this checkout's convex/ to the same preview and
# keeps its data. -Delete then a new run gives an empty one. A preview starts
# empty: a test account's first sign-in makes its user row, and its library
# starts with nothing in it. Sign-in is the same Supabase project as every
# other build, so test accounts work unchanged.
#
# What the preview gets from dev:
# - R2: dev's bucket, icarus-media-dev (public at media-dev.icarus-strats.xyz),
#   so pictures uploaded in a run never reach the production bucket. The
#   script refuses to copy a production bucket name.
# - Presence: dev's worker and pass secret, so live presence works the same
#   as on dev.
#
# Each preview expires after -Hours (default 24) in case -Delete never runs.
# The preview deploy key lives in the secrets file below and can only create,
# deploy to and delete preview deployments. Reading dev's variables uses your
# own `npx convex` login (~/.convex/config.json). Run `npm ci` first.
param(
  [string]$Name,
  [switch]$Delete,
  [ValidateRange(1, 120)] [int]$Hours = 24,
  [string]$KeyFile = (Join-Path $HOME '.agents\secrets\icarus\convex-preview.env')
)
$ErrorActionPreference = 'Stop'
Set-Location (Join-Path $PSScriptRoot '..\..')
$projectId = 1317748 # dara-adedeji:icarus-46d47
$devDeployment = 'dev:majestic-eel-413'
$productionBuckets = @('icarus-media')

if (-not $Name) { $Name = (git rev-parse --abbrev-ref HEAD).Trim() }
if (-not $Name -or $Name -eq 'HEAD') { throw 'Detached HEAD: pass -Name.' }

$keyLine = Get-Content -LiteralPath $KeyFile |
  Where-Object { $_ -match '^CONVEX_PREVIEW_DEPLOY_KEY=' } |
  Select-Object -First 1
if (-not $keyLine) { throw "No CONVEX_PREVIEW_DEPLOY_KEY in $KeyFile" }
$key = $keyLine.Substring('CONVEX_PREVIEW_DEPLOY_KEY='.Length).Trim()
$api = 'https://api.convex.dev/v1'
$headers = @{ Authorization = "Bearer $key" }

function Find-Preview {
  # A preview deploy key lists only this project's previews.
  Invoke-RestMethod -Headers $headers "$api/projects/$projectId/list_deployments" |
    Where-Object { $_.previewIdentifier -eq $Name } |
    Select-Object -First 1
}

# npx convex reads these; a stray one would pick another deployment.
$env:CONVEX_DEPLOYMENT = $null
$env:CONVEX_DEPLOY_KEY = $null

if ($Delete) {
  $preview = Find-Preview
  if (-not $preview) { Write-Host "No preview named $Name."; return }
  Invoke-RestMethod -Method Post -Headers $headers "$api/deployments/$($preview.name)/delete" | Out-Null
  Write-Host "Deleted preview $Name ($($preview.name))."
  return
}

if (-not (Test-Path -LiteralPath 'node_modules\convex')) { throw 'Run npm ci first.' }

# Read dev's variables before deploying, so a dev that would hand the preview
# the production bucket stops the run before anything is made.
$env:CONVEX_DEPLOYMENT = $devDeployment
$devEnv = @(npx convex env list)
$env:CONVEX_DEPLOYMENT = $null
if ($LASTEXITCODE -ne 0) { throw "Could not read $devDeployment's environment variables." }
$bucket = $devEnv | Where-Object { $_ -match '^R2_BUCKET=' } | ForEach-Object { $_.Substring(10).Trim() }
if (-not $bucket) { throw "$devDeployment has no R2_BUCKET." }
if ($productionBuckets -contains $bucket) {
  throw "$devDeployment points at the production bucket $bucket; a preview would upload into it."
}

$env:CONVEX_DEPLOY_KEY = $key
try {
  # --codegen disable: convex/_generated is committed, and codegen rewrites
  # its line endings on Windows.
  npx convex deploy --preview-name $Name --typecheck enable --codegen disable -y | Out-Host
  if ($LASTEXITCODE -ne 0) { throw 'npx convex deploy failed.' }
  $preview = Find-Preview
  if (-not $preview) { throw "Deployed, but no preview named $Name is listed." }
  $devEnv | npx convex env set --force --deployment $preview.name | Out-Host
  if ($LASTEXITCODE -ne 0) { throw "Could not copy dev's environment variables to $($preview.name)." }
} finally {
  $env:CONVEX_DEPLOY_KEY = $null
}

$expiresAt = [DateTimeOffset]::UtcNow.AddHours($Hours).ToUnixTimeMilliseconds()
Invoke-RestMethod -Method Patch -Headers $headers -ContentType 'application/json' `
  -Body (@{ expiresAt = $expiresAt } | ConvertTo-Json) `
  "$api/deployments/$($preview.name)" | Out-Null

Write-Host "Preview $Name is $($preview.name), bucket $bucket, expires in $Hours h."
$preview.deploymentUrl
