#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$core = Join-Path $repoRoot 'src\Core.ps1'
$tracked = @(
  (Join-Path $repoRoot 'src\Core.ps1'),
  (Join-Path $repoRoot 'src\Gui.ps1'),
  (Join-Path $repoRoot 'src\Worker.ps1')
)

Write-Host "Checking PowerShell syntax..."
foreach ($path in $tracked) {
  $tokens = $null
  $errors = $null
  [void][System.Management.Automation.Language.Parser]::ParseFile(
    $path, [ref]$tokens, [ref]$errors
  )
  if (@($errors).Count -gt 0) {
    $messages = @($errors | ForEach-Object { "$($_.Extent.StartLineNumber): $($_.Message)" })
    throw "Parsing failed ($path): $($messages -join '; ')"
  }
}
Write-Host "PowerShell syntax PASS."

$testDir = Join-Path ([IO.Path]::GetTempPath()) ('svb-regression-' + [guid]::NewGuid().ToString('N'))
New-Item -Path $testDir -ItemType Directory -Force | Out-Null
try {
  $configPath = Join-Path $testDir 'Selective-VPN-Bypass.domains.json'
  if (Test-Path -LiteralPath $configPath) { throw 'Test directory was not empty.' }
  $initial = @(& $core -Action list -ConfigDir $testDir)
  if ($initial.Count -ne 0) { throw "Initial exception list must be empty." }

  $targets = @('example.com', 'example.kr', 'example.wiki', '192.0.2.10')
  foreach ($target in $targets) {
    & $core -Action add -Domain $target -ConfigDir $testDir | Out-Null
  }
  & $core -Action add -Domain 'EXAMPLE.KR' -ConfigDir $testDir | Out-Null
  $saved = @( (& $core -Action list -ConfigDir $testDir) | Sort-Object -Unique )
  if ($saved.Count -ne $targets.Count) {
    throw "Expected $($targets.Count) unique entries, got $($saved.Count): $($saved -join ', ')"
  }
  foreach ($target in $targets) {
    if ($saved -notcontains $target) { throw "Missing saved exception: $target" }
  }

  $json = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
  $persisted = @($json.domains)
  if ($persisted.Count -ne 4) { throw 'Config JSON did not persist the expected entries.' }

  & $core -Action remove -Domain 'example.kr' -ConfigDir $testDir | Out-Null
  $after = @(& $core -Action list -ConfigDir $testDir)
  if ($after.Count -ne 3 -or $after -contains 'example.kr') {
    throw 'Removing one selected item did not preserve the other entries.'
  }

  $invalid = @('https://example.com/path', '*.example.com', '999.999.999.999', 'example.com/path')
  foreach ($value in $invalid) {
    $rejected = $false
    try {
      & $core -Action add -Domain $value -ConfigDir $testDir | Out-Null
    } catch { $rejected = $true }
    if (-not $rejected) { throw "Invalid input was accepted: $value" }
  }
  if (@(& $core -Action list -ConfigDir $testDir).Count -ne 3) {
    throw 'Invalid input changed the saved list.'
  }

  Write-Host "Empty defaults, domain/IP add, case normalization, persistence, remove and rejection PASS."
} finally {
  Remove-Item -LiteralPath $testDir -Recurse -Force -ErrorAction SilentlyContinue
}
