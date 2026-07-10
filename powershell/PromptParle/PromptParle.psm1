#Requires -Version 5.1
<#
.SYNOPSIS
  PromptParle PowerShell module — AI context optimization gateway client.

.DESCRIPTION
  Send prompts through PromptParle for optimization and provider routing.
  Configure once with Set-PromptParleApiKey, then use Invoke-PromptParle.

  Docs: https://promptparle.com
#>

Set-StrictMode -Version Latest

# PS 5.1 has no automatic $IsWindows / $IsLinux / $IsMacOS (added in PowerShell 6+)
# StrictMode treats reading an unset automatic variable as a terminating error.
$script:PromptParleIsWindows = $false
if ($PSVersionTable.PSEdition -eq 'Desktop') {
    $script:PromptParleIsWindows = $true
} elseif ($env:OS -match 'Windows') {
    $script:PromptParleIsWindows = $true
} elseif (Get-Variable -Name IsWindows -Scope Global -ErrorAction SilentlyContinue) {
    $script:PromptParleIsWindows = [bool]$IsWindows
}

$script:PromptParleConfigDir = if ($env:PROMPTPARLE_CONFIG_DIR) {
    $env:PROMPTPARLE_CONFIG_DIR
} elseif ($script:PromptParleIsWindows) {
    Join-Path $env:USERPROFILE '.promptparle'
} else {
    Join-Path $HOME '.promptparle'
}
$script:PromptParleConfigPath = Join-Path $script:PromptParleConfigDir 'config.json'
$script:DefaultBaseUrl = 'https://promptparle.com'

#region Private helpers

function Get-PromptParleConfigInternal {
    [CmdletBinding()]
    param()

    $config = [ordered]@{
        ApiKey  = $null
        BaseUrl = $script:DefaultBaseUrl
    }

    if (Test-Path -LiteralPath $script:PromptParleConfigPath) {
        try {
            $raw = Get-Content -LiteralPath $script:PromptParleConfigPath -Raw -ErrorAction Stop
            $json = $raw | ConvertFrom-Json
            if ($json.ApiKey)  { $config.ApiKey  = [string]$json.ApiKey }
            if ($json.BaseUrl) { $config.BaseUrl = [string]$json.BaseUrl.TrimEnd('/') }
        } catch {
            Write-Warning "Could not read PromptParle config at $($script:PromptParleConfigPath): $_"
        }
    }

    if ($env:PROMPTPARLE_API_KEY) {
        $config.ApiKey = $env:PROMPTPARLE_API_KEY
    }
    if ($env:PROMPTPARLE_BASE_URL) {
        $config.BaseUrl = $env:PROMPTPARLE_BASE_URL.TrimEnd('/')
    }

    return [pscustomobject]$config
}

function Save-PromptParleConfigInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ApiKey,

        [string]$BaseUrl = $script:DefaultBaseUrl
    )

    if (-not (Test-Path -LiteralPath $script:PromptParleConfigDir)) {
        New-Item -ItemType Directory -Path $script:PromptParleConfigDir -Force | Out-Null
    }

    $obj = [ordered]@{
        ApiKey    = $ApiKey
        BaseUrl   = $BaseUrl.TrimEnd('/')
        UpdatedAt = (Get-Date).ToUniversalTime().ToString('o')
    }

    $obj | ConvertTo-Json | Set-Content -LiteralPath $script:PromptParleConfigPath -Encoding UTF8

    # Restrict permissions on Unix-like systems
    if (-not $script:PromptParleIsWindows) {
        try { chmod 600 $script:PromptParleConfigPath 2>$null } catch { }
    }
}

