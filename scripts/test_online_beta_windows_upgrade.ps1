param(
    [Parameter(Mandatory = $true)]
    [string]$ReleaseCandidateInstaller,
    # The last stable desktop release: the build users upgrade from, and the
    # one a rollback reinstalls.
    [string]$PublicInstallerUrl = "https://github.com/SunkenInTime/icarus/releases/download/desktop-stable-v4.6.3%2B103/icarus-setup.exe",
    [string]$PublicInstallerSha256 = "356196e515ccab61c547c065dbe8fc93003865ac90c15239d10b318a03055079",
    [string]$PublicVersion = "4.6.3",
    [string]$ReleaseCandidateVersion = "",
    [string]$PublicFixtureUrl = "https://raw.githubusercontent.com/SunkenInTime/icarus/fddec2b0b6163cf3962863db18ab0f06ea467773/base-test.ica",
    [string]$PublicFixtureSha256 = "166eb3ad31a19aca418081dc3ba949aedbf12b5049cd007fda410814a03b0b1a",
    [int]$ReadySeconds = 30,
    [int]$LaunchSeconds = 30
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
$installedExe = $null
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
    param(
        [Parameter(Mandatory = $true)][string]$InstallerPath,
        [Parameter(Mandatory = $true)][string]$ExpectedVersion
    )

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
    $script:installedExe = Resolve-IcarusExecutable -ExpectedVersion $ExpectedVersion
    Write-Host "Resolved installed Icarus executable: $script:installedExe"
}

