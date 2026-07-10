#Requires -Version 5.1
<#
.SYNOPSIS
  Simple PromptParle uninstaller.

.DESCRIPTION
  Stops local chat server, removes the PowerShell module, optionally
  removes saved API key config and/or the git clone.

.EXAMPLE
  .\Uninstall-PromptParle.ps1
  .\Uninstall-PromptParle.ps1 -RemoveConfig
  .\Uninstall-PromptParle.ps1 -RemoveConfig -RemoveClone
#>
[CmdletBinding()]
param(
    # Delete saved API key (~/.promptparle)
    [switch]$RemoveConfig,
    # Delete git clone (default %USERPROFILE%\src\promptparle)
    [switch]$RemoveClone,
    [string]$ClonePath
)

$ErrorActionPreference = 'Stop'

Write-Host ''
Write-Host 'PromptParle uninstaller' -ForegroundColor Cyan
Write-Host ''

# Prefer module cmdlet if available
$modPath = $null
$docs = [Environment]::GetFolderPath('MyDocuments')
$search = @()
if ($docs) {
    $search += (Join-Path $docs 'WindowsPowerShell\Modules\PromptParle\PromptParle.psd1')
    $search += (Join-Path $docs 'PowerShell\Modules\PromptParle\PromptParle.psd1')
}
if ($env:USERPROFILE) {
    $search += (Join-Path $env:USERPROFILE 'Documents\WindowsPowerShell\Modules\PromptParle\PromptParle.psd1')
    $search += (Join-Path $env:USERPROFILE 'Documents\PowerShell\Modules\PromptParle\PromptParle.psd1')
}
# Also from this repo checkout
if ($PSScriptRoot) {
    $search += (Join-Path $PSScriptRoot 'PromptParle\PromptParle.psd1')
}

foreach ($p in $search) {
    if ($p -and (Test-Path -LiteralPath $p)) { $modPath = $p; break }
}

if ($modPath) {
    try {
        Import-Module $modPath -Force -ErrorAction Stop
        $params = @{}
        if ($RemoveConfig) { $params.RemoveConfig = $true }
        if ($RemoveClone) { $params.RemoveClone = $true }
        if ($ClonePath) { $params.ClonePath = $ClonePath }
        Uninstall-PromptParle @params -Confirm:$false
        return
    } catch {
        Write-Host "Module uninstall cmdlet failed, using script fallback: $_" -ForegroundColor Yellow
    }
}

# Fallback without module
Write-Host 'Stopping local servers (ports 7788-7798)...' -ForegroundColor DarkGray
foreach ($port in 7788..7798) {
    try {
        if ($PSVersionTable.PSVersion.Major -le 5) {
            Invoke-WebRequest -Uri "http://127.0.0.1:$port/api/stop" -Method POST -UseBasicParsing -TimeoutSec 1 | Out-Null
        } else {
            Invoke-WebRequest -Uri "http://127.0.0.1:$port/api/stop" -Method POST -TimeoutSec 1 | Out-Null
        }
    } catch { }
    try {
        if (Get-Command Get-NetTCPConnection -ErrorAction SilentlyContinue) {
            $conns = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue
            foreach ($c in @($conns)) {
                $procId = [int]$c.OwningProcess
                if ($procId -gt 0 -and $procId -ne $PID) {
                    $proc = Get-Process -Id $procId -ErrorAction SilentlyContinue
                    if ($proc -and $proc.ProcessName -match '^(powershell|pwsh)$') {
                        Stop-Process -Id $procId -Force -ErrorAction SilentlyContinue
                        Write-Host "Stopped PID $procId on port $port" -ForegroundColor Yellow
                    }
                }
            }
        }
    } catch { }
}

Remove-Module PromptParle -Force -ErrorAction SilentlyContinue

$candidates = @()
if ($docs) {
    $candidates += (Join-Path $docs 'WindowsPowerShell\Modules\PromptParle')
    $candidates += (Join-Path $docs 'PowerShell\Modules\PromptParle')
}
if ($env:USERPROFILE) {
    $candidates += (Join-Path $env:USERPROFILE 'Documents\WindowsPowerShell\Modules\PromptParle')
    $candidates += (Join-Path $env:USERPROFILE 'Documents\PowerShell\Modules\PromptParle')
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
    Write-Host 'No installed module folder found.' -ForegroundColor Yellow
}

if ($RemoveConfig) {
    $dirs = @()
    if ($env:USERPROFILE) { $dirs += (Join-Path $env:USERPROFILE '.promptparle') }
    if ($HOME) { $dirs += (Join-Path $HOME '.promptparle') }
    foreach ($dir in ($dirs | Select-Object -Unique)) {
        if (Test-Path -LiteralPath $dir) {
            Remove-Item -LiteralPath $dir -Recurse -Force
            Write-Host "Removed config $dir" -ForegroundColor Green
        }
    }
}

if ($RemoveClone) {
    if (-not $ClonePath) {
        if ($env:USERPROFILE) { $ClonePath = Join-Path $env:USERPROFILE 'src\promptparle' }
        else { $ClonePath = Join-Path $HOME 'src/promptparle' }
    }
    if (Test-Path -LiteralPath $ClonePath) {
        Remove-Item -LiteralPath $ClonePath -Recurse -Force
        Write-Host "Removed clone $ClonePath" -ForegroundColor Green
    }
}

Write-Host ''
Write-Host 'Uninstall complete.' -ForegroundColor Green
Write-Host 'Reinstall:' -ForegroundColor Cyan
Write-Host '  irm https://raw.githubusercontent.com/exiled4disco/promptparle/main/powershell/Install-FromGitHub.ps1 | iex'
Write-Host ''
