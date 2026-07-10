#Requires -Version 5.1
<#
.SYNOPSIS
  PromptParle PowerShell module - AI context optimization gateway client.

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
        $c.ApiKey.Substring(0, 12) + '...' + $c.ApiKey.Substring($c.ApiKey.Length - 4)
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

function Get-PromptParleModuleRoot {
    if ($PSScriptRoot) { return $PSScriptRoot }
    $mod = Get-Module PromptParle
    if ($mod -and $mod.ModuleBase) { return $mod.ModuleBase }
    return $null
}

function Open-PromptParleUrl {
    param([Parameter(Mandatory)][string]$Url)
    try {
        if ($script:PromptParleIsWindows) {
            Start-Process $Url
        } elseif (Get-Command xdg-open -ErrorAction SilentlyContinue) {
            Start-Process xdg-open $Url
        } elseif (Get-Command open -ErrorAction SilentlyContinue) {
            Start-Process open $Url
        } else {
            Write-Host "Open this URL manually: $Url" -ForegroundColor Yellow
        }
    } catch {
        Write-Host "Could not launch browser. Open: $Url" -ForegroundColor Yellow
    }
}

function Open-PromptParleBrowser {
    <#
    .SYNOPSIS
      Open PromptParle. Default = local chat UI on this PC.
    #>
    [CmdletBinding()]
    param(
        # Open cloud portal chat instead of local UI
        [switch]$Cloud,
        [string]$Path = '/app/chat'
    )

    if ($Cloud) {
        $config = Get-PromptParleConfigInternal
        $base = if ($config.BaseUrl) { $config.BaseUrl.TrimEnd('/') } else { $script:DefaultBaseUrl }
        if (-not $Path.StartsWith('/')) { $Path = "/$Path" }
        $url = "$base$Path"
        Write-Host "Opening cloud portal: $url" -ForegroundColor Yellow
        Write-Host '(Prefer local: Open-PromptParleBrowser  or  pp)' -ForegroundColor DarkGray
        Open-PromptParleUrl -Url $url
        return
    }

    Start-PromptParleLocalServer
}

function Write-PromptParleHttpResponse {
    param(
        [Parameter(Mandatory)]$Context,
        [int]$StatusCode = 200,
        [string]$ContentType = 'text/plain; charset=utf-8',
        [string]$Body = ''
    )

    $buffer = [System.Text.Encoding]::UTF8.GetBytes($Body)
    $Context.Response.StatusCode = $StatusCode
    $Context.Response.ContentType = $ContentType
    $Context.Response.ContentLength64 = $buffer.Length
    $Context.Response.Headers.Add('Cache-Control', 'no-store')
    $Context.Response.OutputStream.Write($buffer, 0, $buffer.Length)
    $Context.Response.OutputStream.Close()
}

function Get-PromptParleListenersOnPort {
    <#
    .SYNOPSIS
      PIDs listening on a local TCP port.
    .OUTPUTS
      System.Collections.Generic.List[int]  (always one List object; .Count is safe under StrictMode)
    .NOTES
      Do NOT return ,@() empty Object[] - in PS that nests an empty array and
      foreach runs once with Id=@() which breaks Get-Process -Id.
    #>
    param([int]$Port)

    $pids = New-Object System.Collections.Generic.List[int]
    try {
        if (Get-Command Get-NetTCPConnection -ErrorAction SilentlyContinue) {
            $conns = @(Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue)
            foreach ($c in $conns) {
                if ($c.OwningProcess) {
                    $op = [int]$c.OwningProcess
                    if ($op -gt 0 -and -not $pids.Contains($op)) { [void]$pids.Add($op) }
                }
            }
        }
    } catch { }

    if ($pids.Count -eq 0 -and $script:PromptParleIsWindows) {
        try {
            $lines = @(netstat -ano -p tcp 2>$null | Select-String -Pattern (":$Port\s+"))
            foreach ($line in $lines) {
                $s = $line.ToString()
                if ($s -notmatch 'LISTENING') { continue }
                $parts = @(($s -split '\s+') | Where-Object { $_ })
                if ($parts.Count -ge 5) {
                    $procId = 0
                    if ([int]::TryParse($parts[-1], [ref]$procId) -and $procId -gt 0) {
                        if (-not $pids.Contains($procId)) { [void]$pids.Add($procId) }
                    }
                }
            }
        } catch { }
    }

    # Unary comma: return the List as one object (empty List is fine; has .Count)
    ,$pids
}

