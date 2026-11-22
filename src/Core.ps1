#Requires -Version 5.1
param(
 [ValidateSet('list','add','remove','dns','status','inspect','apply','restore')][string]$Action='status',
 [string]$Domain='',
 [string]$ConfigDir=$PSScriptRoot
)
$ErrorActionPreference='Stop'
$WifiAlias='Wi-Fi';$VpnAlias='VPN - VPN Client'
$ConfigPath=Join-Path $ConfigDir 'Selective-VPN-Bypass.domains.json'
$StatePath=Join-Path $ConfigDir 'Selective-VPN-Bypass_v3.state.json'
$OwnerComment='Selective-VPN-Bypass-owned'
# Single writer per portable config directory, shared by elevated and normal workers
# in the current Windows session. Lock is acquired before any file/network mutation.
function Enter-ConfigLock {
 $full=[IO.Path]::GetFullPath($ConfigDir).TrimEnd('\').ToUpperInvariant()
 $hash=[Security.Cryptography.SHA256]::Create()
 try {$bytes=$hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($full))}
 finally {$hash.Dispose()}
 $id=([BitConverter]::ToString($bytes)).Replace('-','').Substring(0,32)
 $m=[System.Threading.Mutex]::new($false,("Local\SelectiveVPNBypass-"+$id))
 $acquired=$false
 try{
  try{$acquired=$m.WaitOne(5000)}
  catch [Threading.AbandonedMutexException]{$acquired=$true}
  if(-not $acquired){throw 'Another operation is running for this configuration. Retry after it finishes.'}
  return $m
 }catch{$m.Dispose();throw}
}
# Network settings are system-wide; a folder-scoped lock alone does not
# serialize two portable folders. Local namespace covers the current session.
# This lock does not prove ownership or protect another Windows session.
function Enter-NetworkLock {
 $m=[System.Threading.Mutex]::new($false,'Local\SelectiveVPNBypass-NetworkWriter')
 try {
  $acquired=$false
  try{$acquired=$m.WaitOne(5000)}
  catch [Threading.AbandonedMutexException]{$acquired=$true}
  if(-not $acquired){throw 'Another network operation is running in this Windows session. Inspect before retrying.'}
  return $m
 }catch{$m.Dispose();throw}
}
function Test-ManagedRouteMatch($route,$record,[int]$ifIndex){
 return (
  [string]$route.DestinationPrefix -eq [string]$record.prefix -and
  [string]$route.NextHop -eq [string]$record.gateway -and
  [int]$route.InterfaceIndex -eq $ifIndex -and
  [int]$route.RouteMetric -eq 1
 )
}
function Route-Records($state){
 $all=@()
 foreach($r in @($state.routes)+@($state.pendingRoutes)){
  if($null -eq $r -or !$r.prefix -or !$r.gateway){continue}
  if(-not (@($all|Where-Object{$_.prefix -eq $r.prefix -and $_.gateway -eq $r.gateway}).Count)){
   $all+=,$r
  }
 }
 return $all
}
function Save-Json($path,$value){
 # Never replace a valid state file with a partially-written JSON document.
 # File.Replace is an atomic same-volume replacement on supported Windows FS.
 $suffix=[guid]::NewGuid().ToString('N')
 $temporary=$path+'.'+$suffix+'.tmp'
 $backup=$path+'.'+$suffix+'.bak'
 try{
  $value|ConvertTo-Json -Depth 12|Set-Content -LiteralPath $temporary -Encoding UTF8
  if(Test-Path -LiteralPath $path){
   [IO.File]::Replace($temporary,$path,$backup)
  }else{
   [IO.File]::Move($temporary,$path)
  }
 }finally{
  Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue
 }
}
function Normalize-Target([string]$s){
 $s=$s.Trim().TrimEnd('.').ToLowerInvariant()
 if(!$s){throw 'Enter a domain or IPv4 address.'}
 $ip=$null
 if($s -match '^(?:\d{1,3}\.){3}\d{1,3}$'){
  if([Net.IPAddress]::TryParse($s,[ref]$ip) -and $ip.AddressFamily -eq 'InterNetwork'){return $ip.ToString()}
  throw 'Invalid IPv4 address.'
 }
 if($s -match '^[0-9.]+$' -or $s.Contains(':') -or $s.Contains('/') -or $s.Contains('*')){throw 'Enter a hostname or IPv4 address, not a URL or CIDR.'}
 if($s -notmatch '^(?=.{1,253}$)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$'){throw 'Invalid hostname.'}
 return $s
}
function Is-IPv4([string]$s){
 $ip=$null
 return ([Net.IPAddress]::TryParse($s,[ref]$ip) -and $ip.AddressFamily -eq 'InterNetwork')
}
function Targets{
 if(!(Test-Path -LiteralPath $ConfigPath)){return @()}
 $doc=Get-Content -LiteralPath $ConfigPath -Raw|ConvertFrom-Json
 if($null -eq $doc.domains){throw 'Malformed local domains configuration.'}
 $out=@()
 foreach($v in @($doc.domains)){$out+=Normalize-Target ([string]$v)}
 return @($out|Sort-Object -Unique)
}
function State{
 if(Test-Path -LiteralPath $StatePath){return Get-Content -LiteralPath $StatePath -Raw|ConvertFrom-Json}
 return $null
}
function Require-Admin{
 $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
 $principal=New-Object Security.Principal.WindowsPrincipal($identity)
 if(!$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'Administrator approval is required.'}
}
function Adapter([string]$name){
 $a=Get-NetAdapter -Name $name -ErrorAction Stop
 if($a.Status -ne 'Up'){throw "$name adapter is not connected."}
 return $a
}
function Wifi-Gateway([int]$index){
 $config=Get-NetIPConfiguration -InterfaceIndex $index
 $gw=@($config.IPv4DefaultGateway|Where-Object NextHop|Select-Object -First 1)
 if($gw.Count){return [string]$gw[0].NextHop}
 $hops=@(Get-NetRoute -InterfaceIndex $index -AddressFamily IPv4 -ErrorAction SilentlyContinue|
  Where-Object {$_.NextHop -and $_.NextHop -ne '0.0.0.0'}|Select-Object -ExpandProperty NextHop -Unique)
 if($hops.Count -eq 1){return [string]$hops[0]}
 throw 'Cannot determine Wi-Fi gateway safely. No changes made.'
}
function Wifi-Dns([int]$index){
 $dns=@((Get-DnsClientServerAddress -InterfaceIndex $index -AddressFamily IPv4).ServerAddresses|Where-Object {$_ -and $_ -ne '0.0.0.0'})
 if(!$dns.Count){throw 'No Wi-Fi DNS configured.'}
 return $dns
}
function Lookup([string]$name,[string]$server){
 return @(Resolve-DnsName -Name $name -Server $server -Type A -DnsOnly -ErrorAction Stop|
 Where-Object {$_.Type -eq 'A' -and $_.Section -eq 'Answer' -and $_.Name.TrimEnd('.') -ieq $name -and $_.IPAddress}|
 Select-Object -ExpandProperty IPAddress -Unique)
}
# New journals own a unique NRPT Comment; legacy journals remain readable.
function Get-JournalOwnerComment($journal) {
 if($null -eq $journal){return $OwnerComment}
 if($null -eq $journal.ownerId){
  if($null -ne $journal.version -and [int]$journal.version -ge 7){
   throw 'Version 7+ recovery journal is missing its owner identity. Do not downgrade ownership.'
  }
  return $OwnerComment
 }
 $id=[guid]::Empty
 if(-not [guid]::TryParse([string]$journal.ownerId,[ref]$id) -or $id -eq [guid]::Empty){
  throw 'Invalid recovery journal owner identity. Preserve the file for inspection.'
 }
 return ($OwnerComment+':'+$id.ToString('D'))
}
function Test-CompatibleOwnedNrpt($rule,[string]$namespace,[string[]]$servers,[string]$expectedComment=$OwnerComment){
 if($null -eq $rule){return $false}
 if([string]$rule.Comment -cne $expectedComment){return $false}
 if(@($rule.Namespace).Count -ne 1 -or [string](@($rule.Namespace)[0]) -cne $namespace){return $false}
 $actual=@($rule.NameServers|ForEach-Object{[string]$_}|Sort-Object -Unique)
 $expected=@($servers|ForEach-Object{[string]$_}|Sort-Object -Unique)
 return (($actual -join '|') -ceq ($expected -join '|'))
}
function Get-NamespaceRules([string]$namespace){
 return @(Get-DnsClientNrptRule -ErrorAction Stop|
  Where-Object { @($_.Namespace) -contains $namespace })
}
# Unfinished NRPT intents are stored by namespace before Windows assigns a rule ID.
# A pending intent is *not* proof of ownership. Only a unique, exact owner-tagged
# rule with the expected namespace and DNS server set is eligible for cleanup.
function Pending-NrptRecords($state){
 $items=@()
 foreach($p in @($state.pendingRules)){
  if($null -eq $p -or !$p.namespace){continue}
  if(@($p.servers).Count -lt 1){continue}
  if(-not (@($items|Where-Object{$_.namespace -ceq $p.namespace}).Count)){$items+=,$p}
 }
 return $items
}
function Find-PendingOwnedNrpt($intent,[string]$expectedComment=$OwnerComment){
 $rules=@(Get-NamespaceRules ([string]$intent.namespace))
 if($rules.Count -eq 0){return @()}
 if($rules.Count -ne 1){throw "NRPT recovery ambiguous for $($intent.namespace): $($rules.Count) matching rules."}
 $r=$rules[0]
 if(-not (Test-CompatibleOwnedNrpt $r ([string]$intent.namespace) @($intent.servers) $expectedComment)){
  throw "NRPT recovery ownership or DNS mismatch for $($intent.namespace). Manual review required."
 }
 return @($r)
}
# Read-only inspection of a saved journal against Windows snapshots.
# No route or DNS mutation is performed. Do not mistake a matching snapshot
# for proof of application-level traffic isolation.
function Inspect-JournalSnapshot($journal,$nrptRules,$ipv4Routes) {
 if($null -ne $journal){
  try{Assert-RecoveryJournal $journal}catch{
   return [pscustomobject]@{Code='UNKNOWN';Reason='Recovery journal failed structural validation; preserve bytes and inspect manually.';Rules=0;Routes=0;Missing=0;Conflicts=0;Pending=0}
  }
 }
 if($null -eq $journal){return [pscustomobject]@{Code='NO_JOURNAL';Reason='No local recovery journal. Absence of OS policies is not verified.';Rules=0;Routes=0}}
 $rules=@($journal.rules|Where-Object{$_})
 $pending=@(Pending-NrptRecords $journal)
 $routes=@(Route-Records $journal)
 if($null -eq $journal.version -or $null -eq $journal.wifiIndex -or
    $null -eq $journal.rules -or $null -eq $journal.routes){
  return [pscustomobject]@{Code='UNKNOWN';Reason='Unrecognized or incomplete journal schema. Do not overwrite it.';Rules=$rules.Count;Routes=$routes.Count}
 }
 if($rules.Count -eq 0 -and $pending.Count -eq 0 -and $routes.Count -eq 0){
  return [pscustomobject]@{Code='INCOMPLETE';Reason='An empty journal is present; there is no evidence of completed system changes.';Rules=0;Routes=0;Missing=0;Conflicts=0;Pending=0}
 }
 $expectedComment=Get-JournalOwnerComment $journal
 $conflict=0;$missing=0;$unresolved=0
 foreach($ruleName in $rules){
  $found=@($nrptRules|Where-Object{[string]$_.Name -ceq [string]$ruleName})
  if($found.Count -gt 1){$conflict++;continue}
  if($found.Count -eq 0){$missing++;continue}
  if([string]$found[0].Comment -cne $expectedComment){$conflict++}
 }
 foreach($intent in $pending){
  $matched=@($nrptRules|Where-Object{@($_.Namespace) -contains [string]$intent.namespace})
  if($matched.Count -gt 1){$conflict++;continue}
  if($matched.Count -eq 0){$unresolved++;continue}
  if(-not (Test-CompatibleOwnedNrpt $matched[0] ([string]$intent.namespace) @($intent.servers) $expectedComment)){$conflict++}
 }
 foreach($record in $routes){
  $prefixMatches=@($ipv4Routes|Where-Object{[string]$_.DestinationPrefix -eq [string]$record.prefix})
  $matching=@($prefixMatches|Where-Object{Test-ManagedRouteMatch $_ $record ([int]$journal.wifiIndex)})
  if($matching.Count -eq 0){$missing++;continue}
  if($matching.Count -gt 1 -or $prefixMatches.Count -ne $matching.Count){$conflict++}
 }
 $pendingCount=@($journal.pendingRoutes|Where-Object{$_}).Count+$pending.Count
 $code='MATCHED_SNAPSHOT'
 $reason='Recorded objects match this snapshot. Actual browser traffic has not been verified.'
 if($pendingCount -gt 0 -or $unresolved -gt 0){
  $code='INCOMPLETE'
  $reason='Unfinished journal entries exist. Inspect before reapplying or moving files.'
 }
 if($missing -gt 0){
  $code='MISMATCH'
  $reason='One or more recorded objects are missing. Inspect network changes and retained state.'
 }
 if($conflict -gt 0){
  $code='CONFLICT'
  $reason='Unrecognized or incompatible system objects found. No modifications performed.'
 }
 return [pscustomobject]@{
  Code=$code;Reason=$reason;Rules=$rules.Count+$pending.Count;Routes=$routes.Count;
  Missing=$missing;Conflicts=$conflict;Pending=$pendingCount
 }
}
# Read-only health checks: never normalize a malformed file by overwriting it.
function Get-ConfigHealth {
 if(-not (Test-Path -LiteralPath $ConfigPath)){return 'ABSENT'}
 try{
  $doc=Get-Content -LiteralPath $ConfigPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
  if($null -eq $doc -or $null -eq $doc.domains -or
     $doc.domains -is [string] -or $doc.domains -isnot [array]){return 'INVALID'}
  foreach($item in $doc.domains){
   if($item -isnot [string]){return 'INVALID'}
   [void](Normalize-Target $item)
  }
  return 'OK'
 }catch{return 'INVALID'}
}
function Get-UnattributedOwnedNrpt($journal,$nrptRules) {
 $named=@()
 $pending=@()
 $expectedComment=Get-JournalOwnerComment $journal
 if($null -ne $journal){
  $named=@($journal.rules | Where-Object{$_})
  $pending=@(Pending-NrptRecords $journal)
 }
 $other=@()
 foreach($rule in @($nrptRules)){
  if([string]$rule.Comment -cne $OwnerComment -and -not ([string]$rule.Comment).StartsWith($OwnerComment+':',[StringComparison]::Ordinal)){continue}
  if($named -contains ([string]$rule.Name)){continue}
  $knownPending=$false
  foreach($intent in $pending){
   if(Test-CompatibleOwnedNrpt $rule ([string]$intent.namespace) @($intent.servers) $expectedComment){
    $knownPending=$true
    break
   }
  }
  if(-not $knownPending){$other+=,$rule}
 }
 return $other
}
# Defensive schema/tuple checks before elevated cleanup. This detects accidental
# corruption, but a user-writable JSON file is NOT cryptographically authenticated.
function Assert-RecoveryJournal($journal) {
 if($null -eq $journal){throw 'Recovery journal missing.'}
 $version=0
 $index=0
 if(-not [int]::TryParse([string]$journal.version,[ref]$version) -or $version -lt 3 -or $version -gt 7){
  throw 'Recovery journal has unsupported schema version. No system objects changed.'
 }
 if(-not [int]::TryParse([string]$journal.wifiIndex,[ref]$index) -or $index -le 0){
  throw 'Recovery journal has invalid network interface index.'
 }
 if($journal.routes -isnot [array] -or $journal.rules -isnot [array]){
  throw 'Recovery journal is missing required route or DNS rule arrays.'
 }
 if($version -ge 7){[void](Get-JournalOwnerComment $journal)}
 foreach($group in @(@($journal.routes),@($journal.pendingRoutes))){
  if($group.Count -gt 4096){throw 'Recovery journal contains an implausible route count.'}
  foreach($record in $group){
   if($null -eq $record){throw 'Recovery journal contains a null route record.'}
   $prefix=[string]$record.prefix
   if($prefix -notmatch '^((?:[0-9]{1,3}\.){3}[0-9]{1,3})/32
 $st=State
 if(!$st){Write-Output 'No managed state.';return}
 Assert-RecoveryJournal $st
 $errors=@()
 $expectedComment=Get-JournalOwnerComment $st
 $knownRules=@($st.rules)
 foreach($name in $knownRules){
  try{
   $r=Get-DnsClientNrptRule -Name ([string]$name) -ErrorAction SilentlyContinue
   if($r -and [string]$r.Comment -ceq $expectedComment){
    Remove-DnsClientNrptRule -Name ([string]$name) -Force -ErrorAction Stop|Out-Null
   }elseif($r){throw 'NRPT ownership mismatch'}
  }catch{$errors+="NRPT $name : $_"}
 }
 foreach($intent in @(Pending-NrptRecords $st)){
  try{
   $matched=@(Find-PendingOwnedNrpt $intent $expectedComment)
   foreach($r in $matched){
    if($knownRules -contains ([string]$r.Name)){continue}
    Remove-DnsClientNrptRule -Name ([string]$r.Name) -Force -ErrorAction Stop|Out-Null
   }
  }catch{$errors+="Pending NRPT $($intent.namespace) : $_"}
 }
 foreach($record in @(Route-Records $st)){
  try{
   $a=Get-NetAdapter -Name $WifiAlias -ErrorAction Stop
   if([int]$a.ifIndex -ne [int]$st.wifiIndex){throw 'Interface index changed'}
   $found=@(Get-NetRoute -InterfaceIndex ([int]$st.wifiIndex) -AddressFamily IPv4 -ErrorAction SilentlyContinue|
    Where-Object { Test-ManagedRouteMatch $_ $record ([int]$st.wifiIndex) })
   if($found.Count -gt 1){
    throw 'Multiple identical route candidates exist; ownership is ambiguous. No route removed.'
   }
   foreach($r in $found){Remove-NetRoute -InputObject $r -Confirm:$false -ErrorAction Stop}
  }catch{$errors+="Route $($record.prefix) : $_"}
 }
 if($errors.Count){$errors|ForEach-Object{Write-Warning $_};throw 'Restore incomplete. State retained.'}
 Remove-Item -LiteralPath $StatePath -Force
 Write-Output 'Managed routes and DNS rules restored; VPN default route left intact.'
}
# Read-only operations can proceed; all writes (including Apply/Restore) use
# one cross-process writer lock. No implicit recovery if state is unfamiliar.
$script:configMutex=$null
$script:networkMutex=$null
try {
 if($Action -in @('add','remove','apply','restore')){$script:configMutex=Enter-ConfigLock}
 if($Action -in @('apply','restore')){$script:networkMutex=Enter-NetworkLock}
 switch($Action){
 'list'{Targets|ForEach-Object{Write-Output $_};break}
 'add'{
  $d=Normalize-Target $Domain
  $all=@(@(Targets)+$d|Sort-Object -Unique)
  Save-Json $ConfigPath @{domains=$all}
  Write-Output "Saved $d. Apply to activate.";break
 }
 'remove'{
  $d=Normalize-Target $Domain
  $all=@(Targets|Where-Object {$_ -ne $d})
  Save-Json $ConfigPath @{domains=$all}
  Write-Output "Removed $d. Apply to activate.";break
 }
 'status'{
  Get-NetAdapter -Name @($WifiAlias,$VpnAlias) -ErrorAction SilentlyContinue|
   Select-Object Name,Status,ifIndex|Format-Table -AutoSize|Out-String|Write-Output
  $routes=@(Get-NetRoute -AddressFamily IPv4 -ErrorAction SilentlyContinue|
   Where-Object DestinationPrefix -eq '0.0.0.0/0')
  $routes|Select-Object InterfaceAlias,NextHop,RouteMetric|Format-Table -AutoSize|Out-String|Write-Output
  Write-Output ("Saved entries: "+@((Targets)).Count+"; Recovery journal present (not proof of active routing): "+[bool](State))
  break
 }
 'dns'{
  # Read-only, no changes to DNS, default route, or VPN.
  $wifi=Adapter $WifiAlias
  $servers=@(Wifi-Dns $wifi.ifIndex)
  $names=if($Domain){@(Normalize-Target $Domain)}else{@(Targets)}
  $st=State
  foreach($n in $names){
   Write-Output "Diagnostic: $n"
   $ips=@()
   if(Is-IPv4 $n){$ips=@($n)}
   else{
    foreach($server in $servers){
     try{
      $a=@(Lookup $n $server)
      $ips+=$a
      Write-Output ("Wi-Fi DNS A @ $server : "+($a -join ', '))
     }catch{Write-Warning ("Wi-Fi DNS A lookup failed: "+$_)}
    }
    try{
     $systemA=@(Resolve-DnsName -Name $n -Type A -DnsOnly -ErrorAction Stop|
       Where-Object{$_.Type -eq 'A' -and $_.Section -eq 'Answer' -and $_.IPAddress}|
       Select-Object -ExpandProperty IPAddress -Unique)
     Write-Output ("Windows resolver A: "+($systemA -join ', '))
     $diff=@($systemA|Where-Object{$ips -notcontains $_})
     if($diff.Count){Write-Warning ("Windows A addresses missing from Wi-Fi lookup: "+($diff -join ', '))}
    }catch{Write-Warning ("Windows resolver A failed: "+$_)}
    try{
     $v6=@(Resolve-DnsName -Name $n -Type AAAA -DnsOnly -ErrorAction Stop|
       Where-Object{$_.Type -eq 'AAAA' -and $_.Section -eq 'Answer' -and $_.IPAddress}|
       Select-Object -ExpandProperty IPAddress -Unique)
     if($v6.Count){Write-Warning ("IPv6 AAAA addresses exist but IPv6 bypass is unsupported: "+($v6 -join ', '))}
     else{Write-Output 'AAAA: none returned'}
    }catch{Write-Output 'AAAA: none returned or lookup unavailable'}
   }
   foreach($ip in @($ips|Sort-Object -Unique)){
    $prefix="$ip/32"
    $owned=$false
    if($st){$owned=(@($st.routes|Where-Object{$_.prefix -eq $prefix}).Count -gt 0)}
    $matches=@(Get-NetRoute -AddressFamily IPv4 -ErrorAction SilentlyContinue|
       Where-Object{$_.DestinationPrefix -eq $prefix})
    if(!$matches.Count){Write-Warning ("No /32 route for "+$ip+"; default route may be used.")}
    foreach($route in $matches){
     Write-Output ("Route "+$prefix+" interface="+$route.InterfaceAlias+" gateway="+$route.NextHop+" ownedRecord="+$owned)
    }
    try{
     $chosen=Find-NetRoute -RemoteIPAddress $ip -ErrorAction Stop
     if($chosen){Write-Output ("Selected route for "+$ip+": "+(($chosen|Out-String -Width 200).Trim()))}
    }catch{Write-Warning ("Selected route lookup unavailable for "+$ip+": "+$_)}
   }
   Write-Output 'Browser DoH, existing sockets and site-side VPN checks are not observable here.'
  };break
 }
 'inspect'{
  # Inspection is deliberately non-elevated and mutation-free.
  try{
   $state=State
   $allNrpt=@(Get-DnsClientNrptRule -ErrorAction Stop)
   $allRoutes=@(Get-NetRoute -AddressFamily IPv4 -ErrorAction Stop)
   $report=Inspect-JournalSnapshot $state $allNrpt $allRoutes
   $configHealth=Get-ConfigHealth
   $unattributed=@(Get-UnattributedOwnedNrpt $state $allNrpt)
   $code=$report.Code
   if($unattributed.Count -gt 0 -and $code -in @('NO_JOURNAL','MATCHED_SNAPSHOT')){
    $code='UNATTRIBUTED_POLICIES'
   }
   if($configHealth -eq 'INVALID'){$code='CONFIG_INVALID'}
   Write-Output ("Recovery inspection: "+$code)
   Write-Output $report.Reason
   Write-Output ("Saved list: "+$configHealth)
   if($configHealth -eq 'INVALID'){
    Write-Warning 'Saved exception list is unreadable or malformed. Original bytes preserved; do not overwrite or import blindly.'
   }
   if($unattributed.Count -gt 0){
    Write-Warning ("Owner-tagged NRPT policies not attributable to this journal: "+$unattributed.Count+". May be a stale rule or another portable folder; ownership is NOT proven.")
   }
   if($null -ne $state){
    Write-Output ("Recorded objects: DNS policies="+$report.Rules+" IPv4 routes="+$report.Routes)
    Write-Output ("Unfinished="+$report.Pending+" missing="+$report.Missing+" conflicts="+$report.Conflicts)
   }
   Write-Output 'No changes were made. A matching snapshot is not proof of browser routing or site access.'
  }catch{
   Write-Warning 'Recovery inspection: UNKNOWN (journal unreadable or Windows inspection unavailable).'
   Write-Output 'No changes were made. Preserve configuration files; do not delete network rules without verifying ownership.'
  }
  break
 }
 'restore'{Require-Admin;Restore-Own;break}
 'apply'{
  Require-Admin
  $wifi=Adapter $WifiAlias;$vpn=Adapter $VpnAlias
  $vpnDefault=@(Get-NetRoute -InterfaceIndex $vpn.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue|
   Where-Object DestinationPrefix -eq '0.0.0.0/0')
  if(!$vpnDefault.Count){throw 'VPN default IPv4 route missing. No changes made.'}
  $gateway=Wifi-Gateway $wifi.ifIndex
  $dns=@(Wifi-Dns $wifi.ifIndex)
  $names=@(Targets)
  $ips=@();$hostnames=@()
  foreach($n in $names){
   if(Is-IPv4 $n){$ips+=$n;continue}
   $answers=@(Lookup $n $dns[0])
   if(!$answers.Count){throw "No Wi-Fi A record for $n. No changes made."}
   $ips+=$answers;$hostnames+=$n
  }
  $ips=@($ips|Sort-Object -Unique)
  # Fail closed if ANY route for a target prefix is not precisely in our
  # previous state. Prefix-only ownership is insufficient.
  $previous=State
  foreach($ip in $ips){
   $prefix="$ip/32"
   $existing=@(Get-NetRoute -AddressFamily IPv4 -ErrorAction SilentlyContinue|Where-Object DestinationPrefix -eq $prefix)
   foreach($r in $existing){
    $matched=$false
    if($previous){
     foreach($record in @(Route-Records $previous)){
      if(Test-ManagedRouteMatch $r $record ([int]$previous.wifiIndex)){$matched=$true;break}
     }
    }
    if(-not $matched){throw "Existing unmanaged route $prefix. No changes made."}
   }
  }
  if(State){Restore-Own}
  if(!$ips.Count -and !$hostnames.Count){Write-Output 'No exceptions saved. Nothing to apply.';break}
  $st=[ordered]@{version=7;ownerId=([guid]::NewGuid().ToString('D'));wifiIndex=[int]$wifi.ifIndex;routes=@();pendingRoutes=@();rules=@()}
  Save-Json $StatePath $st
  try{
   foreach($n in $hostnames){
    foreach($ns in @($n,".$n")){
     $existing=@(Get-NamespaceRules $ns)
     if($existing.Count -gt 1){throw "Multiple DNS policies for $ns; manual review required."}
     # Never adopt an owner-tagged orphan into a *new* identity. Legacy
     # restoration still uses its original journal, without silent migration.
     if($existing.Count -gt 0){
      throw "Existing NRPT policy for $ns is not attributable to this new operation. No policy adopted or removed. Inspect before retrying."
     }
     # Journal intent before OS modification. A crash after Add but before
     # receiving the assigned Windows Name can now be reconciled by exact tuple.
     $intent=@{namespace=$ns;servers=@($dns)}
     $st.pendingRules+=,$intent
     Save-Json $StatePath $st
     $r=Add-DnsClientNrptRule -Namespace $ns -NameServers $dns -Comment (Get-JournalOwnerComment $st) -PassThru -ErrorAction Stop
     $st.rules+=([string]$r.Name)
     $st.pendingRules=@($st.pendingRules|Where-Object{$_.namespace -cne $ns})
     Save-Json $StatePath $st
    }
   }
   foreach($ip in $ips){
    $entry=@{prefix="$ip/32";gateway=$gateway}
    # Write-ahead intent: if interrupted after OS route creation but before
    # completion logging, Restore still knows exactly which tuple to inspect.
    $st.pendingRoutes+=$entry
    Save-Json $StatePath $st
    New-NetRoute -DestinationPrefix $entry.prefix -InterfaceIndex $wifi.ifIndex -NextHop $gateway -RouteMetric 1 -PolicyStore ActiveStore -ErrorAction Stop|Out-Null
    $st.routes+=$entry
    $st.pendingRoutes=@($st.pendingRoutes|Where-Object{$_.prefix -ne $entry.prefix})
    Save-Json $StatePath $st
   }
  }catch{
   $reason=$_.Exception.Message
   try{Restore-Own}catch{Write-Warning 'Automatic rollback failed. Inspect managed state.'}
   throw "Apply failed: $reason"
  }
  Write-Output "Applied $($ips.Count) IPv4 routes, $($hostnames.Count) hostnames. Default VPN and Tailscale routes unchanged."
  Write-Warning 'This does not guarantee domain isolation: IPv6, DoH, QUIC, and CDN IP sharing may differ.'
  break
 }
}
} finally {
 if($null -ne $script:networkMutex){
  try{$script:networkMutex.ReleaseMutex()}finally{$script:networkMutex.Dispose()}
 }
 if($null -ne $script:configMutex){
  try{$script:configMutex.ReleaseMutex()}finally{$script:configMutex.Dispose()}
 }
}
){
    throw 'Recovery journal contains a route that is not an IPv4 host prefix.'
   }
   $ip=$null
   $gateway=$null
   if(-not [Net.IPAddress]::TryParse($Matches[1],[ref]$ip) -or
      $ip.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork -or
      -not [Net.IPAddress]::TryParse([string]$record.gateway,[ref]$gateway) -or
      $gateway.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork){
    throw 'Recovery journal contains invalid IPv4 route data.'
   }
  }
 }
 foreach($rule in @($journal.rules)){
  if([string]::IsNullOrWhiteSpace([string]$rule)){throw 'Recovery journal has a blank rule ID.'}
 }
 foreach($intent in @($journal.pendingRules)){
  if($null -eq $intent -or [string]::IsNullOrWhiteSpace([string]$intent.namespace) -or @($intent.servers).Count -eq 0){
   throw 'Recovery journal has an invalid pending DNS policy.'
  }
  $hostName=([string]$intent.namespace).TrimStart('.')
  if(([string]$intent.namespace -ne $hostName) -and -not ([string]$intent.namespace).StartsWith('.')){
   throw 'Invalid DNS policy namespace.'
  }
  if((Normalize-Target $hostName) -ne $hostName -or (Is-IPv4 $hostName)){
   throw 'Recovery journal contains an invalid DNS policy hostname.'
  }
  foreach($server in @($intent.servers)){
   if(-not (Is-IPv4 ([string]$server))){throw 'Recovery journal has an invalid DNS server.'}
  }
 }
}
function Restore-Own {
 $st=State
 if(!$st){Write-Output 'No managed state.';return}
 $errors=@()
 $expectedComment=Get-JournalOwnerComment $st
 $knownRules=@($st.rules)
 foreach($name in $knownRules){
  try{
   $r=Get-DnsClientNrptRule -Name ([string]$name) -ErrorAction SilentlyContinue
   if($r -and [string]$r.Comment -ceq $expectedComment){
    Remove-DnsClientNrptRule -Name ([string]$name) -Force -ErrorAction Stop|Out-Null
   }elseif($r){throw 'NRPT ownership mismatch'}
  }catch{$errors+="NRPT $name : $_"}
 }
 foreach($intent in @(Pending-NrptRecords $st)){
  try{
   $matched=@(Find-PendingOwnedNrpt $intent $expectedComment)
   foreach($r in $matched){
    if($knownRules -contains ([string]$r.Name)){continue}
    Remove-DnsClientNrptRule -Name ([string]$r.Name) -Force -ErrorAction Stop|Out-Null
   }
  }catch{$errors+="Pending NRPT $($intent.namespace) : $_"}
 }
 foreach($record in @(Route-Records $st)){
  try{
   $a=Get-NetAdapter -Name $WifiAlias -ErrorAction Stop
   if([int]$a.ifIndex -ne [int]$st.wifiIndex){throw 'Interface index changed'}
   $found=@(Get-NetRoute -InterfaceIndex ([int]$st.wifiIndex) -AddressFamily IPv4 -ErrorAction SilentlyContinue|
    Where-Object { Test-ManagedRouteMatch $_ $record ([int]$st.wifiIndex) })
   if($found.Count -gt 1){
    throw 'Multiple identical route candidates exist; ownership is ambiguous. No route removed.'
   }
   foreach($r in $found){Remove-NetRoute -InputObject $r -Confirm:$false -ErrorAction Stop}
  }catch{$errors+="Route $($record.prefix) : $_"}
 }
 if($errors.Count){$errors|ForEach-Object{Write-Warning $_};throw 'Restore incomplete. State retained.'}
 Remove-Item -LiteralPath $StatePath -Force
 Write-Output 'Managed routes and DNS rules restored; VPN default route left intact.'
}
# Read-only operations can proceed; all writes (including Apply/Restore) use
# one cross-process writer lock. No implicit recovery if state is unfamiliar.
$script:configMutex=$null
$script:networkMutex=$null
try {
 if($Action -in @('add','remove','apply','restore')){$script:configMutex=Enter-ConfigLock}
 if($Action -in @('apply','restore')){$script:networkMutex=Enter-NetworkLock}
 switch($Action){
 'list'{Targets|ForEach-Object{Write-Output $_};break}
 'add'{
  $d=Normalize-Target $Domain
  $all=@(@(Targets)+$d|Sort-Object -Unique)
  Save-Json $ConfigPath @{domains=$all}
  Write-Output "Saved $d. Apply to activate.";break
 }
 'remove'{
  $d=Normalize-Target $Domain
  $all=@(Targets|Where-Object {$_ -ne $d})
  Save-Json $ConfigPath @{domains=$all}
  Write-Output "Removed $d. Apply to activate.";break
 }
 'status'{
  Get-NetAdapter -Name @($WifiAlias,$VpnAlias) -ErrorAction SilentlyContinue|
   Select-Object Name,Status,ifIndex|Format-Table -AutoSize|Out-String|Write-Output
  $routes=@(Get-NetRoute -AddressFamily IPv4 -ErrorAction SilentlyContinue|
   Where-Object DestinationPrefix -eq '0.0.0.0/0')
  $routes|Select-Object InterfaceAlias,NextHop,RouteMetric|Format-Table -AutoSize|Out-String|Write-Output
  Write-Output ("Saved entries: "+@((Targets)).Count+"; Recovery journal present (not proof of active routing): "+[bool](State))
  break
 }
 'dns'{
  # Read-only, no changes to DNS, default route, or VPN.
  $wifi=Adapter $WifiAlias
  $servers=@(Wifi-Dns $wifi.ifIndex)
  $names=if($Domain){@(Normalize-Target $Domain)}else{@(Targets)}
  $st=State
  foreach($n in $names){
   Write-Output "Diagnostic: $n"
   $ips=@()
   if(Is-IPv4 $n){$ips=@($n)}
   else{
    foreach($server in $servers){
     try{
      $a=@(Lookup $n $server)
      $ips+=$a
      Write-Output ("Wi-Fi DNS A @ $server : "+($a -join ', '))
     }catch{Write-Warning ("Wi-Fi DNS A lookup failed: "+$_)}
    }
    try{
     $systemA=@(Resolve-DnsName -Name $n -Type A -DnsOnly -ErrorAction Stop|
       Where-Object{$_.Type -eq 'A' -and $_.Section -eq 'Answer' -and $_.IPAddress}|
       Select-Object -ExpandProperty IPAddress -Unique)
     Write-Output ("Windows resolver A: "+($systemA -join ', '))
     $diff=@($systemA|Where-Object{$ips -notcontains $_})
     if($diff.Count){Write-Warning ("Windows A addresses missing from Wi-Fi lookup: "+($diff -join ', '))}
    }catch{Write-Warning ("Windows resolver A failed: "+$_)}
    try{
     $v6=@(Resolve-DnsName -Name $n -Type AAAA -DnsOnly -ErrorAction Stop|
       Where-Object{$_.Type -eq 'AAAA' -and $_.Section -eq 'Answer' -and $_.IPAddress}|
       Select-Object -ExpandProperty IPAddress -Unique)
     if($v6.Count){Write-Warning ("IPv6 AAAA addresses exist but IPv6 bypass is unsupported: "+($v6 -join ', '))}
     else{Write-Output 'AAAA: none returned'}
    }catch{Write-Output 'AAAA: none returned or lookup unavailable'}
   }
   foreach($ip in @($ips|Sort-Object -Unique)){
    $prefix="$ip/32"
    $owned=$false
    if($st){$owned=(@($st.routes|Where-Object{$_.prefix -eq $prefix}).Count -gt 0)}
    $matches=@(Get-NetRoute -AddressFamily IPv4 -ErrorAction SilentlyContinue|
       Where-Object{$_.DestinationPrefix -eq $prefix})
    if(!$matches.Count){Write-Warning ("No /32 route for "+$ip+"; default route may be used.")}
    foreach($route in $matches){
     Write-Output ("Route "+$prefix+" interface="+$route.InterfaceAlias+" gateway="+$route.NextHop+" ownedRecord="+$owned)
    }
    try{
     $chosen=Find-NetRoute -RemoteIPAddress $ip -ErrorAction Stop
     if($chosen){Write-Output ("Selected route for "+$ip+": "+(($chosen|Out-String -Width 200).Trim()))}
    }catch{Write-Warning ("Selected route lookup unavailable for "+$ip+": "+$_)}
   }
   Write-Output 'Browser DoH, existing sockets and site-side VPN checks are not observable here.'
  };break
 }
 'inspect'{
  # Inspection is deliberately non-elevated and mutation-free.
  try{
   $state=State
   $allNrpt=@(Get-DnsClientNrptRule -ErrorAction Stop)
   $allRoutes=@(Get-NetRoute -AddressFamily IPv4 -ErrorAction Stop)
   $report=Inspect-JournalSnapshot $state $allNrpt $allRoutes
   $configHealth=Get-ConfigHealth
   $unattributed=@(Get-UnattributedOwnedNrpt $state $allNrpt)
   $code=$report.Code
   if($unattributed.Count -gt 0 -and $code -in @('NO_JOURNAL','MATCHED_SNAPSHOT')){
    $code='UNATTRIBUTED_POLICIES'
   }
   if($configHealth -eq 'INVALID'){$code='CONFIG_INVALID'}
   Write-Output ("Recovery inspection: "+$code)
   Write-Output $report.Reason
   Write-Output ("Saved list: "+$configHealth)
   if($configHealth -eq 'INVALID'){
    Write-Warning 'Saved exception list is unreadable or malformed. Original bytes preserved; do not overwrite or import blindly.'
   }
   if($unattributed.Count -gt 0){
    Write-Warning ("Owner-tagged NRPT policies not attributable to this journal: "+$unattributed.Count+". May be a stale rule or another portable folder; ownership is NOT proven.")
   }
   if($null -ne $state){
    Write-Output ("Recorded objects: DNS policies="+$report.Rules+" IPv4 routes="+$report.Routes)
    Write-Output ("Unfinished="+$report.Pending+" missing="+$report.Missing+" conflicts="+$report.Conflicts)
   }
   Write-Output 'No changes were made. A matching snapshot is not proof of browser routing or site access.'
  }catch{
   Write-Warning 'Recovery inspection: UNKNOWN (journal unreadable or Windows inspection unavailable).'
   Write-Output 'No changes were made. Preserve configuration files; do not delete network rules without verifying ownership.'
  }
  break
 }
 'restore'{Require-Admin;Restore-Own;break}
 'apply'{
  Require-Admin
  $wifi=Adapter $WifiAlias;$vpn=Adapter $VpnAlias
  $vpnDefault=@(Get-NetRoute -InterfaceIndex $vpn.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue|
   Where-Object DestinationPrefix -eq '0.0.0.0/0')
  if(!$vpnDefault.Count){throw 'VPN default IPv4 route missing. No changes made.'}
  $gateway=Wifi-Gateway $wifi.ifIndex
  $dns=@(Wifi-Dns $wifi.ifIndex)
  $names=@(Targets)
  $ips=@();$hostnames=@()
  foreach($n in $names){
   if(Is-IPv4 $n){$ips+=$n;continue}
   $answers=@(Lookup $n $dns[0])
   if(!$answers.Count){throw "No Wi-Fi A record for $n. No changes made."}
   $ips+=$answers;$hostnames+=$n
  }
  $ips=@($ips|Sort-Object -Unique)
  # Fail closed if ANY route for a target prefix is not precisely in our
  # previous state. Prefix-only ownership is insufficient.
  $previous=State
  foreach($ip in $ips){
   $prefix="$ip/32"
   $existing=@(Get-NetRoute -AddressFamily IPv4 -ErrorAction SilentlyContinue|Where-Object DestinationPrefix -eq $prefix)
   foreach($r in $existing){
    $matched=$false
    if($previous){
     foreach($record in @(Route-Records $previous)){
      if(Test-ManagedRouteMatch $r $record ([int]$previous.wifiIndex)){$matched=$true;break}
     }
    }
    if(-not $matched){throw "Existing unmanaged route $prefix. No changes made."}
   }
  }
  if(State){Restore-Own}
  if(!$ips.Count -and !$hostnames.Count){Write-Output 'No exceptions saved. Nothing to apply.';break}
  $st=[ordered]@{version=7;ownerId=([guid]::NewGuid().ToString('D'));wifiIndex=[int]$wifi.ifIndex;routes=@();pendingRoutes=@();rules=@()}
  Save-Json $StatePath $st
  try{
   foreach($n in $hostnames){
    foreach($ns in @($n,".$n")){
     $existing=@(Get-NamespaceRules $ns)
     if($existing.Count -gt 1){throw "Multiple DNS policies for $ns; manual review required."}
     # Never adopt an owner-tagged orphan into a *new* identity. Legacy
     # restoration still uses its original journal, without silent migration.
     if($existing.Count -gt 0){
      throw "Existing NRPT policy for $ns is not attributable to this new operation. No policy adopted or removed. Inspect before retrying."
     }
     # Journal intent before OS modification. A crash after Add but before
     # receiving the assigned Windows Name can now be reconciled by exact tuple.
     $intent=@{namespace=$ns;servers=@($dns)}
     $st.pendingRules+=,$intent
     Save-Json $StatePath $st
     $r=Add-DnsClientNrptRule -Namespace $ns -NameServers $dns -Comment (Get-JournalOwnerComment $st) -PassThru -ErrorAction Stop
     $st.rules+=([string]$r.Name)
     $st.pendingRules=@($st.pendingRules|Where-Object{$_.namespace -cne $ns})
     Save-Json $StatePath $st
    }
   }
   foreach($ip in $ips){
    $entry=@{prefix="$ip/32";gateway=$gateway}
    # Write-ahead intent: if interrupted after OS route creation but before
    # completion logging, Restore still knows exactly which tuple to inspect.
    $st.pendingRoutes+=$entry
    Save-Json $StatePath $st
    New-NetRoute -DestinationPrefix $entry.prefix -InterfaceIndex $wifi.ifIndex -NextHop $gateway -RouteMetric 1 -PolicyStore ActiveStore -ErrorAction Stop|Out-Null
    $st.routes+=$entry
    $st.pendingRoutes=@($st.pendingRoutes|Where-Object{$_.prefix -ne $entry.prefix})
    Save-Json $StatePath $st
   }
  }catch{
   $reason=$_.Exception.Message
   try{Restore-Own}catch{Write-Warning 'Automatic rollback failed. Inspect managed state.'}
   throw "Apply failed: $reason"
  }
  Write-Output "Applied $($ips.Count) IPv4 routes, $($hostnames.Count) hostnames. Default VPN and Tailscale routes unchanged."
  Write-Warning 'This does not guarantee domain isolation: IPv6, DoH, QUIC, and CDN IP sharing may differ.'
  break
 }
}
} finally {
 if($null -ne $script:networkMutex){
  try{$script:networkMutex.ReleaseMutex()}finally{$script:networkMutex.Dispose()}
 }
 if($null -ne $script:configMutex){
  try{$script:configMutex.ReleaseMutex()}finally{$script:configMutex.Dispose()}
 }
}