function Invoke-PromptParleApi {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('GET', 'POST')]
        [string]$Method,

        [Parameter(Mandatory)]
        [string]$Path,

        [object]$Body
    )

    $config = Get-PromptParleConfigInternal
    if (-not $config.ApiKey) {
        throw "PromptParle API key not set. Run Set-PromptParleApiKey -ApiKey 'pp_live_...' first."
    }
    if ($config.ApiKey -notmatch '^pp_live_') {
        throw "API key should start with 'pp_live_'. Create one at $($config.BaseUrl)/app/api-keys"
    }

    $uri = "$($config.BaseUrl)$Path"
    $headers = @{
        Authorization  = "Bearer $($config.ApiKey)"
        Accept         = 'application/json'
        'User-Agent'   = 'PromptParle-PowerShell/0.1'
    }

    $params = @{
        Method      = $Method
        Uri         = $uri
        Headers     = $headers
        ContentType = 'application/json; charset=utf-8'
    }

    if ($PSBoundParameters.ContainsKey('Body') -and $null -ne $Body) {
        $params.Body = ($Body | ConvertTo-Json -Depth 10 -Compress)
    }

    try {
        # PS 5.1 vs 7: use -UseBasicParsing on Windows PowerShell for web requests
        if ($PSVersionTable.PSVersion.Major -le 5) {
            $params.UseBasicParsing = $true
        }
        $response = Invoke-RestMethod @params
        return $response
    } catch {
        $message = $_.Exception.Message
        $detail = $null
        if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
            try {
                $errObj = $_.ErrorDetails.Message | ConvertFrom-Json
                if ($errObj.error) { $detail = [string]$errObj.error }
            } catch {
                $detail = $_.ErrorDetails.Message
            }
        }
        if ($detail) {
            throw "PromptParle API error: $detail"
        }
        throw "PromptParle API request failed: $message"
    }
}

function Write-PromptParleMetadata {
    param([object]$Metadata)

    if (-not $Metadata) { return }

    $orig = $Metadata.original_tokens
    $opt  = $Metadata.optimized_tokens
    $pct  = $Metadata.token_reduction_percent
    $prov = $Metadata.provider
    $model = $Metadata.model
    $prof = $Metadata.optimization_profile
    $expanded = $false
    if ($null -ne $Metadata.expanded) { $expanded = [bool]$Metadata.expanded }
    elseif ($null -ne $orig -and $null -ne $opt -and $opt -gt $orig) { $expanded = $true }

    Write-Host ''
    Write-Host '  --- PromptParle ---' -ForegroundColor DarkCyan
    if ($null -ne $orig)  { Write-Host ("  Original tokens : {0}" -f $orig) }
    if ($null -ne $opt)   { Write-Host ("  Optimized tokens: {0}" -f $opt) }
    if ($expanded) {
        Write-Host '  Size            : expanded (no savings on this message)' -ForegroundColor Yellow
    } elseif ($null -ne $pct -and $pct -gt 0) {
        Write-Host ("  Reduction       : {0}%" -f $pct) -ForegroundColor Green
    } elseif ($null -ne $pct) {
        Write-Host '  Reduction       : 0% (already compact)'
    }
    if ($prov)            { Write-Host ("  Provider        : {0}" -f $prov) }
    if ($model)           { Write-Host ("  Model           : {0}" -f $model) }
    if ($prof)            { Write-Host ("  Profile         : {0}" -f $prof) }
    if ($Metadata.secrets_masked) {
        Write-Host '  Secrets masked  : yes' -ForegroundColor Yellow
    }
    Write-Host ''
}

function Read-PromptParleLine {
    param(
        [string]$PromptText = 'you> ',
        [ConsoleColor]$Color = 'Green'
    )
    Write-Host $PromptText -ForegroundColor $Color -NoNewline
    return [Console]::ReadLine()
}

