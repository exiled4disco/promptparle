#Requires -Version 5.1
<#
.SYNOPSIS
  Install the PromptParle module into the current user's PowerShell module path.

.EXAMPLE
  ./Install-PromptParle.ps1
  Import-Module PromptParle
#>
[CmdletBinding()]
param(
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

$source = Join-Path $PSScriptRoot 'PromptParle'
if (-not (Test-Path -LiteralPath (Join-Path $source 'PromptParle.psd1'))) {
    throw "Module source not found at $source"
}

if ($PSVersionTable.PSEdition -eq 'Core') {
    $userModules = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'PowerShell/Modules'
} else {
    $userModules = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'WindowsPowerShell/Modules'
}

# Non-Windows pwsh
if (-not (Test-Path ([Environment]::GetFolderPath('MyDocuments')))) {
    if ($IsLinux -or $IsMacOS) {
        $userModules = Join-Path $HOME '.local/share/powershell/Modules'
    }
}

$dest = Join-Path $userModules 'PromptParle'

if ((Test-Path -LiteralPath $dest) -and -not $Force) {
    Write-Host "Module already exists at $dest (use -Force to overwrite)" -ForegroundColor Yellow
} else {
    if (Test-Path -LiteralPath $dest) {
        Remove-Item -LiteralPath $dest -Recurse -Force
    }
    New-Item -ItemType Directory -Path $userModules -Force | Out-Null
    Copy-Item -Path $source -Destination $dest -Recurse -Force
    Write-Host "Installed PromptParle to $dest" -ForegroundColor Green
}

# Unblock on Windows if needed
Get-ChildItem -LiteralPath $dest -Recurse -File | ForEach-Object {
    try { Unblock-File -LiteralPath $_.FullName -ErrorAction SilentlyContinue } catch { }
}

Import-Module PromptParle -Force
Write-Host "Imported PromptParle $((Get-Module PromptParle).Version)" -ForegroundColor Green
Write-Host ''
Write-Host 'Next:' -ForegroundColor Cyan
Write-Host "  Set-PromptParleApiKey -ApiKey 'pp_live_xxxxx'"
Write-Host '  Get-PromptParleProvider'
Write-Host "  Invoke-PromptParle -Provider openai -Prompt 'Hello' -Context 'test'"
