#Requires -Version 5.1
<#
.SYNOPSIS
  Remove the PromptParle PowerShell module from this user profile.

.EXAMPLE
  ./Uninstall-PromptParle.ps1
#>
[CmdletBinding()]
param(
    # Also delete saved API key config (~/.promptparle)
    [switch]$RemoveConfig
)

$ErrorActionPreference = 'Stop'

Remove-Module PromptParle -Force -ErrorAction SilentlyContinue

$candidates = @()

$docs = [Environment]::GetFolderPath('MyDocuments')
if ($docs) {
    $candidates += (Join-Path $docs 'WindowsPowerShell\Modules\PromptParle')
    $candidates += (Join-Path $docs 'PowerShell\Modules\PromptParle')
}
if ($env:USERPROFILE) {
    $candidates += (Join-Path $env:USERPROFILE 'Documents\WindowsPowerShell\Modules\PromptParle')
    $candidates += (Join-Path $env:USERPROFILE 'Documents\PowerShell\Modules\PromptParle')
}
if ($HOME) {
    $candidates += (Join-Path $HOME '.local/share/powershell/Modules/PromptParle')
}

$removed = $false
foreach ($path in ($candidates | Select-Object -Unique)) {
    if ($path -and (Test-Path -LiteralPath $path)) {
        Remove-Item -LiteralPath $path -Recurse -Force
        Write-Host "Removed $path" -ForegroundColor Green
        $removed = $true
    }
}

if (-not $removed) {
    Write-Host 'No installed PromptParle module found in standard user module paths.' -ForegroundColor Yellow
}

if ($RemoveConfig) {
    $configDirs = @()
    if ($env:PROMPTPARLE_CONFIG_DIR) { $configDirs += $env:PROMPTPARLE_CONFIG_DIR }
    if ($env:USERPROFILE) { $configDirs += (Join-Path $env:USERPROFILE '.promptparle') }
    if ($HOME) { $configDirs += (Join-Path $HOME '.promptparle') }

    foreach ($dir in ($configDirs | Select-Object -Unique)) {
        if ($dir -and (Test-Path -LiteralPath $dir)) {
            Remove-Item -LiteralPath $dir -Recurse -Force
            Write-Host "Removed config $dir" -ForegroundColor Green
        }
    }
}

Write-Host ''
Write-Host 'Uninstall complete. To reinstall:' -ForegroundColor Cyan
Write-Host '  irm https://raw.githubusercontent.com/exiled4disco/promptparle/main/powershell/Install-FromGitHub.ps1 | iex'