function Select-PromptParleProviderInteractive {
    param(
        [object[]]$Providers,
        [string]$Preferred
    )

    $configured = @($Providers | Where-Object { $_.Configured })
    if ($configured.Count -eq 0) {
        Write-Host ''
        Write-Host 'No AI providers configured yet.' -ForegroundColor Yellow
        Write-Host 'Add a key at https://promptparle.com/app/providers' -ForegroundColor Yellow
        Write-Host 'Then run: Start-PromptParle' -ForegroundColor Cyan
        return $null
    }

    if ($Preferred) {
        $match = $configured | Where-Object { $_.Id -eq $Preferred } | Select-Object -First 1
        if ($match) { return $match }
        Write-Host "Preferred provider '$Preferred' is not configured." -ForegroundColor Yellow
    }

    if ($configured.Count -eq 1) {
        Write-Host ("Using {0} ({1})" -f $configured[0].Name, $configured[0].Id) -ForegroundColor Cyan
        return $configured[0]
    }

    Write-Host ''
    Write-Host 'Which AI do you want to use?' -ForegroundColor Cyan
    Write-Host ''
    for ($i = 0; $i -lt $configured.Count; $i++) {
        $p = $configured[$i]
        Write-Host ("  [{0}] {1}" -f ($i + 1), $p.Name) -ForegroundColor White
        Write-Host ("      id: {0}  default model: {1}" -f $p.Id, $p.DefaultModel) -ForegroundColor DarkGray
    }
    Write-Host ''

    while ($true) {
        $choice = Read-PromptParleLine -PromptText 'provider # (or name)> ' -Color Yellow
        if ($null -eq $choice) { return $null }
        $choice = $choice.Trim()
        if (-not $choice) { continue }

        $num = 0
        if ([int]::TryParse($choice, [ref]$num)) {
            if ($num -ge 1 -and $num -le $configured.Count) {
                return $configured[$num - 1]
            }
        }

        $byId = $configured | Where-Object {
            $_.Id -eq $choice.ToLower() -or $_.Name -like "*$choice*"
        } | Select-Object -First 1
        if ($byId) { return $byId }

        Write-Host 'Pick a number from the list, or type openai / anthropic / gemini / grok' -ForegroundColor Yellow
    }
}

function Show-PromptParleSessionHelp {
    Write-Host ''
    Write-Host 'Commands (type these instead of a normal message):' -ForegroundColor Cyan
    Write-Host '  /help              Show this help'
    Write-Host '  /provider          Switch AI provider'
    Write-Host '  /profile           Change optimization profile'
    Write-Host '  /model <name>      Set model (blank = provider default)'
    Write-Host '  /context           Paste multi-line context (end with a line: EOF)'
    Write-Host '  /file <path>       Load a file as context'
    Write-Host '  /clearcontext      Clear attached context'
    Write-Host '  /optimize          Optimize-only next message (no AI spend)'
    Write-Host '  /usage             Show token savings'
    Write-Host '  /status            Show session settings'
    Write-Host '  /clear             Clear the screen'
    Write-Host '  /quit  or  /exit   Leave PromptParle'
    Write-Host ''
    Write-Host 'Otherwise just type normally and press Enter.' -ForegroundColor DarkGray
    Write-Host ''
}

#endregion

#region Public commands

function Set-PromptParleApiKey {
    <#
    .SYNOPSIS
      Store your PromptParle desktop API key for this user.

    .PARAMETER ApiKey
      Key from https://promptparle.com/app/api-keys (pp_live_...).

    .PARAMETER BaseUrl
      API base URL. Default: https://promptparle.com

    .PARAMETER PassThru
      Return the saved config object (API key masked).

    .EXAMPLE
      Set-PromptParleApiKey -ApiKey 'pp_live_xxxxx'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$ApiKey,

        [string]$BaseUrl = $script:DefaultBaseUrl,

        [switch]$PassThru
    )

    $ApiKey = $ApiKey.Trim()
    if ($ApiKey -notmatch '^pp_live_') {
        throw "API key should start with 'pp_live_'. Generate one in the PromptParle portal."
    }

    Save-PromptParleConfigInternal -ApiKey $ApiKey -BaseUrl $BaseUrl
    Write-Host "PromptParle API key saved to $($script:PromptParleConfigPath)" -ForegroundColor Green

    if ($PassThru) {
        Get-PromptParleConfig
    }
}

function Get-PromptParleConfig {
    <#
    .SYNOPSIS
      Show current PromptParle client configuration (API key masked).
    #>
    [CmdletBinding()]
    param()

    $c = Get-PromptParleConfigInternal
    $masked = if ($c.ApiKey -and $c.ApiKey.Length -gt 12) {
        $c.ApiKey.Substring(0, 12) + '…' + $c.ApiKey.Substring($c.ApiKey.Length - 4)
    } elseif ($c.ApiKey) {
        '****'
    } else {
        '(not set)'
    }

    [pscustomobject]@{
        BaseUrl    = $c.BaseUrl
        ApiKey     = $masked
        ConfigPath = $script:PromptParleConfigPath
        HasApiKey  = [bool]$c.ApiKey
    }
}

