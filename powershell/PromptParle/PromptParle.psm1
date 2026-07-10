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

$script:PromptParleConfigDir = if ($env:PROMPTPARLE_CONFIG_DIR) {
    $env:PROMPTPARLE_CONFIG_DIR
} elseif ($IsWindows -or $env:OS -match 'Windows') {
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
    if (-not ($IsWindows -or $env:OS -match 'Windows')) {
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

    Write-Host ''
    Write-Host 'PromptParle optimized your context:' -ForegroundColor Cyan
    if ($null -ne $orig)  { Write-Host ("  Original tokens : {0}" -f $orig) }
    if ($null -ne $opt)   { Write-Host ("  Optimized tokens: {0}" -f $opt) }
    if ($null -ne $pct)   { Write-Host ("  Reduction       : {0}%" -f $pct) -ForegroundColor Green }
    if ($prov)            { Write-Host ("  Provider        : {0}" -f $prov) }
    if ($model)           { Write-Host ("  Model           : {0}" -f $model) }
    if ($prof)            { Write-Host ("  Profile         : {0}" -f $prof) }
    if ($Metadata.secrets_masked) {
        Write-Host '  Secrets masked  : yes' -ForegroundColor Yellow
    }
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

#endregion

Export-ModuleMember -Function @(
    'Set-PromptParleApiKey',
    'Get-PromptParleConfig',
    'Get-PromptParleProvider',
    'Get-PromptParleUsage',
    'Invoke-PromptParle',
    'Invoke-PromptParleSecurityReview'
)
