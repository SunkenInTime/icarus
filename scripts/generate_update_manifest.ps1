param(
    [string]$MetadataDir = "release\metadata",
    [Parameter(Mandatory = $true)]
    [string]$OutputPath,
    [Parameter(Mandatory = $true)]
    [string]$BaseUrl,
    [ValidateSet("windows", "macos", "linux")]
    [string]$Platform = "windows",
    [string]$Channel = "stable"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot "common_release.ps1")

$repoRoot = Get-RepoRoot -ScriptDirectory $PSScriptRoot
$metadataRoot = Resolve-RepoPath -RepoRoot $repoRoot -RelativePath $MetadataDir
if (-not (Test-Path $metadataRoot)) {
    throw "Metadata directory not found at $metadataRoot"
}

$outputDirectory = Split-Path -Parent $OutputPath
New-Item -ItemType Directory -Force -Path $outputDirectory | Out-Null

$metadataFiles = Get-ChildItem -Path $metadataRoot -Filter *.json -File
$items = New-Object System.Collections.Generic.List[object]
$manifestAppName = "Icarus"
$manifestDescription = "Desktop updater manifest for Icarus."

foreach ($metadataFile in $metadataFiles) {
    $metadata = Get-Content $metadataFile.FullName -Raw | ConvertFrom-Json

    $channels = @($metadata.channels)
    $platforms = @($metadata.platforms)
    if ($channels -notcontains "desktop") {
        continue
    }
    if ($channels -notcontains $Channel) {
        continue
    }
    if ($platforms -notcontains $Platform) {
        continue
    }

    $version = [string]$metadata.version
    if ([string]::IsNullOrWhiteSpace($version)) {
        throw "Metadata file '$($metadataFile.Name)' is missing 'version'."
    }

    $shortVersion = if ($null -ne $metadata.shortVersion) { [int]$metadata.shortVersion } else { [int]($version.Split("+")[-1]) }
    $folderName = "$version-$Platform"
    $changes = @()
    foreach ($change in @($metadata.changes)) {
        if ($null -eq $change) {
            continue
        }

        $changeObject = [ordered]@{
            message = [string]$change.message
        }

        if ($change.PSObject.Properties.Name -contains "type" -and -not [string]::IsNullOrWhiteSpace([string]$change.type)) {
            $changeObject.type = [string]$change.type
        }

        $changes += $changeObject
    }

    if ($changes.Count -eq 0) {
        throw "Metadata file '$($metadataFile.Name)' must define at least one change entry."
    }

    if ($metadata.PSObject.Properties.Name -contains "description" -and -not [string]::IsNullOrWhiteSpace([string]$metadata.description)) {
        $manifestDescription = [string]$metadata.description
    }

    $items.Add([ordered]@{
        version = $version
        shortVersion = $shortVersion
        changes = $changes
        date = [string]$metadata.date
        mandatory = [bool]$metadata.mandatory
        url = ($BaseUrl.TrimEnd("/") + "/" + [System.Uri]::EscapeDataString($folderName))
        platform = $Platform
    })
}

$sortedItems = $items | Sort-Object { [int]$_.shortVersion } -Descending
if ($sortedItems.Count -eq 0) {
    throw "No desktop metadata entries matched channel '$Channel' for platform '$Platform'."
}

$manifest = [ordered]@{
    appName = $manifestAppName
    description = $manifestDescription
    items = @($sortedItems)
}

$manifest | ConvertTo-Json -Depth 8 | Set-Content -Path $OutputPath
Write-Host "Generated desktop updater manifest at $OutputPath" -ForegroundColor Green
