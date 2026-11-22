#Requires -Version 5.1
# Live integration test for an ephemeral GitHub-hosted Windows runner ONLY.
# Touches one reserved .invalid DNS namespace and one TEST-NET-2 /32 route.
# Never run on a personal device or production network.
$ErrorActionPreference='Stop'
if($env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted'){
 throw 'Live network test requires an ephemeral GitHub-hosted Actions runner.'
}
$identity=[Security.Principal.WindowsIdentity]::GetCurrent()
$principal=[Security.Principal.WindowsPrincipal]::new($identity)
if(-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){
 throw 'Runner does not have administrative rights for isolated network integration test.'
}
$root=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$core=Join-Path $root 'src\Core.ps1'
$dir=Join-Path $env:RUNNER_TEMP ('svb-live-recovery-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $dir | Out-Null
$testNamespace=('svb-recovery-'+[guid]::NewGuid().ToString('N')+'.invalid')
$prefix='198.51.100.241/32'
$server='192.0.2.53'
$index=$null
$gw=$null
$statePath=Join-Path $dir 'Selective-VPN-Bypass_v3.state.json'
$testSucceeded=$false
try{
 # Use an already-present physical IPv4 default route; never change that route.
 $defaults=@(Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction Stop|
  Where-Object {$_.NextHop -and $_.NextHop -ne '0.0.0.0'}|
  Sort-Object RouteMetric)
 if(!$defaults.Count){throw 'No ordinary IPv4 gateway; cannot run isolated test.'}
 $selected=$defaults[0]
 $index=[int]$selected.InterfaceIndex
 $gw=[string]$selected.NextHop
 if(@(Get-NetRoute -DestinationPrefix $prefix -AddressFamily IPv4 -ErrorAction SilentlyContinue).Count){
  throw 'Reserved test route unexpectedly exists. No changes made.'
 }
 if(@(Get-DnsClientNrptRule -ErrorAction Stop|Where-Object{@($_.Namespace) -contains $testNamespace}).Count){
  throw 'Reserved test NRPT namespace unexpectedly exists.'
 }
 # Dot-source only read-only list action, which defines reconciliation functions
 # against a dedicated isolated config directory.
 . $core -Action list -ConfigDir $dir | Out-Null
 $journal=[ordered]@{
  version=6;wifiIndex=$index;routes=@()
  pendingRoutes=@(@{prefix=$prefix;gateway=$gw})
  rules=@();pendingRules=@(@{namespace=$testNamespace;servers=@($server)})
 }
 Save-Json $statePath $journal

 # Child creates two real Windows objects then exits WITHOUT updating the journal.
 # This represents interruption after OS mutation and before completing state.
 $child=Join-Path $dir 'inject.ps1'
 @'
param([string]$Domain,[string]$Prefix,[int]$IfIndex,[string]$Gateway,[string]$Dns)
$ErrorActionPreference='Stop'
Add-DnsClientNrptRule -Namespace $Domain -NameServers $Dns -Comment 'Selective-VPN-Bypass-owned' -ErrorAction Stop | Out-Null
New-NetRoute -DestinationPrefix $Prefix -InterfaceIndex $IfIndex -NextHop $Gateway -RouteMetric 1 -PolicyStore ActiveStore -ErrorAction Stop | Out-Null
exit 0
'@ | Set-Content -LiteralPath $child -Encoding UTF8
 $powershell=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
 & $powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $child -Domain $testNamespace -Prefix $prefix -IfIndex $index -Gateway $gw -Dns $server
 if($LASTEXITCODE -ne 0){throw "Fault injection child failed: $LASTEXITCODE"}
 $dnsBefore=@(Get-DnsClientNrptRule -ErrorAction Stop|Where-Object{@($_.Namespace) -contains $testNamespace})
 $routeBefore=@(Get-NetRoute -InterfaceIndex $index -AddressFamily IPv4 -ErrorAction Stop|
  Where-Object {$_.DestinationPrefix -eq $prefix -and $_.NextHop -eq $gw -and $_.RouteMetric -eq 1})
 if($dnsBefore.Count -ne 1 -or $routeBefore.Count -ne 1){
  throw "Injected objects missing: DNS=$($dnsBefore.Count) route=$($routeBefore.Count)"
 }
 # Only adapt Core's Wi-Fi alias lookup to the CI runner's actual NIC; actual
 # DNS/route query and remove cmdlets remain the real Windows commands.
 function Get-NetAdapter {
  [CmdletBinding()]
  param([string]$Name)
  return [pscustomobject]@{ifIndex=$index;Status='Up';Name=$Name}
 }
 Restore-Own | Out-Null
 $dnsAfter=@(Get-DnsClientNrptRule -ErrorAction Stop|Where-Object{@($_.Namespace) -contains $testNamespace})
 $routeAfter=@(Get-NetRoute -InterfaceIndex $index -AddressFamily IPv4 -ErrorAction SilentlyContinue|
  Where-Object {$_.DestinationPrefix -eq $prefix -and $_.NextHop -eq $gw})
 if($dnsAfter.Count -ne 0 -or $routeAfter.Count -ne 0 -or (Test-Path -LiteralPath $statePath)){
  throw "Live restore incomplete: DNS=$($dnsAfter.Count) route=$($routeAfter.Count)"
 }
 # v7: the OS must retain a policy tagged to another journal identity even
 # when the namespace and DNS servers are the same. Only this reserved test
 # namespace is touched, and a mismatched policy is removed by test cleanup.
 $ownerA=[guid]::NewGuid().ToString('D')
 $ownerB=[guid]::NewGuid().ToString('D')
 $v7=[ordered]@{
  version=7;ownerId=$ownerA;wifiIndex=$index;routes=@();pendingRoutes=@();
  rules=@();pendingRules=@(@{namespace=$testNamespace;servers=@($server)})
 }
 Save-Json $statePath $v7
 Add-DnsClientNrptRule -Namespace $testNamespace -NameServers $server -Comment ('Selective-VPN-Bypass-owned:'+$ownerB) -ErrorAction Stop|Out-Null
 $refused=$false
 try{Restore-Own|Out-Null}catch{$refused=$true}
 $foreignStill=@(Get-DnsClientNrptRule -ErrorAction Stop|Where-Object{@($_.Namespace) -contains $testNamespace})
 if(-not $refused -or $foreignStill.Count -ne 1 -or -not (Test-Path -LiteralPath $statePath)){
  throw 'v7 journal incorrectly removed foreign-instance NRPT or lost recovery state.'
 }
 Remove-DnsClientNrptRule -Name ([string]$foreignStill[0].Name) -Force -ErrorAction Stop|Out-Null
 Add-DnsClientNrptRule -Namespace $testNamespace -NameServers $server -Comment ('Selective-VPN-Bypass-owned:'+$ownerA) -ErrorAction Stop|Out-Null
 Restore-Own|Out-Null
 $v7After=@(Get-DnsClientNrptRule -ErrorAction Stop|Where-Object{@($_.Namespace) -contains $testNamespace})
 if($v7After.Count -ne 0 -or (Test-Path -LiteralPath $statePath)){
  throw 'v7 journal failed to recover policy tagged with exact owner identity.'
 }
 Write-Host 'LIVE isolated v7 identity PASS: foreign policy retained, matched policy recovered.'

 # v8: even the correct operation comment and Windows rule ID are insufficient
 # if the namespace/DNS tuple has changed. Use only the reserved test scope.
 $ownerEight=[guid]::NewGuid().ToString('D')
 $badServer='192.0.2.54'
 $v8Observed=Add-DnsClientNrptRule -Namespace $testNamespace -NameServers $badServer -Comment ('Selective-VPN-Bypass-owned:'+$ownerEight) -PassThru -ErrorAction Stop
 $v8=[ordered]@{
  version=8;ownerId=$ownerEight;wifiIndex=$index;routes=@();pendingRoutes=@();
  rules=@([string]$v8Observed.Name)
  ruleDetails=@(@{name=[string]$v8Observed.Name;namespace=$testNamespace;servers=@($server)})
  pendingRules=@()
 }
 Save-Json $statePath $v8
 $v8Rejected=$false
 try{Restore-Own|Out-Null}catch{$v8Rejected=$true}
 $v8Still=@(Get-DnsClientNrptRule -ErrorAction Stop|Where-Object{@($_.Namespace) -contains $testNamespace})
 if(-not $v8Rejected -or $v8Still.Count -ne 1 -or -not (Test-Path -LiteralPath $statePath)){
  throw 'v8 failed to retain a same-owner NRPT policy with changed DNS servers.'
 }
 Remove-DnsClientNrptRule -Name ([string]$v8Still[0].Name) -Force -ErrorAction Stop | Out-Null
 $v8Correct=Add-DnsClientNrptRule -Namespace $testNamespace -NameServers $server -Comment ('Selective-VPN-Bypass-owned:'+$ownerEight) -PassThru -ErrorAction Stop
 $v8.rules=@([string]$v8Correct.Name)
 $v8.ruleDetails=@(@{name=[string]$v8Correct.Name;namespace=$testNamespace;servers=@($server)})
 Save-Json $statePath $v8
 Restore-Own|Out-Null
 if((Test-Path -LiteralPath $statePath) -or
    @(Get-DnsClientNrptRule -ErrorAction Stop|Where-Object{@($_.Namespace) -contains $testNamespace}).Count -ne 0){
  throw 'v8 exact committed NRPT tuple did not restore cleanly.'
 }
 Write-Host 'LIVE isolated v8 NRPT identity PASS: changed DNS blocked, exact tuple removed.'

 $testSucceeded=$true
 Write-Host 'LIVE isolated Windows NRPT+route crash recovery PASS: orphaned OS objects reconciled after child exit.'
}finally{
 # Exceptional cleanup is restricted to the exact reserved namespace, owner tag
 # and known route tuple. Never remove other network policies.
 try{
  foreach($rule in @(Get-DnsClientNrptRule -ErrorAction SilentlyContinue|
   Where-Object{@($_.Namespace) -contains $testNamespace -and ([string]$_.Comment -eq 'Selective-VPN-Bypass-owned' -or ([string]$_.Comment).StartsWith('Selective-VPN-Bypass-owned:',[StringComparison]::Ordinal))})){
   Remove-DnsClientNrptRule -Name ([string]$rule.Name) -Force -ErrorAction Stop | Out-Null
  }
 }catch{Write-Warning "Cleanup NRPT issue: $_"}
 if($null -ne $index -and $null -ne $gw){
  try{
   foreach($route in @(Get-NetRoute -InterfaceIndex $index -AddressFamily IPv4 -ErrorAction SilentlyContinue|
    Where-Object{$_.DestinationPrefix -eq $prefix -and $_.NextHop -eq $gw -and $_.RouteMetric -eq 1})){
    Remove-NetRoute -InputObject $route -Confirm:$false -ErrorAction Stop | Out-Null
   }
  }catch{Write-Warning "Cleanup route issue: $_"}
 }
 Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
}
if(-not $testSucceeded){throw 'Live isolated network recovery did not complete successfully.'}
