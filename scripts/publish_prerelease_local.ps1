param(
    [ValidateSet("none", "patch", "minor", "major")]
    [string]$VersionBump = "patch",
    [switch]$Mandatory,
    [string]$ReleaseTitle = "",
    [string]$ChangeMessage = "Local prerelease build for updater testing.",
    [string]$PagesBranch = "gh-pages",
    [string]$PagesRemote = "origin",
    [string]$PagesDeployWorkflow = "deploy-pages-from-branch.yml",
    [string]$WorkflowRef = "",
    [string]$GitHubToken = "",
    [switch]$SkipPagesDeployTrigger,
    [switch]$SkipPubGet
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Get-EnvFileValue {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,
        [Parameter(Mandatory = $true)]
        [string[]]$Keys
    )

    if (-not (Test-Path $FilePath)) {
        return $null
    }

    foreach ($line in Get-Content $FilePath) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }

        $trimmed = $line.Trim()
        if ($trimmed.StartsWith("#")) {
            continue
        }

        if ($trimmed -notmatch '^(?<key>[A-Za-z_][A-Za-z0-9_]*)\s*=\s*(?<value>.*)$') {
            continue
        }

        $key = $Matches.key
        if ($Keys -notcontains $key) {
            continue
        }

        $value = $Matches.value.Trim()
        if (
            $value.Length -ge 2 -and
            (($value.StartsWith('"') -and $value.EndsWith('"')) -or
            ($value.StartsWith("'") -and $value.EndsWith("'")))
        ) {
            $value = $value.Substring(1, $value.Length - 2)
        }

        if (-not [string]::IsNullOrWhiteSpace($value)) {
            return $value
        }
    }

    return $null
}

function Resolve-GitHubToken {
    param(
        [string]$ExplicitToken
    )

    if (-not [string]::IsNullOrWhiteSpace($ExplicitToken)) {
        return $ExplicitToken
    }

    if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_TOKEN)) {
        return $env:GITHUB_TOKEN
    }

    if (-not [string]::IsNullOrWhiteSpace($env:GH_TOKEN)) {
        return $env:GH_TOKEN
    }

    $repoRoot = Split-Path -Parent $PSScriptRoot
    $envFiles = @(
        (Join-Path $repoRoot ".env.local"),
        (Join-Path $repoRoot ".env")
    )

    foreach ($envFile in $envFiles) {
        $token = Get-EnvFileValue -FilePath $envFile -Keys @("GITHUB_TOKEN", "GH_TOKEN")
        if (-not [string]::IsNullOrWhiteSpace($token)) {
            return $token
        }
    }

    return $null
}

function Get-RemoteRepositorySlug {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RemoteName
    )

    $remoteUrl = (& git remote get-url $RemoteName).Trim()
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($remoteUrl)) {
        throw "Could not resolve git remote URL for '$RemoteName'."
    }

    if ($remoteUrl -match 'github\.com[:/](?<owner>[^/]+)/(?<repo>[^/.]+)(?:\.git)?$') {
        return "$($Matches.owner)/$($Matches.repo)"
    }

    throw "Remote '$RemoteName' does not point to a GitHub repository: $remoteUrl"
}

function Get-RemoteDefaultBranch {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RemoteName
    )

    $remoteHead = (& git symbolic-ref "refs/remotes/$RemoteName/HEAD" 2>$null).Trim()
    if (
        $LASTEXITCODE -eq 0 -and
        $remoteHead -match "^refs/remotes/$([regex]::Escape($RemoteName))/(?<branch>.+)$"
    ) {
        return $Matches.branch
    }

    return "main"
}

function Get-WorkflowDispatchRef {
    param(
        [string]$RequestedRef
    )

    if (-not [string]::IsNullOrWhiteSpace($RequestedRef)) {
        return $RequestedRef
    }

    $branch = (& git rev-parse --abbrev-ref HEAD).Trim()
    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($branch) -and $branch -ne "HEAD") {
        return $branch
    }

    return "update/prerelease"
}

function Test-WorkflowFileOnRemoteRef {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RemoteName,
        [Parameter(Mandatory = $true)]
        [string]$WorkflowBranchRef,
        [Parameter(Mandatory = $true)]
        [string]$WorkflowFile
    )

    $objectPath = "${RemoteName}/${WorkflowBranchRef}:.github/workflows/${WorkflowFile}"
    & git cat-file -e $objectPath 2>$null
    return $LASTEXITCODE -eq 0
}

