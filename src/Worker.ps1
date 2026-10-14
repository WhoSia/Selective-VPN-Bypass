#Requires -Version 5.1
param(
  [Parameter(Mandatory=$true)][string]$BackendPath,
  [Parameter(Mandatory=$true)][ValidateSet('list','add','remove','dns','status','apply','restore')][string]$Action,
  [string]$Domain = '',
  [Parameter(Mandatory=$true)][string]$ConfigDir,
  [Parameter(Mandatory=$true)][string]$LogPath
)
$ErrorActionPreference = 'Stop'
try {
  & $BackendPath -Action $Action -Domain $Domain -ConfigDir $ConfigDir *>&1 | Out-String -Width 200 | Set-Content -LiteralPath $LogPath -Encoding UTF8
  exit 0
} catch {
  $_ | Out-String -Width 200 | Add-Content -LiteralPath $LogPath -Encoding UTF8
  exit 1
}
