# PromptParle install from GitHub — safe for:  irm <url> | iex
# No top-level param() / CmdletBinding() (Invoke-Expression cannot parse those).
# Optional session overrides before running:
#   $PromptParleClonePath = 'D:\src\promptparle'
#   $PromptParleStart = $true
#   $PromptParleSkipKeyPrompt = $true
#   $PromptParleInvitationCode = 'PP-XXXX-XXXX'   # from welcome email

$ErrorActionPreference = 'Stop'

$RepoUrl = 'https://github.com/exiled4disco/promptparle.git'
$Branch = 'main'
$ClonePath = $null
$DoStart = $false
$SkipKeyPrompt = $false
$InvitationCode = ''

if (Get-Variable -Name PromptParleClonePath -ErrorAction SilentlyContinue) {
    if ($PromptParleClonePath) { $ClonePath = [string]$PromptParleClonePath }
}
if (Get-Variable -Name PromptParleStart -ErrorAction SilentlyContinue) {
    if ($PromptParleStart) { $DoStart = $true }
}
if (Get-Variable -Name PromptParleSkipKeyPrompt -ErrorAction SilentlyContinue) {
    if ($PromptParleSkipKeyPrompt) { $SkipKeyPrompt = $true }
}
if (Get-Variable -Name PromptParleInvitationCode -ErrorAction SilentlyContinue) {
    if ($PromptParleInvitationCode) { $InvitationCode = [string]$PromptParleInvitationCode }
}

if (-not $ClonePath) {
    if ($env:USERPROFILE) {
        $ClonePath = Join-Path $env:USERPROFILE 'src\promptparle'
    } elseif ($HOME) {
        $ClonePath = Join-Path $HOME 'src/promptparle'
    } else {
        $ClonePath = Join-Path ([System.IO.Path]::GetTempPath()) 'promptparle'
    }
}

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    $gitHint = if ($env:OS -match 'Windows' -or $PSVersionTable.PSEdition -eq 'Desktop') {
        'Install Git for Windows: https://git-scm.com/download/win'
    } else {
        'Install git (e.g. sudo apt install git) or use the Linux installer: curl -fsSL https://promptparle.com/install.sh | bash'
    }
    throw "git is required. $gitHint"
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
    throw "Path exists but is not a git repo: $ClonePath (remove it or set `$PromptParleClonePath)"
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

Write-Host 'Running installer (invitation code → module → API key)...' -ForegroundColor Yellow
Write-Host 'You need the invitation code from your PromptParle welcome email.' -ForegroundColor DarkGray
$installerArgs = @{}
if ($DoStart) { $installerArgs['Start'] = $true }
if ($SkipKeyPrompt) { $installerArgs['SkipKeyPrompt'] = $true }
if ($InvitationCode) { $installerArgs['InvitationCode'] = $InvitationCode }
& $installScript @installerArgs

Write-Host ''
Write-Host "Clone location: $ClonePath" -ForegroundColor DarkGray
Write-Host 'After install, start local chat with:  pp' -ForegroundColor Cyan
Write-Host 'Local UI has an Update button for future upgrades.' -ForegroundColor DarkGray
