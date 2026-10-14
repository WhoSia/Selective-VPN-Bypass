#Requires -Version 5.1
param(
 [ValidateSet('list','add','remove','dns','status','apply','restore')][string]$Action='status',
 [string]$Domain='',
 [string]$ConfigDir=$PSScriptRoot
)
$ErrorActionPreference='Stop'
$WifiAlias='Wi-Fi';$VpnAlias='VPN - VPN Client'
$ConfigPath=Join-Path $ConfigDir 'Selective-VPN-Bypass.domains.json'
$StatePath=Join-Path $ConfigDir 'Selective-VPN-Bypass_v3.state.json'
$OwnerComment='Selective-VPN-Bypass-owned'
function Save-Json($path,$value){
 $temporary="$path.tmp"
 $value|ConvertTo-Json -Depth 12|Set-Content -LiteralPath $temporary -Encoding UTF8
 Move-Item -LiteralPath $temporary -Destination $path -Force
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
function Restore-Own {
 $st=State
 if(!$st){Write-Output 'No managed state.';return}
 $errors=@()
 foreach($name in @($st.rules)){
  try{
   $r=Get-DnsClientNrptRule -Name ([string]$name) -ErrorAction SilentlyContinue
   if($r -and $r.Comment -eq $OwnerComment){
    Remove-DnsClientNrptRule -Name ([string]$name) -Force -ErrorAction Stop|Out-Null
   }elseif($r){throw 'NRPT ownership mismatch'}
  }catch{$errors+="NRPT $name : $_"}
 }
 foreach($record in @($st.routes)){
  try{
   $a=Get-NetAdapter -Name $WifiAlias -ErrorAction Stop
   if([int]$a.ifIndex -ne [int]$st.wifiIndex){throw 'Interface index changed'}
   $found=@(Get-NetRoute -InterfaceIndex ([int]$st.wifiIndex) -AddressFamily IPv4 -ErrorAction SilentlyContinue|
    Where-Object {$_.DestinationPrefix -eq [string]$record.prefix -and $_.NextHop -eq [string]$record.gateway -and $_.RouteMetric -eq 1})
   foreach($r in $found){Remove-NetRoute -InputObject $r -Confirm:$false -ErrorAction Stop}
  }catch{$errors+="Route $($record.prefix) : $_"}
 }
 if($errors.Count){$errors|ForEach-Object{Write-Warning $_};throw 'Restore incomplete. State retained.'}
 Remove-Item -LiteralPath $StatePath -Force
 Write-Output 'Managed routes and DNS rules restored; VPN default route left intact.'
}
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
  Write-Output ("Saved entries: "+@((Targets)).Count+"; Applied state: "+[bool](State))
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
  # Collision preflight precedes any change.
  $owned=@()
  if(State){$owned=@((State).routes|ForEach-Object{$_.prefix})}
  foreach($ip in $ips){
   $prefix="$ip/32"
   $existing=@(Get-NetRoute -AddressFamily IPv4 -ErrorAction SilentlyContinue|Where-Object DestinationPrefix -eq $prefix)
   if($existing.Count -and $owned -notcontains $prefix){throw "Existing unmanaged route $prefix. No changes made."}
  }
  if(State){Restore-Own}
  if(!$ips.Count -and !$hostnames.Count){Write-Output 'No exceptions saved. Nothing to apply.';break}
  $st=[ordered]@{version=4;wifiIndex=[int]$wifi.ifIndex;routes=@();rules=@()}
  Save-Json $StatePath $st
  try{
   foreach($n in $hostnames){
    foreach($ns in @($n,".$n")){
     $existing=@(Get-DnsClientNrptRule -ErrorAction Stop|Where-Object {@($_.Namespace) -contains $ns})
     if($existing.Count){throw "Existing DNS policy conflicts with $ns"}
     $r=Add-DnsClientNrptRule -Namespace $ns -NameServers $dns -Comment $OwnerComment -PassThru -ErrorAction Stop
     $st.rules+=([string]$r.Name);Save-Json $StatePath $st
    }
   }
   foreach($ip in $ips){
    $entry=@{prefix="$ip/32";gateway=$gateway}
    New-NetRoute -DestinationPrefix $entry.prefix -InterfaceIndex $wifi.ifIndex -NextHop $gateway -RouteMetric 1 -PolicyStore ActiveStore -ErrorAction Stop|Out-Null
    $st.routes+=$entry;Save-Json $StatePath $st
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
