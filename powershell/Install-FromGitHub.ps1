#Requires -Version 5.1
<#
.SYNOPSIS
  Clone/update PromptParle from GitHub and run the full installer (includes API key prompt).

.EXAMPLE
  irm https://raw.githubusercontent.com/exiled4disco/promptparle/main/powershell/Install-FromGitHub.ps1 | iex
  .\Install-FromGitHub.ps1
  .\Install-FromGitHub.ps1 -Start
#>
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
$args = @{}
if ($Start) { $args.Start = $true }
if ($SkipKeyPrompt) { $args.SkipKeyPrompt = $true }
& $installScript @args

Write-Host ''
Write-Host "Clone location: $ClonePath" -ForegroundColor DarkGray