function Clear-PromptParleLocalPort {
    <#
    .SYNOPSIS
      Free a local port used by PromptParle (fast: only acts if something is listening).
    #>
    [CmdletBinding()]
    param(
        [int]$Port = 7788,
        [switch]$Quiet
    )

    $pids = Get-PromptParleListenersOnPort -Port $Port
    if ($null -eq $pids -or $pids.Count -eq 0) {
        # Nothing listening - do not wait on HTTP timeout
        return
    }

    # Quick polite stop (short timeout - only when something is actually listening)
    $stopUrl = "http://127.0.0.1:$Port/api/stop"
    try {
        if ($PSVersionTable.PSVersion.Major -le 5) {
            Invoke-WebRequest -Uri $stopUrl -Method POST -UseBasicParsing -TimeoutSec 1 | Out-Null
        } else {
            Invoke-WebRequest -Uri $stopUrl -Method POST -TimeoutSec 1 | Out-Null
        }
        if (-not $Quiet) { Write-Host "Asked server on port $Port to stop." -ForegroundColor DarkGray }
        Start-Sleep -Milliseconds 200
    } catch { }

    $pids = Get-PromptParleListenersOnPort -Port $Port
    if ($null -eq $pids) { return }

    foreach ($procId in $pids) {
        # Guard: never pass empty/non-int to Get-Process -Id (StrictMode / PS 5.1)
        if ($null -eq $procId) { continue }
        $id = 0
        if (-not [int]::TryParse([string]$procId, [ref]$id) -or $id -le 0) { continue }
        if ($id -eq $PID) { continue }

        $proc = $null
        try {
            $proc = Get-Process -Id $id -ErrorAction SilentlyContinue
        } catch {
            continue
        }
        if (-not $proc) { continue }

        $name = $proc.ProcessName
        if ($name -match '^(powershell|pwsh|powershell_ise)$') {
            if (-not $Quiet) {
                Write-Host ("Stopping leftover {0} (PID {1}) on port {2}..." -f $name, $id, $Port) -ForegroundColor Yellow
            }
            try {
                Stop-Process -Id $id -Force -ErrorAction Stop
                if (-not $Quiet) { Write-Host ("Stopped PID {0}." -f $id) -ForegroundColor Green }
            } catch {
                if (-not $Quiet) { Write-Host ("Could not stop PID {0}: {1}" -f $id, $_) -ForegroundColor Red }
            }
        } else {
            if (-not $Quiet) {
                Write-Host ("Port {0} held by {1} (PID {2}) - not auto-killed." -f $Port, $name, $id) -ForegroundColor Yellow
            }
        }
    }

    Start-Sleep -Milliseconds 150
}

function Stop-PromptParleLocalServer {
    <#
    .SYNOPSIS
      Stop a local PromptParle chat server (same machine).
    .PARAMETER Port
      Port the server is on. Default 7788.
    .PARAMETER AllCommonPorts
      Also clear 7788-7798 (only ports that are listening).
    #>
    [CmdletBinding()]
    param(
        [int]$Port = 7788,
        [switch]$AllCommonPorts
    )

    if ($AllCommonPorts) {
        $any = $false
        foreach ($p in 7788..7798) {
            $listeners = Get-PromptParleListenersOnPort -Port $p
            if ($null -ne $listeners -and $listeners.Count -gt 0) {
                $any = $true
                Clear-PromptParleLocalPort -Port $p
            }
        }
        if ($any) {
            Write-Host 'Cleared busy PromptParle local ports.' -ForegroundColor Green
        } else {
            Write-Host 'No PromptParle listeners found on 7788-7798.' -ForegroundColor DarkGray
        }
        return
    }

    Clear-PromptParleLocalPort -Port $Port
    Write-Host ("Port {0} cleared (or was already free)." -f $Port) -ForegroundColor Green
}

