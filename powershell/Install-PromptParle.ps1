#Requires -Version 5.1
<#
.SYNOPSIS
  Install the PromptParle module into the current user's PowerShell module path.

.DESCRIPTION
  Always copies the module from this repo into the user Modules folder so
  updates from git pull are applied. Use -NoForce only if you want to skip
  when already installed (not recommended).

.EXAMPLE
  ./Install-PromptParle.ps1
  Import-Module PromptParle
  pp
#>
[CmdletBinding()]
param(
    [switch]$Force,
    [switch]$NoForce
)

$ErrorActionPreference = 'Stop'

$source = Join-Path $PSScriptRoot 'PromptParle'
if (-not (Test-Path -LiteralPath (Join-Path $source 'PromptParle.psd1'))) {
    throw "Module source not found at $source"
}

# Confirm local UI is present (v0.4+)
$localUi = Join-Path $source 'local-ui\index.html'
if (-not (Test-Path -LiteralPath $localUi)) {
    $localUi = Join-Path $source 'local-ui/index.html'
}
if (-not (Test-Path -LiteralPath $localUi)) {
    Write-Warning 'local-ui/index.html missing - run git pull and reinstall'
}

$sourceVersion = 'unknown'
try {
    if (Get-Command Import-PowerShellDataFile -ErrorAction SilentlyContinue) {
        $manifest = Import-PowerShellDataFile -Path (Join-Path $source 'PromptParle.psd1')
        if ($manifest.ModuleVersion) { $sourceVersion = [string]$manifest.ModuleVersion }
    } else {
        $raw = Get-Content -LiteralPath (Join-Path $source 'PromptParle.psd1') -Raw
        if ($raw -match "ModuleVersion\s*=\s*'([^']+)'") { $sourceVersion = $Matches[1] }
    }
} catch { }

if ($PSVersionTable.PSEdition -eq 'Core') {
    $userModules = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'PowerShell\Modules'
} else {
    $userModules = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'WindowsPowerShell\Modules'
}

$docs = [Environment]::GetFolderPath('MyDocuments')
if (-not $docs -or -not (Test-Path -LiteralPath $docs)) {
    $userModules = Join-Path $HOME '.local/share/powershell/Modules'
}

$dest = Join-Path $userModules 'PromptParle'
$shouldInstall = $true

if ((Test-Path -LiteralPath $dest) -and $NoForce -and -not $Force) {
    Write-Host "Module already exists at $dest (omit -NoForce to overwrite)" -ForegroundColor Yellow
    $shouldInstall = $false
}

if ($shouldInstall) {
    if (Test-Path -LiteralPath $dest) {
        Remove-Item -LiteralPath $dest -Recurse -Force
    }
    New-Item -ItemType Directory -Path $userModules -Force | Out-Null
    Copy-Item -Path $source -Destination $dest -Recurse -Force
    Write-Host "Installed PromptParle $sourceVersion to $dest" -ForegroundColor Green
}

Get-ChildItem -LiteralPath $dest -Recurse -File | ForEach-Object {
    try { Unblock-File -LiteralPath $_.FullName -ErrorAction SilentlyContinue } catch { }
}

Remove-Module PromptParle -Force -ErrorAction SilentlyContinue
Import-Module PromptParle -Force
$loaded = Get-Module PromptParle
Write-Host ("Imported PromptParle {0}" -f $loaded.Version) -ForegroundColor Green

if ($loaded.Version -lt [version]'0.4.0') {
    Write-Host 'WARNING: expected 0.4.0+ for local chat. git pull and reinstall.' -ForegroundColor Yellow
}

Write-Host ''
Write-Host 'Start local chat:' -ForegroundColor Cyan
Write-Host '  pp'
Write-Host '  # opens http://127.0.0.1:7788  (leave this PowerShell window open)'
Write-Host ''
Write-Host 'Setup once:' -ForegroundColor DarkGray
Write-Host '  1. https://promptparle.com  -> Providers -> add AI key'
Write-Host '  2. API Keys -> create pp_live_ key'
Write-Host '  3. Set-PromptParleApiKey -ApiKey pp_live_YOUR_KEY'
Write-Host '  4. pp'
Write-Host ''
Write-Host 'Notes:' -ForegroundColor DarkGray
Write-Host '  - Chat UI runs on YOUR PC (127.0.0.1), not as cloud HTML'
Write-Host '  - AI token costs bill to YOUR provider keys'
Write-Host '  - Optional terminal: Start-PromptParle -Cli'
Write-Host ''
Write-Host 'Optional auto-load every PowerShell window:' -ForegroundColor DarkGray
Write-Host '  Add-Content $PROFILE ''Import-Module PromptParle'''
Write-Host ''
