param(
  [Parameter(Mandatory)] [string]$Out
)
$ErrorActionPreference = 'Stop'
Set-Location (Join-Path $PSScriptRoot '..\..')
Push-Location packages\icarus_library
dart pub get | Out-Null
Pop-Location
flutter pub get | Out-Null
flutter build windows --release --dart-define=ICARUS_CLOUD_ENVIRONMENT=development
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
if (Test-Path -LiteralPath $Out) { Remove-Item -LiteralPath $Out -Recurse -Force }
Copy-Item -LiteralPath 'build\windows\x64\runner\Release' -Destination $Out -Recurse
"built $Out from $(git rev-parse HEAD)"
