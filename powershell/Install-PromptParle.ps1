#Requires -Version 5.1
<#
.SYNOPSIS
  Install PromptParle with invitation-code onboarding, then API key finish.

.DESCRIPTION
  1) Invitation code (one-time from welcome email)
  2) Copies the module into your user Modules path
  3) Portal setup guidance (Providers + desktop API key)
  4) Prompts for pp_live_ desktop key and verifies it
  5) Marks invitation redeemed; optionally starts local chat

.EXAMPLE
  .\Install-PromptParle.ps1
  .\Install-PromptParle.ps1 -InvitationCode 'PP-AB12-CD34'
  .\Install-PromptParle.ps1 -SkipKeyPrompt
  .\Install-PromptParle.ps1 -Start
#>
[CmdletBinding()]
param(
    [switch]$Force,
    [switch]$NoForce,
    [string]$InvitationCode = '',
    [string]$BaseUrl = 'https://promptparle.com',
    # Do not ask for API key (automation)
    [switch]$SkipKeyPrompt,
    # Skip invitation code prompt (not recommended for new customers)
    [switch]$SkipInvitePrompt,
    # Start local chat after a successful key check
    [switch]$Start
)

$ErrorActionPreference = 'Stop'
$BaseUrl = $BaseUrl.TrimEnd('/')

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

function Invoke-PromptParleInviteValidate {
    param([Parameter(Mandatory)][string]$Code)
    $url = "$BaseUrl/api/v1/invite/validate?code=$([uri]::EscapeDataString($Code))"
    try {
        if ($PSVersionTable.PSVersion.Major -le 5) {
            $resp = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 30
            return ($resp.Content | ConvertFrom-Json)
        }
        return Invoke-RestMethod -Uri $url -Method GET -TimeoutSec 30
    } catch {
        $msg = "$_"
        try {
            if ($_.Exception.Response) {
                $sr = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
                $body = $sr.ReadToEnd()
                $j = $body | ConvertFrom-Json
                if ($j.error) { return [pscustomobject]@{ ok = $false; error = [string]$j.error } }
            }
        } catch { }
        return [pscustomobject]@{ ok = $false; error = $msg }
    }
}

function Request-PromptParleInvitationCode {
    Write-Step 'Step 1: Invitation code' 'Cyan'
    Write-Host 'Your welcome email from PromptParle includes a one-time code like PP-XXXX-XXXX.'
    Write-Host 'If you have not completed the portal invite form yet, do that first (link in the first email).'
    Write-Host ''

    $code = $InvitationCode
    $attempts = 0
    while ($attempts -lt 5) {
        $attempts++
        if (-not $code) {
            $code = Read-Host 'Invitation code'
        }
        if (-not $code) {
            Write-Host 'Code is required to continue install.' -ForegroundColor Yellow
            continue
        }
        $code = $code.Trim().ToUpperInvariant()
        Write-Host "Checking code against $BaseUrl ..." -ForegroundColor DarkGray
        $result = Invoke-PromptParleInviteValidate -Code $code
        if (-not $result -or -not $result.ok) {
            $err = if ($result -and $result.error) { [string]$result.error } else { 'Validation failed' }
            Write-Host "  $err" -ForegroundColor Red
            $code = ''
            continue
        }

        $status = [string]$result.status
        Write-Host ("  Code OK for {0} (status: {1})" -f $result.email_masked, $status) -ForegroundColor Green
        Write-Host ''
        Write-Host 'Next steps from the portal:' -ForegroundColor Yellow
        foreach ($s in @($result.steps)) {
            Write-Host ("  • {0}" -f $s)
        }
        Write-Host ''

        if ($status -eq 'pending') {
            Write-Host 'Your invite is not finished on the portal yet.' -ForegroundColor Yellow
            Write-Host 'Open the invitation link from email, create your password, then re-run this installer.' -ForegroundColor Yellow
            $open = Read-Host 'Open portal now? [Y/n]'
            if (-not $open -or $open -match '^[yY]') {
                Start-Process-PromptParleUrl -Url $BaseUrl
            }
            throw 'Finish the invitation form on the portal, then re-run Install-PromptParle.ps1 with your code.'
        }

        return $code
    }
    throw 'Could not validate invitation code. Check the code from your welcome email and try again.'
}

function Start-Process-PromptParleUrl {
    param([string]$Url)
    try {
        if ($env:OS -match 'Windows' -or $PSVersionTable.PSEdition -eq 'Desktop') {
            Start-Process $Url
        } elseif (Get-Command xdg-open -ErrorAction SilentlyContinue) {
            Start-Process xdg-open $Url
        } elseif (Get-Command open -ErrorAction SilentlyContinue) {
            Start-Process open $Url
        } else {
            Write-Host "Open this URL: $Url" -ForegroundColor Yellow
        }
    } catch {
        Write-Host "Open this URL: $Url" -ForegroundColor Yellow
    }
}

