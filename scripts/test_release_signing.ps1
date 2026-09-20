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