function Start-PromptParleLocalServer {
    <#
    .SYNOPSIS
      Run a local chat UI on http://127.0.0.1 (this PC only).

    .DESCRIPTION
      Browser UI is local - nothing serves HTML from AWS.
      Chat still uses your desktop API key to call PromptParle for
      optimize + your stored provider keys. AI token spend is on YOUR
      provider account (BYOK), not the PromptParle OpenAI bill.

      Stop options:
        - Ctrl+C in this window
        - Click "Stop server" in the browser
        - Another window: Stop-PromptParleLocalServer
        - Close this PowerShell window with the X

    .PARAMETER Port
      Preferred local port. Default 7788. If busy, tries the next free port.
    #>
    [CmdletBinding()]
    param(
        [int]$Port = 7788
    )

    $config = Get-PromptParleConfigInternal
    if (-not $config.ApiKey) {
        Write-Host ''
        Write-Host 'Local chat needs a desktop API key (stays on your PC).' -ForegroundColor Yellow
        Write-Host '1) https://promptparle.com/app/api-keys  -> create pp_live_ key' -ForegroundColor White
        Write-Host '2) Set-PromptParleApiKey -ApiKey pp_live_YOUR_KEY' -ForegroundColor White
        Write-Host '3) pp' -ForegroundColor Cyan
        Write-Host ''
        return
    }

    $root = Get-PromptParleModuleRoot
    $uiPath = Join-Path $root 'local-ui\index.html'
    if (-not (Test-Path -LiteralPath $uiPath)) {
        $uiPath = Join-Path $root 'local-ui/index.html'
    }
    if (-not (Test-Path -LiteralPath $uiPath)) {
        throw "Local UI not found at $uiPath - reinstall the module (git pull + Install-PromptParle.ps1)."
    }
    $html = Get-Content -LiteralPath $uiPath -Raw -Encoding UTF8

    # Free preferred port only if busy, then bind. Try next ports only on failure.
    $listener = $null
    $boundPort = $null
    $tryPorts = @($Port) + @(7788..7798 | Where-Object { $_ -ne $Port })

    foreach ($tryPort in $tryPorts) {
        # Fast path: only clear when something is actually listening
        $busy = Get-PromptParleListenersOnPort -Port $tryPort
        if ($null -ne $busy -and $busy.Count -gt 0) {
            Clear-PromptParleLocalPort -Port $tryPort -Quiet
        }

        $prefix = "http://127.0.0.1:$tryPort/"
        $candidate = New-Object System.Net.HttpListener
        try {
            $candidate.Prefixes.Add($prefix)
            $candidate.Start()
            $listener = $candidate
            $boundPort = $tryPort
            $Port = $tryPort
            break
        } catch {
            try { $candidate.Abort() } catch { }
            try { $candidate.Close() } catch { }
        }
    }

    if (-not $listener) {
        Write-Host 'Could not start local chat - ports 7788-7798 are busy.' -ForegroundColor Red
        Write-Host 'Run:  Stop-PromptParleLocalServer -AllCommonPorts' -ForegroundColor Cyan
        Write-Host 'Or close other PowerShell windows, then:  pp' -ForegroundColor Cyan
        return
    }

    if ($boundPort -ne 7788) {
        Write-Host ("Using port {0} (7788 was busy)." -f $boundPort) -ForegroundColor Yellow
    }

    $script:PromptParleShouldStop = $false
    $script:PromptParleStopAnnounced = $false
    # Shared ref so cancel handler and main loop can both print progress
    $script:PromptParleListener = $listener

    $cancelHandler = [System.ConsoleCancelEventHandler]{
        param($sender, $eventArgs)
        # Keep process alive - we shut down cleanly in the main loop
        $eventArgs.Cancel = $true
        $script:PromptParleShouldStop = $true
        # CancelKeyPress runs on another thread; Write-Host can lag or look like dead air.
        # Console.Out + Flush shows feedback immediately.
        try {
            [Console]::Out.WriteLine('')
            [Console]::Out.WriteLine('Ctrl+C received - stopping local PromptParle...')
            [Console]::Out.WriteLine('  Closing listener and finishing any in-flight request...')
            [Console]::Out.Flush()
        } catch {
            try {
                Write-Host ''
                Write-Host 'Ctrl+C received - stopping local PromptParle...' -ForegroundColor Yellow
            } catch { }
        }
        $script:PromptParleStopAnnounced = $true
        try {
            if ($script:PromptParleListener -and $script:PromptParleListener.IsListening) {
                $script:PromptParleListener.Stop()
            }
        } catch { }
    }
    [Console]::add_CancelKeyPress($cancelHandler)

    $url = "http://127.0.0.1:$Port/"
    Write-Host ''
    Write-Host '========================================' -ForegroundColor Cyan
    Write-Host '  PromptParle  (LOCAL)' -ForegroundColor Cyan
    Write-Host '  Browser UI on this PC only' -ForegroundColor DarkGray
    Write-Host '========================================' -ForegroundColor Cyan
    Write-Host ''
    Write-Host "  $url" -ForegroundColor Green
    Write-Host ''
    Write-Host '  Stop any of these ways:' -ForegroundColor Yellow
    Write-Host '    - Ctrl+C in this window' -ForegroundColor White
    Write-Host '    - Browser button: Stop server' -ForegroundColor White
    Write-Host '    - Close this window with the X' -ForegroundColor White
    Write-Host '    - Other window: Stop-PromptParleLocalServer' -ForegroundColor White
    Write-Host ''

    Open-PromptParleUrl -Url $url

    try {
        while ($listener.IsListening -and -not $script:PromptParleShouldStop) {
            # Polling GetContext so Ctrl+C / Stop can interrupt (blocking GetContext ignores Ctrl+C)
            $async = $null
            try {
                $async = $listener.BeginGetContext($null, $null)
            } catch {
                break
            }

            while (-not $async.IsCompleted) {
                if ($script:PromptParleShouldStop -or -not $listener.IsListening) {
                    if (-not $script:PromptParleStopAnnounced) {
                        Write-Host 'Stop requested - shutting down local server...' -ForegroundColor Yellow
                        $script:PromptParleStopAnnounced = $true
                    }
                    try { $listener.Stop() } catch { }
                    break
                }
                Start-Sleep -Milliseconds 100
            }

            if ($script:PromptParleShouldStop -or -not $listener.IsListening) { break }
            if (-not $async.IsCompleted) { break }

            try {
                $ctx = $listener.EndGetContext($async)
            } catch {
                break
            }

            $req = $ctx.Request
            $path = $req.Url.AbsolutePath.TrimEnd('/')
            if (-not $path) { $path = '/' }

            try {
                # Stop server from browser or Stop-PromptParleLocalServer
                if (($req.HttpMethod -eq 'POST' -or $req.HttpMethod -eq 'GET') -and $path -eq '/api/stop') {
                    Write-PromptParleHttpResponse -Context $ctx -ContentType 'application/json; charset=utf-8' -Body '{"ok":true,"stopped":true}'
                    Write-Host 'Stop requested from browser / remote - shutting down...' -ForegroundColor Yellow
                    $script:PromptParleShouldStop = $true
                    $script:PromptParleStopAnnounced = $true
                    try { $listener.Stop() } catch { }
                    break
                }

                if ($req.HttpMethod -eq 'GET' -and ($path -eq '/' -or $path -eq '/index.html')) {
                    Write-PromptParleHttpResponse -Context $ctx -ContentType 'text/html; charset=utf-8' -Body $html
                    continue
                }

                if ($req.HttpMethod -eq 'GET' -and $path -eq '/api/providers') {
                    try {
                        $result = Invoke-PromptParleApi -Method GET -Path '/api/v1/providers'
                        $json = ($result | ConvertTo-Json -Depth 8 -Compress)
                        Write-PromptParleHttpResponse -Context $ctx -ContentType 'application/json; charset=utf-8' -Body $json
                    } catch {
                        $err = @{ error = "$_" } | ConvertTo-Json -Compress
                        Write-PromptParleHttpResponse -Context $ctx -StatusCode 502 -ContentType 'application/json; charset=utf-8' -Body $err
                    }
                    continue
                }

                if ($req.HttpMethod -eq 'POST' -and $path -eq '/api/chat') {
                    $reader = New-Object System.IO.StreamReader($req.InputStream, $req.ContentEncoding)
                    $rawBody = $reader.ReadToEnd()
                    $reader.Close()
                    try {
                        $body = $rawBody | ConvertFrom-Json
                        $prompt = [string]$body.prompt
                        if (-not $prompt) { throw 'Missing prompt' }
                        $provider = if ($body.provider) { [string]$body.provider } else { 'openai' }
                        $profile = if ($body.profile) { [string]$body.profile } else { 'general' }
                        $context = if ($body.context) { [string]$body.context } else { $null }
                        $optOnly = $false
                        if ($body.optimize_only -eq $true -or $body.optimizeOnly -eq $true) { $optOnly = $true }

                        $params = @{
                            Prompt   = $prompt
                            Provider = $provider
                            Profile  = $profile
                            Quiet    = $true
                            Raw      = $true
                        }
                        if ($context) { $params.Context = $context }
                        if ($optOnly) { $params.OptimizeOnly = $true }

                        $result = Invoke-PromptParle @params
                        $json = ($result | ConvertTo-Json -Depth 10 -Compress)
                        Write-PromptParleHttpResponse -Context $ctx -ContentType 'application/json; charset=utf-8' -Body $json
                    } catch {
                        $err = @{ error = "$_" } | ConvertTo-Json -Compress
                        Write-PromptParleHttpResponse -Context $ctx -StatusCode 502 -ContentType 'application/json; charset=utf-8' -Body $err
                    }
                    continue
                }

                Write-PromptParleHttpResponse -Context $ctx -StatusCode 404 -Body 'Not found'
            } catch {
                try {
                    Write-PromptParleHttpResponse -Context $ctx -StatusCode 500 -Body "$_"
                } catch { }
            }
        }
    } finally {
        if (-not $script:PromptParleStopAnnounced) {
            Write-Host 'Shutting down local PromptParle...' -ForegroundColor Yellow
            $script:PromptParleStopAnnounced = $true
        }
        try { [Console]::remove_CancelKeyPress($cancelHandler) } catch { }
        try {
            if ($listener -and $listener.IsListening) {
                Write-Host '  Closing HTTP listener...' -ForegroundColor DarkGray
                $listener.Stop()
            }
        } catch { }
        try { if ($listener) { $listener.Close() } } catch { }
        $script:PromptParleShouldStop = $false
        $script:PromptParleStopAnnounced = $false
        $script:PromptParleListener = $null
        Write-Host 'Local PromptParle server stopped.' -ForegroundColor Green
        Write-Host 'You can close this window or run:  pp' -ForegroundColor DarkGray
    }
}