function Resolve-IcarusExecutable {
    param([Parameter(Mandatory = $true)][string]$ExpectedVersion)

    $uninstallRoots = @(
        "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall",
        "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall",
        "HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall"
    )
    $registryCandidates = foreach ($root in $uninstallRoots) {
        if (-not (Test-Path $root)) {
            continue
        }
        Get-ChildItem $root -ErrorAction SilentlyContinue |
            ForEach-Object { Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue } |
            Where-Object {
                $displayNameProperty = $_.PSObject.Properties['DisplayName']
                $null -ne $displayNameProperty -and
                    ([string]$displayNameProperty.Value) -like "Icarus*"
            } |
            ForEach-Object {
                $displayIconProperty = $_.PSObject.Properties['DisplayIcon']
                if ($null -ne $displayIconProperty -and
                    -not [string]::IsNullOrWhiteSpace($displayIconProperty.Value)) {
                    $displayIcon = ([string]$displayIconProperty.Value).Trim()
                    ($displayIcon -replace ',\d+$', '').Trim('"')
                }
                $installLocationProperty = $_.PSObject.Properties['InstallLocation']
                if ($null -ne $installLocationProperty -and
                    -not [string]::IsNullOrWhiteSpace($installLocationProperty.Value)) {
                    Join-Path ([string]$installLocationProperty.Value) "icarus.exe"
                }
            }
    }
    $resolved = $registryCandidates |
        Where-Object { Test-Path $_ -PathType Leaf } |
        ForEach-Object { Get-Item $_ } |
        Where-Object {
            Test-ObservedVersion -ObservedVersion (Get-ObservedVersion -ExecutablePath $_.FullName) `
                -ExpectedVersion $ExpectedVersion
        } |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1

    if ($null -eq $resolved) {
        $resolved = Get-ChildItem -Path $env:LOCALAPPDATA -Filter "icarus.exe" `
            -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object {
                Test-ObservedVersion -ObservedVersion (Get-ObservedVersion -ExecutablePath $_.FullName) `
                    -ExpectedVersion $ExpectedVersion
            } |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1
    }
    if ($null -eq $resolved) {
        throw "Installer completed, but no Icarus $ExpectedVersion executable was found in the per-user registry or LocalAppData."
    }
    return $resolved.FullName
}

function Get-ObservedVersion {
    param([Parameter(Mandatory = $true)][string]$ExecutablePath)

    $versionInfo = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($ExecutablePath)
    $observed = [string]$versionInfo.ProductVersion
    if ([string]::IsNullOrWhiteSpace($observed)) {
        $observed = [string]$versionInfo.FileVersion
    }
    return $observed.Trim()
}

function Test-ObservedVersion {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$ObservedVersion,
        [Parameter(Mandatory = $true)][string]$ExpectedVersion
    )

    $expectedMatch = [System.Text.RegularExpressions.Regex]::Match(
        $ExpectedVersion,
        '^\d+\.\d+\.\d+$'
    )
    $observedMatch = [System.Text.RegularExpressions.Regex]::Match(
        $ObservedVersion,
        '^(?<core>\d+\.\d+\.\d+)(?:\.0)?(?:\+\d+)?$'
    )
    return $expectedMatch.Success -and
        $observedMatch.Success -and
        $observedMatch.Groups['core'].Value -eq $ExpectedVersion
}

function Assert-InstalledVersion {
    param([Parameter(Mandatory = $true)][string]$ExpectedVersion)

    $observed = Get-ObservedVersion -ExecutablePath $installedExe
    if (-not (Test-ObservedVersion -ObservedVersion $observed -ExpectedVersion $ExpectedVersion)) {
        throw "Expected installed Icarus $ExpectedVersion, observed '$observed'."
    }
    return $observed
}

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class IcarusRunnerWindow
{
    private delegate bool EnumWindowsProc(IntPtr window, IntPtr parameter);

    [DllImport("user32.dll")]
    private static extern bool EnumWindows(EnumWindowsProc callback, IntPtr parameter);

    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetClassName(IntPtr window, StringBuilder className, int maxCount);

    [DllImport("user32.dll")]
    private static extern bool IsWindowVisible(IntPtr window);

    [DllImport("user32.dll")]
    private static extern IntPtr SendMessageTimeout(
        IntPtr window, uint message, IntPtr wParam, IntPtr lParam,
        uint flags, uint timeoutMilliseconds, out IntPtr result);

    private const uint WmNull = 0x0000;
    private const uint SmtoAbortIfHung = 0x0002;

    public static string State(int processId)
    {
        IntPtr runner = IntPtr.Zero;
        EnumWindows((window, parameter) =>
        {
            uint owner;
            GetWindowThreadProcessId(window, out owner);
            if (owner != (uint)processId)
            {
                return true;
            }
            StringBuilder className = new StringBuilder(64);
            GetClassName(window, className, className.Capacity);
            if (className.ToString() != "FLUTTER_RUNNER_WIN32_WINDOW")
            {
                return true;
            }
            runner = window;
            return false;
        }, IntPtr.Zero);

        if (runner == IntPtr.Zero)
        {
            return "NoWindow";
        }
        IntPtr ignored;
        bool answers = SendMessageTimeout(
            runner, WmNull, IntPtr.Zero, IntPtr.Zero,
            SmtoAbortIfHung, 1000, out ignored) != IntPtr.Zero;
        if (IsWindowVisible(runner))
        {
            return answers ? "Ready" : "ShownNotAnswering";
        }
        return answers ? "Hidden" : "HiddenNotAnswering";
    }
}
'@

$launchTimings = New-Object System.Collections.Generic.List[object]

function Get-DebugLogTail {
    $debugLog = Join-Path $supportDir "icarus_debug.log"
    if (-not (Test-Path $debugLog -PathType Leaf)) {
        return "(no $debugLog)"
    }
    return (Get-Content $debugLog -Tail 40) -join [Environment]::NewLine
}

function Get-LaunchDiagnosis {
    param(
        [Parameter(Mandatory = $true)][System.Diagnostics.Process]$Process,
        [Parameter(Mandatory = $true)][string]$State,
        [Parameter(Mandatory = $true)][double]$RecentCpuSeconds,
        [Parameter(Mandatory = $true)][double]$RecentWindowSeconds
    )

    $children = @(Get-CimInstance Win32_Process -Filter "ParentProcessId = $($Process.Id)" -ErrorAction SilentlyContinue |
        ForEach-Object { "$($_.Name) ($($_.ProcessId))" })
    $busy = if ($RecentCpuSeconds -ge 0.5) {
        "still working: it used $([math]::Round($RecentCpuSeconds, 1)) s of CPU in the last $([math]::Round($RecentWindowSeconds)) s"
    } else {
        "idle: it used $([math]::Round($RecentCpuSeconds, 2)) s of CPU in the last $([math]::Round($RecentWindowSeconds)) s"
    }
    $stage = switch ($State) {
        "NoWindow" { "It never created its window, so native startup stalled before the Flutter engine started." }
        "Hidden" { "Its window exists and answers messages but was never shown, so Flutter never drew a first frame." }
        "HiddenNotAnswering" { "Its window was never shown and stopped answering messages, so the main thread is blocked." }
        "ShownNotAnswering" { "Its window was shown and then stopped answering messages, so the app hung after its first frame." }
        default { "Its last observed state was $State." }
    }
    return "$stage The process is $busy. Child processes: $(if ($children.Count -gt 0) { $children -join ', ' } else { 'none' })."
}

function Read-WebView2Runtime {
    $runtimeRoot = Join-Path ${env:ProgramFiles(x86)} "Microsoft\EdgeWebView\Application"
    if (-not (Test-Path $runtimeRoot -PathType Container)) {
        Write-Host "No WebView2 runtime at $runtimeRoot to read ahead."
        return $null
    }
    $clock = [System.Diagnostics.Stopwatch]::StartNew()
    $files = @(Get-ChildItem -Path $runtimeRoot -Recurse -File)
    $bytes = [long]0
    foreach ($file in $files) {
        $stream = [System.IO.File]::OpenRead($file.FullName)
        try {
            $stream.CopyTo([System.IO.Stream]::Null)
            $bytes += $stream.Length
        }
        finally {
            $stream.Dispose()
        }
    }
    $seconds = [math]::Round($clock.Elapsed.TotalSeconds, 1)
    Write-Host "Read the WebView2 runtime ahead of the first launch: $($files.Count) files, $([math]::Round($bytes / 1MB)) MB in $seconds s"
    return [ordered]@{
        files = $files.Count
        megabytes = [math]::Round($bytes / 1MB)
        seconds = $seconds
    }
}

function Start-And-ProveAlive {
    param(
        [Parameter(Mandatory = $true)][string]$Label,
        [string[]]$Arguments = @()
    )

    $clock = [System.Diagnostics.Stopwatch]::StartNew()
    $process = if ($Arguments.Count -gt 0) {
        Start-Process -FilePath $installedExe -ArgumentList $Arguments -PassThru
    } else {
        Start-Process -FilePath $installedExe -PassThru
    }
    $timing = [ordered]@{
        launch = $Label
        processStartedSeconds = [math]::Round($clock.Elapsed.TotalSeconds, 2)
    }
    $cpuSamples = New-Object System.Collections.Generic.List[object]
    $state = "NoWindow"
    $readyAt = $null
    Write-Host "${Label}: process $($process.Id) started after $($timing.processStartedSeconds) s"

    while ($true) {
        $process.Refresh()
        $elapsed = $clock.Elapsed.TotalSeconds
        if ($process.HasExited) {
            $when = if ($null -eq $readyAt) {
                "before its window was ready (last state: $state)"
            } else {
                "$([math]::Round($elapsed - $readyAt, 1)) s after its window was ready"
            }
            throw "${Label}: Icarus exited $([math]::Round($elapsed, 1)) s after launch, $when. Exit code: $($process.ExitCode).$([Environment]::NewLine)Debug log tail:$([Environment]::NewLine)$(Get-DebugLogTail)"
        }
        if ($null -eq $readyAt) {
            $state = [IcarusRunnerWindow]::State($process.Id)
            if (-not $timing.Contains($state)) {
                $timing[$state] = [math]::Round($clock.Elapsed.TotalSeconds, 2)
                Write-Host "${Label}: $state after $($timing[$state]) s"
            }
            if ($state -eq "Ready") {
                $readyAt = $timing["Ready"]
            } else {
                $cpuSamples.Add([pscustomobject]@{
                    at = $elapsed
                    cpu = $process.TotalProcessorTime.TotalSeconds
                })
                if ($elapsed -ge $ReadySeconds) {
                    $recent = @($cpuSamples | Where-Object { $_.at -ge $elapsed - 10 })
                    $diagnosis = Get-LaunchDiagnosis -Process $process -State $state `
                        -RecentCpuSeconds ($recent[-1].cpu - $recent[0].cpu) `
                        -RecentWindowSeconds ($recent[-1].at - $recent[0].at)
                    throw "${Label}: Icarus did not show a responsive window within $ReadySeconds s. $diagnosis$([Environment]::NewLine)Debug log tail:$([Environment]::NewLine)$(Get-DebugLogTail)"
                }
            }
        }
        if ($null -ne $readyAt -and $elapsed -ge $LaunchSeconds) {
            break
        }
        Start-Sleep -Milliseconds 250
    }

    $timing["aliveSeconds"] = [math]::Round($clock.Elapsed.TotalSeconds, 2)
    $script:launchTimings.Add($timing)
    Write-Host "${Label}: ready after $readyAt s, still running after $($timing.aliveSeconds) s"
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
    Get-Process -Name "icarus" -ErrorAction SilentlyContinue |
        Stop-Process -Force -ErrorAction SilentlyContinue
}

# Processes that can hold files in the support directory: Icarus itself and
# helpers started with a path inside it (for example a WebView2 user-data dir).
function Get-SupportDirProcesses {
    Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Name -eq "icarus.exe" -or
                ($null -ne $_.CommandLine -and $_.CommandLine.Contains($supportDir))
        }
}

function Wait-ForSupportDirRelease {
    $deadline = (Get-Date).AddSeconds(30)
    while ((Get-Date) -lt $deadline) {
        $holders = @(Get-SupportDirProcesses)
        if ($holders.Count -eq 0) {
            return
        }
        $holders | ForEach-Object {
            Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
        }
        Start-Sleep -Milliseconds 500
    }
    $names = (@(Get-SupportDirProcesses) | ForEach-Object { "$($_.Name) ($($_.ProcessId))" }) -join ", "
    Write-Warning "Processes still running 30 seconds after Icarus was stopped: $names"
}

function Remove-SupportDir {
    $attempts = 10
    for ($attempt = 1; $attempt -le $attempts; $attempt++) {
        if (-not (Test-Path $supportDir)) {
            return
        }
        try {
            Remove-Item -Path $supportDir -Recurse -Force -ErrorAction Stop
            return
        }
        catch {
            if ($attempt -eq $attempts) {
                throw "Could not delete $supportDir after $attempts attempts: $($_.Exception.Message)"
            }
            Write-Host "Delete of $supportDir failed (attempt $attempt of $attempts), retrying: $($_.Exception.Message)"
            Start-Sleep -Seconds 2
        }
    }
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
$testError = $null
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

    Install-Icarus -InstallerPath $publicInstaller -ExpectedVersion $PublicVersion
    $observedPublicInstallPath = $installedExe
    $observedPublicVersion = Assert-InstalledVersion -ExpectedVersion $PublicVersion
    $webView2ReadAhead = Read-WebView2Runtime
    $runningProcess = Start-And-ProveAlive -Label "Public $PublicVersion" -Arguments @($fixtureFullPath)
    Wait-ForStrategyLibrary
    Stop-Icarus -Process $runningProcess
    $runningProcess = $null
    $beforeUpgrade = Get-StrategyLibraryEvidence
    $publicProbe = Invoke-LibraryProbe -Stage "public"

    Install-Icarus -InstallerPath $releaseCandidateInstallerPath `
        -ExpectedVersion $ReleaseCandidateVersion
    $observedCandidateInstallPath = $installedExe
    $observedCandidateVersion = Assert-InstalledVersion -ExpectedVersion $ReleaseCandidateVersion
    $runningProcess = Start-And-ProveAlive -Label "Candidate $ReleaseCandidateVersion"
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

    Install-Icarus -InstallerPath $publicInstaller -ExpectedVersion $PublicVersion
    $observedRollbackInstallPath = $installedExe
    $observedRollbackVersion = Assert-InstalledVersion -ExpectedVersion $PublicVersion
    $runningProcess = Start-And-ProveAlive -Label "Rollback $PublicVersion"
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
        publicInstallPath = $observedPublicInstallPath
        releaseCandidateVersion = $observedCandidateVersion
        releaseCandidateInstallPath = $observedCandidateInstallPath
        rollbackVersion = $observedRollbackVersion
        rollbackInstallPath = $observedRollbackInstallPath
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
        webView2ReadAhead = $webView2ReadAhead
        readySecondsLimit = $ReadySeconds
        launchSecondsPerBuild = $LaunchSeconds
        launches = $launchTimings
    }
    $evidence | ConvertTo-Json -Depth 4 | Set-Content -Path $evidencePath -Encoding utf8
    Write-Host "Windows public-upgrade and rollback smoke passed."
    Write-Host "Evidence: $evidencePath"
}
catch {
    $testError = $_
}

# Cleanup runs after the test either way. If both fail, the test's error is the
# one reported; a cleanup failure is only fatal when the test itself passed.
$cleanupError = $null
try {
    Stop-Icarus -Process $runningProcess
    Wait-ForSupportDirRelease
    Remove-SupportDir
    if ($hadPreexistingSupport -and (Test-Path $supportBackup)) {
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $supportDir) | Out-Null
        Move-Item -Path $supportBackup -Destination $supportDir
    }
}
catch {
    $cleanupError = $_
}

if ($null -ne $testError) {
    if ($null -ne $cleanupError) {
        Write-Warning "Cleanup also failed: $cleanupError"
    }
    throw $testError
}
if ($null -ne $cleanupError) {
    throw "The upgrade and rollback test passed, but cleanup failed: $cleanupError"
}
