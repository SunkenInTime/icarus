# Builds Icarus for Windows with the verification driver compiled in
# (lib/dev/drive/drive.dart), into -Out. Build from a short path (E:\w\...):
# long ones break the native plugin builds.
#
#   tool\drive\build.ps1 -Out E:\w\drive-exe
#   tool\drive\build.ps1 -Out E:\w\drive-exe -Mode debug
#   tool\drive\build.ps1 -Out E:\w\drive-exe -Convex (tool\drive\preview.ps1)
#   tool\drive\build.ps1 -Out E:\w\drive-web -Convex <url> -Web
#
# Without -Convex the build talks to the dev deployment, which other threads
# share and CI doesn't deploy. -Convex points it at a preview of your own
# branch from tool\drive\preview.ps1 (see its header). Never point a driver
# build at production: the scripts create folders and strategies in the
# account, so production's URL is refused.
#
# -Web builds the web app instead, without the driver, for a browser rig.
# Serve -Out on port 8765, the only local port the media bucket's CORS
# allows, or picture uploads fail: npx serve -s <Out> -l 8765
#
# flutter build leaves out ffmpeg, which the installer ships, so -Out gets
# the same pinned copy (scripts/fetch_ffmpeg.ps1). Without it, MP4 export
# stops at a "Video encoder not found" toast that a later shot misses.
param(
  [Parameter(Mandatory)] [string]$Out,
  [ValidateSet('release', 'debug')] [string]$Mode = 'release',
  [string]$Convex,
  [switch]$Web
)
$ErrorActionPreference = 'Stop'
Set-Location (Join-Path $PSScriptRoot '..\..')
$defines = @('--dart-define=ICARUS_CLOUD_ENVIRONMENT=development')
# An empty -Convex (say, preview.ps1 failed) must not quietly build against dev.
if ($PSBoundParameters.ContainsKey('Convex') -and -not $Convex) { throw '-Convex is empty.' }
if ($Convex) {
  if ($Convex -notmatch '^https://([a-z0-9-]+)\.convex\.cloud/?$') {
    throw "-Convex must be a https://<deployment>.convex.cloud URL, got $Convex"
  }
  $deployment = $Matches[1]
  if ($deployment -eq 'basic-dove-69') { throw 'basic-dove-69 is production.' }
  # The native client sends the id as its Convex-Client header. Convex
  # refuses the socket (400) unless it ends in -<version>, which
  # dev:<deployment> does.
  $defines += "--dart-define=ICARUS_CONVEX_DEPLOYMENT_URL=https://$deployment.convex.cloud"
  $defines += "--dart-define=ICARUS_CONVEX_CLIENT_ID=dev:$deployment"
}

if ($Web) {
  flutter build web "--$Mode" --no-wasm-dry-run @defines
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
  dart run tool/prepare_web_fonts.dart build/web
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
  if (Test-Path -LiteralPath $Out) { Remove-Item -LiteralPath $Out -Recurse -Force }
  Copy-Item -LiteralPath 'build\web' -Destination $Out -Recurse
  "built $Out; serve it with: npx serve -s $Out -l 8765"
  return
}

flutter build windows "--$Mode" --dart-define=ICARUS_DRIVE=true @defines
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
$built = Join-Path 'build\windows\x64\runner' ((Get-Culture).TextInfo.ToTitleCase($Mode))
if (Test-Path -LiteralPath $Out) { Remove-Item -LiteralPath $Out -Recurse -Force }
Copy-Item -LiteralPath $built -Destination $Out -Recurse
& (Join-Path $PSScriptRoot '..\..\scripts\fetch_ffmpeg.ps1') -DestinationDir (Join-Path $Out 'ffmpeg')
"built $Out"