function Start-PromptParle {
    <#
    .SYNOPSIS
      Start PromptParle - local browser chat by default.

    .DESCRIPTION
      Default: starts a LOCAL web UI on http://127.0.0.1:7788 and opens it.
      The chat page runs on your machine (not hosted as your daily UI on AWS).

      -Cli     terminal chat
      -Cloud   open portal web chat on promptparle.com instead

    .EXAMPLE
      pp
      Start-PromptParle -Port 7790
      Start-PromptParle -Cli
    #>
    [CmdletBinding()]
    param(
        [switch]$Cli,
        [switch]$Cloud,
        [int]$Port = 7788,

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

    if ($Cloud) {
        Open-PromptParleBrowser -Cloud -Path '/app/chat'
        return
    }

    if (-not $Cli) {
        Start-PromptParleLocalServer -Port $Port
        return
    }

    # --- CLI mode ---
    $config = Get-PromptParleConfigInternal
    if (-not $config.ApiKey) {
        Write-Host ''
        Write-Host 'Needs a desktop API key on this PC.' -ForegroundColor Yellow
        Write-Host '1) https://promptparle.com/app/api-keys' -ForegroundColor White
        Write-Host '2) Set-PromptParleApiKey -ApiKey pp_live_YOUR_KEY' -ForegroundColor White
        Write-Host '3) pp' -ForegroundColor Cyan
        Write-Host ''
        return
    }

    Write-Host ''
    Write-Host '========================================' -ForegroundColor Cyan
    Write-Host '  PromptParle (CLI)' -ForegroundColor Cyan
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
            Write-Host ''
            Write-Host 'Bye.' -ForegroundColor DarkGray
            break
        }

        $trimmed = $line.Trim()
        if (-not $trimmed) { continue }

        if ($trimmed.StartsWith('/')) {
            $parts = $trimmed -split '\s+', 2
            $cmd = $parts[0].ToLowerInvariant()
            $arg = if ($parts.Count -gt 1) { $parts[1].Trim() } else { '' }

            switch ($cmd) {
                { $_ -in @('/quit', '/exit', '/q') } {
                    Write-Host 'Bye.' -ForegroundColor DarkGray
                    return
                }
                '/help' { Show-PromptParleSessionHelp; continue }
                '/clear' { Clear-Host; continue }
                '/browser' {
                    Write-Host 'Start a second window and run:  pp' -ForegroundColor Cyan
                    Write-Host 'Or cloud portal:  Open-PromptParleBrowser -Cloud' -ForegroundColor DarkGray
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

function Uninstall-PromptParle {
    <#
    .SYNOPSIS
      Remove PromptParle from this PC (module, optional config, optional git clone).

    .PARAMETER RemoveConfig
      Also delete saved API key at ~/.promptparle

    .PARAMETER RemoveClone
      Also delete the git clone (default: %USERPROFILE%\src\promptparle)

    .PARAMETER ClonePath
      Override clone path when using -RemoveClone

    .EXAMPLE
      Uninstall-PromptParle
      Uninstall-PromptParle -RemoveConfig
      Uninstall-PromptParle -RemoveConfig -RemoveClone
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param(
        [switch]$RemoveConfig,
        [switch]$RemoveClone,
        [string]$ClonePath
    )

    Write-Host ''
    Write-Host 'Uninstalling PromptParle...' -ForegroundColor Cyan

    # 1) Stop local servers
    try { Stop-PromptParleLocalServer -AllCommonPorts } catch {
        Clear-PromptParleLocalPort -Port 7788 -Quiet
    }

    # 2) Unload module
    Remove-Module PromptParle -Force -ErrorAction SilentlyContinue

    # 3) Remove module folders
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
            if ($PSCmdlet.ShouldProcess($path, 'Remove module folder')) {
                Remove-Item -LiteralPath $path -Recurse -Force
                Write-Host "Removed module: $path" -ForegroundColor Green
                $removed = $true
            }
        }
    }
    if (-not $removed) {
        Write-Host 'No module folder found in standard locations.' -ForegroundColor Yellow
    }

    # 4) Optional config
    if ($RemoveConfig) {
        $configDirs = @()
        if ($env:PROMPTPARLE_CONFIG_DIR) { $configDirs += $env:PROMPTPARLE_CONFIG_DIR }
        if ($env:USERPROFILE) { $configDirs += (Join-Path $env:USERPROFILE '.promptparle') }
        if ($HOME) { $configDirs += (Join-Path $HOME '.promptparle') }
        foreach ($dir in ($configDirs | Select-Object -Unique)) {
            if ($dir -and (Test-Path -LiteralPath $dir)) {
                if ($PSCmdlet.ShouldProcess($dir, 'Remove API key config')) {
                    Remove-Item -LiteralPath $dir -Recurse -Force
                    Write-Host "Removed config: $dir" -ForegroundColor Green
                }
            }
        }
    } else {
        Write-Host 'Kept API key config (use -RemoveConfig to delete).' -ForegroundColor DarkGray
    }

    # 5) Optional clone
    if ($RemoveClone) {
        if (-not $ClonePath) {
            if ($env:USERPROFILE) {
                $ClonePath = Join-Path $env:USERPROFILE 'src\promptparle'
            } else {
                $ClonePath = Join-Path $HOME 'src/promptparle'
            }
        }
        if (Test-Path -LiteralPath $ClonePath) {
            if ($PSCmdlet.ShouldProcess($ClonePath, 'Remove git clone')) {
                Remove-Item -LiteralPath $ClonePath -Recurse -Force
                Write-Host "Removed clone: $ClonePath" -ForegroundColor Green
            }
        } else {
            Write-Host "Clone not found: $ClonePath" -ForegroundColor Yellow
        }
    }

    Write-Host ''
    Write-Host 'Uninstall complete.' -ForegroundColor Green
    Write-Host 'Reinstall:' -ForegroundColor Cyan
    Write-Host '  irm https://raw.githubusercontent.com/exiled4disco/promptparle/main/powershell/Install-FromGitHub.ps1 | iex'
    Write-Host ''
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
    'Start-PromptParle',
    'Start-PromptParleLocalServer',
    'Stop-PromptParleLocalServer',
    'Open-PromptParleBrowser',
    'Uninstall-PromptParle'
) -Alias @(
    'pp',
    'promptparle'
)
