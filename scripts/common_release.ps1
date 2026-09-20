Set-StrictMode -Version Latest

function Assert-AuthenticodeSignatures {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Signing input not found at $Path"
    }
    $item = Get-Item -LiteralPath $Path
    $files = if ($item.PSIsContainer) {
        @(Get-ChildItem -LiteralPath $Path -Recurse -File | Where-Object {
            $_.Extension -in @('.exe', '.dll')
        })
    }
    else {
        @($item)
    }
    $files = @($files)
    if ($files.Count -eq 0) {
        throw "No Windows executables or libraries found at $Path"
    }
    foreach ($file in $files) {
        $signature = Get-AuthenticodeSignature -LiteralPath $file.FullName
        if ($signature.Status -ne 'Valid') {
            throw "Invalid Authenticode signature ($($signature.Status)): $($file.FullName). Run Release Desktop from main to build and sign release artifacts."
        }
    }
    Write-Host "Verified $($files.Count) signed Windows files at $Path"
}

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

function Assert-PagesFileSizes {
    param([Parameter(Mandatory = $true)][string]$Path)

    $oversized = @(Get-ChildItem -LiteralPath $Path -Recurse -File | Where-Object {
        $_.Length -gt 100MB
    })
    if ($oversized.Count -gt 0) {
        $details = $oversized | ForEach-Object { "$($_.FullName) ($($_.Length) bytes)" }
        throw "Release files exceed GitHub's 100 MiB blob limit: $($details -join ', ')"
    }
}

function Write-JsonFileUtf8 {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Value,
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter()]
        [int]$Depth = 8
    )

    $json = $Value | ConvertTo-Json -Depth $Depth
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText(
        [System.IO.Path]::GetFullPath($Path),
        $json + [System.Environment]::NewLine,
        $utf8NoBom
    )
}
