#Requires -Version 5.1
<#
.SYNOPSIS
  Clone (or update) the PromptParle repo and install the PowerShell module.

.DESCRIPTION
  Default source: https://github.com/exiled4disco/promptparle
  Installs into the current user's PowerShell Modules path.

.PARAMETER RepoUrl
  Git clone URL. HTTPS or SSH.

.PARAMETER Branch
  Branch to checkout. Default: main

.PARAMETER ClonePath
  Where to clone. Default: $HOME\src\promptparle (Windows) or $HOME/src/promptparle

.PARAMETER Force
  Overwrite an existing module install.

.EXAMPLE
  # One-liner after download, or from a local copy of this script:
  irm https://raw.githubusercontent.com/exiled4disco/promptparle/main/powershell/Install-FromGitHub.ps1 | iex

.EXAMPLE
  .\Install-FromGitHub.ps1 -Force
#>
[CmdletBinding()]
param(
    [string]$RepoUrl = 'https://github.com/exiled4disco/promptparle.git',

    [string]$Branch = 'main',

    [string]$ClonePath,

    [switch]$Force
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

Write-Host "PromptParle install" -ForegroundColor Cyan
Write-Host "  Repo : $RepoUrl"
Write-Host "  Path : $ClonePath"
Write-Host "  Branch: $Branch"
Write-Host ''

if (Test-Path -LiteralPath (Join-Path $ClonePath '.git')) {
    Write-Host "Updating existing clone..." -ForegroundColor Yellow
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
    Write-Host "Cloning..." -ForegroundColor Yellow
    git clone --branch $Branch --single-branch $RepoUrl $ClonePath
}

$installScript = Join-Path $ClonePath 'powershell\Install-PromptParle.ps1'
if (-not (Test-Path -LiteralPath $installScript)) {
    # Linux/mac path separators if cloned elsewhere
    $installScript = Join-Path $ClonePath 'powershell/Install-PromptParle.ps1'
}
if (-not (Test-Path -LiteralPath $installScript)) {
    throw "Install script not found under $ClonePath\powershell"
}

Write-Host "Running module installer..." -ForegroundColor Yellow
& $installScript -Force:$Force

Write-Host ''
Write-Host 'Done. Next steps:' -ForegroundColor Green
Write-Host "  1. Create a desktop API key at https://promptparle.com/app/api-keys"
Write-Host "  2. Set-PromptParleApiKey -ApiKey 'pp_live_xxxxx'"
Write-Host "  3. Get-PromptParleProvider"
Write-Host "  4. Invoke-PromptParle -Provider openai -Prompt 'Hello' -Context 'test'"
Write-Host ''
Write-Host "Clone location: $ClonePath"
Write-Host 'To update later: re-run this script, or git pull in the clone and Install-PromptParle.ps1 -Force'
