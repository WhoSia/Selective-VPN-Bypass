#Requires -Version 5.1
param([string]$RuntimeDir,[string]$DataDir,[switch]$SmokeTest)
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
$left.Controls.Add($items,0,1)
$addRow=New-Object Windows.Forms.TableLayoutPanel
$addRow.Dock='Fill';$addRow.ColumnCount=2
$addRow.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent',70)))|Out-Null
$addRow.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent',30)))|Out-Null
$entry=New-Object Windows.Forms.TextBox
$entry.Dock='Fill';$entry.Margin=New-Object Windows.Forms.Padding(2,7,5,5)
$addRow.Controls.Add($entry,0,0)
$add=New-Object Windows.Forms.Button
$add.Text='Add';$add.Dock='Fill'
$addRow.Controls.Add($add,1,0);$left.Controls.Add($addRow,0,2)
$remove=New-Object Windows.Forms.Button
$remove.Text='Remove selected';$remove.Dock='Fill'
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
function Run-Action([string]$action,[string]$target='') {
 if($script:running){return}
 $script:running=$true
 $log.Text="Running $action ..."
 $logPath=Join-Path $env:TEMP ("svb-"+[guid]::NewGuid().ToString('N')+".log")
 try{
  $ps=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
  $p=New-Object Diagnostics.ProcessStartInfo
  $p.FileName=$ps
  $p.Arguments=('-NoProfile -ExecutionPolicy Bypass -File "{0}" -BackendPath "{1}" -Action {2} -Domain "{3}" -ConfigDir "{4}" -LogPath "{5}"' -f $worker,$backend,$action,$target,$DataDir,$logPath)
  $p.UseShellExecute=($action -in @('apply','restore'))
  if($p.UseShellExecute){$p.Verb='runas'}else{$p.CreateNoWindow=$true}
  $proc=[Diagnostics.Process]::Start($p)
  $timer=New-Object Windows.Forms.Timer
  $timer.Interval=200
  $timer.Add_Tick({
    if(-not $proc.HasExited){return}
    $timer.Stop();$timer.Dispose()
    try{$log.Text=(Get-Content -LiteralPath $logPath -Raw -ErrorAction Stop)}catch{$log.Text="Exit code $($proc.ExitCode); no log."}
    Remove-Item -LiteralPath $logPath -Force -ErrorAction SilentlyContinue
    $proc.Dispose();$script:running=$false
    Update-Items;Update-Status
  }.GetNewClosure())
  $timer.Start()
 }catch{$log.Text=$_.Exception.Message;$script:running=$false}
}
$add.Add_Click({
 try{$v=Valid-Target $entry.Text;Run-Action 'add' $v;$entry.Clear()}
 catch{[Windows.Forms.MessageBox]::Show($_.Exception.Message,'Invalid entry')|Out-Null}
})
$remove.Add_Click({if($null -ne $items.SelectedItem){Run-Action 'remove' ([string]$items.SelectedItem)}})
$top[1][0].Add_Click({Run-Action 'apply'})
$top[1][1].Add_Click({Run-Action 'restore'})
$other[1][0].Add_Click({Run-Action 'status'})
$other[1][1].Add_Click({if($null -ne $items.SelectedItem){Run-Action 'dns' ([string]$items.SelectedItem)}})
Update-Items;Update-Status
if ($SmokeTest) {
  if ($items.Items.Count -ne 0) { throw 'Smoke test requires an empty configuration list.' }
  if ($add.Text -ne 'Add' -or $remove.Text -ne 'Remove selected') { throw 'Missing list controls.' }
  if ($top[1][0].Text -ne 'Apply' -or $top[1][1].Text -ne 'Restore') { throw 'Missing action controls.' }
  Write-Output 'GUI controls initialization PASS (no interactive display or DPI test).'
  $form.Dispose()
  return
}
[void]$form.ShowDialog()
