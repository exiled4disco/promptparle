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
#>
[CmdletBinding()]
param(
    # Kept for backward compatibility; install always overwrites by default.
    [switch]$Force,

    # Skip overwrite if the module folder already exists.
    [switch]$NoForce
)

$ErrorActionPreference = 'Stop'

$source = Join-Path $PSScriptRoot 'PromptParle'
if (-not (Test-Path -LiteralPath (Join-Path $source 'PromptParle.psd1'))) {
    throw "Module source not found at $source"
}

# Read source version for messaging
$sourceVersion = 'unknown'
try {
    $manifest = Import-PowerShellDataFile -Path (Join-Path $source 'PromptParle.psd1')
    if ($manifest.ModuleVersion) { $sourceVersion = [string]$manifest.ModuleVersion }
} catch {
    # PS 5.1 may lack Import-PowerShellDataFile on older builds; ignore
}

if ($PSVersionTable.PSEdition -eq 'Core') {
    $userModules = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'PowerShell/Modules'
} else {
    $userModules = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'WindowsPowerShell/Modules'
}

# Non-Windows pwsh (PS 5.1 has no $IsLinux/$IsMacOS)
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

# Unblock on Windows if needed
Get-ChildItem -LiteralPath $dest -Recurse -File | ForEach-Object {
    try { Unblock-File -LiteralPath $_.FullName -ErrorAction SilentlyContinue } catch { }
}

# Drop any previously loaded (broken) copy from this session
Remove-Module PromptParle -Force -ErrorAction SilentlyContinue
Import-Module PromptParle -Force
$loaded = Get-Module PromptParle
Write-Host "Imported PromptParle $($loaded.Version)" -ForegroundColor Green
Write-Host ''
Write-Host 'Start chatting (LOCAL browser on this PC):' -ForegroundColor Cyan
Write-Host '  pp'
Write-Host '  # opens http://127.0.0.1:7788  (leave PowerShell open)'
Write-Host ''
Write-Host 'Setup (once):' -ForegroundColor DarkGray
Write-Host '  1) https://promptparle.com → Providers → add OpenAI/etc key'
Write-Host '  2) API Keys → create pp_live_…'
Write-Host "  3) Set-PromptParleApiKey -ApiKey 'pp_live_...'"
Write-Host '  4) pp'
Write-Host ''
Write-Host 'Notes:' -ForegroundColor DarkGray
Write-Host '  • Chat UI is local (not served from AWS as your daily UI)'
Write-Host '  • AI token costs bill to YOUR provider keys (BYOK)'
Write-Host '  • Optional terminal: Start-PromptParle -Cli'
Write-Host ''
Write-Host 'Optional — auto-load in every PowerShell window:' -ForegroundColor DarkGray
Write-Host "  Add-Content `$PROFILE `"Import-Module PromptParle`""
