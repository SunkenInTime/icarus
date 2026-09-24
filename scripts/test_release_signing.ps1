$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'common_release.ps1')

function Assert-Rejected {
    param([scriptblock]$Action, [string]$Expected)
    try {
        & $Action
    }
    catch {
        if ($_.Exception.Message -notlike "*$Expected*") { throw }
        return
    }
    throw "Expected rejection containing '$Expected'."
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('icarus-signing-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null
try {
    $signedSource = Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'
    Assert-AuthenticodeSignatures -Path $signedSource
    Assert-Rejected { Assert-AuthenticodeSignatures -Path (Join-Path $testRoot 'missing') } 'not found'
    Assert-Rejected { Assert-AuthenticodeSignatures -Path $testRoot } 'No Windows executables'

    $scripts = Join-Path $testRoot 'scripts'
    New-Item -ItemType Directory -Path $scripts | Out-Null
    foreach ($name in @('common_release.ps1', 'build_desktop_release.ps1', 'publish_pages_branch.ps1')) {
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination $scripts
    }
    Set-Content -LiteralPath (Join-Path $testRoot 'pubspec.yaml') -Value 'version: 1.2.3+4'
    $archive = Join-Path $testRoot 'dist/4/1.2.3+4-windows'
    $installer = Join-Path $testRoot 'build/installer'
    New-Item -ItemType Directory -Path $archive, $installer -Force | Out-Null
    Copy-Item -LiteralPath $signedSource -Destination (Join-Path $archive 'icarus.exe')
    Assert-AuthenticodeSignatures -Path $archive
    $nested = Join-Path $archive 'ffmpeg'
    New-Item -ItemType Directory -Path $nested | Out-Null
    $unsignedDll = Join-Path $nested 'runtime.dll'
    Set-Content -LiteralPath $unsignedDll -Value 'unsigned runtime'
    Assert-Rejected { Assert-AuthenticodeSignatures -Path $archive } 'Invalid Authenticode signature'
    Assert-Rejected { & (Join-Path $scripts 'build_desktop_release.ps1') -Phase stage } 'Invalid Authenticode signature'
    if (Test-Path (Join-Path $testRoot 'release')) { throw 'Stage wrote output before checking signatures.' }

    Copy-Item -LiteralPath $signedSource -Destination $unsignedDll -Force
    $installerExe = Join-Path $installer 'icarus-setup-1.2.3.exe'
    Set-Content -LiteralPath $installerExe -Value 'unsigned installer'
    Assert-Rejected { & (Join-Path $scripts 'build_desktop_release.ps1') -Phase stage } 'Invalid Authenticode signature'
    if (Test-Path (Join-Path $testRoot 'release')) { throw 'Stage wrote output before checking installer.' }

    $pages = Join-Path $testRoot 'pages'
    $downloads = Join-Path $pages 'downloads/windows/prerelease'
    New-Item -ItemType Directory -Path $downloads -Force | Out-Null
    Copy-Item -LiteralPath $installerExe -Destination $downloads
    Assert-Rejected {
        & (Join-Path $scripts 'publish_pages_branch.ps1') -SourceDir 'pages' -Remote 'must-not-contact-remote' -SyncPaths 'downloads/windows/prerelease'
    } 'Invalid Authenticode signature'
    $largeFile = Join-Path $downloads 'oversized.bin'
    $stream = [IO.File]::Create($largeFile)
    try { $stream.SetLength(100MB) } finally { $stream.Dispose() }
    Assert-PagesFileSizes -Path $pages
    $stream = [IO.File]::OpenWrite($largeFile)
    try { $stream.SetLength(100MB + 1) } finally { $stream.Dispose() }
    Assert-Rejected { Assert-PagesFileSizes -Path $pages } '100 MiB blob limit'
    Assert-Rejected {
        & (Join-Path $scripts 'publish_pages_branch.ps1') -SourceDir 'pages' -Remote 'must-not-contact-remote' -SyncPaths 'updates/windows/prerelease'
    } '100 MiB blob limit'
    Write-Host 'Pages size tests passed: 100 MiB accepted; oversized installer-stage file rejected before remote access.'
    Remove-Item -LiteralPath $largeFile
    Copy-Item -LiteralPath $signedSource -Destination (Join-Path $downloads 'icarus-setup-1.2.3.exe') -Force
    $updates = Join-Path $pages 'updates/windows/prerelease/1.2.3+4-windows'
    New-Item -ItemType Directory -Path $updates -Force | Out-Null
    Copy-Item -LiteralPath $signedSource -Destination (Join-Path $updates 'icarus.exe')
    Set-Content -LiteralPath (Join-Path (Split-Path $updates -Parent) 'app-archive.json') -Value '{"items":[]}'

    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'publish_installer_release.ps1') -Destination $scripts
    $releaseAssets = Join-Path $testRoot 'release/out/desktop/1.2.3+4'
    New-Item -ItemType Directory -Path $releaseAssets -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $releaseAssets 'icarus-setup.exe') -Value 'unsigned installer'
    Assert-Rejected { & (Join-Path $scripts 'publish_installer_release.ps1') } 'Invalid Authenticode signature'

    # Run the real release coordinator and publisher against a local Git remote.
    # Only the already-tested staging phase is replaced with prepared signed files.
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'release_desktop.ps1') -Destination $scripts
    Set-Content -LiteralPath (Join-Path $scripts 'build_desktop_release.ps1') -Value 'exit 0'
    Set-Content -LiteralPath (Join-Path $scripts 'publish_installer_release.ps1') -Value 'exit 0'
    $remote = Join-Path $testRoot 'remote.git'
    Invoke-RepoCommand -WorkingDirectory $testRoot -Command 'git' -Arguments @('init', '--bare', $remote)
    Invoke-RepoCommand -WorkingDirectory $testRoot -Command 'git' -Arguments @('init')
    Invoke-RepoCommand -WorkingDirectory $testRoot -Command 'git' -Arguments @('config', 'user.name', 'Release test')
    Invoke-RepoCommand -WorkingDirectory $testRoot -Command 'git' -Arguments @('config', 'user.email', 'release-test@example.invalid')
    Invoke-RepoCommand -WorkingDirectory $testRoot -Command 'git' -Arguments @('remote', 'add', 'origin', $remote)
    Set-Content -LiteralPath (Join-Path $testRoot 'keep.txt') -Value 'Unrelated Pages content'
    $priorVersion = Join-Path $testRoot 'updates/windows/prerelease/0.9.0+3-windows'
    New-Item -ItemType Directory -Path $priorVersion -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $priorVersion 'keep.txt') -Value 'An older update still downloading'
    Invoke-RepoCommand -WorkingDirectory $testRoot -Command 'git' -Arguments @('add', 'keep.txt', 'updates')
    Invoke-RepoCommand -WorkingDirectory $testRoot -Command 'git' -Arguments @('commit', '-m', 'Initial Pages content')
    Invoke-RepoCommand -WorkingDirectory $testRoot -Command 'git' -Arguments @('push', 'origin', 'HEAD:gh-pages')
    & (Join-Path $scripts 'release_desktop.ps1') -Phase stage -Channel prerelease -PublishPages -PagesPublishMode git-branch -PagesStageRoot pages
    $commits = & git --git-dir=$remote rev-list --count gh-pages
    if ($LASTEXITCODE -ne 0 -or $commits -ne '2') { throw 'Release did not publish in exactly one commit.' }
    foreach ($file in @('keep.txt', 'updates/windows/prerelease/0.9.0+3-windows/keep.txt', 'updates/windows/prerelease/1.2.3+4-windows/icarus.exe', 'updates/windows/prerelease/app-archive.json')) {
        & git --git-dir=$remote cat-file -e "gh-pages:$file"
        if ($LASTEXITCODE -ne 0) { throw "Missing published file: $file" }
    }
    Write-Host 'Atomic publication passed: updater and manifest in one commit; previous update and unrelated Pages content preserved.'

    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'publish_installer_release.ps1') -Destination $scripts -Force
    Copy-Item -LiteralPath $signedSource -Destination (Join-Path $releaseAssets 'icarus-setup.exe') -Force
    $metadataDirectory = Join-Path $testRoot 'release/metadata'
    New-Item -ItemType Directory -Path $metadataDirectory -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $metadataDirectory '1.2.3+4.json') -Value '{"title":"Test release","changes":[{"message":"Test"}]}'
    Invoke-RepoCommand -WorkingDirectory $testRoot -Command 'git' -Arguments @('add', 'pubspec.yaml', 'release/metadata')
    Invoke-RepoCommand -WorkingDirectory $testRoot -Command 'git' -Arguments @('commit', '-m', 'Release metadata fixture')
    $global:releaseTestRemoteSource = $signedSource
    function gh {
        $global:LASTEXITCODE = 0
        if ($args[0] -eq 'release' -and $args[1] -eq 'list') {
            '[{"tagName":"desktop-stable-v1.2.3+4","isDraft":false}]'
        }
        elseif ($args[0] -eq 'release' -and $args[1] -eq 'download') {
            $directoryIndex = [Array]::IndexOf($args, '--dir') + 1
            Copy-Item -LiteralPath $global:releaseTestRemoteSource -Destination (Join-Path $args[$directoryIndex] 'icarus-setup.exe')
        }
        else { throw 'A retry attempted to create or modify a public release.' }
    }
    & (Join-Path $scripts 'publish_installer_release.ps1')
    $global:releaseTestRemoteSource = Join-Path $env:SystemRoot 'System32/cmd.exe'
    Assert-Rejected { & (Join-Path $scripts 'publish_installer_release.ps1') } 'different bytes'
    Remove-Item Function:gh
    Remove-Variable releaseTestRemoteSource -Scope Global
    Write-Host 'Release retry passed: identical signed asset accepted; different signed asset rejected without modifying the public release.'
    Write-Host 'Release signing tests passed: signed file accepted; missing, empty, nested unsigned DLL, unsigned installer, and direct unsigned publication rejected.'
}
finally {
    $resolvedTestRoot = [IO.Path]::GetFullPath($testRoot)
    $tempParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if (-not $resolvedTestRoot.StartsWith($tempParent, [StringComparison]::OrdinalIgnoreCase) -or
        (Split-Path -Leaf $resolvedTestRoot) -notlike 'icarus-signing-test-*') {
        throw "Refusing to remove unexpected test directory $resolvedTestRoot"
    }
    Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force
}
