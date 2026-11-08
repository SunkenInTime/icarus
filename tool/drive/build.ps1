# Builds Icarus for Windows with the verification driver compiled in
# (lib/dev/drive/drive.dart), into -Out. Build from a short path (E:\w\...):
# long ones break the native plugin builds.
#
#   tool\drive\build.ps1 -Out E:\w\drive-exe
#   tool\drive\build.ps1 -Out E:\w\drive-exe -Mode debug
#
# The build talks to the dev deployment. Never point a driver build at
# production: the scripts create folders and strategies in the account.
#
# flutter build leaves out ffmpeg, which the installer ships, so -Out gets
# the same pinned copy (scripts/fetch_ffmpeg.ps1). Without it, MP4 export
# stops at a "Video encoder not found" toast that a later shot misses.
param(
  [Parameter(Mandatory)] [string]$Out,
  [ValidateSet('release', 'debug')] [string]$Mode = 'release'
)
$ErrorActionPreference = 'Stop'
Set-Location (Join-Path $PSScriptRoot '..\..')
flutter build windows "--$Mode" --dart-define=ICARUS_DRIVE=true --dart-define=ICARUS_CLOUD_ENVIRONMENT=development
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
$built = Join-Path 'build\windows\x64\runner' ((Get-Culture).TextInfo.ToTitleCase($Mode))
if (Test-Path -LiteralPath $Out) { Remove-Item -LiteralPath $Out -Recurse -Force }
Copy-Item -LiteralPath $built -Destination $Out -Recurse
& (Join-Path $PSScriptRoot '..\..\scripts\fetch_ffmpeg.ps1') -DestinationDir (Join-Path $Out 'ffmpeg')
"built $Out"