function Request-PromptParleApiKeyInteractive {
    param([string]$InviteCode)

    Write-Step 'Step 3: Desktop API key' 'Cyan'
    Write-Host 'The local app needs a desktop key from your PromptParle account.'
    Write-Host '  Portal: https://promptparle.com/app/api-keys'
    Write-Host ''
    Write-Host 'Before pasting a key, finish portal setup:'
    Write-Host '  1) Sign in at https://promptparle.com/login'
    Write-Host '  2) API Keys → Create → copy the full pp_live_… value (shown once)'
    Write-Host '  3) After install: run pp → ⋯ → Providers to save OpenAI/Claude/Gemini/Grok'
    Write-Host '     keys on this PC (not in the portal). Or: Set-PromptParleProviderKey'
    Write-Host ''
    Write-Host '  [1] I have a pp_live_ key - paste it now'
    Write-Host '  [2] Open the portal so I can create a license key, then paste it'
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
        Start-Process-PromptParleUrl -Url $url
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
            if ($InviteCode) {
                try {
                    $redeemUrl = "$BaseUrl/api/v1/invite/redeem"
                    $body = @{ code = $InviteCode } | ConvertTo-Json -Compress
                    $headers = @{
                        Authorization  = "Bearer $plain"
                        'Content-Type' = 'application/json'
                    }
                    if ($PSVersionTable.PSVersion.Major -le 5) {
                        Invoke-WebRequest -Uri $redeemUrl -Method POST -Headers $headers -Body $body -UseBasicParsing -TimeoutSec 20 | Out-Null
                    } else {
                        Invoke-RestMethod -Uri $redeemUrl -Method POST -Headers $headers -Body $body -TimeoutSec 20 | Out-Null
                    }
                    Write-Host 'Invitation marked complete.' -ForegroundColor DarkGray
                } catch {
                    Write-Host "Note: could not mark invitation redeemed (install still OK): $_" -ForegroundColor DarkGray
                }
            }
            return $true
        }

        Write-Host 'Key saved but the server returned unauthorized (401).' -ForegroundColor Red
        Write-Host 'Usually: wrong key, revoked key, or incomplete paste.' -ForegroundColor Yellow
        Write-Host 'Create a NEW key in the portal and try again.' -ForegroundColor Yellow
    }

    Write-Host 'Gave up on API key for now. Fix later with Set-PromptParleApiKey.' -ForegroundColor Yellow
    return $false
}

# --- Invitation gate (before module install so bad codes fail fast) ---
$script:PromptParleInstallInviteCode = $null
if (-not $SkipInvitePrompt) {
    $script:PromptParleInstallInviteCode = Request-PromptParleInvitationCode
} else {
    Write-Host 'Skipped invitation code (-SkipInvitePrompt).' -ForegroundColor DarkGray
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

# Module install path: Windows Documents\… or Linux/macOS XDG Modules dir
$isWin = $false
if ($env:OS -match 'Windows' -or $PSVersionTable.PSEdition -eq 'Desktop') {
    $isWin = $true
} elseif (Get-Variable -Name IsWindows -Scope Global -ErrorAction SilentlyContinue) {
    $isWin = [bool]$IsWindows
}

if (-not $isWin) {
    # PowerShell 7 on Linux/macOS
    $userModules = Join-Path $HOME '.local/share/powershell/Modules'
} elseif ($PSVersionTable.PSEdition -eq 'Core') {
    $userModules = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'PowerShell\Modules'
} else {
    $userModules = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'WindowsPowerShell\Modules'
}

$docs = [Environment]::GetFolderPath('MyDocuments')
if ($isWin -and (-not $docs -or -not (Test-Path -LiteralPath $docs))) {
    $userModules = Join-Path $HOME '.local/share/powershell/Modules'
}

$dest = Join-Path $userModules 'PromptParle'
$shouldInstall = $true

if ((Test-Path -LiteralPath $dest) -and $NoForce -and -not $Force) {
    Write-Host "Module already exists at $dest (omit -NoForce to overwrite)" -ForegroundColor Yellow
    $shouldInstall = $false
}

Write-Step 'Step 2: Installing PromptParle module...' 'Cyan'

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
            if ($script:PromptParleInstallInviteCode) {
                try {
                    $plain = $cfg.ApiKey
                    $redeemUrl = "$BaseUrl/api/v1/invite/redeem"
                    $body = @{ code = $script:PromptParleInstallInviteCode } | ConvertTo-Json -Compress
                    $headers = @{
                        Authorization  = "Bearer $plain"
                        'Content-Type' = 'application/json'
                    }
                    if ($PSVersionTable.PSVersion.Major -le 5) {
                        Invoke-WebRequest -Uri $redeemUrl -Method POST -Headers $headers -Body $body -UseBasicParsing -TimeoutSec 20 | Out-Null
                    } else {
                        Invoke-RestMethod -Uri $redeemUrl -Method POST -Headers $headers -Body $body -TimeoutSec 20 | Out-Null
                    }
                } catch { }
            }
        } else {
            Write-Host 'Existing API key is missing, revoked, or invalid.' -ForegroundColor Yellow
            $keyOk = Request-PromptParleApiKeyInteractive -InviteCode $script:PromptParleInstallInviteCode
        }
    } else {
        $keyOk = Request-PromptParleApiKeyInteractive -InviteCode $script:PromptParleInstallInviteCode
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
Write-Host '  pp                              Start local chat'
Write-Host '  Stop-PromptParleLocalServer     Stop local chat (frees port)'
Write-Host '  Uninstall-PromptParle           Remove module from this PC'
Write-Host '  Set-PromptParleApiKey           Save desktop API key'
Write-Host ''

if ($keyOk) {
    $doStart = $Start
    if (-not $Start -and -not $SkipKeyPrompt) {
        $ans = Read-Host 'Start local chat now? [Y/n]'
        if (-not $ans -or $ans -match '^[yY]') { $doStart = $true }
    }
    if ($doStart) {
        Write-Host 'Starting local PromptParle...' -ForegroundColor Cyan
        Start-PromptParle
    } else {
        Write-Host 'When ready:  pp' -ForegroundColor Cyan
    }
} else {
    Write-Host 'Next: portal API Keys → create pp_live_…, then Set-PromptParleApiKey. After pp starts, set model keys: ⋯ → Providers or Set-PromptParleProviderKey.' -ForegroundColor Yellow
}
