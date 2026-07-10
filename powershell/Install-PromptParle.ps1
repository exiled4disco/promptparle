#Requires -Version 5.1
<#
.SYNOPSIS
  Install PromptParle and finish setup (including API key).

.DESCRIPTION
  1) Copies the module into your user Modules path
  2) Imports it
  3) Prompts for a desktop API key if missing/invalid
  4) Verifies the key against the API
  5) Optionally starts local chat (pp)

.EXAMPLE
  .\Install-PromptParle.ps1
  .\Install-PromptParle.ps1 -SkipKeyPrompt
  .\Install-PromptParle.ps1 -Start
#>
[CmdletBinding()]
param(
    [switch]$Force,
    [switch]$NoForce,
    # Do not ask for API key (automation)
    [switch]$SkipKeyPrompt,
    # Start local chat after a successful key check
    [switch]$Start
)

$ErrorActionPreference = 'Stop'

function Write-Step {
    param([string]$Message, [string]$Color = 'Cyan')
    Write-Host ''
    Write-Host $Message -ForegroundColor $Color
}

function Read-PlainFromSecure {
    param([System.Security.SecureString]$Secure)
    if (-not $Secure) { return $null }
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    } finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
}

function Test-PromptParleKeyWorks {
    try {
        $null = Get-PromptParleProvider -ErrorAction Stop
        return $true
    } catch {
        return $false
    }
}

function Request-PromptParleApiKeyInteractive {
    Write-Step 'Desktop API key setup' 'Cyan'
    Write-Host 'The local app needs a desktop key from your PromptParle account.'
    Write-Host '  Portal: https://promptparle.com/app/api-keys'
    Write-Host ''
    Write-Host '  [1] I have a key - paste it now'
    Write-Host '  [2] Open the portal so I can create a key, then paste it'
    Write-Host '  [3] Skip for now (you can run Set-PromptParleApiKey later)'
    Write-Host ''

    $choice = Read-Host 'Choose 1, 2, or 3'
    if (-not $choice) { $choice = '1' }
    $choice = $choice.Trim()

    if ($choice -eq '3' -or $choice -match '^[sS]') {
        Write-Host 'Skipped API key. Run later:' -ForegroundColor Yellow
        Write-Host '  Set-PromptParleApiKey -ApiKey pp_live_YOUR_KEY'
        return $false
    }

    if ($choice -eq '2' -or $choice -match '^[oO]') {
        $url = 'https://promptparle.com/app/api-keys'
        Write-Host "Opening $url ..." -ForegroundColor DarkGray
        try {
            if ($env:OS -match 'Windows' -or $PSVersionTable.PSEdition -eq 'Desktop') {
                Start-Process $url
            } elseif (Get-Command xdg-open -ErrorAction SilentlyContinue) {
                Start-Process xdg-open $url
            } elseif (Get-Command open -ErrorAction SilentlyContinue) {
                Start-Process open $url
            } else {
                Write-Host "Open this URL: $url" -ForegroundColor Yellow
            }
        } catch {
            Write-Host "Open this URL: $url" -ForegroundColor Yellow
        }
        Write-Host ''
        Write-Host 'Create a key, copy the full pp_live_ value (shown once), then come back here.' -ForegroundColor Yellow
        Write-Host ''
    }

    $attempts = 0
    while ($attempts -lt 3) {
        $attempts++
        Write-Host ''
        Write-Host 'Paste your desktop API key (pp_live_...). Input is hidden.' -ForegroundColor Cyan
        $secure = Read-Host 'API key' -AsSecureString
        $plain = Read-PlainFromSecure -Secure $secure
        if (-not $plain) {
            Write-Host 'No key entered.' -ForegroundColor Yellow
            continue
        }
        $plain = $plain.Trim()
        # strip accidental quotes users paste from docs
        if (($plain.StartsWith("'") -and $plain.EndsWith("'")) -or ($plain.StartsWith('"') -and $plain.EndsWith('"'))) {
            $plain = $plain.Substring(1, $plain.Length - 2).Trim()
        }

        if ($plain -notmatch '^pp_live_[a-zA-Z0-9]{16,}') {
            Write-Host 'That does not look like a full pp_live_ key.' -ForegroundColor Red
            Write-Host 'Create one at https://promptparle.com/app/api-keys and paste the whole value.' -ForegroundColor Yellow
            continue
        }

        try {
            Set-PromptParleApiKey -ApiKey $plain | Out-Null
        } catch {
            Write-Host "Could not save key: $_" -ForegroundColor Red
            continue
        }

        Write-Host 'Checking key with PromptParle...' -ForegroundColor DarkGray
        if (Test-PromptParleKeyWorks) {
            Write-Host 'API key OK.' -ForegroundColor Green
            Get-PromptParleConfig | Format-List BaseUrl, ApiKey, HasApiKey | Out-String | Write-Host
            return $true
        }

        Write-Host 'Key saved but the server returned unauthorized (401).' -ForegroundColor Red
        Write-Host 'Usually: wrong key, revoked key, or incomplete paste.' -ForegroundColor Yellow
        Write-Host 'Create a NEW key in the portal and try again.' -ForegroundColor Yellow
    }

    Write-Host 'Gave up on API key for now. Fix later with Set-PromptParleApiKey.' -ForegroundColor Yellow
    return $false
}

