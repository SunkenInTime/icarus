param(
    [string]$SourceDir = "release\out\gh-pages",
    [string]$Branch = "gh-pages",
    [string]$Remote = "origin",
    [string[]]$SyncPaths = @()
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot "common_release.ps1")

$repoRoot = Get-RepoRoot -ScriptDirectory $PSScriptRoot
$resolvedSourceDir = Resolve-RepoPath -RepoRoot $repoRoot -RelativePath $SourceDir

if (-not (Test-Path $resolvedSourceDir)) {
    throw "Pages source directory not found at $resolvedSourceDir"
}

$remoteUrl = (& git -C $repoRoot remote get-url $Remote).Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($remoteUrl)) {
    throw "Could not resolve git remote URL for '$Remote'."
}

$remoteUri = $null
if ($remoteUrl -match '^https://') {
    $remoteUri = [System.Uri]$remoteUrl
}

$versionInfo = Get-VersionInfo -RepoRoot $repoRoot
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("icarus-pages-" + [System.Guid]::NewGuid().ToString("N"))

New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null

try {
    Invoke-RepoCommand -WorkingDirectory $tempRoot -Command "git" -Arguments @("init")
    Invoke-RepoCommand -WorkingDirectory $tempRoot -Command "git" -Arguments @("remote", "add", $Remote, $remoteUrl)

    if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_TOKEN) -and $null -ne $remoteUri) {
        $tokenBytes = [System.Text.Encoding]::ASCII.GetBytes("x-access-token:$($env:GITHUB_TOKEN)")
        $tokenHeader = "AUTHORIZATION: basic {0}" -f [System.Convert]::ToBase64String($tokenBytes)
        Push-Location $tempRoot
        try {
            & git config ("http.https://{0}/.extraheader" -f $remoteUri.Host) $tokenHeader
            if ($LASTEXITCODE -ne 0) {
                throw "Failed to configure authenticated git access for $($remoteUri.Host)."
            }
        }
        finally {
            Pop-Location
        }
    }

    $branchExists = $false
    $branchProbe = & git -C $repoRoot ls-remote --heads $Remote $Branch 2>$null
    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace(($branchProbe | Out-String).Trim())) {
        $branchExists = $true
    }

    if ($branchExists) {
        Invoke-RepoCommand -WorkingDirectory $tempRoot -Command "git" -Arguments @("fetch", "--depth", "1", $Remote, $Branch)
        Invoke-RepoCommand -WorkingDirectory $tempRoot -Command "git" -Arguments @("checkout", "-B", $Branch, "FETCH_HEAD")
    }
    else {
        Invoke-RepoCommand -WorkingDirectory $tempRoot -Command "git" -Arguments @("checkout", "-B", $Branch)
    }

    if ($SyncPaths.Count -gt 0) {
        foreach ($syncPath in $SyncPaths) {
            $sourcePath = Join-Path $resolvedSourceDir $syncPath
            $targetPath = Join-Path $tempRoot $syncPath

            if (Test-Path $targetPath) {
                Remove-Item -Path $targetPath -Recurse -Force
            }

            if (Test-Path $sourcePath) {
                $targetParent = Split-Path -Parent $targetPath
                if (-not [string]::IsNullOrWhiteSpace($targetParent)) {
                    New-Item -ItemType Directory -Force -Path $targetParent | Out-Null
                }
                Copy-Item -Path $sourcePath -Destination $targetPath -Recurse -Force
            }
        }
    }
    else {
        Copy-Item -Path (Join-Path $resolvedSourceDir "*") -Destination $tempRoot -Recurse -Force
    }

    $noJekyllPath = Join-Path $tempRoot ".nojekyll"
    if (-not (Test-Path $noJekyllPath)) {
        New-Item -ItemType File -Path $noJekyllPath | Out-Null
    }

    Invoke-RepoCommand -WorkingDirectory $tempRoot -Command "git" -Arguments @("config", "user.name", "Icarus Local Publisher")
    Invoke-RepoCommand -WorkingDirectory $tempRoot -Command "git" -Arguments @("config", "user.email", "local-publisher@users.noreply.github.com")
    Invoke-RepoCommand -WorkingDirectory $tempRoot -Command "git" -Arguments @("add", "--all")
    & git -C $tempRoot diff --cached --quiet
    if ($LASTEXITCODE -eq 0) {
        Write-Host "No Pages changes detected for $Remote/$Branch" -ForegroundColor Yellow
        return
    }

    Invoke-RepoCommand -WorkingDirectory $tempRoot -Command "git" -Arguments @("commit", "-m", "deploy: desktop $($versionInfo.FullVersion) [$Branch]")
    Invoke-RepoCommand -WorkingDirectory $tempRoot -Command "git" -Arguments @("push", "--force", $Remote, "HEAD:$Branch")

    Write-Host "Published staged Pages content to $Remote/$Branch" -ForegroundColor Green
}
finally {
    if (Test-Path $tempRoot) {
        Remove-Item -Path $tempRoot -Recurse -Force
    }
}
