param(
    [Parameter(Mandatory = $true)]
    [string]$ReleaseCandidateInstaller,
    [string]$PublicInstallerUrl = "https://github.com/SunkenInTime/icarus/releases/download/3.2.3/icarus-setup-3.2.3.exe",
    [string]$PublicVersion = "3.2.3",
    [string]$ReleaseCandidateVersion = "",
    [string]$FixturePath = "test\fixtures\strategy_integrity\base-test.ica",
    [int]$LaunchSeconds = 12
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

if ($env:GITHUB_ACTIONS -ne "true") {
    throw "This smoke test replaces the installed Icarus build and is restricted to disposable GitHub Actions runners."
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$releaseCandidateInstallerPath = if ([System.IO.Path]::IsPathRooted($ReleaseCandidateInstaller)) {
    [System.IO.Path]::GetFullPath($ReleaseCandidateInstaller)
} else {
    [System.IO.Path]::GetFullPath((Join-Path $repoRoot $ReleaseCandidateInstaller))
}
$fixtureFullPath = [System.IO.Path]::GetFullPath((Join-Path $repoRoot $FixturePath))
$installDir = Join-Path $env:LOCALAPPDATA "Programs\Icarus"
$installedExe = Join-Path $installDir "icarus.exe"
$supportDir = Join-Path $env:APPDATA "xyz.icarus-strats\icarus"
$strategyBox = Join-Path $supportDir "strategy_box.hive"
$testRoot = Join-Path $env:RUNNER_TEMP "icarus-online-beta-windows-smoke"
$publicInstaller = Join-Path $testRoot "icarus-setup-$PublicVersion.exe"
$supportBackup = Join-Path $testRoot "preexisting-app-support"
$evidencePath = Join-Path $testRoot "evidence.json"

if (-not (Test-Path $releaseCandidateInstallerPath -PathType Leaf)) {
    throw "Release-candidate installer not found: $releaseCandidateInstallerPath"
}
if (-not (Test-Path $fixtureFullPath -PathType Leaf)) {
    throw "Legacy .ica fixture not found: $fixtureFullPath"
}
if ([string]::IsNullOrWhiteSpace($ReleaseCandidateVersion)) {
    $pubspec = Get-Content (Join-Path $repoRoot "pubspec.yaml") -Raw
    if ($pubspec -notmatch 'version:\s*(\d+\.\d+\.\d+)\+\d+') {
        throw "Could not parse the release-candidate version from pubspec.yaml."
    }
    $ReleaseCandidateVersion = $Matches[1]
}

function Install-Icarus {
    param([Parameter(Mandatory = $true)][string]$InstallerPath)

    $process = Start-Process -FilePath $InstallerPath -ArgumentList @(
        "/VERYSILENT",
        "/SUPPRESSMSGBOXES",
        "/NORESTART",
        "/SP-",
        "/TASKS=`"`""
    ) -Wait -PassThru
    if ($process.ExitCode -ne 0) {
        throw "Installer failed with exit code $($process.ExitCode): $InstallerPath"
    }
    if (-not (Test-Path $installedExe -PathType Leaf)) {
        throw "Installer completed without producing $installedExe"
    }
}

function Assert-InstalledVersion {
    param([Parameter(Mandatory = $true)][string]$ExpectedVersion)

    $versionInfo = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($installedExe)
    $observed = $versionInfo.ProductVersion
    if ([string]::IsNullOrWhiteSpace($observed)) {
        $observed = $versionInfo.FileVersion
    }
    if ([string]::IsNullOrWhiteSpace($observed) -or -not $observed.StartsWith($ExpectedVersion)) {
        throw "Expected installed Icarus $ExpectedVersion, observed '$observed'."
    }
    return $observed
}

function Start-And-ProveAlive {
    param([string[]]$Arguments = @())

    $process = if ($Arguments.Count -gt 0) {
        Start-Process -FilePath $installedExe -ArgumentList $Arguments -PassThru
    } else {
        Start-Process -FilePath $installedExe -PassThru
    }
    Start-Sleep -Seconds $LaunchSeconds
    $process.Refresh()
    if ($process.HasExited) {
        throw "Icarus exited during the $LaunchSeconds-second Windows launch smoke. Exit code: $($process.ExitCode)"
    }
    return $process
}

function Stop-Icarus {
    param([System.Diagnostics.Process]$Process)

    if ($null -ne $Process) {
        $Process.Refresh()
        if (-not $Process.HasExited) {
            Stop-Process -Id $Process.Id -Force
            $Process.WaitForExit(10000) | Out-Null
        }
    }
    Get-Process -Name "icarus" -ErrorAction SilentlyContinue | Stop-Process -Force
}

function Wait-ForStrategyLibrary {
    $deadline = (Get-Date).AddSeconds(30)
    while ((Get-Date) -lt $deadline) {
        if ((Test-Path $strategyBox -PathType Leaf) -and (Get-Item $strategyBox).Length -gt 0) {
            return
        }
        Start-Sleep -Milliseconds 500
    }
    throw "The public build did not import the legacy .ica fixture into $strategyBox"
}

function Get-StrategyLibraryEvidence {
    if (-not (Test-Path $strategyBox -PathType Leaf)) {
        throw "Strategy library is missing: $strategyBox"
    }
    $file = Get-Item $strategyBox
    if ($file.Length -le 0) {
        throw "Strategy library is empty: $strategyBox"
    }
    return [ordered]@{
        byteSize = $file.Length
        sha256 = (Get-FileHash -Path $strategyBox -Algorithm SHA256).Hash.ToLowerInvariant()
    }
}

New-Item -ItemType Directory -Force -Path $testRoot | Out-Null
$hadPreexistingSupport = Test-Path $supportDir
if ($hadPreexistingSupport) {
    if (Test-Path $supportBackup) {
        Remove-Item -Path $supportBackup -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $supportBackup) | Out-Null
    Move-Item -Path $supportDir -Destination $supportBackup
}

$runningProcess = $null
try {
    Invoke-WebRequest -Uri $PublicInstallerUrl -OutFile $publicInstaller

    Install-Icarus -InstallerPath $publicInstaller
    $observedPublicVersion = Assert-InstalledVersion -ExpectedVersion $PublicVersion
    $runningProcess = Start-And-ProveAlive -Arguments @($fixtureFullPath)
    Wait-ForStrategyLibrary
    Stop-Icarus -Process $runningProcess
    $runningProcess = $null
    $beforeUpgrade = Get-StrategyLibraryEvidence

    Install-Icarus -InstallerPath $releaseCandidateInstallerPath
    $observedCandidateVersion = Assert-InstalledVersion -ExpectedVersion $ReleaseCandidateVersion
    $runningProcess = Start-And-ProveAlive
    Stop-Icarus -Process $runningProcess
    $runningProcess = $null
    $afterUpgrade = Get-StrategyLibraryEvidence
    if ($afterUpgrade.byteSize -ne $beforeUpgrade.byteSize -or
        $afterUpgrade.sha256 -ne $beforeUpgrade.sha256) {
        throw "The release-candidate upgrade changed the local Strategy library bytes."
    }

    Install-Icarus -InstallerPath $publicInstaller
    $observedRollbackVersion = Assert-InstalledVersion -ExpectedVersion $PublicVersion
    $runningProcess = Start-And-ProveAlive
    Stop-Icarus -Process $runningProcess
    $runningProcess = $null
    $afterRollback = Get-StrategyLibraryEvidence
    if ($afterRollback.byteSize -ne $beforeUpgrade.byteSize -or
        $afterRollback.sha256 -ne $beforeUpgrade.sha256) {
        throw "Rolling back to the public build changed the local Strategy library bytes."
    }

    $evidence = [ordered]@{
        publicInstallerUrl = $PublicInstallerUrl
        publicVersion = $observedPublicVersion
        releaseCandidateVersion = $observedCandidateVersion
        rollbackVersion = $observedRollbackVersion
        fixture = (Split-Path -Leaf $fixtureFullPath)
        strategyLibraryBytes = $beforeUpgrade.byteSize
        strategyLibrarySha256 = $beforeUpgrade.sha256
        upgradePreservedLibrary = $true
        rollbackPreservedLibrary = $true
        launchSecondsPerBuild = $LaunchSeconds
    }
    $evidence | ConvertTo-Json -Depth 4 | Set-Content -Path $evidencePath -Encoding utf8
    Write-Host "Windows public-upgrade and rollback smoke passed."
    Write-Host "Evidence: $evidencePath"
}
finally {
    Stop-Icarus -Process $runningProcess
    if (Test-Path $supportDir) {
        Remove-Item -Path $supportDir -Recurse -Force
    }
    if ($hadPreexistingSupport -and (Test-Path $supportBackup)) {
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $supportDir) | Out-Null
        Move-Item -Path $supportBackup -Destination $supportDir
    }
}
