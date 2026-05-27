Set-StrictMode -Version Latest

function Get-RepoRoot {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ScriptDirectory
    )

    return Split-Path -Parent $ScriptDirectory
}

function Resolve-RepoPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepoRoot,
        [Parameter(Mandatory = $true)]
        [string]$RelativePath
    )

    return Join-Path $RepoRoot $RelativePath
}

function Get-VersionInfo {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepoRoot
    )

    $pubspecPath = Resolve-RepoPath -RepoRoot $RepoRoot -RelativePath "pubspec.yaml"
    if (-not (Test-Path $pubspecPath)) {
        throw "pubspec.yaml not found at $pubspecPath"
    }

    $pubspecContent = Get-Content $pubspecPath -Raw
    if ($pubspecContent -notmatch 'version:\s*(\d+\.\d+\.\d+)\+(\d+)') {
        throw "Could not parse version: X.Y.Z+N from pubspec.yaml"
    }

    $versionName = $Matches[1]
    $buildNumber = [int]$Matches[2]
    $fullVersion = "$versionName+$buildNumber"

    return @{
        VersionName = $versionName
        BuildNumber = $buildNumber
        FullVersion = $fullVersion
        WindowsArchiveFolderName = "$fullVersion-windows"
    }
}

function Get-FlutterRoot {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepoRoot
    )

    $fvmConfigPath = Resolve-RepoPath -RepoRoot $RepoRoot -RelativePath ".fvmrc"
    if (-not (Test-Path $fvmConfigPath)) {
        throw ".fvmrc not found at $fvmConfigPath"
    }

    $fvmConfig = Get-Content $fvmConfigPath -Raw | ConvertFrom-Json
    $configuredVersion = $fvmConfig.flutter

    $candidates = @(
        (Resolve-RepoPath -RepoRoot $RepoRoot -RelativePath ".fvm\versions\$configuredVersion"),
        (Resolve-RepoPath -RepoRoot $RepoRoot -RelativePath ".fvm\flutter_sdk"),
        $env:FLUTTER_ROOT
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

    foreach ($candidate in $candidates) {
        $flutterBat = Join-Path $candidate "bin\flutter.bat"
        $flutterExe = Join-Path $candidate "bin\flutter"
        if ((Test-Path $flutterBat) -or (Test-Path $flutterExe)) {
            return $candidate
        }
    }

    throw "Unable to resolve FLUTTER_ROOT. Install the FVM SDK first with 'fvm install'."
}

function Invoke-RepoCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string]$WorkingDirectory,
        [Parameter(Mandatory = $true)]
        [string]$Command,
        [Parameter()]
        [string[]]$Arguments = @()
    )

    Write-Host "Running: $Command $($Arguments -join ' ')" -ForegroundColor Cyan
    Push-Location $WorkingDirectory
    try {
        & $Command @Arguments
        if ($LASTEXITCODE -ne 0) {
            throw ("Command failed with exit code {0}: {1} {2}" -f $LASTEXITCODE, $Command, ($Arguments -join ' '))
        }
    }
    finally {
        Pop-Location
    }
}
