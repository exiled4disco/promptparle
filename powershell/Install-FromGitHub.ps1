#Requires -Version 5.1
<#
.SYNOPSIS
  Clone/update PromptParle from GitHub and run the full installer (includes API key prompt).

.DESCRIPTION
  Works with both:
    irm <url> | iex
    .\Install-FromGitHub.ps1
    .\Install-FromGitHub.ps1 -Start

  (Top-level param() is not valid under Invoke-Expression, so switches are
   handled via a small self-invoking scriptblock.)

.EXAMPLE
  # One-liner (Windows PowerShell 5.1 / PowerShell 7+)
  irm https://raw.githubusercontent.com/exiled4disco/promptparle/main/powershell/Install-FromGitHub.ps1 | iex

.EXAMPLE
  .\Install-FromGitHub.ps1 -Start
  .\Install-FromGitHub.ps1 -ClonePath D:\src\promptparle
#>

# iex-safe: entire installer is a scriptblock (param works inside scriptblocks).
# When this file is executed normally, we re-invoke the block with file args.
$__PromptParleFromGitHub = {
    [CmdletBinding()]
    param(
        [string]$RepoUrl = 'https://github.com/exiled4disco/promptparle.git',
        [string]$Branch = 'main',
        [string]$ClonePath,
        [switch]$Start,
        [switch]$SkipKeyPrompt
    )

    $ErrorActionPreference = 'Stop'

    function Test-CommandExists {
        param([string]$Name)
        return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
    }

    if (-not $ClonePath) {
        if ($env:USERPROFILE) {
            $ClonePath = Join-Path $env:USERPROFILE 'src\promptparle'
        } else {
            $ClonePath = Join-Path $HOME 'src/promptparle'
        }
    }

    if (-not (Test-CommandExists 'git')) {
        throw 'git is required. Install Git for Windows: https://git-scm.com/download/win'
    }

    Write-Host 'PromptParle install from GitHub' -ForegroundColor Cyan
    Write-Host "  Repo   : $RepoUrl"
    Write-Host "  Path   : $ClonePath"
    Write-Host "  Branch : $Branch"
    Write-Host ''

    if (Test-Path -LiteralPath (Join-Path $ClonePath '.git')) {
        Write-Host 'Updating existing clone...' -ForegroundColor Yellow
        Push-Location $ClonePath
        try {
            git fetch origin
            git checkout $Branch
            git pull --ff-only origin $Branch
        } finally {
            Pop-Location
        }
    } elseif (Test-Path -LiteralPath $ClonePath) {
        throw "Path exists but is not a git repo: $ClonePath (remove it or pass -ClonePath)"
    } else {
        $parent = Split-Path -Parent $ClonePath
        if ($parent -and -not (Test-Path -LiteralPath $parent)) {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }
        Write-Host 'Cloning...' -ForegroundColor Yellow
        git clone --branch $Branch --single-branch $RepoUrl $ClonePath
    }

    $installScript = Join-Path $ClonePath 'powershell\Install-PromptParle.ps1'
    if (-not (Test-Path -LiteralPath $installScript)) {
        $installScript = Join-Path $ClonePath 'powershell/Install-PromptParle.ps1'
    }
    if (-not (Test-Path -LiteralPath $installScript)) {
        throw "Install script not found under $ClonePath\powershell"
    }

    Write-Host 'Running installer (module + API key setup)...' -ForegroundColor Yellow
    $installerArgs = @{}
    if ($Start) { $installerArgs['Start'] = $true }
    if ($SkipKeyPrompt) { $installerArgs['SkipKeyPrompt'] = $true }
    & $installScript @installerArgs

    Write-Host ''
    Write-Host "Clone location: $ClonePath" -ForegroundColor DarkGray
    Write-Host 'Module version should be 0.8.0+ (compression dial + tools rail).' -ForegroundColor DarkGray
}

# --- entry points ---
# 1) irm | iex  → no bound file parameters; run defaults
# 2) .\Install-FromGitHub.ps1 -Start → $args holds unbound tokens when there is
#    no script-level param; for real -Start binding we also accept common patterns.

$__ppInvokeArgs = @{}
if ($args -and $args.Count -gt 0) {
    for ($i = 0; $i -lt $args.Count; $i++) {
        $a = [string]$args[$i]
        switch -Regex ($a) {
            '^-Start$'          { $__ppInvokeArgs['Start'] = $true }
            '^-SkipKeyPrompt$'  { $__ppInvokeArgs['SkipKeyPrompt'] = $true }
            '^-RepoUrl$'        { $__ppInvokeArgs['RepoUrl'] = [string]$args[++$i] }
            '^-Branch$'         { $__ppInvokeArgs['Branch'] = [string]$args[++$i] }
            '^-ClonePath$'      { $__ppInvokeArgs['ClonePath'] = [string]$args[++$i] }
            '^-RepoUrl=(.+)$'   { $__ppInvokeArgs['RepoUrl'] = $Matches[1] }
            '^-Branch=(.+)$'    { $__ppInvokeArgs['Branch'] = $Matches[1] }
            '^-ClonePath=(.+)$' { $__ppInvokeArgs['ClonePath'] = $Matches[1] }
        }
    }
}

# Optional session overrides (set before irm|iex)
if (Get-Variable -Name PromptParleClonePath -Scope Global -ErrorAction SilentlyContinue) {
    if ($global:PromptParleClonePath) { $__ppInvokeArgs['ClonePath'] = [string]$global:PromptParleClonePath }
}
if (Get-Variable -Name PromptParleStart -Scope Global -ErrorAction SilentlyContinue) {
    if ($global:PromptParleStart) { $__ppInvokeArgs['Start'] = $true }
}

& $__PromptParleFromGitHub @__ppInvokeArgs
