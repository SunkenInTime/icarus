param(
    [string]$Device = "windows",
    [string[]]$WatchPath = @("lib", "assets", "pubspec.yaml"),
    [int]$DebounceMs = 750
)

$ErrorActionPreference = "Stop"
$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")

function New-RepoWatcher {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $resolved = Resolve-Path (Join-Path $repoRoot $Path)
    $item = Get-Item -LiteralPath $resolved
    $watcher = [System.IO.FileSystemWatcher]::new()

    if ($item.PSIsContainer) {
        $watcher.Path = $item.FullName
        $watcher.IncludeSubdirectories = $true
        $watcher.Filter = "*.*"
    }
    else {
        $watcher.Path = $item.DirectoryName
        $watcher.IncludeSubdirectories = $false
        $watcher.Filter = $item.Name
    }

    $watcher.NotifyFilter = [System.IO.NotifyFilters]'FileName, DirectoryName, LastWrite, Size'
    $watcher.EnableRaisingEvents = $true
    return $watcher
}

$process = [System.Diagnostics.Process]::new()
$process.StartInfo.FileName = "cmd.exe"
$process.StartInfo.Arguments = "/c fvm flutter run -d $Device"
$process.StartInfo.WorkingDirectory = $repoRoot
$process.StartInfo.UseShellExecute = $false
$process.StartInfo.RedirectStandardInput = $true

Write-Host "Starting: fvm flutter run -d $Device"
[void]$process.Start()

$lastReload = [DateTime]::MinValue
$syncRoot = [object]::new()

$action = {
    $path = $Event.SourceEventArgs.FullPath
    $name = [System.IO.Path]::GetFileName($path)

    if ($name -like "*.tmp" -or
        $name -like "*.swp" -or
        $name -like "*.lock" -or
        $path -match "\\\.dart_tool\\" -or
        $path -match "\\build\\") {
        return
    }

    [System.Threading.Monitor]::Enter($syncRoot)
    try {
        $now = [DateTime]::UtcNow
        if (($now - $script:lastReload).TotalMilliseconds -lt $DebounceMs) {
            return
        }

        $script:lastReload = $now
        if (-not $process.HasExited) {
            Write-Host "Hot reload: $path"
            $process.StandardInput.WriteLine("r")
        }
    }
    finally {
        [System.Threading.Monitor]::Exit($syncRoot)
    }
}

$watchers = @()
$subscriptions = @()

foreach ($path in $WatchPath) {
    $watcher = New-RepoWatcher -Path $path
    $watchers += $watcher

    foreach ($eventName in @("Changed", "Created", "Deleted", "Renamed")) {
        $subscriptions += Register-ObjectEvent -InputObject $watcher -EventName $eventName -Action $action
    }

    Write-Host "Watching: $path"
}

try {
    while (-not $process.HasExited) {
        Start-Sleep -Milliseconds 250
    }
}
finally {
    foreach ($subscription in $subscriptions) {
        Unregister-Event -SubscriptionId $subscription.Id -ErrorAction SilentlyContinue
    }

    foreach ($watcher in $watchers) {
        $watcher.Dispose()
    }

    if (-not $process.HasExited) {
        $process.StandardInput.WriteLine("q")
        $process.WaitForExit(5000)
    }
}
