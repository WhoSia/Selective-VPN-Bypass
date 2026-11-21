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

  # Import helper functions without touching the network. The list action reads only
  # this temporary JSON file; mocked rules are in-memory.
  . $core -Action list -ConfigDir $testDir | Out-Null
  $owned=[pscustomobject]@{
    Name='{00000000-0000-0000-0000-000000000001}'
    Namespace=@('example.com')
    Comment='Selective-VPN-Bypass-owned'
    NameServers=@('168.126.63.1','168.126.63.2')
  }
  if(-not (Test-CompatibleOwnedNrpt $owned 'example.com' @('168.126.63.2','168.126.63.1'))){
    throw 'Owned exact rule with matching DNS should be reusable.'
  }
  $foreign=[pscustomobject]@{Name=$owned.Name;Namespace=@('example.com');Comment='Another-VPN';NameServers=$owned.NameServers}
  if(Test-CompatibleOwnedNrpt $foreign 'example.com' @('168.126.63.1','168.126.63.2')){
    throw 'A foreign rule must never be adopted.'
  }
  $otherDns=[pscustomobject]@{Name=$owned.Name;Namespace=@('example.com');Comment=$owned.Comment;NameServers=@('1.1.1.1')}
  if(Test-CompatibleOwnedNrpt $otherDns 'example.com' @('168.126.63.1','168.126.63.2')){
    throw 'A tagged rule with mismatched DNS must be rejected.'
  }
  $otherScope=[pscustomobject]@{Name=$owned.Name;Namespace=@('.example.com');Comment=$owned.Comment;NameServers=$owned.NameServers}
  if(Test-CompatibleOwnedNrpt $otherScope 'example.com' @('168.126.63.1','168.126.63.2')){
    throw 'Exact-name and subdomain namespaces are not interchangeable.'
  }
  $multi=[pscustomobject]@{Name=$owned.Name;Namespace=@('example.com','.example.com');Comment=$owned.Comment;NameServers=$owned.NameServers}
  if(Test-CompatibleOwnedNrpt $multi 'example.com' @('168.126.63.1','168.126.63.2')){
    throw 'Multi-namespace rules must not be adopted as exact matches.'
  }
  Write-Host 'NRPT reconciliation predicate PASS: owned exact, foreign, mismatched DNS, wrong namespace, mixed namespace.'
  # Pure route identity and journal reconciliation regression tests.
  $rec=[pscustomobject]@{prefix='192.0.2.10/32';gateway='192.0.2.1'}
  $mockRoute=[pscustomobject]@{DestinationPrefix='192.0.2.10/32';NextHop='192.0.2.1';InterfaceIndex=9;RouteMetric=1}
  if(-not (Test-ManagedRouteMatch $mockRoute $rec 9)){throw 'Exact managed route rejected'}
  foreach($bad in @(
    [pscustomobject]@{DestinationPrefix='192.0.2.10/32';NextHop='192.0.2.2';InterfaceIndex=9;RouteMetric=1},
    [pscustomobject]@{DestinationPrefix='192.0.2.10/32';NextHop='192.0.2.1';InterfaceIndex=15;RouteMetric=1},
    [pscustomobject]@{DestinationPrefix='192.0.2.10/32';NextHop='192.0.2.1';InterfaceIndex=9;RouteMetric=20}
  )){
    if(Test-ManagedRouteMatch $bad $rec 9){throw 'Unmanaged route was incorrectly accepted'}
  }
  $st=[pscustomobject]@{routes=@();pendingRoutes=@($rec)}
  $pending=@(Route-Records $st)
  if($pending.Count -ne 1 -or $pending[0].prefix -ne '192.0.2.10/32'){
    throw 'Pending route was not available for crash recovery.'
  }
  $st.routes=@($rec)
  if(@(Route-Records $st).Count -ne 1){throw 'Committed and pending records must deduplicate'}
  $legacy=[pscustomobject]@{routes=@($rec)}
  if(@(Route-Records $legacy).Count -ne 1){throw 'Legacy state without pendingRoutes is not handled'}
  Write-Host 'Route journal tests PASS: pending/crash, dedupe, legacy, strict route tuple.'

  # A separate PowerShell process must not acquire the same named mutex.
  $lock=Enter-ConfigLock
  try{
    $probe=Join-Path $testDir 'lock-probe.ps1'
    @'
param([string]$Core,[string]$Dir)
$ErrorActionPreference='Stop'
. $Core -Action list -ConfigDir $Dir | Out-Null
try {
  $held=Enter-ConfigLock
  if($null -ne $held){$held.ReleaseMutex();$held.Dispose()}
  exit 7
} catch {
  if($_.Exception.Message -match 'Another operation is running'){exit 0}
  exit 8
}
'@ | Set-Content -LiteralPath $probe -Encoding UTF8
    $exe=Join-Path $PSHOME 'powershell.exe'
    & $exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $probe -Core $core -Dir $testDir
    if($LASTEXITCODE -ne 0){throw "Independent process lock isolation failed: exit $LASTEXITCODE"}
  }finally{
    $lock.ReleaseMutex()
    $lock.Dispose()
  }
  Write-Host 'Cross-process single-writer mutex PASS.'

  # End-to-end Restore-Own with mocked Windows NetTCPIP cmdlets:
  # same destination prefix, but one is owned and the other is foreign.
  $script:removedRoutes=@()
  function Get-NetAdapter {
    [CmdletBinding()]
    param([string]$Name)
    return [pscustomobject]@{ifIndex=9;Name=$Name}
  }
  function Get-NetRoute {
    [CmdletBinding()]
    param([int]$InterfaceIndex,[string]$AddressFamily)
    return @(
      [pscustomobject]@{DestinationPrefix='192.0.2.10/32';NextHop='192.0.2.1';InterfaceIndex=9;RouteMetric=1},
      [pscustomobject]@{DestinationPrefix='192.0.2.10/32';NextHop='192.0.2.254';InterfaceIndex=9;RouteMetric=1}
    )
  }
  function Remove-NetRoute {
    [CmdletBinding(SupportsShouldProcess=$true)]
    param([object]$InputObject)
    $script:removedRoutes+=,$InputObject
  }
  $journal=[ordered]@{version=5;wifiIndex=9;routes=@();pendingRoutes=@($rec);rules=@()}
  Save-Json $StatePath $journal
  Restore-Own | Out-Null
  if($script:removedRoutes.Count -ne 1 -or $script:removedRoutes[0].NextHop -ne '192.0.2.1'){
    throw 'Restore removed an unmanaged same-prefix route or missed pending route.'
  }
  if(Test-Path -LiteralPath $StatePath){throw 'Successful mocked Restore did not remove completed state file.'}
  Write-Host 'Mocked Restore PASS: pending route removed, same-prefix foreign route retained.'

  # Simulate a crash after NRPT creation but before its Windows-assigned ID
  # can be saved in completed rules. No live DNS settings are modified.
  $script:mockNrpt=@(
    [pscustomobject]@{Name='mock-owned-guid';Namespace=@('example.org');Comment='Selective-VPN-Bypass-owned';NameServers=@('192.0.2.53')},
    [pscustomobject]@{Name='mock-foreign-guid';Namespace=@('foreign.org');Comment='Other software';NameServers=@('192.0.2.53')}
  )
  $script:removedNrpt=@()
  function Get-DnsClientNrptRule {
    [CmdletBinding()]
    param([string]$Name)
    if($Name){return @($script:mockNrpt|Where-Object{$_.Name -eq $Name})}
    return $script:mockNrpt
  }
  function Remove-DnsClientNrptRule {
    [CmdletBinding()]
    param([string]$Name,[switch]$Force)
    $script:removedNrpt+=,$Name
  }
  $pendingRule=[pscustomobject]@{namespace='example.org';servers=@('192.0.2.53')}
  $state6=[ordered]@{version=6;wifiIndex=9;routes=@();pendingRoutes=@();rules=@();pendingRules=@($pendingRule)}
  if(@(Pending-NrptRecords $state6).Count -ne 1){throw 'Pending NRPT journal record was lost'}
  Save-Json $StatePath $state6
  Restore-Own | Out-Null
  if(($script:removedNrpt -join ',') -ne 'mock-owned-guid'){throw 'Pending recovery removed a foreign rule or missed the owned rule'}
  if(Test-Path -LiteralPath $StatePath){throw 'Successful pending NRPT Restore left state behind'}
  Write-Host 'Mocked NRPT crash recovery PASS: exact owner removed, foreign namespace preserved.'

  # A tagged-but-unrelated policy must not be deleted and the recovery
  # journal must remain so manual remediation is possible.
  $script:mockNrpt=@([pscustomobject]@{Name='mock-foreign-conflict';Namespace=@('example.org');Comment='Unrelated';NameServers=@('192.0.2.53')})
  $script:removedNrpt=@()
  Save-Json $StatePath $state6
  $refused=$false
  try{Restore-Own | Out-Null}catch{$refused=$true}
  if(-not $refused -or $script:removedNrpt.Count -ne 0 -or -not (Test-Path -LiteralPath $StatePath)){
    throw 'Conflicting NRPT policy was deleted or pending state was discarded.'
  }
  Remove-Item -LiteralPath $StatePath -Force
  Write-Host 'NRPT collision safety PASS: foreign policy refused, journal retained.'



  # Read-only Recovery Inspector classification matrix (no network writes).
  $mockOwned=[pscustomobject]@{
    Name='managed-rule';Namespace=@('example.org');Comment='Selective-VPN-Bypass-owned';NameServers=@('192.0.2.53')
  }
  $mockOwnedRoute=[pscustomobject]@{
    DestinationPrefix='192.0.2.10/32';NextHop='192.0.2.1';InterfaceIndex=9;RouteMetric=1
  }
  $complete=[pscustomobject]@{
    version=6;wifiIndex=9;rules=@('managed-rule');pendingRules=@();
    routes=@($rec);pendingRoutes=@()
  }
  $emptyJournal=[pscustomobject]@{version=6;wifiIndex=9;rules=@();routes=@();pendingRules=@();pendingRoutes=@()}
  $emptyResult=Inspect-JournalSnapshot $emptyJournal @() @()
  if($emptyResult.Code -ne 'INCOMPLETE'){throw 'Empty recovery journal must never imply verified applied state'}
  $matched=Inspect-JournalSnapshot $complete @($mockOwned) @($mockOwnedRoute)
  if($matched.Code -ne 'MATCHED_SNAPSHOT'){throw "Expected matching snapshot, got $($matched.Code)"}
  $none=Inspect-JournalSnapshot $null @() @()
  if($none.Code -ne 'NO_JOURNAL'){throw 'No journal must not be treated as verified clean'}
  $partial=Inspect-JournalSnapshot ([pscustomobject]@{
    version=6;wifiIndex=9;rules=@();routes=@();pendingRules=@(
      [pscustomobject]@{namespace='example.org';servers=@('192.0.2.53')}
    );pendingRoutes=@()
  }) @($mockOwned) @()
  if($partial.Code -ne 'INCOMPLETE'){throw 'Pending DNS journal must be incomplete'}
  $missing=Inspect-JournalSnapshot $complete @() @($mockOwnedRoute)
  if($missing.Code -ne 'MISMATCH'){throw 'Missing recorded DNS rule must be mismatch'}
  $conflict=Inspect-JournalSnapshot $complete @(
    [pscustomobject]@{Name='managed-rule';Namespace=@('example.org');Comment='foreign';NameServers=@('192.0.2.53')}
  ) @($mockOwnedRoute)
  if($conflict.Code -ne 'CONFLICT'){throw 'Foreign DNS with same ID must be conflict'}
  $unreadable=Inspect-JournalSnapshot ([pscustomobject]@{version=6;wifiIndex=9}) @() @()
  if($unreadable.Code -ne 'UNKNOWN'){throw 'Malformed schema must be unknown'}
  Write-Host 'Recovery Inspector PASS: matched, no journal, empty journal, pending, missing, conflict, invalid schema.'

  # Exercise public read-only action, including the normal CLI dispatch path.
  if(Test-Path -LiteralPath $StatePath){throw 'Inspector CLI test requires absent journal'}
  $output=@(& $core -Action inspect -ConfigDir $testDir)
  if(($output -join ' ') -notmatch 'Recovery inspection: NO_JOURNAL'){
    throw ("Read-only inspector dispatch failed: "+($output -join ' '))
  }
  if(Test-Path -LiteralPath $StatePath){throw 'Read-only inspector created or modified a recovery journal'}
  Write-Host 'Read-only recovery inspection command PASS: missing journal remains absent.'

  # A broken file must not be silently repaired, overwritten, or treated as empty.
  $originalConfig=Get-Content -LiteralPath $ConfigPath -Raw
  try{
    $broken='{"domains": ["example.com", }'
    Set-Content -LiteralPath $ConfigPath -Value $broken -NoNewline -Encoding UTF8
    if((Get-ConfigHealth) -ne 'INVALID'){throw 'Corrupt JSON was misreported as valid'}
    $before=[IO.File]::ReadAllBytes($ConfigPath)
    $diagnostic=@(& $core -Action inspect -ConfigDir $testDir 3>&1)
    if(($diagnostic -join ' ') -notmatch 'Recovery inspection: CONFIG_INVALID'){
      throw 'Inspector did not identify malformed config.'
    }
    $after=[IO.File]::ReadAllBytes($ConfigPath)
    if(([Convert]::ToBase64String($before)) -cne ([Convert]::ToBase64String($after))){
      throw 'Read-only inspection modified the malformed configuration'
    }
  }finally {
    Set-Content -LiteralPath $ConfigPath -Value $originalConfig -NoNewline -Encoding UTF8
  }
  if((Get-ConfigHealth) -ne 'OK'){throw 'Valid configuration not recognized'}
  $foreignOwned=[pscustomobject]@{
    Name='other-portable-guid';Namespace=@('orphan.example');Comment='Selective-VPN-Bypass-owned';NameServers=@('192.0.2.53')
  }
  if(@(Get-UnattributedOwnedNrpt $null @($foreignOwned)).Count -ne 1){
    throw 'Unattributed owner-tagged policy was hidden without a journal'
  }
  if(@(Get-UnattributedOwnedNrpt ([pscustomobject]@{
    rules=@('known-guid');pendingRules=@()
  }) @($foreignOwned)).Count -ne 1){
    throw 'Unknown policy was treated as owned by this portable folder'
  }
  if(@(Get-UnattributedOwnedNrpt ([pscustomobject]@{
    rules=@('other-portable-guid');pendingRules=@()
  }) @($foreignOwned)).Count -ne 0){
    throw 'Journal-known policy was counted as unattributed'
  }
  Write-Host 'Configuration and multi-portable diagnostics PASS: corrupted bytes preserved, unattributed owner tag signaled.'



  Write-Host "Empty defaults, domain/IP add, case normalization, persistence, remove and rejection PASS."
} finally {
  Remove-Item -LiteralPath $testDir -Recurse -Force -ErrorAction SilentlyContinue
}
