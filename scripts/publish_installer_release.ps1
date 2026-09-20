param(
    [ValidateSet('stable', 'prerelease')][string]$Channel = 'stable',
    [string]$MetadataDir = 'release/metadata',
    [string]$Repository = 'SunkenInTime/icarus'
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'common_release.ps1')
$repoRoot = Get-RepoRoot -ScriptDirectory $PSScriptRoot
$version = Get-VersionInfo -RepoRoot $repoRoot
$installer = Join-Path $repoRoot "release/out/desktop/$($version.FullVersion)/icarus-setup.exe"
Assert-AuthenticodeSignatures -Path $installer
$metadata = Get-Content (Join-Path $repoRoot "$MetadataDir/$($version.FullVersion).json") -Raw | ConvertFrom-Json
$tag = "desktop-$Channel-v$($version.FullVersion)"
$releaseList = & gh release list --repo $Repository --limit 100 --json tagName,isDraft
if ($LASTEXITCODE -ne 0) { throw 'Could not inspect existing GitHub releases.' }
$releases = $releaseList | ConvertFrom-Json
$existing = @($releases | Where-Object { $_.tagName -eq $tag })
if ($existing.Count -gt 0 -and -not $existing[0].isDraft) {
    throw "Release $tag is already public. Use a new build number instead of replacing published bytes."
}
$draftExists = $existing.Count -gt 0
$notesFile = Join-Path ([IO.Path]::GetTempPath()) ("icarus-release-notes-" + [guid]::NewGuid() + '.md')
try {
    @($metadata.changes | ForEach-Object { '- ' + $_.message }) | Set-Content -LiteralPath $notesFile -Encoding UTF8
    if (-not $draftExists) {
        $target = (& git -C $repoRoot rev-parse HEAD).Trim()
        if ($LASTEXITCODE -ne 0) { throw 'Could not resolve release commit.' }
        Invoke-RepoCommand -WorkingDirectory $repoRoot -Command 'gh' -Arguments @(
            'release', 'create', $tag, '--repo', $Repository, '--target', $target,
            '--title', $metadata.title, '--notes-file', $notesFile, '--draft'
        )
    }
    Invoke-RepoCommand -WorkingDirectory $repoRoot -Command 'gh' -Arguments @(
        'release', 'upload', $tag, $installer, '--repo', $Repository, '--clobber'
    )
    $publishArgs = @('release', 'edit', $tag, '--repo', $Repository, '--draft=false')
    if ($Channel -eq 'prerelease') { $publishArgs += @('--prerelease', '--latest=false') }
    else { $publishArgs += '--latest=true' }
    Invoke-RepoCommand -WorkingDirectory $repoRoot -Command 'gh' -Arguments $publishArgs
}
finally {
    Remove-Item -LiteralPath $notesFile -Force -ErrorAction SilentlyContinue
}