function Get-PromptParleProvider {
    <#
    .SYNOPSIS
      List AI providers available to your account and which keys are configured.

    .EXAMPLE
      Get-PromptParleProvider
    #>
    [CmdletBinding()]
    param()

    $result = Invoke-PromptParleApi -Method GET -Path '/api/v1/providers'
    $list = @($result.providers)
    foreach ($p in $list) {
        [pscustomobject]@{
            Id           = $p.id
            Name         = $p.name
            Routing      = [bool]$p.routing
            DefaultModel = $p.default_model
            Configured   = [bool]$p.configured
        }
    }
}

function Get-PromptParleUsage {
    <#
    .SYNOPSIS
      Show token savings and recent PromptParle usage for your account.

    .PARAMETER Recent
      Also return recent request rows.

    .EXAMPLE
      Get-PromptParleUsage
    #>
    [CmdletBinding()]
    param(
        [switch]$Recent
    )

    $result = Invoke-PromptParleApi -Method GET -Path '/api/v1/usage'

    $summary = [pscustomobject]@{
        RequestCount      = $result.request_count
        OriginalTokens    = $result.original_tokens
        OptimizedTokens   = $result.optimized_tokens
        TokensSaved       = $result.tokens_saved
        ReductionPercent  = $result.reduction_percent
    }

    if ($Recent) {
        $summary | Add-Member -NotePropertyName Recent -NotePropertyValue @($result.recent)
    }

    $summary
}

function Invoke-PromptParle {
    <#
    .SYNOPSIS
      Send a prompt through PromptParle (optimize + optional AI provider).

    .DESCRIPTION
      Context can be passed as -Context, piped from the pipeline (strings or
      file content), or both. Pipeline input becomes context by default.

    .PARAMETER Prompt
      The user goal / instruction.

    .PARAMETER Provider
      openai | anthropic | gemini | grok

    .PARAMETER Model
      Provider model id. Uses provider default if omitted.

    .PARAMETER Profile
      Optimization profile: general, developer, security-review, log-analysis,
      documentation, executive-summary.

    .PARAMETER Context
      Extra material (code, logs, configs).

    .PARAMETER OptimizeOnly
      Only optimize; do not call the AI provider.

    .PARAMETER Quiet
      Do not print token reduction banner to the host.

    .PARAMETER Raw
      Return the raw API JSON object instead of a friendly result object.

    .EXAMPLE
      Invoke-PromptParle -Provider openai -Prompt 'Summarize this' -Context (Get-Content .\notes.txt -Raw)

    .EXAMPLE
      Get-Content .\firewall-rules.txt | Invoke-PromptParle -Provider openai -Profile security-review -Prompt 'Find risky rules'

    .EXAMPLE
      Invoke-PromptParle -Provider anthropic -Prompt 'Explain this' -Context $code -OptimizeOnly
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Prompt,

        [Parameter()]
        [ValidateSet('openai', 'anthropic', 'gemini', 'grok')]
        [string]$Provider = 'openai',

        [Parameter()]
        [string]$Model,

        [Parameter()]
        [Alias('OptimizationProfile')]
        [ValidateSet(
            'general',
            'developer',
            'security-review',
            'log-analysis',
            'documentation',
            'executive-summary'
        )]
        [string]$Profile = 'general',

        [Parameter(ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [AllowEmptyString()]
        [object[]]$Context,

        [Parameter()]
        [Alias('ContextFile')]
        [string]$Path,

        [switch]$OptimizeOnly,

        [switch]$Quiet,

        [switch]$Raw
    )

    begin {
        $contextChunks = New-Object System.Collections.Generic.List[string]
    }

    process {
        if ($null -ne $Context) {
            foreach ($item in $Context) {
                if ($null -eq $item) { continue }
                if ($item -is [System.IO.FileInfo]) {
                    $contextChunks.Add((Get-Content -LiteralPath $item.FullName -Raw -ErrorAction Stop))
                } else {
                    $contextChunks.Add([string]$item)
                }
            }
        }
    }

    end {
        if ($Path) {
            if (-not (Test-Path -LiteralPath $Path)) {
                throw "Context file not found: $Path"
            }
            $contextChunks.Add((Get-Content -LiteralPath $Path -Raw -ErrorAction Stop))
        }

        $contextText = $null
        if ($contextChunks.Count -gt 0) {
            $contextText = ($contextChunks -join "`n")
        }

        $body = [ordered]@{
            provider              = $Provider
            prompt                = $Prompt
            optimization_profile  = $Profile
            return_metadata       = $true
        }
        if ($Model) { $body.model = $Model }
        if ($contextText) { $body.context = $contextText }
        if ($OptimizeOnly) { $body.optimize_only = $true }

        $result = Invoke-PromptParleApi -Method POST -Path '/api/v1/prompt' -Body $body

        if ($Raw) {
            return $result
        }

        $meta = $result.metadata
        if (-not $Quiet) {
            Write-PromptParleMetadata -Metadata $meta
        }

        if ($OptimizeOnly) {
            if (-not $Quiet) {
                Write-Host 'Optimized prompt:' -ForegroundColor Cyan
            }
            return [pscustomobject]@{
                OptimizedPrompt = $result.optimized_prompt
                Metadata        = $meta
                Provider        = $Provider
                Profile         = $Profile
                OptimizeOnly    = $true
            }
        }

        if (-not $Quiet) {
            Write-Host 'AI Response:' -ForegroundColor Cyan
        }

        $responseText = [string]$result.response
        # Also emit response text for simple capture: $out = Invoke-PromptParle ... ; $out.Response
        [pscustomobject]@{
            Response = $responseText
            Metadata = $meta
            Provider = if ($meta.provider) { $meta.provider } else { $Provider }
            Model    = if ($meta.model) { $meta.model } else { $Model }
            Profile  = if ($meta.optimization_profile) { $meta.optimization_profile } else { $Profile }
            OptimizeOnly = $false
        }
    }
}

function Invoke-PromptParleSecurityReview {
    <#
    .SYNOPSIS
      Convenience wrapper: security-review profile.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Prompt,

        [ValidateSet('openai', 'anthropic', 'gemini', 'grok')]
        [string]$Provider = 'openai',

        [string]$Model,

        [Parameter(ValueFromPipeline)]
        [object[]]$Context,

        [string]$Path,

        [switch]$OptimizeOnly,
        [switch]$Quiet,
        [switch]$Raw
    )

    process {
        $params = @{
            Prompt         = $Prompt
            Provider       = $Provider
            Profile        = 'security-review'
            OptimizeOnly   = $OptimizeOnly
            Quiet          = $Quiet
            Raw            = $Raw
        }
        if ($Model) { $params.Model = $Model }
        if ($Path)  { $params.Path = $Path }
        if ($null -ne $Context) { $params.Context = $Context }

        Invoke-PromptParle @params
    }
}

