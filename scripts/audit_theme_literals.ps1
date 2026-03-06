# Theme literal audit for runtime UI code.
# Flags hardcoded colors/shadows outside allowlist patterns.

param(
  [string]$Root = "lib",
  [string]$AllowlistPath = "scripts/theme_literal_allowlist.txt",
  [switch]$UpdateBaseline
)

$patterns = @(
  "\bColor\(",
  "\bColors\.",
  "\bBoxShadow\(",
  "\bShadow\("
)

$matches = rg -n --glob "*.dart" ($patterns -join "|") $Root

if (-not $matches) {
  Write-Host "No color/shadow literals found."
  exit 0
}

$normalizedMatches = @()
foreach ($line in $matches) {
  if ($line -notmatch '^(?<path>[^:]+):(?<lineno>\d+):(?<content>.*)$') {
    continue
  }

  $path = $Matches['path']
  $lineno = $Matches['lineno']
  $content = $Matches['content']

  if ($path.EndsWith('.g.dart')) {
    continue
  }

  if ($content.TrimStart().StartsWith('//')) {
    continue
  }

  $normalizedMatches += "${path}:${lineno}:${content}"
}

$normalizedMatches = $normalizedMatches | Sort-Object -Unique

if ($UpdateBaseline) {
  $header = @(
    "# Regex allowlist for scripts/audit_theme_literals.ps1",
    "# One regex per line.",
    "# Generated baseline on $(Get-Date -Format o).",
    ""
  )

  $escaped = $normalizedMatches | ForEach-Object {
    [Regex]::Escape($_)
  }

  Set-Content -Path $AllowlistPath -Value ($header + $escaped)
  Write-Host "Updated theme literal allowlist baseline at $AllowlistPath with $($escaped.Count) entries."
  exit 0
}

$allowRules = @()
if (Test-Path $AllowlistPath) {
  $allowRules = Get-Content $AllowlistPath | Where-Object {
    $_.Trim() -and -not $_.TrimStart().StartsWith('#')
  }
}

$violations = @()
foreach ($line in $normalizedMatches) {
  $allowed = $false
  foreach ($rule in $allowRules) {
    if ($line -match $rule) {
      $allowed = $true
      break
    }
  }
  if (-not $allowed) {
    $violations += $line
  }
}

if ($violations.Count -eq 0) {
  Write-Host "Theme literal audit passed."
  exit 0
}

Write-Host "Theme literal audit found $($violations.Count) unallowlisted entries:" -ForegroundColor Yellow
$violations | ForEach-Object { Write-Host $_ }
exit 1

