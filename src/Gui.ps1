#Requires -Version 5.1
param([string]$RuntimeDir,[string]$DataDir,[switch]$SmokeTest,[switch]$InteractionTest)
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
$other=Make-Row @('Status','DNS')
$right.Controls.Add($other[0],0,2)
$log=New-Object Windows.Forms.TextBox
$log.Multiline=$true;$log.ReadOnly=$true;$log.ScrollBars='Vertical'
$log.Dock='Fill';$log.Font=New-Object Drawing.Font('Consolas',9)
$log.Text='No changes applied. Apply and Restore require administrator approval.'
$right.Controls.Add($log,0,3)
$foot=New-Object Windows.Forms.Label
$foot.Dock='Fill';$foot.Text='IPv4 only. DNS/DoH, IPv6, shared CDN addresses may not follow these rules.'
$foot.ForeColor=[Drawing.Color]::DarkSlateGray
$layout.Controls.Add($foot,0,2);$layout.SetColumnSpan($foot,2)
function Update-Items {
 $items.Items.Clear()
 if(Test-Path -LiteralPath $config){
  try {
   $obj=Get-Content -LiteralPath $config -Raw | ConvertFrom-Json
   foreach($v in @($obj.domains|Sort-Object -Unique)){if($v){[void]$items.Items.Add([string]$v)}}
  }catch{$log.Text="Invalid local configuration: $($_.Exception.Message)"}
 }
 $remove.Enabled=($items.SelectedIndex -ge 0 -and -not $script:running)
}
function Update-Status {
 try {
  $v=Get-NetAdapter -Name 'VPN - VPN Client' -ErrorAction SilentlyContinue
  $w=Get-NetAdapter -Name 'Wi-Fi' -ErrorAction SilentlyContinue
  $status.Text="SoftEther: $($v.Status)   |   Wi-Fi: $($w.Status)   |   Applied: $(Test-Path $state)"
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
function Set-UiBusy([bool]$busy) {
  foreach($button in @($add,$top[1][0],$top[1][1],$other[1][0],$other[1][1])){
    $button.Enabled = -not $busy
  }
  $remove.Enabled=(-not $busy -and $items.SelectedIndex -ge 0)
  $entry.Enabled=-not $busy
}
# Single timer in GUI script scope; no GetNewClosure / separate module state.
$script:actionTimer=New-Object Windows.Forms.Timer
$script:actionTimer.Interval=150
$script:actionTimer.Add_Tick({
  if(-not $script:running -or $null -eq $script:activeProcess){return}
  try {
    if(-not $script:activeProcess.HasExited){
      $elapsed=[int]([DateTime]::UtcNow-$script:activeStarted).TotalSeconds
      if($elapsed -ge 4){$log.Text="Running $($script:activeAction) ($elapsed s)... The window is responsive."}
      return
    }
    $exitCode=$script:activeProcess.ExitCode
    if(Test-Path -LiteralPath $script:activeLogPath){
      $output=Get-Content -LiteralPath $script:activeLogPath -Raw -ErrorAction Stop
      if($exitCode -eq 0){$log.Text="Completed: $($script:activeAction)"+[Environment]::NewLine+$output}
      else{$log.Text="FAILED: $($script:activeAction) (exit $exitCode)"+[Environment]::NewLine+$output}
    }else{$log.Text="FAILED: No result log for $($script:activeAction) (exit $exitCode)"}
  }catch{
    $log.Text="Worker completion error: $($_.Exception.Message)"
  }finally{
    if($script:activeProcess.HasExited){
      $script:actionTimer.Stop()
      try{$script:activeProcess.Dispose()}catch{}
      if($script:activeLogPath){Remove-Item -LiteralPath $script:activeLogPath -Force -ErrorAction SilentlyContinue}
      $script:activeProcess=$null
      $script:activeAction=$null
      $script:activeLogPath=$null
      $script:running=$false
      Set-UiBusy $false
      Update-Items
      Update-Status
      if($script:activeAction -eq $null -and -not $form.IsDisposed){$form.BeginInvoke([Action]{if($entry.Enabled){$entry.Focus()}}) | Out-Null}
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
    $p.FileName=$ps
    $p.Arguments=('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -BackendPath "{1}" -Action {2} -Domain "{3}" -ConfigDir "{4}" -LogPath "{5}"' -f $workerPath,$backend,$action,$target,$DataDir,$path)
    $p.UseShellExecute=($action -in @('apply','restore') -and -not $InteractionTest)
    if($p.UseShellExecute){$p.Verb='runas'}else{$p.CreateNoWindow=$true}
    $script:activeProcess=[Diagnostics.Process]::Start($p)
    if($null -eq $script:activeProcess){throw "Could not start $action."}
    $script:activeLogPath=$path
    $script:actionTimer.Start()
    return $true
  }catch{
    $script:actionTimer.Stop()
    $script:running=$false
    Set-UiBusy $false
    $script:activeAction=$null
    $script:activeProcess=$null
    $script:activeLogPath=$null
    $log.Text="Failed to start $action : $($_.Exception.Message)"
    return $false
  }
}
$add.Add_Click({
 try{$v=Valid-Target $entry.Text;if(Run-Action 'add' $v){$entry.Clear()}}
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
 $remove.Enabled=($items.SelectedIndex -ge 0 -and -not $script:running)
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
"SIMULATED $Action SUCCESS" | Set-Content -LiteralPath $LogPath -Encoding UTF8
exit 0
'@ | Set-Content -LiteralPath $mock -Encoding UTF8
  function Wait-Idle([string]$step) {
    for($k=0;$k -lt 400;$k++){
      [Windows.Forms.Application]::DoEvents()
      if(-not $script:running){return}
      [Threading.Thread]::Sleep(25)
    }
    throw "GUI remained busy after $step (10-second limit)"
  }
  function Assert-Items([string[]]$expected,[string]$label) {
    Update-Items
    $actual=@($items.Items | ForEach-Object{[string]$_})
    if(($actual -join ',') -ne (($expected|Sort-Object) -join ',')){
      throw "$label mismatch; expected $($expected -join ','), actual $($actual -join ',')"
    }
  }
  try {
    # Dispatch actual Button Click events, rather than calling Run-Action directly.
    # Reflection invokes protected OnClick without requiring an interactive desktop.
    function Click-Button([Windows.Forms.Button]$button) {
      $flags=[Reflection.BindingFlags]::Instance -bor [Reflection.BindingFlags]::NonPublic
      $onClick=$button.GetType().GetMethod('OnClick',$flags)
      if($null -eq $onClick){throw "OnClick not found: $($button.Text)"}
      [void]$onClick.Invoke($button,@([EventArgs]::Empty))
    }
    $entry.Text='example.com'; Click-Button $add; Wait-Idle 'first add'
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
      Click-Button ($top[1][0])
      if($i -eq 0){
        $entry.Text='busy.example'
        Click-Button $add
        if($entry.Text -ne 'busy.example'){throw 'Busy add click discarded text'}
      }
      Wait-Idle "apply cycle $i"
      if($log.Text -notmatch "SIMULATED apply SUCCESS"){throw 'Simulated apply did not complete'}
      Click-Button ($top[1][1]); Wait-Idle "restore cycle $i"
      if($log.Text -notmatch "SIMULATED restore SUCCESS"){throw 'Simulated restore did not complete'}
    }
    [void](Run-Action 'apply' 'fail')
    Wait-Idle 'failed apply worker'
    if($log.Text -notmatch 'FAILED: apply' -or $log.Text -notmatch 'SIMULATED FAILURE'){
      throw 'Failed worker result not displayed correctly'
    }
    if($script:running){throw 'Busy flag remained locked after failure'}
    $entry.Text='example.net'; Click-Button $add; Wait-Idle 'add after restore'
    Assert-Items @('example.com','example.wiki','example.net','192.0.2.10') 'post-restore add'
    # Keyboard handler registration is covered by parser and GUI init.
    # Real key events require an interactive Windows desktop and are field tests.
    Write-Output 'GUI button-click regression PASS: multi-add, selected remove, 3 simulated apply/restore pairs, busy click, failed worker recovery, post-restore add.'
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
  Write-Output 'GUI controls initialization PASS (no interactive display or DPI test).'
  $form.Dispose()
  return
}
[void]$form.ShowDialog()