# --- install module files ---
$source = Join-Path $PSScriptRoot 'PromptParle'
if (-not (Test-Path -LiteralPath (Join-Path $source 'PromptParle.psd1'))) {
    throw "Module source not found at $source"
}

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

Write-Step 'Installing PromptParle module...' 'Cyan'

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
if (-not $loaded) {
    throw 'Module installed but failed to import. Check errors above.'
}
Write-Host ("Imported PromptParle {0}" -f $loaded.Version) -ForegroundColor Green

# --- API key finish ---
$keyOk = $false
if (-not $SkipKeyPrompt) {
    $cfg = Get-PromptParleConfig
    if ($cfg.HasApiKey) {
        Write-Host ''
        Write-Host 'Existing API key found. Verifying...' -ForegroundColor DarkGray
        if (Test-PromptParleKeyWorks) {
            Write-Host 'Existing API key works.' -ForegroundColor Green
            $keyOk = $true
        } else {
            Write-Host 'Existing API key is missing, revoked, or invalid.' -ForegroundColor Yellow
            $keyOk = Request-PromptParleApiKeyInteractive
        }
    } else {
        $keyOk = Request-PromptParleApiKeyInteractive
    }
} else {
    Write-Host 'Skipped API key prompt (-SkipKeyPrompt).' -ForegroundColor DarkGray
    $keyOk = Test-PromptParleKeyWorks
}

Write-Step 'Install finished' 'Green'
Write-Host ("  Module  : {0}" -f $loaded.Version)
Write-Host ("  Path    : {0}" -f $dest)
Write-Host ("  API key : {0}" -f $(if ($keyOk) { 'OK' } else { 'not configured / failed' }))
Write-Host ''
Write-Host 'Commands:' -ForegroundColor Cyan
Write-Host '  pp                          Start local chat (http://127.0.0.1:7788)'
Write-Host '  Stop-PromptParleLocalServer Stop local chat'
Write-Host '  Get-PromptParleProvider     List AI providers'
Write-Host '  Get-PromptParleUsage        Token savings'
Write-Host ''

if ($keyOk) {
    $doStart = $Start
    if (-not $Start -and -not $SkipKeyPrompt) {
        $ans = Read-Host 'Start local chat now? [Y/n]'
        if (-not $ans -or $ans -match '^[yY]') { $doStart = $true }
    }
    if ($doStart) {
        Write-Host 'Starting local PromptParle...' -ForegroundColor Cyan
        Write-Host '(Stop with Ctrl+C, browser Stop server, or Stop-PromptParleLocalServer)' -ForegroundColor DarkGray
        Start-PromptParle
    } else {
        Write-Host 'When ready:  pp' -ForegroundColor Cyan
    }
} else {
    Write-Host 'Next: create a key at https://promptparle.com/app/api-keys' -ForegroundColor Yellow
    Write-Host 'Then: Set-PromptParleApiKey -ApiKey pp_live_YOUR_KEY' -ForegroundColor Yellow
    Write-Host 'Then: pp' -ForegroundColor Yellow
}
