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

    return "main"
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

    if ([string]::IsNullOrWhiteSpace($Token)) {
        $Token = $env:GITHUB_TOKEN
    }
    if ([string]::IsNullOrWhiteSpace($Token)) {
        $Token = $env:GH_TOKEN
    }

    if ([string]::IsNullOrWhiteSpace($Token)) {
        Write-Warning ("Skipped GitHub Pages deploy trigger because no token was provided. " +
            "Set -GitHubToken, GITHUB_TOKEN, or GH_TOKEN with permission to dispatch workflows, " +
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

    Write-Host ("Triggering GitHub Pages deploy workflow '{0}' on '{1}' for content branch '{2}'." -f $WorkflowFile, $WorkflowBranchRef, $PagesContentBranch) -ForegroundColor Cyan
    Invoke-RestMethod -Method Post -Uri $dispatchUri -Headers @{
        Accept = "application/vnd.github+json"
        Authorization = "Bearer $Token"
        "X-GitHub-Api-Version" = "2022-11-28"
    } -ContentType "application/json" -Body $payload | Out-Null

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