function Start-PromptParle {
    <#
    .SYNOPSIS
      Friendly interactive PromptParle session.

    .DESCRIPTION
      Starts PromptParle like a chat app:
        1) Picks an AI provider you already configured in the portal
        2) Gives you a normal prompt line (you> )
        3) Optimizes + routes each message through PromptParle

      Shortcuts: pp   and   promptparle

    .EXAMPLE
      Start-PromptParle
      pp
    #>
    [CmdletBinding()]
    param(
        [ValidateSet('openai', 'anthropic', 'gemini', 'grok')]
        [string]$Provider,

        [ValidateSet(
            'general',
            'developer',
            'security-review',
            'log-analysis',
            'documentation',
            'executive-summary'
        )]
        [string]$Profile = 'general',

        [string]$Model
    )

    $config = Get-PromptParleConfigInternal
    if (-not $config.ApiKey) {
        Write-Host ''
        Write-Host 'PromptParle is not configured yet.' -ForegroundColor Yellow
        Write-Host '1) Create a desktop key: https://promptparle.com/app/api-keys' -ForegroundColor White
        Write-Host "2) Run:  Set-PromptParleApiKey -ApiKey 'pp_live_...'" -ForegroundColor White
        Write-Host '3) Run:  Start-PromptParle   (or: pp)' -ForegroundColor White
        Write-Host ''
        return
    }

    Write-Host ''
    Write-Host '========================================' -ForegroundColor Cyan
    Write-Host '  PromptParle' -ForegroundColor Cyan
    Write-Host '  Trim the prompt. Keep the signal.' -ForegroundColor DarkGray
    Write-Host '========================================' -ForegroundColor Cyan
    Write-Host ''

    try {
        $allProviders = @(Get-PromptParleProvider)
    } catch {
        Write-Host "Could not load providers: $_" -ForegroundColor Red
        return
    }

    $selected = Select-PromptParleProviderInteractive -Providers $allProviders -Preferred $Provider
    if (-not $selected) { return }

    $sessionProvider = [string]$selected.Id
    $sessionModel = $Model
    $sessionProfile = $Profile
    $sessionContext = $null
    $optimizeOnlyNext = $false

    Write-Host ''
    Write-Host ("Ready. Talking to {0}." -f $selected.Name) -ForegroundColor Green
    Write-Host 'Type a message and press Enter.  /help for commands.  /quit to leave.' -ForegroundColor DarkGray
    Write-Host ''

    while ($true) {
        $line = Read-PromptParleLine -PromptText 'you> ' -Color Green
        if ($null -eq $line) {
            # Ctrl+Z / EOF
            Write-Host ''
            Write-Host 'Bye.' -ForegroundColor DarkGray
            break
        }

        $trimmed = $line.Trim()
        if (-not $trimmed) { continue }

        # Slash commands
        if ($trimmed.StartsWith('/')) {
            $parts = $trimmed -split '\s+', 2
            $cmd = $parts[0].ToLowerInvariant()
            $arg = if ($parts.Count -gt 1) { $parts[1].Trim() } else { '' }

            switch ($cmd) {
                { $_ -in @('/quit', '/exit', '/q') } {
                    Write-Host 'Bye.' -ForegroundColor DarkGray
                    return
                }
                '/help' {
                    Show-PromptParleSessionHelp
                    continue
                }
                '/clear' {
                    Clear-Host
                    continue
                }
                '/status' {
                    Write-Host ''
                    Write-Host ("  Provider : {0}" -f $sessionProvider)
                    Write-Host ("  Model    : {0}" -f $(if ($sessionModel) { $sessionModel } else { '(default)' }))
                    Write-Host ("  Profile  : {0}" -f $sessionProfile)
                    Write-Host ("  Context  : {0}" -f $(if ($sessionContext) { "$($sessionContext.Length) chars" } else { '(none)' }))
                    Write-Host ''
                    continue
                }
                '/usage' {
                    try {
                        $u = Get-PromptParleUsage
                        Write-Host ''
                        Write-Host ("  Requests     : {0}" -f $u.RequestCount)
                        Write-Host ("  Tokens saved : {0} ({1}%)" -f $u.TokensSaved, $u.ReductionPercent) -ForegroundColor Green
                        Write-Host ''
                    } catch {
                        Write-Host "Usage error: $_" -ForegroundColor Red
                    }
                    continue
                }
                '/provider' {
                    try {
                        $allProviders = @(Get-PromptParleProvider)
                        $picked = Select-PromptParleProviderInteractive -Providers $allProviders
                        if ($picked) {
                            $sessionProvider = [string]$picked.Id
                            $sessionModel = $null
                            Write-Host ("Switched to {0}." -f $picked.Name) -ForegroundColor Green
                        }
                    } catch {
                        Write-Host "Provider error: $_" -ForegroundColor Red
                    }
                    continue
                }
                '/profile' {
                    $profiles = @(
                        'general', 'developer', 'security-review',
                        'log-analysis', 'documentation', 'executive-summary'
                    )
                    if ($arg -and $profiles -contains $arg) {
                        $sessionProfile = $arg
                        Write-Host ("Profile set to {0}." -f $sessionProfile) -ForegroundColor Green
                        continue
                    }
                    Write-Host ''
                    Write-Host 'Profiles:' -ForegroundColor Cyan
                    for ($i = 0; $i -lt $profiles.Count; $i++) {
                        $mark = if ($profiles[$i] -eq $sessionProfile) { '*' } else { ' ' }
                        Write-Host ("  [{0}]{1} {2}" -f ($i + 1), $mark, $profiles[$i])
                    }
                    $pchoice = Read-PromptParleLine -PromptText 'profile # or name> ' -Color Yellow
                    if ($pchoice) {
                        $pchoice = $pchoice.Trim()
                        $n = 0
                        if ([int]::TryParse($pchoice, [ref]$n) -and $n -ge 1 -and $n -le $profiles.Count) {
                            $sessionProfile = $profiles[$n - 1]
                        } elseif ($profiles -contains $pchoice) {
                            $sessionProfile = $pchoice
                        } else {
                            Write-Host 'Unknown profile.' -ForegroundColor Yellow
                            continue
                        }
                        Write-Host ("Profile set to {0}." -f $sessionProfile) -ForegroundColor Green
                    }
                    continue
                }
                '/model' {
                    if ($arg) {
                        $sessionModel = $arg
                        Write-Host ("Model set to {0}." -f $sessionModel) -ForegroundColor Green
                    } else {
                        $sessionModel = $null
                        Write-Host 'Model cleared (using provider default).' -ForegroundColor Green
                    }
                    continue
                }
                '/context' {
                    Write-Host 'Paste context. End with a line that is only: EOF' -ForegroundColor Cyan
                    $buf = New-Object System.Collections.Generic.List[string]
                    while ($true) {
                        $cl = Read-PromptParleLine -PromptText '... ' -Color DarkGray
                        if ($null -eq $cl) { break }
                        if ($cl.Trim() -eq 'EOF') { break }
                        $buf.Add($cl)
                    }
                    if ($buf.Count -gt 0) {
                        $sessionContext = ($buf -join "`n")
                        Write-Host ("Context attached ({0} chars)." -f $sessionContext.Length) -ForegroundColor Green
                    } else {
                        Write-Host 'No context captured.' -ForegroundColor Yellow
                    }
                    continue
                }
                '/file' {
                    if (-not $arg) {
                        Write-Host 'Usage: /file C:\path\to\file.txt' -ForegroundColor Yellow
                        continue
                    }
                    if (-not (Test-Path -LiteralPath $arg)) {
                        Write-Host "File not found: $arg" -ForegroundColor Red
                        continue
                    }
                    try {
                        $sessionContext = Get-Content -LiteralPath $arg -Raw -ErrorAction Stop
                        Write-Host ("Loaded context from file ({0} chars)." -f $sessionContext.Length) -ForegroundColor Green
                    } catch {
                        Write-Host "Could not read file: $_" -ForegroundColor Red
                    }
                    continue
                }
                '/clearcontext' {
                    $sessionContext = $null
                    Write-Host 'Context cleared.' -ForegroundColor Green
                    continue
                }
                '/optimize' {
                    $optimizeOnlyNext = $true
                    Write-Host 'Next message will optimize only (no AI call).' -ForegroundColor Yellow
                    continue
                }
                default {
                    Write-Host "Unknown command: $cmd  (try /help)" -ForegroundColor Yellow
                    continue
                }
            }
        }

        # Normal chat message
        Write-Host 'thinking...' -ForegroundColor DarkGray
        try {
            $params = @{
                Prompt   = $trimmed
                Provider = $sessionProvider
                Profile  = $sessionProfile
                Quiet    = $false
            }
            if ($sessionModel) { $params.Model = $sessionModel }
            if ($sessionContext) { $params.Context = $sessionContext }
            if ($optimizeOnlyNext) {
                $params.OptimizeOnly = $true
                $optimizeOnlyNext = $false
            }

            $result = Invoke-PromptParle @params

            if ($result.OptimizeOnly) {
                Write-Host 'optimized prompt>' -ForegroundColor Cyan
                Write-Host $result.OptimizedPrompt
            } else {
                Write-Host ("{0}>" -f $sessionProvider) -ForegroundColor Magenta
                Write-Host $result.Response
            }
            Write-Host ''
        } catch {
            Write-Host "Error: $_" -ForegroundColor Red
            Write-Host ''
        }
    }
}

# Friendly entry points
Set-Alias -Name pp -Value Start-PromptParle -Scope Script -Force
Set-Alias -Name promptparle -Value Start-PromptParle -Scope Script -Force

#endregion

Export-ModuleMember -Function @(
    'Set-PromptParleApiKey',
    'Get-PromptParleConfig',
    'Get-PromptParleProvider',
    'Get-PromptParleUsage',
    'Invoke-PromptParle',
    'Invoke-PromptParleSecurityReview',
    'Start-PromptParle'
) -Alias @(
    'pp',
    'promptparle'
)
