param(
    [Parameter(Mandatory = $true)]
    [string]$ReleaseCandidateInstaller,
    [string]$PublicInstallerUrl = "https://github.com/SunkenInTime/icarus/releases/download/3.2.3/icarus-setup-3.2.3.exe",
    [string]$PublicInstallerSha256 = "58e489dbdc5f338747fbe0681137cd86052e1bda727dbfe2b938861043a57870",
    [string]$PublicVersion = "3.2.3",
    [string]$ReleaseCandidateVersion = "",
    [string]$PublicFixtureUrl = "https://raw.githubusercontent.com/SunkenInTime/icarus/fddec2b0b6163cf3962863db18ab0f06ea467773/base-test.ica",
    [string]$PublicFixtureSha256 = "166eb3ad31a19aca418081dc3ba949aedbf12b5049cd007fda410814a03b0b1a",
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
$installDir = Join-Path $env:LOCALAPPDATA "Programs\Icarus"
$installedExe = Join-Path $installDir "icarus.exe"
$supportDir = Join-Path $env:APPDATA "xyz.icarus-strats\icarus"
$strategyBox = Join-Path $supportDir "strategy_box.hive"
$testRoot = Join-Path $env:RUNNER_TEMP "icarus-online-beta-windows-smoke"
$publicInstaller = Join-Path $testRoot "icarus-setup-$PublicVersion.exe"
$fixtureFullPath = Join-Path $testRoot "base-test-v35.ica"
$supportBackup = Join-Path $testRoot "preexisting-app-support"
$evidencePath = Join-Path $testRoot "evidence.json"

if (-not (Test-Path $releaseCandidateInstallerPath -PathType Leaf)) {
    throw "Release-candidate installer not found: $releaseCandidateInstallerPath"
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
    $deadline = (Get-Date).AddSeconds($LaunchSeconds)
    $windowReady = $false
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 500
        $process.Refresh()
        if ($process.HasExited) {
            throw "Icarus exited during the $LaunchSeconds-second Windows launch smoke. Exit code: $($process.ExitCode)"
        }
        if ($process.MainWindowHandle -ne 0 -and $process.Responding) {
            $windowReady = $true
        }
    }
    if (-not $windowReady) {
        throw "Icarus stayed alive but did not expose a responsive Windows window within $LaunchSeconds seconds."
    }
    return $process
}