function Invoke-PagesDeployWorkflow {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RemoteName,
        [Parameter(Mandatory = $true)]
        [string]$WorkflowFile,
        [Parameter(Mandatory = $true)]
        [string]$WorkflowBranchRef,
        [Parameter(Mandatory = $true)]
        [string]$PagesContentBranch,
        [string]$Token
    )

    $Token = Resolve-GitHubToken -ExplicitToken $Token

    if ([string]::IsNullOrWhiteSpace($Token)) {
        Write-Warning ("Skipped GitHub Pages deploy trigger because no token was provided. " +
            "Set -GitHubToken, GITHUB_TOKEN, or GH_TOKEN with permission to dispatch workflows, " +
            "or place GITHUB_TOKEN / GH_TOKEN in .env.local or .env, " +
            "then rerun the script or manually run '{0}' on branch '{1}'." -f $WorkflowFile, $WorkflowBranchRef)
        return
    }

    $repoSlug = Get-RemoteRepositorySlug -RemoteName $RemoteName
    $dispatchUri = "https://api.github.com/repos/$repoSlug/actions/workflows/$WorkflowFile/dispatches"
    $payload = @{
        ref = $WorkflowBranchRef
        inputs = @{
            pages_branch = $PagesContentBranch
        }
    } | ConvertTo-Json -Depth 4

    if (-not (Test-WorkflowFileOnRemoteRef -RemoteName $RemoteName -WorkflowBranchRef $WorkflowBranchRef -WorkflowFile $WorkflowFile)) {
        Write-Warning ("Local git metadata does not show '.github/workflows/{0}' on '{1}/{2}'. " +
            "GitHub cannot run the prerelease dispatch unless the workflow exists on that branch. " +
            "If you merged it recently, run 'git fetch {1}' and try again." -f $WorkflowFile, $RemoteName, $WorkflowBranchRef)
    }

    $remoteDefaultBranch = Get-RemoteDefaultBranch -RemoteName $RemoteName
    if (-not (Test-WorkflowFileOnRemoteRef -RemoteName $RemoteName -WorkflowBranchRef $remoteDefaultBranch -WorkflowFile $WorkflowFile)) {
        Write-Warning ("Local git metadata does not show '.github/workflows/{0}' on the default branch '{1}/{2}'. " +
            "GitHub workflow_dispatch events are only received when the workflow file exists on the default branch, " +
            "even when the dispatched run ref remains '{3}'." -f $WorkflowFile, $RemoteName, $remoteDefaultBranch, $WorkflowBranchRef)
    }

    Write-Host ("Triggering GitHub Pages deploy workflow '{0}' on '{1}' for content branch '{2}'." -f $WorkflowFile, $WorkflowBranchRef, $PagesContentBranch) -ForegroundColor Cyan
    try {
        Invoke-RestMethod -Method Post -Uri $dispatchUri -Headers @{
            Accept = "application/vnd.github+json"
            Authorization = "Bearer $Token"
            "X-GitHub-Api-Version" = "2022-11-28"
        } -ContentType "application/json" -Body $payload | Out-Null
    }
    catch {
        $statusCode = $null
        if ($_.Exception.Response -and $_.Exception.Response.StatusCode) {
            $statusCode = [int]$_.Exception.Response.StatusCode
        }

        if ($statusCode -eq 404) {
            throw ("GitHub returned 404 while dispatching '{0}' at '{1}'. " +
                "Make sure '.github/workflows/{0}' exists on '{2}/{1}' and on the repository default branch so GitHub Actions receives workflow_dispatch events. " +
                "For private repositories, also make sure the token can access '{3}' and has workflow dispatch permission " +
                "(classic PAT: repo; fine-grained PAT: Actions read/write and Contents read)." -f $WorkflowFile, $WorkflowBranchRef, $RemoteName, $repoSlug)
        }

        throw
    }

    Write-Host "GitHub Pages deploy workflow dispatched." -ForegroundColor Green
}

$scriptPath = Join-Path $PSScriptRoot "release_desktop.ps1"
$params = @{
    VersionBump = $VersionBump
    Channel = "prerelease"
    PublishPages = $true
    PagesPublishMode = "git-branch"
    PagesBranch = $PagesBranch
    PagesRemote = $PagesRemote
    ReleaseTitle = $ReleaseTitle
    ChangeMessage = $ChangeMessage
}

if ($Mandatory) {
    $params.Mandatory = $true
}

if ($SkipPubGet) {
    $params.SkipPubGet = $true
}

& $scriptPath @params

if ($LASTEXITCODE -ne 0) {
    throw "Local prerelease publish failed."
}

if (-not $SkipPagesDeployTrigger) {
    $resolvedWorkflowRef = Get-WorkflowDispatchRef -RequestedRef $WorkflowRef
    Invoke-PagesDeployWorkflow -RemoteName $PagesRemote -WorkflowFile $PagesDeployWorkflow -WorkflowBranchRef $resolvedWorkflowRef -PagesContentBranch $PagesBranch -Token $GitHubToken
}
