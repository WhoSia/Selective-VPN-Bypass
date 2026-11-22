#Requires -Version 5.1
param([string]$RuntimeDir,[string]$DataDir,[string]$LauncherPath,[switch]$SmokeTest,[switch]$InteractionTest)
$ErrorActionPreference = 'Stop'
# DPI awareness must be declared before any WinForms controls are created.
# Windows may refuse the request if the process already has a DPI context.
try {
  Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class SVBDpi {
    [DllImport("user32.dll", EntryPoint="SetProcessDpiAwarenessContext", SetLastError=true)]
    public static extern bool SetContext(IntPtr awareness);
    [DllImport("user32.dll", EntryPoint="SetProcessDPIAware", SetLastError=true)]
    public static extern bool SetLegacy();
    public static void BestEffort() {
        if (!SetContext(new IntPtr(-4))) { SetLegacy(); }
    }
}
'@ -ErrorAction Stop
  [SVBDpi]::BestEffort()
} catch {
  # Fall back to Windows defaults; never prevent the UI from starting for DPI.
}
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()
$backend=Join-Path $RuntimeDir 'Core.ps1'
$worker=Join-Path $RuntimeDir 'Worker.ps1'
$config=Join-Path $DataDir 'Selective-VPN-Bypass.domains.json'
$state=Join-Path $DataDir 'Selective-VPN-Bypass_v3.state.json'
$script:running=$false
$script:activeProcess=$null
$script:activeLogPath=$null
$script:activeAction=$null
$script:activeStarted=$null
$script:pendingAddText=$null
$script:actionStartedCount=0
$script:actionFinishedCount=0
$script:configInvalid=$false
$form=New-Object Windows.Forms.Form
$form.Text='Selective VPN Bypass - Preview'
$form.Size=New-Object Drawing.Size(780,560)
$form.MinimumSize=New-Object Drawing.Size(720,510)
$form.StartPosition='CenterScreen'
$form.Font=New-Object Drawing.Font('Segoe UI',10)
$form.AutoScaleMode='Dpi'
$form.BackColor=[Drawing.Color]::FromArgb(246,248,251)
$layout=New-Object Windows.Forms.TableLayoutPanel
$layout.Dock='Fill'; $layout.Padding=New-Object Windows.Forms.Padding(18)
$layout.ColumnCount=2; $layout.RowCount=3
$layout.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent',43)))|Out-Null
$layout.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent',57)))|Out-Null
$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute',62)))|Out-Null
$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Percent',100)))|Out-Null
$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute',35)))|Out-Null
$form.Controls.Add($layout)
$heading=New-Object Windows.Forms.Label
$heading.Text='Selective VPN Bypass'
$heading.Dock='Fill';$heading.Font=New-Object Drawing.Font('Segoe UI',19,[Drawing.FontStyle]::Bold)
$heading.TextAlign='MiddleLeft'
$layout.Controls.Add($heading,0,0);$layout.SetColumnSpan($heading,2)
$left=New-Object Windows.Forms.TableLayoutPanel
$left.Dock='Fill';$left.Padding=New-Object Windows.Forms.Padding(0,0,12,0)
$left.RowCount=4
$left.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute',38)))|Out-Null
$left.RowStyles.Add((New-Object Windows.Forms.RowStyle('Percent',100)))|Out-Null
$left.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute',45)))|Out-Null
$left.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute',46)))|Out-Null
$layout.Controls.Add($left,0,1)
$label=New-Object Windows.Forms.Label
$label.Text='Direct connection exceptions';$label.Dock='Fill';$label.TextAlign='MiddleLeft'
$left.Controls.Add($label,0,0)
$items=New-Object Windows.Forms.ListBox
$items.Dock='Fill';$items.IntegralHeight=$false
$items.BorderStyle='FixedSingle'
$items.AccessibleName='Direct connection exceptions'
$left.Controls.Add($items,0,1)
$addRow=New-Object Windows.Forms.TableLayoutPanel
$addRow.Dock='Fill';$addRow.ColumnCount=2
$addRow.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent',70)))|Out-Null
$addRow.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent',30)))|Out-Null
$entry=New-Object Windows.Forms.TextBox
$entry.Dock='Fill';$entry.Margin=New-Object Windows.Forms.Padding(2,7,5,5)
$entry.AccessibleName='Exception domain or IPv4 address'
$entry.ShortcutsEnabled=$true
$addRow.Controls.Add($entry,0,0)
$add=New-Object Windows.Forms.Button
$add.Text='Add';$add.Dock='Fill'
$addRow.Controls.Add($add,1,0);$left.Controls.Add($addRow,0,2)
$remove=New-Object Windows.Forms.Button
$remove.Text='Remove selected';$remove.Dock='Fill'
$remove.Enabled=$false
$left.Controls.Add($remove,0,3)
$right=New-Object Windows.Forms.TableLayoutPanel
$right.Dock='Fill';$right.RowCount=4
$right.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute',48)))|Out-Null
$right.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute',52)))|Out-Null
$right.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute',48)))|Out-Null
$right.RowStyles.Add((New-Object Windows.Forms.RowStyle('Percent',100)))|Out-Null
$layout.Controls.Add($right,1,1)
$status=New-Object Windows.Forms.Label
$status.Dock='Fill';$status.TextAlign='MiddleLeft';$status.Text='Checking connections...'
$right.Controls.Add($status,0,0)
function Make-Row($texts) {
 $r=New-Object Windows.Forms.TableLayoutPanel
 $r.Dock='Fill';$r.ColumnCount=$texts.Count
 foreach($t in $texts){$r.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent',(100/$texts.Count))))|Out-Null}
 $buttons=@()
 for($i=0;$i -lt $texts.Count;$i++){
  $b=New-Object Windows.Forms.Button
  $b.Text=$texts[$i];$b.Dock='Fill'
  $r.Controls.Add($b,$i,0);$buttons+=,$b
 }
 return ,@($r,$buttons)
}
$top=Make-Row @('Apply','Restore')
$right.Controls.Add($top[0],0,1)
$other=Make-Row @('Status','DNS','Inspect','Backup')
$right.Controls.Add($other[0],0,2)
$log=New-Object Windows.Forms.TextBox
$log.Multiline=$true;$log.ReadOnly=$true;$log.ScrollBars='Vertical'
$log.Dock='Fill';$log.Font=New-Object Drawing.Font('Consolas',9)
$log.Text='Network state has not been verified. Use Inspect to review the journal. Apply and Restore require administrator approval.'
$right.Controls.Add($log,0,3)
$foot=New-Object Windows.Forms.Label
$foot.Dock='Fill';$foot.Text='IPv4 only. State file presence does not verify routing. DNS/DoH, IPv6 and CDN may differ.'
$foot.ForeColor=[Drawing.Color]::DarkSlateGray
$layout.Controls.Add($foot,0,2);$layout.SetColumnSpan($foot,2)
function Update-Items {
 $items.Items.Clear()
 $script:configInvalid=$false
 if(Test-Path -LiteralPath $config){
  try {
   $obj=Get-Content -LiteralPath $config -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
   if($null -eq $obj.domains -or $obj.domains -isnot [array]){throw 'Expected domains array.'}
   foreach($v in @($obj.domains|Sort-Object -Unique)){
    if($v -isnot [string] -or [string]::IsNullOrWhiteSpace($v)){throw 'Invalid entry type.'}
    [void]$items.Items.Add([string]$v)
   }
  }catch{
   $script:configInvalid=$true
   $items.Items.Clear()
   $log.Text="Saved list is unreadable. Original file preserved; no automatic repair. Use Inspect to diagnose before editing."
  }
 }
 $add.Enabled=(-not $script:configInvalid -and -not $script:running)
 $other[1][3].Enabled=(-not $script:configInvalid -and -not $script:running)
 $remove.Enabled=($items.SelectedIndex -ge 0 -and -not $script:running -and -not $script:configInvalid)
}
function Update-Status {
 try {
  $v=Get-NetAdapter -Name 'VPN - VPN Client' -ErrorAction SilentlyContinue
  $w=Get-NetAdapter -Name 'Wi-Fi' -ErrorAction SilentlyContinue
  $stateLabel=if(Test-Path -LiteralPath $state){"present (unverified)"}else{"absent"}
  $savedLabel=if($script:configInvalid){'INVALID'}else{'readable/absent'}
  $status.Text="SoftEther: $($v.Status) | Wi-Fi: $($w.Status) | Journal: $stateLabel | Saved list: $savedLabel"
 }catch{$status.Text='Network status unavailable'}
}
function Valid-Target([string]$value) {
 $v=$value.Trim().TrimEnd('.').ToLowerInvariant()
 $ip=$null
 if($v -match '^(?:\d{1,3}\.){3}\d{1,3}$'){
   if([Net.IPAddress]::TryParse($v,[ref]$ip) -and $ip.AddressFamily -eq 'InterNetwork'){return $v}
   throw 'Invalid IPv4 address.'
 }
 if($v -match '^(?=.{1,253}$)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$'){return $v}
 throw 'Enter a hostname or IPv4 address (not a URL).'
}
# Portable backup contains desired entries only, never an elevated recovery
# journal or Windows network object identifiers.
function Get-TargetsBackupJson([string]$source) {
 if(-not (Test-Path -LiteralPath $source)){throw 'No saved exception list to back up.'}
 $cfg=Get-Content -LiteralPath $source -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
 if($null -eq $cfg.domains -or $cfg.domains -isnot [array]){throw 'Saved exception list is invalid; no backup created.'}
 $targets=@()
 foreach($item in $cfg.domains){
  if($item -isnot [string] -or [string]::IsNullOrWhiteSpace($item)){throw 'Invalid exception entry; no backup created.'}
  $normalized=Valid-Target $item
  if($normalized -cne $item){throw 'Unexpected non-normalized entry; no backup created.'}
  $targets+=,$item
 }
 return (ConvertTo-Json -InputObject ([ordered]@{
  format='SelectiveVPNBypass.TargetsBackup.v1'
  createdUtc=[DateTime]::UtcNow.ToString('o')
  domains=@($targets|Sort-Object -Unique)
 }) -Depth 4)
}
# Exclusive creation: a backup action must not replace a user's existing file.
function Save-TargetsBackupFile([string]$destination,[string]$payload) {
 $created=$false
 $stream=$null
 $writer=$null
 try {
  $stream=[IO.File]::Open($destination,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
  $created=$true
  $writer=[IO.StreamWriter]::new($stream,[Text.UTF8Encoding]::new($false))
  $writer.Write($payload)
  $writer.Flush()
 }catch{
  $failure=$_
  if($null -ne $writer){$writer.Dispose();$writer=$null;$stream=$null}
  elseif($null -ne $stream){$stream.Dispose();$stream=$null}
  if($created){Remove-Item -LiteralPath $destination -Force -ErrorAction SilentlyContinue}
  throw $failure
 }finally{
  if($null -ne $writer){$writer.Dispose()}
  elseif($null -ne $stream){$stream.Dispose()}
 }
}
function Set-UiBusy([bool]$busy) {
  foreach($button in @($add,$top[1][0],$top[1][1],$other[1][0],$other[1][1],$other[1][2],$other[1][3])){
    $button.Enabled = -not $busy
  }
  $add.Enabled=(-not $busy -and -not $script:configInvalid)
  $other[1][3].Enabled=(-not $busy -and -not $script:configInvalid)
  $remove.Enabled=(-not $busy -and $items.SelectedIndex -ge 0 -and -not $script:configInvalid)
  $entry.Enabled=(-not $busy -and -not $script:configInvalid)
}
# Never force-terminate Apply/Restore because it may leave an incomplete
# Windows operation. Make long-running work and next steps explicit instead.
function Get-RunningNotice([string]$action,[int]$elapsed) {
 if($elapsed -ge 120){
  return "Still running $action ($elapsed s). Do not open another copy. If the operation is interrupted, use Inspect before retrying; the app cannot confirm its current network stage."
 }
 if($elapsed -ge 30){
  return "Running $action ($elapsed s), longer than usual. The window is responsive; no automatic cancellation is performed. If interrupted, inspect the recovery journal."
 }
 return "Running $action ($elapsed s)... The window is responsive."
}
# Diagnostic codes are advisory; they do not prove rollback succeeded.
function Get-FailureGuidance([string]$details,[int]$nativeErrorCode=0) {
 if($nativeErrorCode -eq 1223 -or $details -match '(?i)operation was cancel(?:l)?ed by the user'){
  return '[UAC_CANCELLED] Approval was cancelled. No completion was confirmed; inspect any prior recovery journal.'
 }
 if($details -match '(?i)cannot create a fresh worker log|worker log must reside'){
  return '[LOG_UNAVAILABLE] The elevated helper could not create its result log. Check the Windows TEMP directory.'
 }
 if($details -match '(?i)recovery journal.*(invalid|missing|unsupported|corrupt|schema|unreadable)|invalid.*owner identity|unsupported.*schema|malformed.*configuration'){
  return '[JOURNAL_INVALID] Recovery records are unreadable or incompatible. Preserve their original bytes and run Inspect.'
 }
 if($details -match '(?i)ambiguous|duplicate matching route|unmanaged route|existing NRPT policy|ownership.*mismatch|another network operation'){
  return '[OWNERSHIP_CONFLICT] Existing Windows objects or another operation prevent a safe change. Inspect before retrying.'
 }
 if($details -match '(?i)adapter is not connected|default IPv4 route missing|cannot determine Wi-Fi gateway|no Wi-Fi DNS configured'){
  return '[NETWORK_UNAVAILABLE] Expected adapter, VPN route, gateway or DNS is unavailable. Check connections and run Status.'
 }
 return '[WORKER_FAILED] No success was confirmed. Retain the journal and use Inspect before reapplying.'
}
# Single timer in GUI script scope; no GetNewClosure / separate module state.
function Get-ActiveWorkerExitWarning {
 return 'A network operation is still running. Closing this window does not cancel its worker or guarantee rollback. Choose No to keep watching, or Yes to close the window and later use Inspect before another Apply/Restore.'
}
$form.Add_FormClosing({
 param($sender,$args)
 if(-not $script:running -or $InteractionTest -or $SmokeTest){return}
 if($args.CloseReason -eq [Windows.Forms.CloseReason]::WindowsShutDown){return}
 $choice=[Windows.Forms.MessageBox]::Show(
  (Get-ActiveWorkerExitWarning),'Unfinished network operation',
  [Windows.Forms.MessageBoxButtons]::YesNo,
  [Windows.Forms.MessageBoxIcon]::Warning,
  [Windows.Forms.MessageBoxDefaultButton]::Button2
 )
 if($choice -ne [Windows.Forms.DialogResult]::Yes){$args.Cancel=$true}
})
$script:actionTimer=New-Object Windows.Forms.Timer
$script:actionTimer.Interval=150
$script:actionTimer.Add_Tick({
  if(-not $script:running -or $null -eq $script:activeProcess){return}
  try {
    if(-not $script:activeProcess.HasExited){
      $elapsed=[int]([DateTime]::UtcNow-$script:activeStarted).TotalSeconds
      if($elapsed -ge 4){$log.Text=Get-RunningNotice $script:activeAction $elapsed}
      return
    }
    $exitCode=$script:activeProcess.ExitCode
    if(Test-Path -LiteralPath $script:activeLogPath){
      $output=Get-Content -LiteralPath $script:activeLogPath -Raw -Encoding UTF8 -ErrorAction Stop
      if($exitCode -eq 0 -and [string]::IsNullOrWhiteSpace($output)){
        $log.Text="FAILED: Empty result log for $($script:activeAction)"+[Environment]::NewLine+"[EMPTY_RESULT_LOG] The worker did not report a verifiable result. Preserve the journal and run Inspect before retrying."
      }elseif($exitCode -eq 0){
        $log.Text="Completed: $($script:activeAction)"+[Environment]::NewLine+$output
        # Only acknowledge Add after both worker success and readable log.
        # Never erase a user's input on a missing/unreadable result.
        if($script:activeAction -eq 'add' -and $null -ne $script:pendingAddText -and
           $entry.Text -ceq $script:pendingAddText){$entry.Clear()}
      }else{
        $log.Text="FAILED: $($script:activeAction) (exit $exitCode)"+[Environment]::NewLine+(Get-FailureGuidance $output)+[Environment]::NewLine+$output
      }
    }else{$log.Text="FAILED: No result log for $($script:activeAction) (exit $exitCode)"+[Environment]::NewLine+"[NO_RESULT_LOG] The helper exited without a readable result. A different administrator account can use a different TEMP directory; do not assume a network change succeeded. Run Inspect before retrying."}
  }catch{
    $log.Text="Worker completion error: $($_.Exception.Message)"
  }finally{
    if($script:activeProcess.HasExited){
      $script:actionTimer.Stop()
      $script:actionFinishedCount++
      try{$script:activeProcess.Dispose()}catch{}
      if($script:activeLogPath){Remove-Item -LiteralPath $script:activeLogPath -Force -ErrorAction SilentlyContinue}
      $script:activeProcess=$null
      $script:activeAction=$null
      $script:pendingAddText=$null
      $script:activeLogPath=$null
      $script:running=$false
      Set-UiBusy $false
      Update-Items
      Update-Status
      if($form.IsHandleCreated -and -not $form.IsDisposed -and -not $InteractionTest){$form.BeginInvoke([Action]{if($entry.Enabled){$entry.Focus()}}) | Out-Null}
    }
  }
})
function Run-Action([string]$action,[string]$target='') {
  if($script:running){
    $log.Text="Please wait: $($script:activeAction) is still running."
    return $false
  }
  $script:running=$true
  Set-UiBusy $true
  $script:activeAction=$action
  $script:activeStarted=[DateTime]::UtcNow
  $log.Text="Running $action ..."
  $path=Join-Path $env:TEMP ("svb-"+[guid]::NewGuid().ToString('N')+".log")
  try {
    $ps=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $workerPath=$worker
    if($InteractionTest -and $action -in @('apply','restore')) {
      $workerPath=Join-Path $DataDir 'MockWorker.ps1'
    }
    $p=New-Object Diagnostics.ProcessStartInfo
    $requiresElevation=($action -in @('apply','restore') -and -not $InteractionTest)
    if($requiresElevation){
      if(-not $LauncherPath -or -not (Test-Path -LiteralPath $LauncherPath)){
        throw 'The original portable executable is required for elevated actions.'
      }
      $p.FileName=$LauncherPath
      $p.Arguments=('--worker -Action {0} -ConfigDir "{1}" -LogPath "{2}"' -f $action,$DataDir,$path)
      $p.UseShellExecute=$true
      $p.Verb='runas'
    }else{
      $p.FileName=$ps
      $p.Arguments=('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -BackendPath "{1}" -Action {2} -Domain "{3}" -ConfigDir "{4}" -LogPath "{5}"' -f $workerPath,$backend,$action,$target,$DataDir,$path)
      $p.UseShellExecute=$false
      $p.CreateNoWindow=$true
    }
    $script:activeProcess=[Diagnostics.Process]::Start($p)
    if($null -eq $script:activeProcess){throw "Could not start $action."}
    $script:activeLogPath=$path
    $script:actionStartedCount++
    $script:actionTimer.Start()
    return $true
  }catch{
    $script:actionTimer.Stop()
    $script:running=$false
    Set-UiBusy $false
    $script:activeAction=$null
    $script:activeProcess=$null
    $script:activeLogPath=$null
    $nativeCode=0
    if($_.Exception -is [ComponentModel.Win32Exception]){$nativeCode=$_.Exception.NativeErrorCode}
    $log.Text="Failed to start $action : "+(Get-FailureGuidance $_.Exception.Message $nativeCode)+[Environment]::NewLine+$_.Exception.Message
    return $false
  }
}
$add.Add_Click({
 try{$v=Valid-Target $entry.Text;if(Run-Action 'add' $v){$script:pendingAddText=$entry.Text}}
 catch{if($InteractionTest){throw}else{[Windows.Forms.MessageBox]::Show($_.Exception.Message,'Invalid entry')|Out-Null}}
})
$remove.Add_Click({if($null -ne $items.SelectedItem){Run-Action 'remove' ([string]$items.SelectedItem)}})
# Keyboard UX: Enter in input adds, Delete on selected list item removes.
# Handled suppresses the Windows alert sound and prevents accidental dialog submission.
$entry.Add_KeyDown({
 param($sender,$keyEvent)
 if($keyEvent.KeyCode -eq [Windows.Forms.Keys]::Enter){
   $keyEvent.Handled=$true
   $keyEvent.SuppressKeyPress=$true
   if(-not $script:running -and $entry.Text.Trim().Length -gt 0){$add.PerformClick()}
 }
})
$items.Add_SelectedIndexChanged({
 $remove.Enabled=($items.SelectedIndex -ge 0 -and -not $script:running -and -not $script:configInvalid)
})
$items.Add_KeyDown({
 param($sender,$keyEvent)
 if($keyEvent.KeyCode -eq [Windows.Forms.Keys]::Delete -and $items.SelectedIndex -ge 0){
   $keyEvent.Handled=$true
   $keyEvent.SuppressKeyPress=$true
   if(-not $script:running){$remove.PerformClick()}
 }
})
$entry.Add_KeyDown({
 param($sender,$keyEvent)
 if($keyEvent.KeyCode -eq [Windows.Forms.Keys]::Escape){
   $entry.Clear();$keyEvent.Handled=$true;$keyEvent.SuppressKeyPress=$true
 }
})
$top[1][0].Add_Click({Run-Action 'apply'})
$top[1][1].Add_Click({Run-Action 'restore'})
$other[1][0].Add_Click({Run-Action 'status'})
$other[1][1].Add_Click({if($null -ne $items.SelectedItem){Run-Action 'dns' ([string]$items.SelectedItem)}})
$other[1][2].Add_Click({Run-Action 'inspect'})

$other[1][3].Add_Click({
 if($script:running -or $script:configInvalid){return}
 $created=$null
 try{
  $payload=Get-TargetsBackupJson $config
  $dialog=New-Object Windows.Forms.SaveFileDialog
  $dialog.Title='Export saved exceptions (not recovery journal)'
  $dialog.Filter='JSON backup (*.json)|*.json'
  $dialog.DefaultExt='json'
  $dialog.FileName='SelectiveVPNBypass-Targets-'+[DateTime]::Now.ToString('yyyyMMdd-HHmmss')+'.json'
  $dialog.OverwritePrompt=$false # CreateNew never overwrites; an occupied filename produces a clear error.
  try{
   if($dialog.ShowDialog($form) -ne [Windows.Forms.DialogResult]::OK){return}
   # No silent overwrite even when the chosen name already exists.
   Save-TargetsBackupFile $dialog.FileName $payload
   $created=$dialog.FileName
  }finally{$dialog.Dispose()}
  $log.Text='Targets backup created. It contains saved exceptions only; no routes or NRPT recovery state.'
 }catch{
  if($created -and (Test-Path -LiteralPath $created)){
   Remove-Item -LiteralPath $created -Force -ErrorAction SilentlyContinue
  }
  $log.Text='Backup not created: '+$_.Exception.Message
 }
})

Update-Items;Update-Status
if ($InteractionTest) {
  # Same dispatcher as GUI; simulated apply/restore never touch network.
  $mock=Join-Path $DataDir 'MockWorker.ps1'
  @'
param([string]$BackendPath,[string]$Action,[string]$Domain,[string]$ConfigDir,[string]$LogPath)
Start-Sleep -Milliseconds 80
if($Action -eq 'apply' -and $Domain -eq 'fail'){
  "SIMULATED FAILURE" | Set-Content -LiteralPath $LogPath -Encoding UTF8
  exit 7
}
if($Action -eq 'apply' -and $Domain -eq 'nolog'){exit 0}
if($Action -eq 'apply' -and $Domain -eq 'emptylog'){
  [IO.File]::WriteAllText($LogPath,'')
  exit 0
}
"SIMULATED $Action SUCCESS" | Set-Content -LiteralPath $LogPath -Encoding UTF8
exit 0
'@ | Set-Content -LiteralPath $mock -Encoding UTF8
  function Wait-Idle([string]$step) {
    for($k=0;$k -lt 400;$k++){
      [Windows.Forms.Application]::DoEvents()
      if(-not $script:running){
        if($log.Text -match '^Running '){
          throw "GUI state mismatch after $step : started=$script:actionStartedCount finished=$script:actionFinishedCount log=$($log.Text)"
        }
        return
      }
      [Threading.Thread]::Sleep(25)
    }
    $pidInfo=if($null -ne $script:activeProcess){[string]$script:activeProcess.Id}else{'none'}
    throw "GUI remained busy after $step : started=$script:actionStartedCount finished=$script:actionFinishedCount action=$script:activeAction process=$pidInfo (10-second limit)"
  }
  function Assert-Items([string[]]$expected,[string]$label) {
    Update-Items
    $actual=@($items.Items | ForEach-Object{[string]$_})
    if(($actual -join ',') -ne (($expected|Sort-Object) -join ',')){
      throw "$label mismatch; expected $($expected -join ','), actual $($actual -join ',')"
    }
  }
  try {
    foreach($case in @(
      @{details='Operation was canceled by the user.';code=1223;expect='UAC_CANCELLED'},
      @{details='cannot create a fresh worker log';code=0;expect='LOG_UNAVAILABLE'},
      @{details='Recovery journal has unsupported schema';code=0;expect='JOURNAL_INVALID'},
      @{details='Restore incomplete. Recovery journal retained.';code=0;expect='WORKER_FAILED'},
      @{details='Preflight: duplicate matching route candidates';code=0;expect='OWNERSHIP_CONFLICT'},
      @{details='Wi-Fi adapter is not connected.';code=0;expect='NETWORK_UNAVAILABLE'},
      @{details='Unhandled worker failure';code=0;expect='WORKER_FAILED'}
    )){
      $guidance=Get-FailureGuidance $case.details $case.code
      if($guidance -notmatch ('^\['+$case.expect+'\]')){
        throw ('Wrong failure guidance: '+$case.expect+' => '+$guidance)
      }
    }
    if((Get-ActiveWorkerExitWarning) -notmatch 'does not cancel its worker'){
      throw 'Closing an active worker lacked a non-destructive warning'
    }
    # Long-running notice never promises a safe automatic rollback or cancellation.
    if((Get-RunningNotice 'apply' 35) -notmatch 'no automatic cancellation'){
      throw 'Long-running work did not explain cancellation limitations'
    }
    if((Get-RunningNotice 'restore' 130) -notmatch 'Inspect before retrying'){
      throw 'Overdue worker did not explain recovery inspection'
    }
    # Dispatch actual Button Click events, rather than calling Run-Action directly.
    # Reflection invokes protected OnClick without requiring an interactive desktop.
    function Click-Button([Windows.Forms.Button]$button) {
      $flags=[Reflection.BindingFlags]::Instance -bor [Reflection.BindingFlags]::NonPublic
      $onClick=$button.GetType().GetMethod('OnClick',$flags)
      if($null -eq $onClick){throw "OnClick not found: $($button.Text)"}
      [void]$onClick.Invoke($button,@([EventArgs]::Empty))
    }
    $entry.Text='example.com'; Click-Button $add; Wait-Idle 'first add'
    if($entry.Text -ne ''){throw 'Input not cleared after successful add'}
    Assert-Items @('example.com') 'first add'
    $entry.Text='example.kr'; Click-Button $add; Wait-Idle 'second add'
    $entry.Text='example.wiki'; Click-Button $add; Wait-Idle 'third add'
    $entry.Text='192.0.2.10'; Click-Button $add; Wait-Idle 'IPv4 add'
    Assert-Items @('example.com','example.kr','example.wiki','192.0.2.10') 'multi-add'
    $items.SelectedIndex=$items.Items.IndexOf('example.kr')
    if($items.SelectedIndex -lt 0){throw 'Could not select item for deletion'}
    Click-Button $remove; Wait-Idle 'remove selected'
    Assert-Items @('example.com','example.wiki','192.0.2.10') 'remove'
    for($i=0;$i -lt 3;$i++){
      $countBefore=$script:actionStartedCount
      Click-Button ($top[1][0])
      if($script:actionStartedCount -ne ($countBefore+1)){
        throw "Apply cycle $i did not launch a worker: started=$script:actionStartedCount finished=$script:actionFinishedCount buttonEnabled=$($top[1][0].Enabled)"
      }
      if($i -eq 0){
        $entry.Text='busy.example'
        Click-Button $add
        if($entry.Text -ne 'busy.example'){throw 'Busy add click discarded text'}
      }
      Wait-Idle "apply cycle $i"
      if($log.Text -notmatch "SIMULATED apply SUCCESS"){throw ("Simulated apply did not complete: "+$log.Text)}
      Click-Button ($top[1][1]); Wait-Idle "restore cycle $i"
      if($log.Text -notmatch "SIMULATED restore SUCCESS"){throw 'Simulated restore did not complete'}
    }
    # A successful exit without an output log is not verified completion.
    if(-not (Run-Action 'apply' 'nolog')){throw 'No-log mock worker failed to launch'}
    Wait-Idle 'worker without result log'
    if($log.Text -notmatch '\[NO_RESULT_LOG\]' -or $log.Text -match '^Completed:'){
      throw ('No-log worker incorrectly reported success: '+$log.Text)
    }
    if($script:running){throw 'No-log worker left the GUI in busy state'}
    if($log.Text -notmatch 'administrator account'){throw 'No-log diagnostic does not mention cross-account UAC uncertainty'}

    if(-not (Run-Action 'apply' 'emptylog')){throw 'Empty-log mock worker failed to launch'}
    Wait-Idle 'worker with empty result log'
    if($log.Text -notmatch '\[EMPTY_RESULT_LOG\]' -or $log.Text -match '^Completed:'){
      throw ('Empty-log worker incorrectly reported success: '+$log.Text)
    }

    [void](Run-Action 'apply' 'fail')
    Wait-Idle 'failed apply worker'
    if($log.Text -notmatch 'FAILED: apply' -or $log.Text -notmatch 'SIMULATED FAILURE'){
      throw 'Failed worker result not displayed correctly'
    }
    if($script:running){throw 'Busy flag remained locked after failure'}
    if($entry.Text -ne 'busy.example'){throw 'Worker failure unexpectedly discarded pending user input'}
    # The Add input must survive a real failed worker (invalid backend path).
    $savedBackend=$backend
    try {
      $backend=Join-Path $DataDir 'does-not-exist-backend.ps1'
      $entry.Text='retry.example'
      Click-Button $add
      Wait-Idle 'failed add worker'
      if($log.Text -notmatch 'FAILED: add'){throw 'Failed Add was not shown as a failure'}
      if($entry.Text -ne 'retry.example'){throw 'Failed Add unexpectedly erased user input'}
      Assert-Items @('example.com','example.wiki','192.0.2.10') 'failed add must not persist entry'
    } finally {
      $backend=$savedBackend
    }
    $entry.Text='example.net'; Click-Button $add; Wait-Idle 'add after restore'
    Assert-Items @('example.com','example.wiki','example.net','192.0.2.10') 'post-restore add'
    $export=Get-TargetsBackupJson $config | ConvertFrom-Json
    if($export.format -ne 'SelectiveVPNBypass.TargetsBackup.v1' -or
       @($export.domains).Count -ne 4 -or
       $null -ne $export.PSObject.Properties['routes'] -or
       $null -ne $export.PSObject.Properties['ownerId'] -or
       $null -ne $export.PSObject.Properties['pendingRules']){
      throw 'Portable backup contains recovery journal data or is malformed.'
    }
    if($other[1][3].Text -ne 'Backup'){throw 'Missing safe configuration backup action.'}

    $backupPath=Join-Path $DataDir 'backup-regression.json'
    $payload=Get-TargetsBackupJson $config
    Save-TargetsBackupFile $backupPath $payload
    $firstBackup=[IO.File]::ReadAllBytes($backupPath)
    $overwriteRejected=$false
    try{Save-TargetsBackupFile $backupPath '{"different":true}'}catch{$overwriteRejected=$true}
    $secondBackup=[IO.File]::ReadAllBytes($backupPath)
    if(-not $overwriteRejected -or
       [Convert]::ToBase64String($firstBackup) -cne [Convert]::ToBase64String($secondBackup)){
      throw 'Targets backup overwrote an existing file.'
    }
    Remove-Item -LiteralPath $backupPath -Force

    # A malformed saved list must not look like an editable empty list.
    $goodConfig=Get-Content -LiteralPath $config -Raw
    try{
      '{"domains":[' | Set-Content -LiteralPath $config -Encoding UTF8
      Update-Items;Update-Status
      if(-not $script:configInvalid -or $add.Enabled -or $status.Text -notmatch 'Saved list: INVALID'){
        throw 'Malformed saved list was not exposed as read-only invalid state'
      }
    }finally{
      Set-Content -LiteralPath $config -Value $goodConfig -NoNewline -Encoding UTF8
      Update-Items;Update-Status
    }
    if($script:configInvalid -or -not $add.Enabled){throw 'Valid list did not recover after file repair'}
    # Keyboard handler registration is covered by parser and GUI init.
    # Real key events require an interactive Windows desktop and are field tests.
    Write-Output 'GUI button-click regression PASS: multi-add, selected remove, 3 simulated apply/restore pairs, busy click, failed worker recovery, post-restore add, deferred input clear, failed Add retention, honest journal label.'
  }finally {
    $script:actionTimer.Stop()
    Remove-Item -LiteralPath $mock -Force -ErrorAction SilentlyContinue
    $form.Dispose()
  }
  return
}
if ($SmokeTest) {
  if ($items.Items.Count -ne 0) { throw 'Smoke test requires an empty configuration list.' }
  if ($add.Text -ne 'Add' -or $remove.Text -ne 'Remove selected') { throw 'Missing list controls.' }
  if ($top[1][0].Text -ne 'Apply' -or $top[1][1].Text -ne 'Restore') { throw 'Missing action controls.' }
  if ($other[1][2].Text -ne 'Inspect') { throw 'Missing read-only recovery inspector.' }
  if ($status.Text -match 'Applied: True|Applied: False') { throw 'Status misrepresents journal presence as verified application.' }
  Write-Output 'GUI controls initialization PASS (no interactive display or DPI test).'
  $form.Dispose()
  return
}
[void]$form.ShowDialog()