function Stop-Icarus {
    param([System.Diagnostics.Process]$Process)

    if ($null -ne $Process) {
        $Process.Refresh()
        if (-not $Process.HasExited) {
            $closeRequested = $Process.CloseMainWindow()
            if (-not $closeRequested -or -not $Process.WaitForExit(10000)) {
                Stop-Process -Id $Process.Id -Force
                $Process.WaitForExit(10000) | Out-Null
            }
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

function Invoke-LibraryProbe {
    param([Parameter(Mandatory = $true)][string]$Stage)

    $probePath = Join-Path $testRoot "library-$Stage.json"
    $beforeProbe = Get-StrategyLibraryEvidence
    $env:ICARUS_WINDOWS_SMOKE_SUPPORT_DIR = $supportDir
    $env:ICARUS_WINDOWS_SMOKE_PROBE_PATH = $probePath
    $env:ICARUS_WINDOWS_SMOKE_EXPECTED_STRATEGY_NAME = "base-test-v35"
    Push-Location $repoRoot
    try {
        & fvm flutter test test/windows_online_beta_library_probe_test.dart --reporter compact | Write-Host
        if ($LASTEXITCODE -ne 0) {
            throw "The $Stage Strategy library probe failed with exit code $LASTEXITCODE."
        }
    }
    finally {
        Pop-Location
        Remove-Item Env:ICARUS_WINDOWS_SMOKE_SUPPORT_DIR -ErrorAction SilentlyContinue
        Remove-Item Env:ICARUS_WINDOWS_SMOKE_PROBE_PATH -ErrorAction SilentlyContinue
        Remove-Item Env:ICARUS_WINDOWS_SMOKE_EXPECTED_STRATEGY_NAME -ErrorAction SilentlyContinue
    }

    if (-not (Test-Path $probePath -PathType Leaf)) {
        throw "The $Stage Strategy library probe did not write $probePath"
    }
    $afterProbe = Get-StrategyLibraryEvidence
    if ($afterProbe.byteSize -ne $beforeProbe.byteSize -or
        $afterProbe.sha256 -ne $beforeProbe.sha256) {
        throw "The read-only $Stage Strategy library probe changed the Hive file."
    }

    $probe = Get-Content $probePath -Raw | ConvertFrom-Json
    $hasher = [System.Security.Cryptography.SHA256]::Create()
    try {
        $invariantHash = [System.BitConverter]::ToString(
            $hasher.ComputeHash(
                [System.Text.Encoding]::UTF8.GetBytes(
                    [string]$probe.preservationInvariants
                )
            )
        ).Replace("-", "").ToLowerInvariant()
        $hasher.Initialize()
        $canonicalHash = [System.BitConverter]::ToString(
            $hasher.ComputeHash(
                [System.Text.Encoding]::UTF8.GetBytes(
                    [string]$probe.canonicalCurrentState
                )
            )
        ).Replace("-", "").ToLowerInvariant()
    }
    finally {
        $hasher.Dispose()
    }
    $probe | Add-Member -NotePropertyName invariantSha256 -NotePropertyValue $invariantHash
    $probe | Add-Member -NotePropertyName canonicalSha256 -NotePropertyValue $canonicalHash
    return $probe
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
    $observedPublicInstallerSha256 =
        (Get-FileHash -Path $publicInstaller -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($observedPublicInstallerSha256 -ne $PublicInstallerSha256.ToLowerInvariant()) {
        throw "Public installer checksum mismatch. Expected $PublicInstallerSha256, observed $observedPublicInstallerSha256."
    }
    Invoke-WebRequest -Uri $PublicFixtureUrl -OutFile $fixtureFullPath
    $observedFixtureSha256 =
        (Get-FileHash -Path $fixtureFullPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($observedFixtureSha256 -ne $PublicFixtureSha256.ToLowerInvariant()) {
        throw "Historical .ica fixture checksum mismatch. Expected $PublicFixtureSha256, observed $observedFixtureSha256."
    }

    Install-Icarus -InstallerPath $publicInstaller
    $observedPublicVersion = Assert-InstalledVersion -ExpectedVersion $PublicVersion
    $runningProcess = Start-And-ProveAlive -Arguments @($fixtureFullPath)
    Wait-ForStrategyLibrary
    Stop-Icarus -Process $runningProcess
    $runningProcess = $null
    $beforeUpgrade = Get-StrategyLibraryEvidence
    $publicProbe = Invoke-LibraryProbe -Stage "public"

    Install-Icarus -InstallerPath $releaseCandidateInstallerPath
    $observedCandidateVersion = Assert-InstalledVersion -ExpectedVersion $ReleaseCandidateVersion
    $runningProcess = Start-And-ProveAlive
    Stop-Icarus -Process $runningProcess
    $runningProcess = $null
    $afterUpgrade = Get-StrategyLibraryEvidence
    $candidateProbe = Invoke-LibraryProbe -Stage "candidate"
    if ($candidateProbe.invariantSha256 -ne $publicProbe.invariantSha256) {
        throw "The release-candidate upgrade changed Strategy, page, or entity identity and ordering invariants."
    }
    if ($candidateProbe.canonicalSha256 -ne $publicProbe.canonicalSha256) {
        throw "The release-candidate upgrade changed the normalized Strategy library semantics."
    }

    Install-Icarus -InstallerPath $publicInstaller
    $observedRollbackVersion = Assert-InstalledVersion -ExpectedVersion $PublicVersion
    $runningProcess = Start-And-ProveAlive
    Stop-Icarus -Process $runningProcess
    $runningProcess = $null
    $afterRollback = Get-StrategyLibraryEvidence
    $rollbackProbe = Invoke-LibraryProbe -Stage "rollback"
    if ($rollbackProbe.invariantSha256 -ne $candidateProbe.invariantSha256) {
        throw "Rolling back to the public build changed Strategy, page, or entity identity and ordering invariants."
    }
    if ($rollbackProbe.canonicalSha256 -ne $candidateProbe.canonicalSha256) {
        throw "Rolling back to the public build changed the Strategy library semantics."
    }
    if ($afterRollback.byteSize -ne $afterUpgrade.byteSize -or
        $afterRollback.sha256 -ne $afterUpgrade.sha256) {
        throw "The public rollback build rewrote the release-candidate Strategy library bytes."
    }

    $evidence = [ordered]@{
        publicInstallerUrl = $PublicInstallerUrl
        publicInstallerSha256 = $observedPublicInstallerSha256
        publicVersion = $observedPublicVersion
        releaseCandidateVersion = $observedCandidateVersion
        rollbackVersion = $observedRollbackVersion
        fixture = (Split-Path -Leaf $fixtureFullPath)
        fixtureSourceCommit = "fddec2b0b6163cf3962863db18ab0f06ea467773"
        fixtureSha256 = $observedFixtureSha256
        strategyCount = $candidateProbe.strategyCount
        strategyNames = $candidateProbe.strategyNames
        publicStoredVersions = $publicProbe.storedVersions
        candidateStoredVersions = $candidateProbe.storedVersions
        rollbackStoredVersions = $rollbackProbe.storedVersions
        preservationInvariantSha256 = $candidateProbe.invariantSha256
        normalizedLibrarySha256 = $candidateProbe.canonicalSha256
        publicLibraryBytes = $beforeUpgrade.byteSize
        publicLibrarySha256 = $beforeUpgrade.sha256
        candidateLibraryBytes = $afterUpgrade.byteSize
        candidateLibrarySha256 = $afterUpgrade.sha256
        rollbackLibraryBytes = $afterRollback.byteSize
        rollbackLibrarySha256 = $afterRollback.sha256
        upgradePreservedLibrarySemantics = $true
        rollbackPreservedLibrarySemantics = $true
        rollbackPreservedCandidateBytes = $true
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
