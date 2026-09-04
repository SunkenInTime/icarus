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

function Get-ReleaseBranchName {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepoRoot,
        [string]$BranchName = ""
    )

    if (-not [string]::IsNullOrWhiteSpace($BranchName)) {
        return $BranchName.Trim()
    }

    if ($env:GITHUB_REF_TYPE -eq "branch" -and -not [string]::IsNullOrWhiteSpace($env:GITHUB_REF_NAME)) {
        return $env:GITHUB_REF_NAME.Trim()
    }

    $resolvedBranch = (& git -C $RepoRoot branch --show-current).Trim()
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($resolvedBranch)) {
        throw "Could not determine the current branch for release safety checks."
    }

    return $resolvedBranch
}

function Assert-ReleaseBranch {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepoRoot,
        [Parameter(Mandatory = $true)]
        [ValidateSet("stable-desktop", "prerelease-desktop", "store", "production-backend")]
        [string]$ReleaseTarget,
        [string]$BranchName = ""
    )

    $resolvedBranch = Get-ReleaseBranchName -RepoRoot $RepoRoot -BranchName $BranchName
    if ($ReleaseTarget -ne "prerelease-desktop" -and $resolvedBranch -ne "main") {
        throw "Release target '$ReleaseTarget' is public and can only run from branch 'main'. Current branch: '$resolvedBranch'."
    }

    Write-Host "Release branch check passed for '$ReleaseTarget' on '$resolvedBranch'." -ForegroundColor Green
    return $resolvedBranch
}

function Resolve-CloudBuildConfiguration {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("stable", "prerelease", "store")]
        [string]$ReleaseTarget,
        [string]$ProductionConvexDeploymentUrl = "",
        [string]$ProductionConvexClientId = ""
    )

    if ($ReleaseTarget -eq "prerelease") {
        return [ordered]@{
            Environment = "development"
            DeploymentUrl = ""
            ClientId = ""
        }
    }

    $deploymentUrl = $ProductionConvexDeploymentUrl.Trim()
    $clientId = $ProductionConvexClientId.Trim()
    if ([string]::IsNullOrWhiteSpace($deploymentUrl) -or [string]::IsNullOrWhiteSpace($clientId)) {
        throw "Production cloud configuration is missing. Set ICARUS_PRODUCTION_CONVEX_DEPLOYMENT_URL and ICARUS_PRODUCTION_CONVEX_CLIENT_ID before building '$ReleaseTarget'."
    }

    $parsedUrl = $null
    if (-not [System.Uri]::TryCreate($deploymentUrl, [System.UriKind]::Absolute, [ref]$parsedUrl) -or
        $parsedUrl.Scheme -ne "https" -or
        [string]::IsNullOrWhiteSpace($parsedUrl.Host)) {
        throw "ICARUS_PRODUCTION_CONVEX_DEPLOYMENT_URL must be an absolute HTTPS URL."
    }

    if ($parsedUrl.Host -ieq "majestic-eel-413.convex.cloud" -or $clientId -eq "dev:majestic-eel-413") {
        throw "Production cloud configuration cannot use the Icarus development Convex deployment."
    }

    return [ordered]@{
        Environment = "production"
        DeploymentUrl = $deploymentUrl
        ClientId = $clientId
    }
}

function Test-PublishesStablePages {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourceDirectory,
        [Parameter()]
        [string[]]$SyncPaths = @()
    )

    $explicitStablePath = @($SyncPaths | Where-Object {
        (($_ -replace '\\', '/').Trim('/')) -match '^(updates|downloads)/windows/stable($|/)'
    }).Count -gt 0
    if ($explicitStablePath) {
        return $true
    }

    if ($SyncPaths.Count -gt 0) {
        return $false
    }

    $stableRoots = @(
        (Join-Path $SourceDirectory "updates\windows\stable"),
        (Join-Path $SourceDirectory "downloads\windows\stable")
    )
    return @($stableRoots | Where-Object { Test-Path -LiteralPath $_ }).Count -gt 0
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
