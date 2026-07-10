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
# Brief caches (local-only; avoid re-running git/SSH/web on every chat turn)
$script:PromptParleConnBriefCache = @{ key = ''; text = ''; at = [datetime]::MinValue }
$script:PromptParleWebSearchCache = @{}
# StrictMode-safe: always initialize before any read
$script:PromptParleShouldStop = $false
$script:PromptParleStopAnnounced = $false
$script:PromptParleListener = $null
$script:PromptParleExitProcessAfterStop = $false

#region Private helpers

function Get-PromptParleProp {
    <#
    .SYNOPSIS
      Read a note property under Set-StrictMode (missing props must not throw).
    #>
    param(
        $Object,
        [Parameter(Mandatory)][string]$Name,
        $Default = $null
    )
    if ($null -eq $Object) { return $Default }
    $prop = $Object.PSObject.Properties[$Name]
    if ($null -eq $prop) { return $Default }
    return $prop.Value
}

function ConvertFrom-PromptParleJson {
    <#
    .SYNOPSIS
      JSON parse that allows large payloads (images) on Windows PowerShell 5.1.
    #>
    param([Parameter(Mandatory)][string]$Json)

    if ($PSVersionTable.PSVersion.Major -ge 6) {
        return ($Json | ConvertFrom-Json -Depth 30)
    }

    # PS 5.1 ConvertFrom-Json caps ~2MB. Raise via JavaScriptSerializer.
    try {
        Add-Type -AssemblyName System.Web.Extensions -ErrorAction Stop
    } catch {
        return ($Json | ConvertFrom-Json)
    }

    $ser = New-Object System.Web.Script.Serialization.JavaScriptSerializer
    $ser.MaxJsonLength = 64 * 1024 * 1024
    $ser.RecursionLimit = 100
    $raw = $ser.DeserializeObject($Json)
    return ConvertTo-PromptParlePsObject $raw
}

function ConvertTo-PromptParleNetObject {
    <#
    .SYNOPSIS
      PSObject/hashtable/array → plain .NET types for JavaScriptSerializer.
    #>
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [string] -or $Value -is [bool] -or $Value -is [int] -or $Value -is [long] -or $Value -is [double] -or $Value -is [decimal]) {
        return $Value
    }
    if ($Value -is [byte] -or $Value -is [int16] -or $Value -is [uint32] -or $Value -is [uint64]) {
        return [int]$Value
    }
    # Hashtable / Dictionary first (also IEnumerable — must not enumerate as KeyValue pairs)
    if ($Value -is [System.Collections.IDictionary]) {
        $d = New-Object 'System.Collections.Generic.Dictionary[string,object]'
        foreach ($key in $Value.Keys) {
            $d[[string]$key] = ConvertTo-PromptParleNetObject $Value[$key]
        }
        return $d
    }
    if ($Value -is [System.Management.Automation.PSObject] -and $Value.PSObject -and $Value.PSObject.Properties) {
        # Prefer NoteProperty dictionary shape over enumerating PSObject
        $d = New-Object 'System.Collections.Generic.Dictionary[string,object]'
        foreach ($p in $Value.PSObject.Properties) {
            if ($null -eq $p.Name) { continue }
            if ($p.MemberType -and [string]$p.MemberType -notmatch 'NoteProperty|Property') { continue }
            $d[[string]$p.Name] = ConvertTo-PromptParleNetObject $p.Value
        }
        if ($d.Count -gt 0) { return $d }
    }
    if ($Value -is [System.Collections.IEnumerable] -and -not ($Value -is [string]) -and -not ($Value -is [System.Collections.IDictionary])) {
        $list = New-Object System.Collections.ArrayList
        foreach ($item in $Value) {
            # Flatten accidental nested arrays (PS unary-comma + @() wrap)
            if ($item -is [System.Array]) {
                foreach ($inner in $item) {
                    [void]$list.Add((ConvertTo-PromptParleNetObject $inner))
                }
            } else {
                [void]$list.Add((ConvertTo-PromptParleNetObject $item))
            }
        }
        # Plain Object[] — no unary comma (would re-nest under @())
        return $list.ToArray()
    }
    return [string]$Value
}

function ConvertTo-PromptParleJson {
    <#
    .SYNOPSIS
      JSON serialize with large MaxJsonLength (vision base64).
      PS 5.1 ConvertTo-Json defaults ~2MB and breaks multi-image chat.
    #>
    param(
        [Parameter(Mandatory)]$InputObject,
        [int]$Depth = 20
    )
    if ($PSVersionTable.PSVersion.Major -ge 6) {
        return ($InputObject | ConvertTo-Json -Depth $Depth -Compress)
    }
    try {
        Add-Type -AssemblyName System.Web.Extensions -ErrorAction Stop
        $ser = New-Object System.Web.Script.Serialization.JavaScriptSerializer
        $ser.MaxJsonLength = 64 * 1024 * 1024
        $ser.RecursionLimit = [Math]::Max(100, $Depth * 5)
        $net = ConvertTo-PromptParleNetObject $InputObject
        return $ser.Serialize($net)
    } catch {
        # last resort — may still fail on multi-image
        return ($InputObject | ConvertTo-Json -Depth $Depth -Compress)
    }
}

function ConvertTo-PromptParlePsObject {
    param($Value)
    if ($null -eq $Value) { return $null }

    # Dictionary from JavaScriptSerializer
    if ($Value -is [System.Collections.IDictionary]) {
        $o = [ordered]@{}
        foreach ($key in $Value.Keys) {
            $o[[string]$key] = ConvertTo-PromptParlePsObject $Value[$key]
        }
        return [pscustomobject]$o
    }

    if ($Value -is [System.Collections.IEnumerable] -and -not ($Value -is [string])) {
        $list = New-Object System.Collections.Generic.List[object]
        foreach ($item in $Value) {
            [void]$list.Add((ConvertTo-PromptParlePsObject $item))
        }
        return ,$list.ToArray()
    }

    return $Value
}

function ConvertTo-PromptParleImageList {
    <#
    .SYNOPSIS
      Normalize UI/API image objects into a flat Object[] of hashtables.
      Do NOT use unary-comma return — that nests as [[img,img]] after @() wrap
      and Zod rejects with "images: expected object, received array".
    #>
    param($Images)

    $out = New-Object System.Collections.Generic.List[hashtable]
    if ($null -eq $Images) { return @() }

    # Flatten one nesting level (PS often wraps arrays)
    $items = New-Object System.Collections.Generic.List[object]
    foreach ($x in @($Images)) {
        if ($null -eq $x) { continue }
        if ($x -is [System.Array]) {
            foreach ($y in $x) { if ($null -ne $y) { [void]$items.Add($y) } }
        } else {
            [void]$items.Add($x)
        }
    }

    foreach ($img in $items) {
        if ($null -eq $img) { continue }
        # Skip pure nested arrays that aren't image objects
        if ($img -is [System.Array] -and -not (Get-PromptParleProp $img 'media_type' $null) -and -not (Get-PromptParleProp $img 'data_base64' $null)) {
            continue
        }
        $mediaType = Get-PromptParleProp $img 'media_type' $null
        if (-not $mediaType) { $mediaType = Get-PromptParleProp $img 'mediaType' 'image/png' }
        $data = Get-PromptParleProp $img 'data_base64' $null
        if (-not $data) { $data = Get-PromptParleProp $img 'dataBase64' $null }
        if (-not $data) { $data = Get-PromptParleProp $img 'data' $null }
        if (-not $data) { continue }
        $name = Get-PromptParleProp $img 'name' $null
        $entry = @{
            media_type  = [string]$mediaType
            data_base64 = [string]$data
        }
        if ($name) { $entry.name = [string]$name }
        [void]$out.Add($entry)
        if ($out.Count -ge 6) { break }
    }
    # Flat array of hashtables (pipeline-unroll is OK — callers use @())
    return $out.ToArray()
}

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

        [string]$BaseUrl = $script:DefaultBaseUrl,

        [string]$DesktopClientId = ''
    )

    if (-not (Test-Path -LiteralPath $script:PromptParleConfigDir)) {
        New-Item -ItemType Directory -Path $script:PromptParleConfigDir -Force | Out-Null
    }

    # Preserve existing desktop client id when not explicitly passed
    $existingClientId = ''
    if (-not $DesktopClientId -and (Test-Path -LiteralPath $script:PromptParleConfigPath)) {
        try {
            $prev = Get-Content -LiteralPath $script:PromptParleConfigPath -Raw | ConvertFrom-Json
            $existingClientId = [string](Get-PromptParleProp $prev 'DesktopClientId' '')
        } catch { }
    }
    $clientId = if ($DesktopClientId) { $DesktopClientId } else { $existingClientId }

    $obj = [ordered]@{
        ApiKey           = $ApiKey
        BaseUrl          = $BaseUrl.TrimEnd('/')
        DesktopClientId  = $clientId
        UpdatedAt        = (Get-Date).ToUniversalTime().ToString('o')
    }

    $obj | ConvertTo-Json | Set-Content -LiteralPath $script:PromptParleConfigPath -Encoding UTF8

    # Restrict permissions on Unix-like systems
    if (-not $script:PromptParleIsWindows) {
        try { chmod 600 $script:PromptParleConfigPath 2>$null } catch { }
    }
}

function Get-PromptParleDesktopClientId {
    <#
    .SYNOPSIS
      Stable per-machine desktop client id (stored in config.json) for concurrent seat gating.
    #>
    $id = ''
    if (Test-Path -LiteralPath $script:PromptParleConfigPath) {
        try {
            $raw = Get-Content -LiteralPath $script:PromptParleConfigPath -Raw -ErrorAction Stop
            $json = $raw | ConvertFrom-Json
            $id = [string](Get-PromptParleProp $json 'DesktopClientId' '')
        } catch { }
    }
    if (-not $id -or $id.Length -lt 8) {
        $id = [guid]::NewGuid().ToString('n')
        # Persist without requiring a re-set of API key
        try {
            $cfg = Get-PromptParleConfigInternal
            if ($cfg.ApiKey) {
                Save-PromptParleConfigInternal -ApiKey $cfg.ApiKey -BaseUrl $cfg.BaseUrl -DesktopClientId $id
            } else {
                if (-not (Test-Path -LiteralPath $script:PromptParleConfigDir)) {
                    New-Item -ItemType Directory -Path $script:PromptParleConfigDir -Force | Out-Null
                }
                $obj = [ordered]@{
                    DesktopClientId = $id
                    UpdatedAt       = (Get-Date).ToUniversalTime().ToString('o')
                }
                if (Test-Path -LiteralPath $script:PromptParleConfigPath) {
                    try {
                        $prev = Get-Content -LiteralPath $script:PromptParleConfigPath -Raw | ConvertFrom-Json
                        if ($prev.ApiKey) { $obj.ApiKey = [string]$prev.ApiKey }
                        if ($prev.BaseUrl) { $obj.BaseUrl = [string]$prev.BaseUrl }
                    } catch { }
                }
                $obj | ConvertTo-Json | Set-Content -LiteralPath $script:PromptParleConfigPath -Encoding UTF8
                if (-not $script:PromptParleIsWindows) {
                    try { chmod 600 $script:PromptParleConfigPath 2>$null } catch { }
                }
            }
        } catch { }
    }
    return $id
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
        # Avoid silent hangs in local UI when the cloud API is slow/unreachable
        # (vision + large context can take longer than plain text)
        TimeoutSec  = 180
    }

    if ($PSBoundParameters.ContainsKey('Body') -and $null -ne $Body) {
        # Large image payloads: never use default ConvertTo-Json (2MB cap on PS 5.1)
        $params.Body = ConvertTo-PromptParleJson -InputObject $Body -Depth 12
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
                # Surface Zod field errors when present (was silent "Invalid request")
                $det = Get-PromptParleProp $errObj 'details' $null
                if ($det -and -not ($detail -match ':')) {
                    try {
                        $fe = Get-PromptParleProp $det 'fieldErrors' $null
                        if ($fe) {
                            $bits = New-Object System.Collections.Generic.List[string]
                            foreach ($p in @($fe.PSObject.Properties)) {
                                $msgs = @($p.Value) | Where-Object { $_ } | ForEach-Object { "$_" }
                                if ($msgs.Count) { $bits.Add("$($p.Name)=$($msgs -join ';')") }
                            }
                            if ($bits.Count) {
                                $detail = "$(if ($detail) { $detail } else { 'Invalid request' }): $($bits -join ' · ')"
                            }
                        }
                    } catch { }
                }
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

    $orig = Get-PromptParleProp $Metadata 'original_tokens'
    $opt  = Get-PromptParleProp $Metadata 'optimized_tokens'
    $pct  = Get-PromptParleProp $Metadata 'token_reduction_percent'
    $prov = Get-PromptParleProp $Metadata 'provider'
    $model = Get-PromptParleProp $Metadata 'model'
    $prof = Get-PromptParleProp $Metadata 'optimization_profile'
    $expandedFlag = Get-PromptParleProp $Metadata 'expanded'
    $expanded = $false
    if ($null -ne $expandedFlag) { $expanded = [bool]$expandedFlag }
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
    $dial = Get-PromptParleProp $Metadata 'compression_level'
    if ($null -eq $dial) { $dial = Get-PromptParleProp $Metadata 'compressionLevel' }
    if ($null -ne $dial -and "$dial" -ne '') {
        Write-Host ("  Dial            : {0}/5" -f $dial)
    }
    if (Get-PromptParleProp $Metadata 'secrets_masked') {
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

#region Agents + slash commands (free desktop surface)
# Local-first: agents live under ~/.promptparle/agents
# Cloud later: team workspaces, shared libraries, analytics (not in this path)

function Get-PromptParleAgentsDir {
    $dir = Join-Path $script:PromptParleConfigDir 'agents'
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    return $dir
}

function Get-PromptParleSessionStatePath {
    return (Join-Path $script:PromptParleConfigDir 'session.json')
}

function ConvertTo-PromptParleAgentId {
    param([string]$Name)
    if (-not $Name) { return 'default' }
    $id = ($Name.ToLowerInvariant() -replace '[^a-z0-9]+', '-').Trim('-')
    if (-not $id) { $id = 'agent' }
    return $id
}

function New-PromptParleAgentObject {
    param(
        [string]$Id,
        [string]$Name,
        [string]$System = '',
        [string]$Profile = 'general',
        [int]$Dial = 3,
        [hashtable]$Commands = $null,
        [string]$Description = '',
        [string[]]$Tools = $null
    )
    if ($Dial -lt 1) { $Dial = 1 }
    if ($Dial -gt 5) { $Dial = 5 }
    if (-not $Commands) { $Commands = @{} }
    if (-not $Tools -or $Tools.Count -eq 0) {
        $Tools = @('files', 'workspace', 'secret_scan')
    }
    return [pscustomobject]@{
        id          = $Id
        name        = $Name
        description = $Description
        system      = $System
        profile     = $Profile
        dial        = $Dial
        commands    = $Commands
        tools       = @($Tools)
        updated_at  = (Get-Date).ToString('o')
    }
}

function Initialize-PromptParleDefaultAgents {
    $dir = Get-PromptParleAgentsDir
    $defaults = @(
        (New-PromptParleAgentObject -Id 'auto' -Name 'Auto' -Description 'Deterministic default: pick best lens + tools for THIS message' -Profile 'general' -Dial 3 `
            -System 'You are PromptParle Auto. Each turn is routed to the best lens for the user message (code, security, docs, general). Answer THIS message fully. Prior findings are context only — never trap the user in a previous mode. Honor [CONN]/[SSH]/[WEB] evidence.' `
            -Tools @('files', 'workspace', 'git', 'ssh', 'secret_scan', 'code_brief', 'connections', 'web_search', 'relevant_slice', 'error_brief')),
        (New-PromptParleAgentObject -Id 'default' -Name 'General' -Description 'General assistant (also used as Auto fallback lens)' -Profile 'general' -Dial 3 `
            -System 'You are a helpful assistant. Respect [CONN] Project connections (local PC folder, Git, SSH). Prefer attached local evidence; use [WEB] briefs when present. Answer THIS user message; do not force a prior specialized mode.' `
            -Tools @('files', 'workspace', 'secret_scan', 'connections', 'web_search')),
        (New-PromptParleAgentObject -Id 'security' -Name 'Security reviewer' -Description 'Security review for the current ask (not a permanent lock)' -Profile 'security-review' -Dial 3 `
            -System 'You are a security reviewer for THIS user message only. Prioritize real risk with evidence and concrete fixes. When [CONN] shows SSH cwd, [SSH] blocks are live remote file evidence — do not invent missing files. Prefer [SSH]/[CONN]/attachments. Do not invent ship-blockers. Do not refuse unrelated product/work questions if the user changed topics. PowerShell ExecutionPolicy is not a security boundary (Microsoft); do not treat -ExecutionPolicy Bypass alone as privilege escalation.' `
            -Commands @{ audit = 'Find the highest risk items and recommend actions with severity.'; threats = 'Map attack surface and threat scenarios from the material.' } `
            -Tools @('files', 'workspace', 'git', 'ssh', 'secret_scan', 'code_brief', 'git_diff', 'file_index', 'connections', 'web_search', 'relevant_slice')),
        (New-PromptParleAgentObject -Id 'docs' -Name 'Doc analyst' -Description 'Document coverage + obligations' -Profile 'documentation' -Dial 3 `
            -System 'You are a careful document analyst. Preserve structure and obligations. Lead with the most useful findings, then cover gaps. Use [WEB] only to fill doc gaps, cite sources.' `
            -Commands @{ summary = 'Summarize with section coverage and hard requirements.'; risks = 'Extract risks, must/shall obligations, and deadlines.' } `
            -Tools @('files', 'workspace', 'secret_scan', 'tree_pack', 'connections', 'web_search')),
        (New-PromptParleAgentObject -Id 'code' -Name 'Code reviewer' -Description 'Code-focused review' -Profile 'developer' -Dial 2 `
            -System 'You are a senior code reviewer. Focus on bugs, security, and maintainability. Cite symbols and files from the [CONN] workspace when possible.' `
            -Commands @{ review = 'Review the attached code for bugs, risks, and improvements.'; explain = 'Explain the attached code structure and control flow.' } `
            -Tools @('files', 'workspace', 'git', 'code_brief', 'secret_scan', 'file_index', 'deps', 'git_diff', 'tree_pack', 'connections', 'web_search'))
    )
    foreach ($a in $defaults) {
        $path = Join-Path $dir ($a.id + '.json')
        if (-not (Test-Path -LiteralPath $path)) {
            $cmdObj = [ordered]@{}
            if ($a.commands) {
                foreach ($k in $a.commands.Keys) { $cmdObj[[string]$k] = [string]$a.commands[$k] }
            }
            $out = [ordered]@{
                id          = $a.id
                name        = $a.name
                description = $a.description
                system      = $a.system
                profile     = $a.profile
                dial        = $a.dial
                commands    = $cmdObj
                tools       = @($a.tools)
                updated_at  = (Get-Date).ToString('o')
            }
            ($out | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $path -Encoding UTF8
        } else {
            # Migrate older built-ins that only had tools=@('files') — write JSON directly (no Save re-entry)
            try {
                $existing = Read-PromptParleAgentFile -Path $path
                if ($existing -and $existing.tools) {
                    $need = @($a.tools)
                    $have = @($existing.tools)
                    $upgradeLegacy = ($have.Count -le 1 -and ($have.Count -eq 0 -or $have -contains 'files'))
                    # Built-in security agent: ensure ssh tool + live-cwd doctrine in system prompt
                    $upgradeSecuritySsh = (
                        $a.id -eq 'security' -and (
                            ($have -notcontains 'ssh') -or
                            ([string]$existing.system -notmatch 'auto-fetched') -or
                            ([string]$existing.system -match 'hostile') -or
                            ([string]$existing.system -notmatch 'THIS user message only')
                        )
                    )
                    if ($upgradeLegacy -or $upgradeSecuritySsh) {
                        $merged = @($have)
                        foreach ($t in $need) {
                            if ($merged -notcontains $t) { $merged += $t }
                        }
                        $sysOut = [string]$existing.system
                        if ($upgradeSecuritySsh -and $a.system) { $sysOut = [string]$a.system }
                        $cmdObj = [ordered]@{}
                        if ($existing.commands) {
                            foreach ($k in $existing.commands.Keys) {
                                $cmdObj[[string]$k] = [string]$existing.commands[$k]
                            }
                        }
                        $out = [ordered]@{
                            id          = $existing.id
                            name        = $existing.name
                            description = $existing.description
                            system      = $sysOut
                            profile     = $existing.profile
                            dial        = [int]$existing.dial
                            commands    = $cmdObj
                            tools       = @($merged)
                            updated_at  = (Get-Date).ToString('o')
                        }
                        ($out | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $path -Encoding UTF8
                    }
                }
            } catch { }
        }
    }
}

function Read-PromptParleAgentFile {
    param([string]$Path)
    try {
        $raw = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
        $obj = $raw | ConvertFrom-Json
        $cmds = @{}
        $cprop = Get-PromptParleProp $obj 'commands'
        if ($null -ne $cprop) {
            $cprop.PSObject.Properties | ForEach-Object {
                $cmds[$_.Name] = [string]$_.Value
            }
        }
        $id = [string](Get-PromptParleProp $obj 'id' ([IO.Path]::GetFileNameWithoutExtension($Path)))
        $dial = 3
        $d = Get-PromptParleProp $obj 'dial'
        if ($null -ne $d) { try { $dial = [int]$d } catch { $dial = 3 } }
        $toolsRaw = Get-PromptParleProp $obj 'tools' @('files', 'workspace', 'secret_scan')
        $tools = @()
        foreach ($t in @($toolsRaw)) {
            if ($t -and "$t".Trim()) { $tools += [string]$t }
        }
        if ($tools.Count -eq 0) { $tools = @('files', 'workspace', 'secret_scan') }
        return [pscustomobject]@{
            id          = $id
            name        = [string](Get-PromptParleProp $obj 'name' $id)
            description = [string](Get-PromptParleProp $obj 'description' '')
            system      = [string](Get-PromptParleProp $obj 'system' '')
            profile     = [string](Get-PromptParleProp $obj 'profile' 'general')
            dial        = $dial
            commands    = $cmds
            tools       = $tools
            path        = $Path
            builtin     = @('auto', 'default', 'security', 'docs', 'code') -contains $id
        }
    } catch {
        return $null
    }
}

function Get-PromptParleAgent {
    <#
    .SYNOPSIS
      Get one local agent by id or name.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)
    Initialize-PromptParleDefaultAgents
    $dir = Get-PromptParleAgentsDir
    $want = ConvertTo-PromptParleAgentId $Name
    $byId = Join-Path $dir ($want + '.json')
    if (Test-Path -LiteralPath $byId) {
        return Read-PromptParleAgentFile -Path $byId
    }
    foreach ($f in (Get-ChildItem -LiteralPath $dir -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
        $a = Read-PromptParleAgentFile -Path $f.FullName
        if ($null -eq $a) { continue }
        if ($a.id -eq $want -or $a.name -eq $Name -or $a.name.ToLowerInvariant() -eq $Name.ToLowerInvariant()) {
            return $a
        }
    }
    return $null
}

function Get-PromptParleAgentList {
    <#
    .SYNOPSIS
      List local agents (free desktop). Cloud shared libraries come later.
    #>
    [CmdletBinding()]
    param()
    Initialize-PromptParleDefaultAgents
    $dir = Get-PromptParleAgentsDir
    $list = New-Object System.Collections.Generic.List[object]
    foreach ($f in (Get-ChildItem -LiteralPath $dir -Filter '*.json' -File -ErrorAction SilentlyContinue | Sort-Object Name)) {
        $a = Read-PromptParleAgentFile -Path $f.FullName
        if ($a) { $list.Add($a) }
    }
    return @($list.ToArray())
}

function Save-PromptParleAgent {
    <#
    .SYNOPSIS
      Create or update a local agent definition (tools run on this PC first).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [string]$System = '',
        [string]$Profile = 'general',
        [ValidateRange(1, 5)][int]$Dial = 3,
        [hashtable]$Commands,
        [string]$Description = '',
        [string]$Id,
        [string[]]$Tools
    )
    Initialize-PromptParleDefaultAgents
    if (-not $Id) { $Id = ConvertTo-PromptParleAgentId $Name }
    if (-not $Commands) { $Commands = @{} }
    if (-not $Tools -or $Tools.Count -eq 0) {
        $Tools = @('files', 'workspace', 'secret_scan')
    }
    # Keep only known tool ids
    $known = @{}
    foreach ($t in @(Get-PromptParleToolCatalog)) { $known[[string]$t.id] = $true }
    $cleanTools = @()
    foreach ($t in @($Tools)) {
        $tid = [string]$t
        if ($tid -and $known.ContainsKey($tid)) { $cleanTools += $tid }
    }
    if ($cleanTools.Count -eq 0) { $cleanTools = @('files', 'workspace', 'secret_scan') }

    $path = Join-Path (Get-PromptParleAgentsDir) ($Id + '.json')
    $cmdObj = [ordered]@{}
    foreach ($k in $Commands.Keys) { $cmdObj[[string]$k] = [string]$Commands[$k] }
    $out = [ordered]@{
        id          = $Id
        name        = $Name
        description = $Description
        system      = $System
        profile     = $Profile
        dial        = $Dial
        commands    = $cmdObj
        tools       = @($cleanTools)
        updated_at  = (Get-Date).ToString('o')
    }
    ($out | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $path -Encoding UTF8
    return Get-PromptParleAgent -Name $Id
}

function Remove-PromptParleAgent {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)
    $a = Get-PromptParleAgent -Name $Name
    if (-not $a) { throw "Agent not found: $Name" }
    if ($a.id -eq 'default') { throw 'Cannot remove the default agent.' }
    Remove-Item -LiteralPath $a.path -Force
    $active = Get-PromptParleActiveAgentId
    if ($active -eq $a.id) { Set-PromptParleActiveAgent -Name 'default' | Out-Null }
    return $true
}

function Get-PromptParleActiveAgentId {
    $path = Get-PromptParleSessionStatePath
    if (Test-Path -LiteralPath $path) {
        try {
            $s = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
            $id = Get-PromptParleProp $s 'active_agent'
            if ($id) {
                # Legacy: bare 'default' as sticky → Auto router
                if ([string]$id -eq 'default') { return 'auto' }
                return [string]$id
            }
        } catch { }
    }
    return 'auto'
}

function Get-PromptParleSessionState {
    $path = Get-PromptParleSessionStatePath
    $state = [ordered]@{
        active_agent      = 'none'
        provider          = 'openai'
        profile           = 'general'
        dial              = 3
        model             = $null
        optimize_only     = $false
        tools_enabled     = $true
        workspace_path    = ''
        workspace_kind    = 'none'
        workspace_recent  = @()
        ssh_target        = ''
        ssh_port          = 22
        ssh_cwd           = ''
        # 0.15: durable product bind (monorepo root + live deploy) — not per-turn keyword packs
        product_root      = ''
        product_live      = ''
        # 0.18 sticky open obligation (document/implement contract across short follow-ups)
        open_obligation_kind       = ''
        open_obligation_artifact   = ''
        open_obligation_source     = ''
        open_obligation_source_ref = ''
    }
    if (Test-Path -LiteralPath $path) {
        try {
            $s = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
            foreach ($k in @('active_agent', 'provider', 'profile', 'model', 'workspace_path', 'workspace_kind', 'ssh_target', 'ssh_cwd', 'product_root', 'product_live', 'open_obligation_kind', 'open_obligation_artifact', 'open_obligation_source', 'open_obligation_source_ref')) {
                $v = Get-PromptParleProp $s $k
                if ($null -ne $v -and "$v" -ne '') { $state[$k] = [string]$v }
            }
            $d = Get-PromptParleProp $s 'dial'
            if ($null -ne $d) { try { $state.dial = [int]$d } catch { } }
            $o = Get-PromptParleProp $s 'optimize_only'
            if ($null -ne $o) { $state.optimize_only = [bool]$o }
            # Default ON when key missing (older session.json)
            $te = Get-PromptParleProp $s 'tools_enabled' $null
            if ($null -ne $te) { $state.tools_enabled = [bool]$te } else { $state.tools_enabled = $true }
            $sp = Get-PromptParleProp $s 'ssh_port'
            if ($null -ne $sp) { try { $state.ssh_port = [int]$sp } catch { } }
            $rec = Get-PromptParleProp $s 'workspace_recent'
            if ($null -ne $rec) {
                $list = @()
                foreach ($item in @($rec)) {
                    if ($item -and "$item".Trim()) { $list += [string]$item }
                }
                $state.workspace_recent = $list
            }
        } catch { }
    }
    # Deterministic default is Auto (legacy sessions with 'default' promote to auto)
    # Agents retired 0.14 — keep active_agent field for old session JSON only
    if (-not $state.active_agent) {
        $state.active_agent = 'none'
    }
    # Never let a stored agent override dial/profile (dial is the only aggressiveness knob)
    $agent = $null
    try { $agent = Get-PromptParleAgent -Name $state.active_agent } catch { $agent = $null }
    if ($agent) {
        $state.agent = [ordered]@{
            id          = $agent.id
            name        = $agent.name
            description = $agent.description
            system      = $agent.system
            profile     = 'general'
            dial        = $state.dial
            commands    = $agent.commands
        }
    }
    return [pscustomobject]$state
}

function New-PromptParleSessionSnapshot {
    <#
    .SYNOPSIS
      Build a session object, preserving workspace/ssh fields from base state.
    #>
    param(
        $Base,
        [string]$ActiveAgent,
        [string]$Provider,
        [string]$Profile,
        [int]$Dial = -1,
        $Model = $null,
        $OptimizeOnly = $null,
        $ToolsEnabled = $null,
        [string]$WorkspacePath,
        [string]$WorkspaceKind,
        $WorkspaceRecent = $null,
        [string]$SshTarget,
        $SshPort = $null,
        [string]$SshCwd,
        [string]$ProductRoot,
        [string]$ProductLive,
        [string]$OpenObligationKind,
        [string]$OpenObligationArtifact,
        [string]$OpenObligationSource,
        [string]$OpenObligationSourceRef
    )
    if (-not $Base) { $Base = Get-PromptParleSessionState }
    $recent = @()
    if ($null -ne $WorkspaceRecent) {
        foreach ($item in @($WorkspaceRecent)) {
            if ($item -and "$item".Trim()) { $recent += [string]$item }
        }
    } else {
        $baseRec = Get-PromptParleProp $Base 'workspace_recent'
        if ($null -ne $baseRec) {
            foreach ($item in @($baseRec)) {
                if ($item -and "$item".Trim()) { $recent += [string]$item }
            }
        }
    }
    $toolsEn = $true
    if ($null -ne $ToolsEnabled) {
        $toolsEn = [bool]$ToolsEnabled
    } else {
        $baseTe = Get-PromptParleProp $Base 'tools_enabled' $null
        if ($null -ne $baseTe) { $toolsEn = [bool]$baseTe } else { $toolsEn = $true }
    }
    $out = [ordered]@{
        active_agent     = if ($PSBoundParameters.ContainsKey('ActiveAgent') -and $ActiveAgent) { $ActiveAgent } else { [string](Get-PromptParleProp $Base 'active_agent' 'default') }
        provider         = if ($PSBoundParameters.ContainsKey('Provider') -and $Provider) { $Provider } else { [string](Get-PromptParleProp $Base 'provider' 'openai') }
        profile          = if ($PSBoundParameters.ContainsKey('Profile') -and $Profile) { $Profile } else { [string](Get-PromptParleProp $Base 'profile' 'general') }
        dial             = if ($Dial -ge 1) { $Dial } else { [int](Get-PromptParleProp $Base 'dial' 3) }
        model            = if ($PSBoundParameters.ContainsKey('Model')) { $Model } else { Get-PromptParleProp $Base 'model' $null }
        optimize_only    = if ($null -ne $OptimizeOnly) { [bool]$OptimizeOnly } else { [bool](Get-PromptParleProp $Base 'optimize_only' $false) }
        tools_enabled    = $toolsEn
        workspace_path   = if ($PSBoundParameters.ContainsKey('WorkspacePath')) { [string]$WorkspacePath } else { [string](Get-PromptParleProp $Base 'workspace_path' '') }
        workspace_kind   = if ($PSBoundParameters.ContainsKey('WorkspaceKind')) { [string]$WorkspaceKind } else { [string](Get-PromptParleProp $Base 'workspace_kind' 'none') }
        workspace_recent = $recent
        ssh_target       = if ($PSBoundParameters.ContainsKey('SshTarget')) { [string]$SshTarget } else { [string](Get-PromptParleProp $Base 'ssh_target' '') }
        ssh_port         = if ($null -ne $SshPort) { [int]$SshPort } else { [int](Get-PromptParleProp $Base 'ssh_port' 22) }
        ssh_cwd          = if ($PSBoundParameters.ContainsKey('SshCwd')) { [string]$SshCwd } else { [string](Get-PromptParleProp $Base 'ssh_cwd' '') }
        product_root     = if ($PSBoundParameters.ContainsKey('ProductRoot')) { [string]$ProductRoot } else { [string](Get-PromptParleProp $Base 'product_root' '') }
        product_live     = if ($PSBoundParameters.ContainsKey('ProductLive')) { [string]$ProductLive } else { [string](Get-PromptParleProp $Base 'product_live' '') }
        open_obligation_kind       = if ($PSBoundParameters.ContainsKey('OpenObligationKind')) { [string]$OpenObligationKind } else { [string](Get-PromptParleProp $Base 'open_obligation_kind' '') }
        open_obligation_artifact   = if ($PSBoundParameters.ContainsKey('OpenObligationArtifact')) { [string]$OpenObligationArtifact } else { [string](Get-PromptParleProp $Base 'open_obligation_artifact' '') }
        open_obligation_source     = if ($PSBoundParameters.ContainsKey('OpenObligationSource')) { [string]$OpenObligationSource } else { [string](Get-PromptParleProp $Base 'open_obligation_source' '') }
        open_obligation_source_ref = if ($PSBoundParameters.ContainsKey('OpenObligationSourceRef')) { [string]$OpenObligationSourceRef } else { [string](Get-PromptParleProp $Base 'open_obligation_source_ref' '') }
    }
    return [pscustomobject]$out
}

function Save-PromptParleSessionState {
    param($State)
    $path = Get-PromptParleSessionStatePath
    $dir = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $recent = @()
    $recRaw = Get-PromptParleProp $State 'workspace_recent'
    if ($null -ne $recRaw) {
        foreach ($item in @($recRaw)) {
            if ($item -and "$item".Trim()) { $recent += [string]$item }
        }
    }
    $toolsEnSave = Get-PromptParleProp $State 'tools_enabled' $null
    if ($null -eq $toolsEnSave) { $toolsEnSave = $true } else { $toolsEnSave = [bool]$toolsEnSave }
    $out = [ordered]@{
        active_agent     = [string](Get-PromptParleProp $State 'active_agent' 'default')
        provider         = [string](Get-PromptParleProp $State 'provider' 'openai')
        profile          = [string](Get-PromptParleProp $State 'profile' 'general')
        dial             = [int](Get-PromptParleProp $State 'dial' 3)
        model            = Get-PromptParleProp $State 'model' $null
        optimize_only    = [bool](Get-PromptParleProp $State 'optimize_only' $false)
        tools_enabled    = $toolsEnSave
        workspace_path   = [string](Get-PromptParleProp $State 'workspace_path' '')
        workspace_kind   = [string](Get-PromptParleProp $State 'workspace_kind' 'none')
        workspace_recent = $recent
        ssh_target       = [string](Get-PromptParleProp $State 'ssh_target' '')
        ssh_port         = [int](Get-PromptParleProp $State 'ssh_port' 22)
        ssh_cwd          = [string](Get-PromptParleProp $State 'ssh_cwd' '')
        product_root     = [string](Get-PromptParleProp $State 'product_root' '')
        product_live     = [string](Get-PromptParleProp $State 'product_live' '')
        open_obligation_kind       = [string](Get-PromptParleProp $State 'open_obligation_kind' '')
        open_obligation_artifact   = [string](Get-PromptParleProp $State 'open_obligation_artifact' '')
        open_obligation_source     = [string](Get-PromptParleProp $State 'open_obligation_source' '')
        open_obligation_source_ref = [string](Get-PromptParleProp $State 'open_obligation_source_ref' '')
        updated_at       = (Get-Date).ToString('o')
    }
    ($out | ConvertTo-Json -Depth 4) | Set-Content -LiteralPath $path -Encoding UTF8
}

function Set-PromptParleActiveAgent {
    <#
    .SYNOPSIS
      Activate a local agent (applies profile + dial defaults).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)
    $agent = Get-PromptParleAgent -Name $Name
    if (-not $agent) { throw "Agent not found: $Name" }
    $state = Get-PromptParleSessionState
    $state = New-PromptParleSessionSnapshot -Base $state -ActiveAgent $agent.id -Profile $agent.profile -Dial $agent.dial
    Save-PromptParleSessionState -State $state
    return $agent
}

function Get-PromptParlePromptIntent {
    <#
    .SYNOPSIS
      Classify THIS user message for turn-level agent routing.
      Doctrine: sticky agent is a preference, not a prison.
    #>
    [CmdletBinding()]
    param([string]$Prompt = '')
    $p = if ($null -eq $Prompt) { '' } else { $Prompt.ToLowerInvariant() }
    if (-not $p.Trim()) { return 'general' }

    # Meta / product / agent UX — always escape specialized corridors
    if ($p -match '(?i)\b(agent|agents|stuck on|keep (saying|telling)|narrow corridor|wrong agent|switch agent|how (do|should) agents|agent use|not (working|correct) with agent|why does (my )?(pp|promptparle)|these agents)\b') {
        return 'meta'
    }
    if ($p -match '(?i)\b(handoff|continue (from|the session)|session hand)\b') {
        return 'product'
    }
    # Talking ABOUT a prior finding vs asking for a new security review
    if ($p -match '(?i)\b(why (does|do|is|are)|keep (saying|telling)|is (this|that) (wrong|correct|accurate|true)|false positive|overblown|do you agree|not a (real )?risk)\b') {
        return 'meta'
    }

    $secStrong = $p -match '(?i)\b(security review|secure code review|audit (this|the|for)|threat model|penetration test|owasp|find (vulnerabilit|cve|exploit)|is this (code |file )?(safe|vulnerable)|review .{0,40} for security)\b'
    $secWeak = $p -match '(?i)\b(vulnerab|exploit|cve-|cve\b|injection|xss|csrf|rce\b|privilege.?escalat|eop\b)\b'
    if ($secStrong) { return 'security' }
    if ($secWeak -and $p -match '(?i)\b(review|audit|scan|check|assess)\b') { return 'security' }

    if ($p -match '(?i)\b(implement|refactor|bug|fix|function|class|typescript|javascript|python|powershell|api endpoint|stack trace|compile error)\b') {
        return 'code'
    }
    if ($p -match '(?i)\b(document|documentation|policy|obligation|compliance|summarize (the )?(doc|spec|manual)|readme)\b') {
        return 'docs'
    }
    if ($p -match '(?i)\b(syslog|splunk|siem|trace log|log line|error log)\b') {
        return 'logs'
    }
    if ($p -match '(?i)\b(ship|release|version|update client|product|feature|ux|ui)\b') {
        return 'product'
    }
    return 'general'
}

function Get-PromptParleDeterministicLens {
    <#
    .SYNOPSIS
      Fixed intent → agent/profile map (no model choice). Same input → same lens.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Intent
    )
    switch ($Intent) {
        'security' {
            return [pscustomobject]@{ agent_id = 'security'; profile = 'security-review'; dial = 3; label = 'Security' }
        }
        'code' {
            return [pscustomobject]@{ agent_id = 'code'; profile = 'developer'; dial = 2; label = 'Code' }
        }
        'docs' {
            return [pscustomobject]@{ agent_id = 'docs'; profile = 'documentation'; dial = 3; label = 'Docs' }
        }
        'logs' {
            return [pscustomobject]@{ agent_id = 'default'; profile = 'log-analysis'; dial = 4; label = 'Logs' }
        }
        'meta' {
            return [pscustomobject]@{ agent_id = 'default'; profile = 'general'; dial = 3; label = 'General' }
        }
        'product' {
            return [pscustomobject]@{ agent_id = 'default'; profile = 'general'; dial = 3; label = 'General' }
        }
        default {
            return [pscustomobject]@{ agent_id = 'default'; profile = 'general'; dial = 3; label = 'General' }
        }
    }
}

function Test-PromptParleAutoRouterAgent {
    <# True when sticky selection means "pick best lens each turn". #>
    param([string]$AgentId)
    $id = if ($AgentId) { $AgentId.ToLowerInvariant() } else { 'auto' }
    return ($id -eq 'auto' -or $id -eq 'default' -or $id -eq '' -or $id -eq 'general')
}

function Resolve-PromptParleTurnLens {
    <#
    .SYNOPSIS
      Retired 0.14 — agents/lenses removed. Always general; dial owns shrink.
      Kept as a no-op for any old callers.
    #>
    [CmdletBinding()]
    param(
        [string]$Prompt = '',
        [string]$StickyAgentId = 'auto',
        [string]$StickyProfile = 'general',
        [switch]$AgentLocked
    )
    return [pscustomobject]@{
        intent         = 'general'
        agent_id       = 'none'
        profile        = 'general'
        sticky_agent   = 'none'
        sticky_profile = 'general'
        override       = $false
        reason         = 'agents retired — dial-only optimize'
        doctrine       = ''
        locked         = $false
        mode           = 'none'
        lens_label     = 'Chat'
        dial_hint      = $null
    }
}

function Get-PromptParleChatSystemPrompt {
    <#
    .SYNOPSIS
      0.19: normal AI eng client — brain (API) + hands (this PC/SSH/web).
      Primary product goal: fewest tokens that still get real work done.
      Experience must match Claude/Cursor/Grok Build — natural, not boxed.
    #>
    return @(
        'You are a capable engineering assistant in a continuous connected session (same feel as Grok Build / Claude / Cursor). Natural language only — no modes for the user.',
        'BRAIN + HANDS: You are the brain (this API). PromptParle on the user PC is the hands: local workspace, SSH/remote product bind, web fetch, apply/run, document deliver. Prefer hands over guessing.',
        'TOKEN DISCIPLINE (non-negotiable): minimize tokens. Do not restate large evidence. Do not dump full files unless required. Prefer short targeted hands requests over long essays. One clear plan, then act.',
        'HANDS PROTOCOL: When you need evidence you do not have, emit ONLY a fenced hands block with lines tool: arg — then stop. Tools: web_search, web_page, ssh_list, ssh_read, ssh_run, workspace_find, relevant_slice, file_index, git_diff, git, connections, tree_pack. Client runs them (0 AI tokens) and returns [HANDS] results. Then answer from results.',
        'FORBIDDEN: never emit toolcall/tool_call/function_call XML, HTML tool tags, or any foreign tool protocol. Never show raw tool markup to the user. Only ```hands fences. If [OBSERVE]/[WEB] already present, answer from that — do not re-search as theater.',
        'When evidence is enough: answer or implement. NEVER answer with the method (no run-ls homework, no search-yourself, no toolcall dumps) when hands/observe can do it. NEVER Generating-now without a file fence body for user documents.',
        'MUTATE: apply path=rel full files under source_root (client writes, backups, never live /var/www). run allowlisted pipeline only (prisma/npm/git status-class). Client reports What changed.',
        'DELIVER: user docs need file name=Report.md (pdf/docx/xlsx/csv/md/txt/html/json) with FULL body. Client builds download.',
        'PLAN: for non-trivial mutate, brief plan + blast radius in few lines; on clear go-ahead implement same turn. Tags CONN PROJECT SSH MEM ATTACH WEB OBSERVE HANDS GROUNDING PROVENANCE are live evidence — trust them over memory invention.',
        'GROUNDING 0.20: When [OBSERVE]/[WEB]/[GROUNDING] present, state ONLY facts supported by that text. Never invent capabilities (e.g. honeypots) not in the fetch.',
        'PROVENANCE 0.20: When [PROVENANCE] is present, you MUST report client YES/NO facts: on-source or not, and if prior assistant invented the claim say so explicitly. Never answer only "nowhere" without saying where the phrase entered the chat.',
        'QUALITY GATE 0.21: Client post-pass scores claims against evidence and may strike unverified product terms. Prefer source-backed wording so the gate stays clean.',
        'Opaque outcomes are bugs: hands result, apply/run/file, provenance facts, quality score, or one hard blocker.'
    ) -join ' '
}

function Get-PromptParleTurnKind {
    <#
    .SYNOPSIS
      Prep-depth hint only — NOT "does the model understand English".
      The model already understands "lets do it" / "just get it done".
      We only classify so prep pulls enough code / forces apply directive.
      question | implement | chat
    #>
    param(
        [string]$Prompt = '',
        [object[]]$History = @()
    )
    $p = if ($null -eq $Prompt) { '' } else { $Prompt.Trim() }
    if (-not $p) { return 'chat' }

    # Pure questions first (but not "how do I implement" style — those still need code)
    $looksQuestion = (
        $p -match '\?\s*$' `
        -or $p -match '(?i)^\s*(where|what|why|when|who|which|is |are |can |does |did |should |could |would |read |show |explain |list |find |tell me)\b' `
        -or $p -match '(?i)\b(where is|is it in|in the handoff|look at the handoff|what does)\b'
    ) -and ($p -notmatch '(?i)\b(implement|fix|add|build|change|do it|get it done)\b')

    # Natural go-ahead / act language (same phrases a human assistant understands)
    $looksAct = (
        $p -match '(?i)\b(implement|build|ship|fix|add|create|patch|change|rename|bump|deploy|wire|refactor|apply)\b' `
        -or $p -match '(?i)\b(lets? do|do it|do this|do that|just do|go ahead|ship it|make (the )?change|get it (done|implemented)|make it so|stop asking|wasting tokens|dont ask|don''t ask|enough talking|just get)\b' `
        -or $p -match '(?i)^\s*(yes|yep|yeah|ok|okay|sure|please|proceed|continue|same|go)\b' `
        -or $p -match '(?i)\b(i leave .{0,40} to you|best .{0,20} option|you (choose|decide|pick))\b'
    )

    if ($looksAct) { return 'implement' }

    # Sticky: open work in recent history + any non-pure-question follow-up = implement depth
    # (so "yes" / "where is it" after a feature ask still gets code evidence + directive when act-like)
    try {
        if ($History -and $History.Count -gt 0) {
            $recent = New-Object System.Text.StringBuilder
            $n = 0
            for ($i = $History.Count - 1; $i -ge 0 -and $n -lt 8; $i--) {
                $hr = [string](Get-PromptParleProp $History[$i] 'role' 'user')
                $ht = [string](Get-PromptParleProp $History[$i] 'text' (Get-PromptParleProp $History[$i] 'content' ''))
                if ($hr -match '(?i)user|human') {
                    [void]$recent.AppendLine($ht)
                    $n++
                }
            }
            $histText = $recent.ToString()
            $openWork = $histText -match '(?i)\b(implement|add |build |fix |network security|cidr|allowlist|feature|settings|portal|ip/?)\b'
            if ($openWork -and -not $looksQuestion) { return 'implement' }
            if ($openWork -and $looksQuestion -and $p -match '(?i)\b(where did you|dont see|don''t see|not in|missing|ui|interface|settings)\b') {
                # User checking for landed work — still implement depth so we can finish, not re-plan
                return 'implement'
            }
        }
    } catch { }

    if ($looksQuestion) { return 'question' }
    return 'chat'
}

function Resolve-PromptParleProductBind {
    <#
    .SYNOPSIS
      Durable product roots for this session. Prefer saved bind; else infer from SSH/workspace.
      Mapping handoff cwd is NOT product root — monorepo is.
    #>
    [CmdletBinding()]
    param()
    $defaultRoot = '/home/ubuntu/projects/promptparle'
    $defaultLive = '/var/www/promptparle'
    $root = ''
    $live = ''
    $src = 'default'
    try {
        $st = Get-PromptParleSessionState
        $root = [string](Get-PromptParleProp $st 'product_root' '')
        $live = [string](Get-PromptParleProp $st 'product_live' '')
        if ($root) { $src = 'session' }
        $sshCwd = [string](Get-PromptParleProp $st 'ssh_cwd' '')
        $wsPath = [string](Get-PromptParleProp $st 'workspace_path' '')
        if (-not $root) {
            if ($sshCwd -match '(?i)/promptparle/?$') {
                $root = $sshCwd.TrimEnd('/\')
                $src = 'ssh_cwd'
            } elseif ($sshCwd -match '(?i)ExampleCorp-Mapping') {
                # Handoff mirror only — bind monorepo
                $root = $defaultRoot
                $src = 'handoff_mirror→monorepo'
            } elseif ($wsPath -match '(?i)promptparle') {
                $root = $wsPath
                $src = 'workspace'
            } elseif ([string](Get-PromptParleProp $st 'ssh_target' '')) {
                # SSH up, no better signal — product host default
                $root = $defaultRoot
                $src = 'ssh_host_default'
            }
        }
        if (-not $live) {
            if ($root -eq $defaultRoot -or $root -match '(?i)/promptparle') {
                $live = $defaultLive
            }
        }
    } catch {
        $root = $defaultRoot
        $live = $defaultLive
        $src = 'fallback'
    }
    if (-not $root) { $root = $defaultRoot; if ($src -eq 'default') { $src = 'product_default' } }
    if (-not $live) { $live = $defaultLive }
    # Persist bind so next turns don't re-infer from bad cwd
    try {
        $st2 = Get-PromptParleSessionState
        $needSave = $false
        if (-not [string](Get-PromptParleProp $st2 'product_root' '')) {
            $st2 = New-PromptParleSessionSnapshot -Base $st2 -ProductRoot $root -ProductLive $live
            $needSave = $true
        } elseif (-not [string](Get-PromptParleProp $st2 'product_live' '')) {
            $st2 = New-PromptParleSessionSnapshot -Base $st2 -ProductLive $live
            $needSave = $true
        }
        if ($needSave) { Save-PromptParleSessionState -State $st2 }
    } catch { }
    return [pscustomobject]@{
        root   = $root
        live   = $live
        public = ($live.TrimEnd('/\') + '/public')
        source = $src
    }
}

function Get-PromptParleProjectCard {
    <#
    .SYNOPSIS
      Always-on tiny project map (~150-250 tokens). Architecture layer — not a one-off pack.
    #>
    [CmdletBinding()]
    param(
        [string]$TurnKind = 'chat'
    )
    $b = Resolve-PromptParleProductBind
    $lines = @(
        '[PROJECT] product bind (always — handoff/docs are maps into these roots)',
        "source_root: $($b.root)",
        "live_app: $($b.live)",
        "live_public: $($b.public)",
        'layout: portal=src/app + prisma + src/lib · desktop=powershell/PromptParle (+ local-ui) · ship=public/ + live_public',
        "bind: $($b.source) · turn: $TurnKind",
        'rule: answer from [PROJECT]/evidence; implement under source_root; deploy to live_*; do not claim portal missing because only a handoff mirror was in SSH cwd'
    )
    return ($lines -join "`n")
}

function Get-PromptParleChatFraming {
    <#
    .SYNOPSIS
      Build native system + runtime + user parts (0.14.12+).
      Prefer this over Format-PromptParleAgentPrompt (which bakes into one string).
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Prompt,
        [string]$RuntimeNote = ''
    )
    $sys = Get-PromptParleChatSystemPrompt
    $rt = if ($RuntimeNote) { $RuntimeNote.Trim() } else {
        'Evidence tags may include [PROJECT][CONN][SSH][MEM]. Be a normal assistant: answer or implement from evidence.'
    }
    return [pscustomobject]@{
        System  = $sys
        Runtime = $rt
        Prompt  = $Prompt
    }
}

function Format-PromptParleAgentPrompt {
    <#
    .SYNOPSIS
      Legacy: bake system + runtime into one user string.
      Prefer Get-PromptParleChatFraming + Invoke-PromptParle -System/-Runtime (0.14.12+).
      AgentId/Doctrine/TurnNote kept for call-site compat; ignored.
    #>
    param(
        [string]$Prompt,
        [string]$AgentId,
        [string]$Doctrine = '',
        [string]$TurnNote = '',
        [string]$RuntimeNote = ''
    )
    $f = Get-PromptParleChatFraming -Prompt $Prompt -RuntimeNote $RuntimeNote
    return ("[SYS] {0}`n[RT] {1}`n[USER]`n{2}" -f $f.System, $f.Runtime, $f.Prompt)
}

#region Local-first tools (run on this PC before AI tokens are spent)

function Get-PromptParleToolCatalog {
    <#
    .SYNOPSIS
      Base tools available to local agents. All run on the user's machine first.
    #>
    [CmdletBinding()]
    param()
    return @(
        [pscustomobject]@{
            id = 'files'; name = 'Files / attach'
            category = 'project'; local = $true
            description = 'Attach files from this PC into chat context.'
            auto = $false
        },
        [pscustomobject]@{
            id = 'workspace'; name = 'Workspace'
            category = 'project'; local = $true
            description = 'Attach a project folder; ls / tree / cat / pack stay local.'
            auto = $false
        },
        [pscustomobject]@{
            id = 'git'; name = 'Git / GitHub'
            category = 'project'; local = $true
            description = 'status, diff, log, clone using YOUR local git credentials.'
            auto = $false
        },
        [pscustomobject]@{
            id = 'ssh'; name = 'SSH'
            category = 'project'; local = $true
            description = 'Remote ls/cat/run; private keys never leave this machine.'
            auto = $false
        },
        [pscustomobject]@{
            id = 'secret_scan'; name = 'Secret scan'
            category = 'security'; local = $true
            description = 'Mask keys/tokens before send.'
            auto = $true
        },
        [pscustomobject]@{
            id = 'code_brief'; name = 'Code brief'
            category = 'optimize'; local = $true
            description = 'Local shrink: comments, blanks, dups, long lines. Dial = budget.'
            auto = $true
        },
        [pscustomobject]@{
            id = 'file_index'; name = 'File index'
            category = 'optimize'; local = $true
            description = 'Tiny ext/count map — not a file dump.'
            auto = $true
        },
        [pscustomobject]@{
            id = 'deps'; name = 'Deps map'
            category = 'optimize'; local = $true
            description = 'Brief package names/versions only.'
            auto = $true
        },
        [pscustomobject]@{
            id = 'git_diff'; name = 'Git diff pack'
            category = 'optimize'; local = $true
            description = 'Short diff/stat beats whole files.'
            auto = $true
        },
        [pscustomobject]@{
            id = 'tree_pack'; name = 'Tree pack'
            category = 'optimize'; local = $true
            description = 'Shallow tree (prefer index when auto).'
            auto = $true
        },
        [pscustomobject]@{
            id = 'connections'; name = 'Project connections'
            category = 'project'; local = $true
            description = 'Ultra-brief PC / Git / SSH session map (always injected).'
            auto = $true
        },
        [pscustomobject]@{
            id = 'web_search'; name = 'Web search'
            category = 'research'; local = $true
            description = 'Brief web results (DDG + Wikipedia); cached, char-capped.'
            auto = $true
        },
        [pscustomobject]@{
            id = 'error_brief'; name = 'Error brief'
            category = 'optimize'; local = $true
            description = 'Keep exceptions/stacks; drop DEBUG spam (high fidelity).'
            auto = $true
        },
        [pscustomobject]@{
            id = 'relevant_slice'; name = 'Relevant slice'
            category = 'optimize'; local = $true
            description = 'Prompt-ranked code windows from workspace (select, not destroy).'
            auto = $true
        },
        [pscustomobject]@{
            id = 'chat_memory'; name = 'Chat memory'
            category = 'optimize'; local = $true
            description = 'Prior turns → compact [MEM] brief (recent full, older extractive).'
            auto = $true
        }
    )
}

function Get-PromptParleShortPath {
    <# Compact path for connection briefs (~ for home). #>
    param([string]$Path)
    if (-not $Path) { return '' }
    $p = [string]$Path
    try {
        $home = Get-PromptParleHomePath
        if ($home -and $p.StartsWith($home, [StringComparison]::OrdinalIgnoreCase)) {
            $rest = $p.Substring($home.Length).TrimStart('\', '/')
            if ($rest) { return "~/$rest".Replace('\', '/') }
            return '~'
        }
    } catch { }
    # Prefer leaf + parent for long paths
    try {
        if ($p.Length -gt 48) {
            $leaf = [IO.Path]::GetFileName($p.TrimEnd('\', '/'))
            $parent = [IO.Path]::GetFileName([IO.Path]::GetDirectoryName($p.TrimEnd('\', '/')))
            if ($parent -and $leaf) { return ".../$parent/$leaf" }
            if ($leaf) { return ".../$leaf" }
        }
    } catch { }
    return $p.Replace('\', '/')
}

function Get-PromptParleProjectConnectionsBrief {
    <#
    .SYNOPSIS
      Ultra-brief Project Connections map for every chat turn.
      Doctrine: one block, few lines, cache ~20s — model always knows PC/Git/SSH.
    #>
    [CmdletBinding()]
    param(
        [int]$MaxChars = 520,
        [switch]$Force
    )
    $ws = $null
    try { $ws = Get-PromptParleWorkspace } catch { $ws = $null }
    $key = 'none'
    if ($ws) {
        $key = ("{0}|{1}|{2}|{3}|{4}" -f `
            [string](Get-PromptParleProp $ws 'path' ''), `
            [string](Get-PromptParleProp $ws 'ssh_target' ''), `
            [string](Get-PromptParleProp $ws 'ssh_cwd' ''), `
            [string](Get-PromptParleProp $ws 'ssh_port' '22'), `
            [string](Get-PromptParleProp $ws 'branch' ''))
    }
    $now = [datetime]::UtcNow
    if (-not $Force -and $script:PromptParleConnBriefCache.key -eq $key -and `
        $script:PromptParleConnBriefCache.text -and `
        ($now - $script:PromptParleConnBriefCache.at).TotalSeconds -lt 20) {
        return [string]$script:PromptParleConnBriefCache.text
    }

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('[CONN] Project connections (this session — local PC)')

    # PC / workspace
    if ($ws -and $ws.path) {
        $short = Get-PromptParleShortPath -Path ([string]$ws.path)
        $bits = New-Object System.Collections.Generic.List[string]
        $bits.Add($short)
        if ($ws.exists) {
            if ($ws.is_git) {
                $bits.Add('git')
                if ($ws.branch) { $bits.Add([string]$ws.branch) }
            } else {
                $bits.Add([string](Get-PromptParleProp $ws 'kind' 'folder'))
            }
        } else {
            $bits.Add('MISSING')
        }
        $pcLine = 'PC: ' + ($bits -join ' · ')
        if ($ws.is_git -and $ws.remote) {
            $rem = [string]$ws.remote
            if ($rem.Length -gt 56) { $rem = $rem.Substring(0, 53) + '…' }
            $pcLine += " | origin $rem"
        }
        $lines.Add($pcLine)
    } else {
        $lines.Add('PC: none — attach via Project connections / /workspace <path>')
    }

    # SSH
    $sshT = if ($ws) { [string](Get-PromptParleProp $ws 'ssh_target' '') } else { '' }
    if ($sshT) {
        $port = if ($ws) { [int](Get-PromptParleProp $ws 'ssh_port' 22) } else { 22 }
        $cwd = if ($ws) { [string](Get-PromptParleProp $ws 'ssh_cwd' '') } else { '' }
        $sshLine = "SSH: ${sshT}:$port"
        if ($cwd) { $sshLine += " cwd $(Get-PromptParleShortPath -Path $cwd)" }
        $lines.Add($sshLine)
    } else {
        $lines.Add('SSH: none — /ssh user@host [cwd]')
    }

    # Git tooling availability (not a full status dump)
    $gitOk = Test-PromptParleCommandAvailable -Name 'git'
    $lines.Add($(if ($gitOk) { 'Git: available on this PC' } else { 'Git: not found on PATH' }))

    if ($sshT -and $cwd) {
        $lines.Add('SSH cwd is LIVE — relative names resolve there; files named in the user message are auto-fetched into [SSH] when found.')
    } else {
        $lines.Add('Use attached workspace/SSH evidence; do not invent paths. Web facts → web_search.')
    }
    $text = ($lines -join "`n")
    if ($text.Length -gt $MaxChars) {
        $text = $text.Substring(0, $MaxChars) + "`n…[conn]"
    }
    $script:PromptParleConnBriefCache = @{ key = $key; text = $text; at = $now }
    return $text
}

function Get-PromptParleWebSearchQuery {
    <# Extract a clean search query from a user prompt when auto-triggering. #>
    param([string]$Prompt)
    if (-not $Prompt) { return '' }
    $p = $Prompt.Trim()
    # Prefer explicit URL
    if ($p -match 'https?://[^\s<>"'']+') { return $Matches[0].TrimEnd('.,;:)') }
    # Prefer domain after search/from/of/about
    if ($p -match '(?i)\bsearch\s+([\w.-]+\.[a-z]{2,}(?:\.[a-z]{2,})?)') { return $Matches[1] }
    if ($p -match '(?i)\bfrom\s+(?:the\s+)?([\w.-]+\.[a-z]{2,}(?:\.[a-z]{2,})?)') { return $Matches[1] }
    # "research the strengths of examplecorp.com" → domain + topic (page fetch uses domain; search uses this)
    if ($p -match '(?i)\b([\w.-]+\.(?:com|org|net|io|ai|dev|co))\b') {
        $dom = $Matches[1]
        $topics = New-Object System.Collections.Generic.List[string]
        [void]$topics.Add($dom)
        if ($p -match '(?i)\bstrengths?\b') { [void]$topics.Add('strengths') }
        if ($p -match '(?i)\bcapabilit') { [void]$topics.Add('capabilities') }
        if ($p -match '(?i)\bfeatures?\b') { [void]$topics.Add('features') }
        if ($p -match '(?i)\boverview\b') { [void]$topics.Add('overview') }
        if ($p -match '(?i)\bsolution\b') { [void]$topics.Add('solution') }
        if ($p -match '(?i)\bresearch\b') { [void]$topics.Add('product overview') }
        return ($topics -join ' ')
    }
    # Strip leading search-intent phrases
    $p2 = [regex]::Replace($p, '(?i)^(please\s+)?(can you\s+)?(research|investigate|search(\s+the\s+web)?(\s+for)?|look\s+up|google|find\s+online|web\s+search(\s+for)?|what\s+is|who\s+is|what''?s\s+the\s+latest|docs?\s+for|documentation\s+for|tell me about|explain)\s*[:\-]?\s*', '')
    if (-not $p2) { $p2 = $p }
    # Drop trailing summarize/write clauses
    $p2 = [regex]::Replace($p2, '(?i)\s+and\s+(summarize|summarise|write|create|make|give|tell).*$', '').Trim()
    $p2 = [regex]::Replace($p2, '(?i)\s+I would like to understand.*$', '').Trim()
    # Drop trailing "please" / filler
    $p2 = [regex]::Replace($p2, '(?i)\s+(please|thanks|thank you)[.!?]?\s*$', '').Trim()
    if ($p2.Length -gt 160) { $p2 = $p2.Substring(0, 160).Trim() }
    return $p2
}

function Test-PromptParleWebSearchIntent {
    <# 0.18/0.21: structural web observe — URLs/domains/research verbs, not a phrase mole list. #>
    param([string]$Prompt)
    if (-not $Prompt) { return $false }
    $b = $Prompt.ToLowerInvariant()
    if ($b -match 'https?://') { return $true }
    if ($b -match '(?i)\b(search the web|web search|look up|google|find online|according to (the )?(docs|documentation|internet|web)|on the website|from (their|the) site)\b') { return $true }
    # research / understand / strengths of a product or site
    if ($b -match '(?i)\b(research|investigate|dig into|learn about|tell me about|overview of|strengths?( of)?|weaknesses?( of)?|capabilities of|understand (this |the )?(solution|product|company|platform|site|website))\b') { return $true }
    # "from the website" / "from the X.com website" / "I said from … website"
    if ($b -match '(?i)\bfrom\b.{0,60}\bwebsite\b') { return $true }
    if ($b -match '(?i)\b(not (from )?memory|live site|official site)\b') { return $true }
    if ($b -match '(?i)\bsearch\s+[\w.-]+\.[a-z]{2,}') { return $true }
    if ($b -match '(?i)\b(?:from|on|at|via|of|about|for)\s+(?:the\s+)?[\w.-]+\.(?:com|org|net|io|ai|dev|co|info|biz)\b') { return $true }
    # domain present + research/product language (not only "website/search")
    if ($b -match '(?i)\b[\w.-]+\.(?:com|org|net|io|ai|dev)\b' -and $b -match '(?i)\b(website|web site|site|search|online|url|http|research|strengths?|capabilities|solution|product|platform|company|overview|features?|understand)\b') { return $true }
    # bare public domain as the subject of the ask
    if ($b -match '(?i)\b[\w.-]+\.(?:com|org|net|io|ai|dev)\b' -and $b -match '(?i)\b(can you|please|what|how|why|tell|show|summar|explain)\b') { return $true }
    if ($b -match '(?i)^(what is|who is|what''?s the latest|current version of)\b') { return $true }
    if ($b -match '(?i)\b(latest (news|release|version)|as of 20\d{2})\b') { return $true }
    return $false
}

function Invoke-PromptParleWebSearchLocal {
    <#
    .SYNOPSIS
      Brief multi-source web search on this PC (no AI tokens for the fetch).
      Sources: DuckDuckGo Instant Answer → Wikipedia opensearch/summary.
      Optimized: cache 5m, max N hits, hard char budget, no HTML dumps.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Query,
        [int]$MaxResults = 4,
        [int]$MaxChars = 2400
    )
    $q = if ($null -eq $Query) { '' } else { $Query.Trim() }
    if (-not $q) {
        return [pscustomobject]@{
            ok = $false; tool = 'web_search'; local = $true
            text = ''; notes = @('web_search: empty query'); query = ''
        }
    }
    if ($MaxResults -lt 1) { $MaxResults = 1 }
    if ($MaxResults -gt 6) { $MaxResults = 6 }
    if ($MaxChars -lt 400) { $MaxChars = 400 }
    if ($MaxChars -gt 6000) { $MaxChars = 6000 }

    $cacheKey = ("{0}|{1}|{2}" -f $q.ToLowerInvariant(), $MaxResults, $MaxChars)
    $now = [datetime]::UtcNow
    if ($script:PromptParleWebSearchCache.ContainsKey($cacheKey)) {
        $hit = $script:PromptParleWebSearchCache[$cacheKey]
        if ($hit -and $hit.text -and ($now - $hit.at).TotalSeconds -lt 300) {
            return [pscustomobject]@{
                ok = $true; tool = 'web_search'; local = $true
                text = [string]$hit.text
                notes = @('web_search: cache hit')
                query = $q
                cached = $true
            }
        }
    }

    $ua = 'PromptParle/0.12 (desktop local tools; +https://promptparle.com)'
    $hits = New-Object System.Collections.Generic.List[object]
    $notes = New-Object System.Collections.Generic.List[string]
    $abstract = ''

    # 1) DuckDuckGo Instant Answer (free, no key) — best for entities
    try {
        $enc = [uri]::EscapeDataString($q)
        $ddgUrl = "https://api.duckduckgo.com/?q=$enc&format=json&no_html=1&skip_disambig=1"
        $ddg = Invoke-RestMethod -Uri $ddgUrl -TimeoutSec 12 -Headers @{ 'User-Agent' = $ua } -ErrorAction Stop
        $abs = [string](Get-PromptParleProp $ddg 'AbstractText' '')
        if (-not $abs) { $abs = [string](Get-PromptParleProp $ddg 'Abstract' '') }
        $absUrl = [string](Get-PromptParleProp $ddg 'AbstractURL' '')
        $heading = [string](Get-PromptParleProp $ddg 'Heading' '')
        $answer = [string](Get-PromptParleProp $ddg 'Answer' '')
        if ($answer) {
            $abstract = $answer.Trim()
            $notes.Add('ddg-answer')
        }
        if ($abs) {
            if ($abstract) { $abstract = $abstract + ' ' + $abs.Trim() } else { $abstract = $abs.Trim() }
            $notes.Add('ddg-abstract')
            if ($heading -or $absUrl) {
                $hits.Add([pscustomobject]@{
                    title = if ($heading) { $heading } else { 'DuckDuckGo' }
                    url   = $absUrl
                    snip  = if ($abs.Length -gt 180) { $abs.Substring(0, 177) + '…' } else { $abs }
                })
            }
        }
        $related = Get-PromptParleProp $ddg 'RelatedTopics' @()
        foreach ($rt in @($related)) {
            if ($hits.Count -ge $MaxResults) { break }
            $txt = [string](Get-PromptParleProp $rt 'Text' '')
            $first = Get-PromptParleProp $rt 'FirstURL' $null
            if (-not $txt -and (Get-PromptParleProp $rt 'Topics' $null)) {
                foreach ($sub in @(Get-PromptParleProp $rt 'Topics' @())) {
                    if ($hits.Count -ge $MaxResults) { break }
                    $txt2 = [string](Get-PromptParleProp $sub 'Text' '')
                    $u2 = [string](Get-PromptParleProp $sub 'FirstURL' '')
                    if ($txt2) {
                        $title2 = $txt2
                        if ($txt2 -match '^([^\-–]+)\s*[\-–]') { $title2 = $Matches[1].Trim() }
                        $snip2 = $txt2
                        if ($snip2.Length -gt 160) { $snip2 = $snip2.Substring(0, 157) + '…' }
                        $hits.Add([pscustomobject]@{ title = $title2; url = $u2; snip = $snip2 })
                    }
                }
                continue
            }
            if ($txt) {
                $title = $txt
                if ($txt -match '^([^\-–]+)\s*[\-–]') { $title = $Matches[1].Trim() }
                $snip = $txt
                if ($snip.Length -gt 160) { $snip = $snip.Substring(0, 157) + '…' }
                $hits.Add([pscustomobject]@{
                    title = $title
                    url   = [string]$first
                    snip  = $snip
                })
            }
        }
        if ($hits.Count -gt 0) { $notes.Add("ddg-related:$($hits.Count)") }
    } catch {
        $notes.Add('ddg-skip')
    }

    # 2) Wikipedia opensearch + 1–2 summaries when still thin (reliable, free)
    if ($hits.Count -lt 2 -or -not $abstract) {
        try {
            $enc = [uri]::EscapeDataString($q)
            $osUrl = "https://en.wikipedia.org/w/api.php?action=opensearch&search=$enc&limit=$MaxResults&namespace=0&format=json"
            $os = Invoke-RestMethod -Uri $osUrl -TimeoutSec 12 -Headers @{ 'User-Agent' = $ua } -ErrorAction Stop
            # opensearch: [query, [titles], [descs], [urls]]
            $titles = @()
            $descs = @()
            $urls = @()
            if ($os -is [System.Array] -and $os.Count -ge 4) {
                $titles = @($os[1])
                $descs = @($os[2])
                $urls = @($os[3])
            }
            $wikiAdded = 0
            for ($i = 0; $i -lt $titles.Count -and $hits.Count -lt $MaxResults; $i++) {
                $t = [string]$titles[$i]
                if (-not $t) { continue }
                $u = if ($i -lt $urls.Count) { [string]$urls[$i] } else { '' }
                $d = if ($i -lt $descs.Count) { [string]$descs[$i] } else { '' }
                # Enrich first 2 with REST summary extract
                if ($wikiAdded -lt 2) {
                    try {
                        $canon = ($t -replace ' ', '_')
                        $sumUrl = "https://en.wikipedia.org/api/rest_v1/page/summary/$([uri]::EscapeDataString($canon))"
                        $sum = Invoke-RestMethod -Uri $sumUrl -TimeoutSec 10 -Headers @{ 'User-Agent' = $ua } -ErrorAction Stop
                        $ext = [string](Get-PromptParleProp $sum 'extract' '')
                        if ($ext) {
                            $d = if ($ext.Length -gt 200) { $ext.Substring(0, 197) + '…' } else { $ext }
                            if (-not $abstract -and $wikiAdded -eq 0) { $abstract = $ext }
                        }
                        $page = Get-PromptParleProp (Get-PromptParleProp $sum 'content_urls' @{}) 'desktop' $null
                        $pageUrl = [string](Get-PromptParleProp $page 'page' '')
                        if ($pageUrl) { $u = $pageUrl }
                    } catch { }
                }
                # Dedup by URL/title
                $dup = $false
                foreach ($h in $hits) {
                    if (($u -and $h.url -eq $u) -or ($h.title -eq $t)) { $dup = $true; break }
                }
                if ($dup) { continue }
                if (-not $d) { $d = 'Wikipedia' }
                if ($d.Length -gt 160) { $d = $d.Substring(0, 157) + '…' }
                $hits.Add([pscustomobject]@{ title = $t; url = $u; snip = $d })
                $wikiAdded++
            }
            if ($wikiAdded -gt 0) { $notes.Add("wiki:$wikiAdded") }
        } catch {
            $notes.Add('wiki-skip')
        }
    }

    # Build brief text
    $out = New-Object System.Collections.Generic.List[string]
    $out.Add("[WEB] q=$q")
    if ($abstract) {
        $a = $abstract.Trim()
        if ($a.Length -gt 420) { $a = $a.Substring(0, 417) + '…' }
        $out.Add("Summary: $a")
    }
    $n = 0
    foreach ($h in $hits) {
        if ($n -ge $MaxResults) { break }
        $n++
        $line = "$n. $($h.title)"
        if ($h.url) { $line += " | $($h.url)" }
        $out.Add($line)
        if ($h.snip) { $out.Add("   $($h.snip)") }
    }
    if ($n -eq 0 -and -not $abstract) {
        $out.Add('(no brief hits — try a more specific query or /search <terms>)')
        $notes.Add('empty')
    }
    $out.Add('Cite sources; prefer local workspace facts over web when they conflict.')
    $text = ($out -join "`n")
    if ($text.Length -gt $MaxChars) {
        $text = $text.Substring(0, $MaxChars) + "`n…[web budget]"
        $notes.Add("cap $MaxChars")
    }

    $script:PromptParleWebSearchCache[$cacheKey] = @{ text = $text; at = $now }
    # Bound cache size
    if ($script:PromptParleWebSearchCache.Count -gt 24) {
        $oldest = $script:PromptParleWebSearchCache.GetEnumerator() |
            Sort-Object { $_.Value.at } |
            Select-Object -First 8
        foreach ($o in $oldest) {
            $script:PromptParleWebSearchCache.Remove($o.Key)
        }
    }

    return [pscustomobject]@{
        ok      = $true
        tool    = 'web_search'
        local   = $true
        text    = $text
        notes   = @($notes.ToArray())
        query   = $q
        cached  = $false
        hits    = $n
    }
}

function Invoke-PromptParleSecretScanLocal {
    param([string]$Text)
    if (-not $Text) {
        return [pscustomobject]@{ text = ''; masked = 0 }
    }
    $masked = 0
    $out = $Text
    $patterns = @(
        @{ re = '(?i)(sk-[A-Za-z0-9]{20,})'; rep = 'sk-***MASKED***' },
        @{ re = '(?i)(sk-ant-[A-Za-z0-9\-_]{20,})'; rep = 'sk-ant-***MASKED***' },
        @{ re = '(?i)(xai-[A-Za-z0-9]{20,})'; rep = 'xai-***MASKED***' },
        @{ re = '(?i)(AIza[0-9A-Za-z\-_]{20,})'; rep = 'AIza***MASKED***' },
        @{ re = '(?i)(ghp_[A-Za-z0-9]{20,})'; rep = 'ghp_***MASKED***' },
        @{ re = '(?i)(github_pat_[A-Za-z0-9_]{20,})'; rep = 'github_pat_***MASKED***' },
        @{ re = '(?i)(pp_live_[A-Za-z0-9]{16,})'; rep = 'pp_live_***MASKED***' },
        @{ re = '(?i)(-----BEGIN (?:RSA |OPENSSH |EC )?PRIVATE KEY-----[\s\S]*?-----END (?:RSA |OPENSSH |EC )?PRIVATE KEY-----)'; rep = '-----BEGIN PRIVATE KEY-----***MASKED***-----END PRIVATE KEY-----' },
        @{ re = '(?i)((?:api[_-]?key|secret|password|token|passwd)\s*[=:]\s*)(["'']?)([^\s"'';]{8,})\2'; rep = '${1}${2}***MASKED***${2}' }
    )
    foreach ($p in $patterns) {
        $before = $out
        try {
            $out = [regex]::Replace($out, $p.re, $p.rep)
        } catch { }
        if ($out -ne $before) {
            # rough count of replacements
            $masked += [Math]::Max(1, [int](($before.Length - $out.Length) / 8))
        }
    }
    return [pscustomobject]@{ text = $out; masked = $masked }
}

function Get-PromptParlePromptTokens {
    <# Tokenize a prompt for fidelity scoring (local, free). #>
    param([string]$Text)
    if (-not $Text) { return @() }
    $stop = @{
        'a'=1;'an'=1;'the'=1;'and'=1;'or'=1;'but'=1;'if'=1;'in'=1;'on'=1;'at'=1;'to'=1;'for'=1;'of'=1;'as'=1;
        'is'=1;'are'=1;'was'=1;'were'=1;'be'=1;'been'=1;'this'=1;'that'=1;'it'=1;'its'=1;'with'=1;'from'=1;
        'by'=1;'please'=1;'review'=1;'code'=1;'file'=1;'look'=1;'analyze'=1;'explain'=1;'what'=1;'how'=1;
        'why'=1;'fix'=1;'bug'=1;'issue'=1;'function'=1;'class'=1;'can'=1;'you'=1;'me'=1;'my'=1;'we'=1;
        'need'=1;'help'=1;'about'=1;'into'=1;'using'=1;'use'=1;'just'=1;'also'=1;'any'=1;'all'=1;'not'=1
    }
    $raw = [regex]::Matches($Text.ToLowerInvariant(), '[a-z0-9][a-z0-9\-_./]{1,}')
    $out = New-Object System.Collections.Generic.List[string]
    $seen = @{}
    foreach ($m in $raw) {
        $t = $m.Value
        if ($t.Length -lt 3) { continue }
        if ($stop.ContainsKey($t)) { continue }
        if ($seen.ContainsKey($t)) { continue }
        $seen[$t] = 1
        $out.Add($t)
        if ($out.Count -ge 40) { break }
    }
    return @($out)
}

function Test-PromptParleLineMatchesTokens {
    param([string]$Line, [string[]]$Tokens)
    if (-not $Tokens -or $Tokens.Count -eq 0) { return $false }
    if (-not $Line) { return $false }
    $low = $Line.ToLowerInvariant()
    foreach ($t in $Tokens) {
        if ($t -and $low.Contains($t)) { return $true }
    }
    return $false
}

function Get-PromptParleFidelityTrim {
    <#
    .SYNOPSIS
      Head+tail trim that preserves signal at both ends (not a blind head cut).
      Prefer keeping recent attach content (tail) + headers/imports (head).
    #>
    param(
        [string]$Text,
        [int]$MaxChars,
        [string]$Marker = '…[fidelity budget]…'
    )
    if (-not $Text) { return '' }
    if ($MaxChars -lt 200) { $MaxChars = 200 }
    if ($Text.Length -le $MaxChars) { return $Text }
    $mark = "`n$Marker`n"
    $room = $MaxChars - $mark.Length
    if ($room -lt 120) {
        return $Text.Substring(0, $MaxChars) + '…'
    }
    $head = [int][Math]::Floor($room * 0.62)
    $tail = $room - $head
    if ($tail -lt 80) { $tail = 80; $head = $room - $tail }
    return $Text.Substring(0, $head) + $mark + $Text.Substring($Text.Length - $tail)
}

function Invoke-PromptParleCodeBriefLocal {
    <#
    .SYNOPSIS
      Fidelity-first local shrink: drop noise, keep signal. $0 AI tokens.
      When -Prompt is set, lines matching prompt tokens are never dropped.
    #>
    param(
        [string]$Text,
        [int]$MaxChars = 48000,
        [int]$Dial = 3,
        [string]$Prompt = ''
    )
    if (-not $Text) {
        return [pscustomobject]@{ text = ''; notes = @(); chars_in = 0; chars_out = 0 }
    }
    $charsIn = $Text.Length
    $tokens = @(Get-PromptParlePromptTokens -Text $Prompt)
    $lines = $Text -split "`r?`n", -1
    $outLines = New-Object System.Collections.Generic.List[string]
    $inBlock = $false
    $blankRun = 0
    $dropped = 0
    $seen = @{}
    $dupDropped = 0
    $keptHot = 0
    # Higher dial = drop more low-signal lines (never drop hot/error/FILE lines)
    $dropDebug = $Dial -ge 4
    $dropVerboseLog = $Dial -ge 3
    foreach ($line in $lines) {
        $trim = $line.TrimEnd()
        $t = $trim.Trim()
        $isHot = $false
        if ($t -match '(?i)^===== FILE:') { $isHot = $true }
        elseif ($t -match '(?i)\b(ERROR|FATAL|EXCEPTION|Traceback|FAILED|CRITICAL|SECURITY|TODO|FIXME)\b') { $isHot = $true }
        elseif ($t -match '(?i)^\s*(at\s+\S+\(|File\s+".+",\s*line\s+\d+|#+ Step |\[CONN\]|\[WEB\]|\[MEM\]|\[SLICE\]|\[ERR\])') { $isHot = $true }
        elseif (Test-PromptParleLineMatchesTokens -Line $t -Tokens $tokens) { $isHot = $true; $keptHot++ }

        if ($inBlock) {
            if ($t -match '\*/') { $inBlock = $false }
            if (-not $isHot) { $dropped++; continue }
        }
        if (-not $isHot -and $t -match '^/\*' -and $t -notmatch '\*/') {
            if ($t -notmatch '@license|copyright|SPDX|TODO|FIXME|SECURITY') {
                $inBlock = $true; $dropped++; continue
            }
        }
        if (-not $isHot -and $t -match '^/\*.*\*/$' -and $t -notmatch '@license|copyright|SPDX|TODO|FIXME|SECURITY') {
            $dropped++; continue
        }
        if (-not $isHot -and ($t -match '^//' -or $t -match '^#(?!!)' -or $t -match '^;' -or $t -match '^--\s')) {
            if ($t -notmatch 'TODO|FIXME|HACK|SECURITY|XXX|BUG') { $dropped++; continue }
        }
        # Inline trailing comments (light) — keep code left of // when obvious
        if (-not $isHot -and $t -match '^(.+?)\s+//(?!/).*$' -and $t -notmatch 'https?://' -and $t -notmatch 'TODO|FIXME') {
            $left = $Matches[1].TrimEnd()
            if ($left.Length -gt 0 -and $left -notmatch '["''].*//') {
                $trim = $left
                $t = $trim.Trim()
            }
        }
        if ($t -eq '') {
            $blankRun++
            if ($blankRun -gt 1) { $dropped++; continue }
            $outLines.Add('')
            continue
        }
        $blankRun = 0
        # Collapse pure noise / debug spam — never if hot
        if (-not $isHot -and $dropDebug -and $t -match '(?i)^\s*(console\.(log|debug|info)|Write-Host|print\(|logger\.(debug|info))\b') {
            $dropped++; continue
        }
        if (-not $isHot -and $dropVerboseLog -and $t -match '(?i)^\s*(DEBUG|TRACE)\b' -and $t.Length -lt 200) {
            $dropped++; continue
        }
        # Dedup exact lines (logs) — keep first 2 of noise; always keep hot
        $key = $t
        if (-not $isHot -and $key.Length -gt 24 -and $seen.ContainsKey($key)) {
            $dupDropped++
            if ($dupDropped -gt 2 -or $Dial -ge 3) { $dropped++; continue }
        } else {
            if ($seen.Count -lt 4000) { $seen[$key] = 1 }
        }
        # Cap ultra-long lines (base64 / minified) — keep more of hot lines
        $cap = if ($isHot) { 600 } else { 400 }
        if ($trim.Length -gt $cap) {
            $trim = $trim.Substring(0, $cap) + '…'
            $dropped++
        }
        $outLines.Add($trim)
    }
    $out = ($outLines -join "`n")
    $out = [regex]::Replace($out, "(`n){3,}", "`n`n")
    if ($out.Length -gt $MaxChars) {
        $out = Get-PromptParleFidelityTrim -Text $out -MaxChars $MaxChars -Marker '…[brief budget]…'
    }
    $pct = if ($charsIn -gt 0) { [int][Math]::Round(100.0 * (1.0 - ($out.Length / [double]$charsIn))) } else { 0 }
    $notes = @("brief −${pct}% ($charsIn→$($out.Length))")
    if ($keptHot -gt 0) { $notes += "hot-keep $keptHot" }
    return [pscustomobject]@{
        text      = $out
        notes     = $notes
        chars_in  = $charsIn
        chars_out = $out.Length
    }
}

function Test-PromptParleLooksLikeErrorLog {
    param([string]$Text)
    if (-not $Text -or $Text.Length -lt 40) { return $false }
    $sample = if ($Text.Length -gt 8000) { $Text.Substring(0, 8000) } else { $Text }
    $hits = 0
    if ($sample -match '(?im)^\s*(ERROR|FATAL|CRITICAL|WARN(ING)?|Exception|Traceback)\b') { $hits += 2 }
    if ($sample -match '(?i)\b(NullReferenceException|TypeError|ReferenceError|panic:|Segmentation fault)\b') { $hits += 2 }
    if ($sample -match '(?im)^\s*at\s+\S+\(') { $hits += 2 }
    if ($sample -match '(?im)^File ".+", line \d+') { $hits += 2 }
    if ($sample -match '(?im)^\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}:\d{2}') { $hits += 1 }
    if ($sample -match '(?i)\b(npm ERR!|FAILED|Build failed|AssertionError)\b') { $hits += 2 }
    # Many short timestamped lines → log-ish
    $lines = ($sample -split "`n").Count
    if ($lines -gt 40 -and $sample -match '(?im)^\s*\[?(DEBUG|INFO|WARN|ERROR)\]?') { $hits += 1 }
    return ($hits -ge 3)
}

function Invoke-PromptParleErrorBriefLocal {
    <#
    .SYNOPSIS
      High-fidelity log/error shrink: keep exceptions, stack frames, FAIL lines;
      drop DEBUG spam and duplicate noise. Preserves order of first unique errors.
    #>
    param(
        [string]$Text,
        [int]$MaxChars = 12000,
        [int]$Dial = 3,
        [string]$Prompt = ''
    )
    if (-not $Text) {
        return [pscustomobject]@{ text = ''; notes = @('error_brief: empty'); chars_in = 0; chars_out = 0 }
    }
    $charsIn = $Text.Length
    $tokens = @(Get-PromptParlePromptTokens -Text $Prompt)
    $lines = $Text -split "`r?`n", -1
    $keep = New-Object System.Collections.Generic.List[string]
    $seen = @{}
    $dropped = 0
    $keptErr = 0
    $contextWindow = 0  # keep N following lines after a hot error
    $maxDup = if ($Dial -ge 4) { 1 } else { 2 }

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $raw = $lines[$i]
        $t = $raw.TrimEnd()
        $trim = $t.Trim()
        if (-not $trim) {
            if ($contextWindow -gt 0) { $keep.Add(''); $contextWindow-- }
            continue
        }

        $isErr = $false
        if ($trim -match '(?i)\b(ERROR|FATAL|CRITICAL|EXCEPTION|Traceback|FAILED|FAILURE|PANIC|Assert|npm ERR!|Build failed)\b') { $isErr = $true }
        elseif ($trim -match '(?i)^\s*(at\s+\S+\(|File\s+".+",\s*line\s+\d+|Caused by:|--- End of|#+ Error)') { $isErr = $true }
        elseif ($trim -match '(?i)\b(NullReference|TypeError|ReferenceError|SyntaxError|ENOENT|EACCES|segfault)\b') { $isErr = $true }
        elseif (Test-PromptParleLineMatchesTokens -Line $trim -Tokens $tokens) { $isErr = $true }

        $isWarn = $trim -match '(?i)\bWARN(ING)?\b'
        $isNoise = $trim -match '(?i)^\s*(\[?(DEBUG|TRACE|VERBOSE)\]?|console\.(log|debug)|Write-Host)\b'

        if ($isErr) {
            $key = $trim
            if ($key.Length -gt 120) { $key = $key.Substring(0, 120) }
            if ($seen.ContainsKey($key) -and $seen[$key] -ge $maxDup) {
                $dropped++; continue
            }
            if (-not $seen.ContainsKey($key)) { $seen[$key] = 0 }
            $seen[$key]++
            $keep.Add($t)
            $keptErr++
            $contextWindow = if ($Dial -le 2) { 4 } else { 2 }
            continue
        }

        if ($contextWindow -gt 0) {
            # Keep stack-ish followers even if not matching ERROR keyword
            if ($trim -match '(?i)^\s*(at\s+|File\s+"|Caused by:|\.\.\. \d+ more|---|\s+\^)') {
                $keep.Add($t)
                $contextWindow = [Math]::Max($contextWindow, 2)
                continue
            }
            if (-not $isNoise) {
                $keep.Add($t)
                $contextWindow--
                continue
            }
            $dropped++
            $contextWindow--
            continue
        }

        if ($isNoise) { $dropped++; continue }

        # Keep a thin sample of WARN and INFO only at low dial / first occurrences
        if ($isWarn) {
            $wk = 'W:' + $(if ($trim.Length -gt 80) { $trim.Substring(0, 80) } else { $trim })
            if (-not $seen.ContainsKey($wk)) {
                $seen[$wk] = 1
                $keep.Add($t)
            } else { $dropped++ }
            continue
        }

        # Drop bulk INFO unless dial 1 (max fidelity) — keep every 20th for shape
        if ($trim -match '(?i)^\s*\[?INFO\]?\b') {
            if ($Dial -eq 1 -and ($i % 8 -eq 0)) { $keep.Add($t) } else { $dropped++ }
            continue
        }

        # Non-log free text mixed in: keep if short or hot tokens
        if ($Dial -le 2 -and $trim.Length -lt 160 -and $i -lt 30) {
            $keep.Add($t)
        } else {
            $dropped++
        }
    }

    $out = ($keep -join "`n")
    $out = [regex]::Replace($out, "(`n){3,}", "`n`n")
    if (-not $out.Trim()) {
        # Fallback: don't destroy fidelity if classifier was wrong
        $fb = Invoke-PromptParleCodeBriefLocal -Text $Text -MaxChars $MaxChars -Dial $Dial -Prompt $Prompt
        return [pscustomobject]@{
            text = $fb.text
            notes = @('error_brief→code_brief fallback') + @($fb.notes)
            chars_in = $charsIn
            chars_out = $fb.chars_out
        }
    }
    $header = "[ERR] kept $keptErr error/stack signals; dropped ~$dropped noise lines"
    $out = $header + "`n" + $out
    if ($out.Length -gt $MaxChars) {
        $out = Get-PromptParleFidelityTrim -Text $out -MaxChars $MaxChars -Marker '…[err budget]…'
    }
    $pct = if ($charsIn -gt 0) { [int][Math]::Round(100.0 * (1.0 - ($out.Length / [double]$charsIn))) } else { 0 }
    return [pscustomobject]@{
        text      = $out
        notes     = @("error_brief −${pct}% ($charsIn→$($out.Length))", "err-signals $keptErr")
        chars_in  = $charsIn
        chars_out = $out.Length
    }
}

function Reduce-PromptParleTurnTextForMemory {
    <#
    .SYNOPSIS
      Strip prior deliverable bodies / apply dumps so [MEM] does not re-anchor the next document ask
      on the previous attachment's summary (e.g. doc1 summary poisons doc2 executive brief).
    #>
    param(
        [AllowEmptyString()][string]$Text = '',
        [string]$Role = 'user'
    )
    if (-not $Text) { return '' }
    $t = [string]$Text

    # Collapse ```file / ```deliver full bodies → one-line note (keep names only)
    $fileNames = New-Object System.Collections.Generic.List[string]
    foreach ($m in [regex]::Matches($t, '(?ms)```(?:file|deliver)\s+(?:name|path|filename)\s*[=:]\s*([^\s\r\n`]+)[^\n]*\r?\n.*?```')) {
        $fileNames.Add($m.Groups[1].Value.Trim())
    }
    foreach ($m in [regex]::Matches($t, '(?ms)```(?:file|deliver)\s+([A-Za-z0-9._\- ]+\.[A-Za-z0-9]+)[ \t]*\r?\n.*?```')) {
        $n = $m.Groups[1].Value.Trim()
        if ($fileNames -notcontains $n) { $fileNames.Add($n) }
    }
    $t = [regex]::Replace($t, '(?ms)```(?:file|deliver)[^\n]*\r?\n.*?```', '[prior deliverable body omitted]')
    # Apply blocks — never keep full file contents in memory
    $t = [regex]::Replace($t, '(?ms)```apply\s+path\s*[=:][^\n]*\r?\n.*?```', '[prior apply body omitted]')
    # Downloads ready header block
    $t = [regex]::Replace($t, '(?ms)^## Downloads ready\r?\n.*?(?=^## |\Z)', '')
    $t = [regex]::Replace($t, '(?ms)^## What changed\r?\n.*?(?=^## |\Z)', '[prior pipeline report omitted]`n')
    # Strip export markdown links (noise)
    $t = [regex]::Replace($t, '\[([^\]]+)\]\(/api/exports/[^)]+\)', '`$1`')
    # Attachment footer noise
    $t = [regex]::Replace($t, '(?m)^\s*\[ATTACHED THIS TURN:[^\]]*\]\s*$', '')
    $t = [regex]::Replace($t, '(?m)^\s*\[\d+ attachment\(s\)\]\s*$', '')

    if ($Role -match 'assistant|bot|ai') {
        if ($fileNames.Count -gt 0) {
            $names = ($fileNames | Select-Object -First 6) -join ', '
            $t = "delivered: $names"
            # keep a short non-file prose lead if any (before first fence)
            return $t
        }
        # Long prior summaries without file fences still poison next doc asks — hard cap assistants in MEM
        if ($t.Length -gt 900) {
            $t = $t.Substring(0, 700).Trim() + '…[prior assistant compressed]'
        }
    } else {
        # User: keep ask, drop huge pasted bodies if any
        if ($t.Length -gt 1500) {
            $t = $t.Substring(0, 1200).Trim() + '…'
        }
    }
    return $t.Trim()
}

function Invoke-PromptParleChatMemoryBrief {
    <#
    .SYNOPSIS
      Continuous auto-compact of prior turns into a fidelity-preserving [MEM] brief.
      Tiered densify (no user manual compaction):
        - Spine: durable facts across the whole window (paths, versions, decisions)
        - Deep past: ultra-dense extract bullets
        - Mid: denser extracts
        - Recent: near-full body (dial-capped)
      Prior ```file``` deliverable bodies are collapsed so they cannot poison the next attachment.
    #>
    param(
        [object[]]$History,
        [string]$HistoryText = '',
        [int]$MaxChars = 2400,
        [int]$Dial = 3
    )
    $turns = New-Object System.Collections.Generic.List[object]
    if ($History -and $History.Count -gt 0) {
        foreach ($h in $History) {
            $role = [string](Get-PromptParleProp $h 'role' (Get-PromptParleProp $h 'Role' 'user'))
            $text = [string](Get-PromptParleProp $h 'text' (Get-PromptParleProp $h 'content' (Get-PromptParleProp $h 'Content' '')))
            if (-not $text) { continue }
            $role = $role.ToLowerInvariant()
            if ($role -match 'sys|system|tool') { continue }
            if ($role -match 'bot|assistant|ai|model') { $role = 'assistant' }
            else { $role = 'user' }
            # Drop pure acknowledgements early
            $trimT = $text.Trim()
            if ($trimT -match '(?is)^(thanks|thank you|ok|okay|sure|got it|k|cool|nice)[.!\s]*$' -and $trimT.Length -lt 28) {
                continue
            }
            $trimT = Reduce-PromptParleTurnTextForMemory -Text $trimT -Role $role
            if (-not $trimT) { continue }
            $turns.Add([pscustomobject]@{ role = $role; text = $trimT })
        }
    } elseif ($HistoryText) {
        # Parse "user: …" / "assistant: …" blocks
        $blocks = [regex]::Split($HistoryText.Trim(), '(?m)(?=^(?:user|assistant|bot|human|ai)\s*:)')
        foreach ($b in $blocks) {
            if ($b -match '(?is)^(user|assistant|bot|human|ai)\s*:\s*(.+)$') {
                $r = $Matches[1].ToLowerInvariant()
                if ($r -match 'bot|ai|assistant') { $r = 'assistant' } else { $r = 'user' }
                $turns.Add([pscustomobject]@{ role = $r; text = $Matches[2].Trim() })
            }
        }
    }
    if ($turns.Count -eq 0) {
        return [pscustomobject]@{ text = ''; notes = @('memory: none'); chars_in = 0; chars_out = 0 }
    }

    $charsIn = 0
    foreach ($t in $turns) { $charsIn += $t.text.Length }

    # Tier sizes by dial (more fidelity at low dial; denser at high)
    $recentN = if ($Dial -le 2) { 4 } elseif ($Dial -eq 3) { 3 } else { 2 }
    $midN = if ($Dial -le 2) { 6 } elseif ($Dial -eq 3) { 5 } else { 4 }
    $startRecent = [Math]::Max(0, $turns.Count - $recentN)
    $startMid = [Math]::Max(0, $startRecent - $midN)

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('[MEM] continuous session (auto-compact — high-signal only; treat as known context)')

    # Spine: durable facts across ALL turns (paths, versions, decisions, open work)
    $spine = Get-PromptParleMemorySpine -Turns @($turns.ToArray()) -MaxLen $(if ($Dial -ge 4) { 420 } elseif ($Dial -le 2) { 720 } else { 560 })
    if ($spine) {
        $lines.Add('Spine:')
        $lines.Add($spine)
    }

    # Deep past (everything before mid)
    if ($startMid -gt 0) {
        $lines.Add('Earlier:')
        for ($i = 0; $i -lt $startMid; $i++) {
            $t = $turns[$i]
            $extract = Get-PromptParleMemoryExtract -Text $t.text -MaxLen $(if ($Dial -ge 4) { 100 } else { 140 })
            if ($extract) {
                $tag = if ($t.role -eq 'assistant') { 'A' } else { 'U' }
                $lines.Add("· ${tag}: $extract")
            }
        }
    }

    # Mid band
    if ($startMid -lt $startRecent) {
        $lines.Add('Mid:')
        for ($i = $startMid; $i -lt $startRecent; $i++) {
            $t = $turns[$i]
            $extract = Get-PromptParleMemoryExtract -Text $t.text -MaxLen $(if ($Dial -ge 4) { 160 } else { 220 })
            if ($extract) {
                $tag = if ($t.role -eq 'assistant') { 'A' } else { 'U' }
                $lines.Add("· ${tag}: $extract")
            }
        }
    }

    # Recent: near-full densified body
    $lines.Add('Recent:')
    for ($i = $startRecent; $i -lt $turns.Count; $i++) {
        $t = $turns[$i]
        $tag = if ($t.role -eq 'assistant') { 'assistant' } else { 'user' }
        $body = $t.text
        $cap = if ($Dial -le 2) { 1100 } elseif ($Dial -eq 3) { 750 } elseif ($Dial -eq 4) { 480 } else { 320 }
        if ($body.Length -gt $cap) {
            $body = Get-PromptParleFidelityTrim -Text $body -MaxChars $cap -Marker '…'
        }
        $body = $body.Trim()
        if ($body) { $lines.Add("${tag}: $body") }
    }

    $out = ($lines -join "`n")
    if ($out.Length -gt $MaxChars) {
        # Prefer keeping Spine + Recent; trim Mid/Earlier first via fidelity trim
        $out = Get-PromptParleFidelityTrim -Text $out -MaxChars $MaxChars -Marker '…[mem budget]…'
    }
    $pct = if ($charsIn -gt 0) { [int][Math]::Round(100.0 * (1.0 - ($out.Length / [double]$charsIn))) } else { 0 }
    return [pscustomobject]@{
        text      = $out
        notes     = @("memory −${pct}% ($charsIn→$($out.Length))", "turns $($turns.Count)", 'auto-compact')
        chars_in  = $charsIn
        chars_out = $out.Length
        turns     = $turns.Count
    }
}

function Get-PromptParleMemorySpine {
    <#
    .SYNOPSIS
      Rolling durable facts for continuous [MEM] — paths, versions, decisions, open work.
      Deduped across turns so long sessions stay relevant without full replay.
    #>
    param(
        [object[]]$Turns,
        [int]$MaxLen = 560
    )
    if (-not $Turns -or $Turns.Count -eq 0) { return '' }
    $bits = New-Object System.Collections.Generic.List[string]
    $seen = @{}
    $add = {
        param([string]$s)
        if (-not $s) { return }
        $k = $s.ToLowerInvariant()
        if ($seen.ContainsKey($k)) { return }
        $seen[$k] = $true
        $bits.Add($s)
    }
    foreach ($t in $Turns) {
        $text = [string]$t.text
        if (-not $text) { continue }
        # Versions (0.14.x, v1.2.3)
        foreach ($m in [regex]::Matches($text, '(?i)\b(?:v?\d+\.\d+(?:\.\d+)?(?:\.\d+)?)\b')) {
            if ($m.Value -match '^\d+\.\d+$' -and [double]$m.Value -lt 1) { continue }
            & $add $m.Value
            if ($bits.Count -ge 18) { break }
        }
        # Paths / files — skip prior *deliverable* names (…Executive_Summary.md) so spine
        # does not lock the next attachment ask onto the previous document's topic
        foreach ($m in [regex]::Matches($text, '(?i)(?:[A-Za-z]:\\|~/|\./|[\w.-]+/)+[\w.-]+\.[\w]+|[\w.-]+\.(?:psm1|psd1|html|ts|tsx|js|php|py|go|md|json|yml)')) {
            $fn = $m.Value
            # Skip names that look like prior *outputs* (summaries/one-pagers), not product sources
            if ($fn -match '(?i)(executive[_-]?summary|one[_-]?pager|[_-]summary\.(md|pdf|docx)|delivered:)') { continue }
            & $add $fn
            if ($bits.Count -ge 22) { break }
        }
        # Decision / open-work sentences
        foreach ($line in ($text -split "`n")) {
            $ln = $line.Trim()
            if ($ln.Length -lt 16 -or $ln.Length -gt 160) { continue }
            if ($ln -match '(?i)\b(decided|ship|version|must|blocker|fixed|todo|in progress|use |don''t |never |always |activity log|auto-compact|\[MEM\])\b') {
                $s = if ($ln.Length -gt 110) { $ln.Substring(0, 107) + '…' } else { $ln }
                & $add $s
                if ($bits.Count -ge 28) { break }
            }
        }
        if ($bits.Count -ge 28) { break }
    }
    if ($bits.Count -eq 0) { return '' }
    $joined = ($bits | Select-Object -First 14) -join ' · '
    if ($joined.Length -gt $MaxLen) { $joined = $joined.Substring(0, $MaxLen - 1) + '…' }
    return $joined
}

function Get-PromptParleMemoryExtract {
    <# Pull paths, errors, decisions, names from a turn — fidelity without full prose. #>
    param([string]$Text, [int]$MaxLen = 180)
    if (-not $Text) { return '' }
    $bits = New-Object System.Collections.Generic.List[string]
    # Paths / files
    foreach ($m in [regex]::Matches($Text, '(?i)(?:[A-Za-z]:\\|~/|\./|[\w.-]+/)+[\w.-]+\.[\w]+|[\w.-]+\.(?:psm1|psd1|html|ts|tsx|js|php|py|go|md|json|yml)')) {
        $bits.Add($m.Value)
        if ($bits.Count -ge 5) { break }
    }
    # Versions
    foreach ($m in [regex]::Matches($Text, '(?i)\b(?:v?\d+\.\d+\.\d+(?:\.\d+)?)\b')) {
        $bits.Add($m.Value)
        if ($bits.Count -ge 7) { break }
    }
    # Decision / error / action sentences
    foreach ($line in ($Text -split "`n")) {
        $t = $line.Trim()
        if ($t -match '(?i)\b(error|failed|fixed|decided|ship|use|because|must|cannot|bug|CVE|blocker|version|implement|deploy|todo|open)\b' -and $t.Length -gt 12) {
            $s = if ($t.Length -gt 110) { $t.Substring(0, 107) + '…' } else { $t }
            $bits.Add($s)
            if ($bits.Count -ge 6) { break }
        }
    }
    if ($bits.Count -eq 0) {
        $s = $Text.Trim()
        if ($s.Length -gt $MaxLen) { $s = $s.Substring(0, $MaxLen - 1) + '…' }
        return $s
    }
    $joined = ($bits | Select-Object -Unique | Select-Object -First 6) -join ' · '
    if ($joined.Length -gt $MaxLen) { $joined = $joined.Substring(0, $MaxLen - 1) + '…' }
    return $joined
}

function Get-PromptParleRelevantSlice {
    <#
    .SYNOPSIS
      Rank workspace files by prompt tokens; return high-fidelity slices around hits.
      Selection > destruction: full local context windows, not summaries of code.
    #>
    param(
        [string]$Prompt = '',
        [int]$MaxFiles = 4,
        [int]$MaxChars = 14000,
        [int]$ContextLines = 12,
        [int]$MaxScanFiles = 400
    )
    $ws = Get-PromptParleWorkspace
    if (-not $ws.exists) { throw 'No workspace attached. /workspace <path> first.' }
    $tokens = @(Get-PromptParlePromptTokens -Text $Prompt)
    if ($tokens.Count -eq 0) {
        return [pscustomobject]@{ text = ''; notes = @('slice: no query tokens'); files = 0 }
    }
    $root = [string]$ws.path
    $codeExt = @{
        '.ps1'=1;'.psm1'=1;'.psd1'=1;'.ts'=1;'.tsx'=1;'.js'=1;'.jsx'=1;'.mjs'=1;'.py'=1;'.go'=1;
        '.rs'=1;'.java'=1;'.php'=1;'.rb'=1;'.cs'=1;'.c'=1;'.h'=1;'.cpp'=1;'.hpp'=1;'.sql'=1;
        '.json'=1;'.yml'=1;'.yaml'=1;'.md'=1;'.sh'=1;'.vue'=1;'.svelte'=1;'.kt'=1;'.swift'=1
    }
    $scored = New-Object System.Collections.Generic.List[object]
    $scanned = 0
    Get-ChildItem -LiteralPath $root -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object {
            $rel = $_.FullName.Substring($root.Length).TrimStart('\', '/')
            $skip = $false
            foreach ($d in $script:PromptParleSkipDirNames) {
                if ($rel -match [regex]::Escape([IO.Path]::DirectorySeparatorChar + $d + [IO.Path]::DirectorySeparatorChar) -or
                    $rel.StartsWith($d + [IO.Path]::DirectorySeparatorChar) -or
                    $rel.StartsWith($d + '/') -or $rel.StartsWith($d + '\')) {
                    $skip = $true; break
                }
            }
            if ($skip) { return $false }
            $ext = if ($_.Extension) { $_.Extension.ToLowerInvariant() } else { '' }
            if (-not $codeExt.ContainsKey($ext)) { return $false }
            if ($_.Length -gt 800000) { return $false }
            return $true
        } |
        Select-Object -First $MaxScanFiles |
        ForEach-Object {
            $scanned++
            $rel = $_.FullName.Substring($root.Length).TrimStart('\', '/')
            $relLow = $rel.ToLowerInvariant()
            $nameLow = $_.BaseName.ToLowerInvariant()
            $score = 0
            foreach ($t in $tokens) {
                if ($nameLow -eq $t -or $nameLow.Contains($t)) { $score += 8 }
                if ($relLow.Contains($t)) { $score += 3 }
            }
            # Quick content probe (first 32KB + sample)
            $raw = ''
            try {
                $fs = [IO.File]::Open(
                    $_.FullName,
                    [IO.FileMode]::Open,
                    [IO.FileAccess]::Read,
                    [IO.FileShare]::ReadWrite
                )
                try {
                    $len = [Math]::Min(32768, [int]$fs.Length)
                    $buf = New-Object byte[] $len
                    [void]$fs.Read($buf, 0, $len)
                    $raw = [Text.Encoding]::UTF8.GetString($buf)
                } finally { $fs.Close() }
            } catch {
                try { $raw = Get-Content -LiteralPath $_.FullName -TotalCount 400 -ErrorAction Stop | Out-String } catch { $raw = '' }
            }
            if (-not $raw) { return }
            $rawLow = $raw.ToLowerInvariant()
            $hitLines = New-Object System.Collections.Generic.List[int]
            $lineArr = $raw -split "`r?`n", -1
            for ($li = 0; $li -lt $lineArr.Count; $li++) {
                $ll = $lineArr[$li].ToLowerInvariant()
                foreach ($t in $tokens) {
                    if ($ll.Contains($t)) {
                        $score += 2
                        if ($hitLines.Count -lt 12) { $hitLines.Add($li) }
                        break
                    }
                }
            }
            # Symbol bonus
            foreach ($t in $tokens) {
                if ($rawLow -match ("(?i)\b(function|class|def|const|interface|type)\s+$([regex]::Escape($t))\b")) {
                    $score += 10
                }
            }
            if ($score -gt 0) {
                $scored.Add([pscustomobject]@{
                    path = $_.FullName
                    rel = $rel
                    score = $score
                    hits = @($hitLines)
                    lines = $lineArr
                })
            }
        }

    if ($scored.Count -eq 0) {
        return [pscustomobject]@{ text = ''; notes = @("slice: 0 hits in $scanned files"); files = 0 }
    }

    $top = $scored | Sort-Object score -Descending | Select-Object -First $MaxFiles
    $chunks = New-Object System.Collections.Generic.List[string]
    $chunks.Add("[SLICE] prompt-ranked code (fidelity windows · top $($top.Count) of $($scored.Count) hits · scanned $scanned)")
    $used = 0
    $fileN = 0
    foreach ($f in $top) {
        $fileN++
        $lineArr = @($f.lines)
        $ranges = New-Object System.Collections.Generic.List[object]
        $hits = @($f.hits)
        if ($hits.Count -eq 0) {
            # Path-name match only: keep head of file (imports + start)
            $end = [Math]::Min($lineArr.Count - 1, 80)
            $ranges.Add([pscustomobject]@{ a = 0; b = $end })
        } else {
            foreach ($h in $hits) {
                $a = [Math]::Max(0, $h - $ContextLines)
                $b = [Math]::Min($lineArr.Count - 1, $h + $ContextLines)
                $ranges.Add([pscustomobject]@{ a = $a; b = $b })
            }
            # Merge overlapping ranges
            $merged = New-Object System.Collections.Generic.List[object]
            foreach ($r in ($ranges | Sort-Object a)) {
                if ($merged.Count -eq 0) { $merged.Add($r); continue }
                $last = $merged[$merged.Count - 1]
                if ($r.a -le ($last.b + 2)) {
                    $nb = [Math]::Max($last.b, $r.b)
                    $merged[$merged.Count - 1] = [pscustomobject]@{ a = $last.a; b = $nb }
                } else { $merged.Add($r) }
            }
            $ranges = $merged
        }

        $body = New-Object System.Collections.Generic.List[string]
        $body.Add("===== SLICE: $($f.rel) (score $($f.score)) =====")
        foreach ($r in $ranges) {
            if ($r.a -gt 0) { $body.Add("… L$($r.a + 1)–$($r.b + 1)") }
            for ($i = $r.a; $i -le $r.b; $i++) {
                $body.Add(("{0,5}| {1}" -f ($i + 1), $lineArr[$i]))
            }
        }
        $piece = ($body -join "`n")
        if (($used + $piece.Length) -gt $MaxChars -and $used -gt 0) { break }
        if ($piece.Length -gt ($MaxChars - $used)) {
            $piece = Get-PromptParleFidelityTrim -Text $piece -MaxChars ($MaxChars - $used) -Marker '…[slice]…'
        }
        $chunks.Add($piece)
        $used += $piece.Length
        if ($used -ge $MaxChars) { break }
    }

    $text = ($chunks -join "`n`n")
    if ($text.Length -gt $MaxChars) {
        $text = Get-PromptParleFidelityTrim -Text $text -MaxChars $MaxChars -Marker '…[slice budget]…'
    }
    return [pscustomobject]@{
        text  = $text
        notes = @("slice: $fileN files · score-top · $used chars")
        files = $fileN
    }
}

function Invoke-PromptParleFidelityContextLocal {
    <#
    .SYNOPSIS
      Split multi-file context (===== FILE: … =====) and shrink each part with the
      right high-fidelity tool: error_brief for logs, code_brief for code.
    #>
    param(
        [string]$Text,
        [string]$Prompt = '',
        [int]$MaxChars = 32000,
        [int]$Dial = 3
    )
    if (-not $Text) {
        return [pscustomobject]@{ text = ''; notes = @(); chars_in = 0; chars_out = 0 }
    }
    $charsIn = $Text.Length
    $notes = New-Object System.Collections.Generic.List[string]
    # Split on FILE markers; keep leading non-file prefix
    $parts = New-Object System.Collections.Generic.List[object]
    $rx = [regex]'(?m)^===== FILE:\s*(.+?)\s*=====\s*$'
    $matches = $rx.Matches($Text)
    if ($matches.Count -eq 0) {
        if (Test-PromptParleLooksLikeErrorLog -Text $Text) {
            $r = Invoke-PromptParleErrorBriefLocal -Text $Text -MaxChars $MaxChars -Dial $Dial -Prompt $Prompt
            foreach ($n in @($r.notes)) { if ($n) { $notes.Add([string]$n) } }
            return [pscustomobject]@{ text = $r.text; notes = @($notes); chars_in = $charsIn; chars_out = $r.text.Length }
        }
        $r2 = Invoke-PromptParleCodeBriefLocal -Text $Text -MaxChars $MaxChars -Dial $Dial -Prompt $Prompt
        foreach ($n in @($r2.notes)) { if ($n) { $notes.Add([string]$n) } }
        return [pscustomobject]@{ text = $r2.text; notes = @($notes); chars_in = $charsIn; chars_out = $r2.text.Length }
    }

    $prefix = ''
    if ($matches[0].Index -gt 0) {
        $prefix = $Text.Substring(0, $matches[0].Index).Trim()
    }
    for ($i = 0; $i -lt $matches.Count; $i++) {
        $name = $matches[$i].Groups[1].Value.Trim()
        $start = $matches[$i].Index + $matches[$i].Length
        $end = if ($i + 1 -lt $matches.Count) { $matches[$i + 1].Index } else { $Text.Length }
        $body = $Text.Substring($start, $end - $start).Trim()
        $parts.Add([pscustomobject]@{ name = $name; text = $body })
    }

    # Per-part budget: favor files matching prompt tokens
    $tokens = @(Get-PromptParlePromptTokens -Text $Prompt)
    $weights = @()
    $wSum = 0.0
    foreach ($p in $parts) {
        $w = 1.0
        $nl = $p.name.ToLowerInvariant()
        foreach ($t in $tokens) {
            if ($nl.Contains($t)) { $w += 3.0 }
        }
        if (Test-PromptParleLooksLikeErrorLog -Text $p.text) { $w += 1.5 }
        $weights += $w
        $wSum += $w
    }
    if ($wSum -le 0) { $wSum = 1.0 }

    $outChunks = New-Object System.Collections.Generic.List[string]
    if ($prefix) {
        $prefBudget = [Math]::Min(800, [int]($MaxChars * 0.08))
        if ($prefix.Length -gt $prefBudget) {
            $prefix = Get-PromptParleFidelityTrim -Text $prefix -MaxChars $prefBudget
        }
        $outChunks.Add($prefix)
    }
    $remain = $MaxChars
    foreach ($c in $outChunks) { $remain -= $c.Length }

    for ($i = 0; $i -lt $parts.Count; $i++) {
        $p = $parts[$i]
        $share = [int][Math]::Max(1200, [Math]::Floor($MaxChars * ($weights[$i] / $wSum)))
        if ($share -gt $remain -and $i -lt ($parts.Count - 1)) {
            $share = [Math]::Max(800, [int]($remain * 0.5))
        } elseif ($share -gt $remain) {
            $share = $remain
        }
        if ($share -lt 400) { continue }

        $body = $p.text
        $strat = 'brief'
        if (Test-PromptParleLooksLikeErrorLog -Text $body) {
            $er = Invoke-PromptParleErrorBriefLocal -Text $body -MaxChars $share -Dial $Dial -Prompt $Prompt
            $body = $er.text
            $strat = 'error_brief'
            foreach ($n in @($er.notes)) { if ($n) { $notes.Add("$($p.name): $n") } }
        } else {
            $br = Invoke-PromptParleCodeBriefLocal -Text $body -MaxChars $share -Dial $Dial -Prompt $Prompt
            $body = $br.text
            $strat = 'code_brief'
            foreach ($n in @($br.notes)) { if ($n) { $notes.Add("$($p.name): $n") } }
        }
        $outChunks.Add("===== FILE: $($p.name) · $strat =====`n$body")
        $remain = $MaxChars
        foreach ($c in $outChunks) { $remain -= $c.Length }
        if ($remain -lt 400) { break }
    }

    $out = ($outChunks -join "`n`n")
    if ($out.Length -gt $MaxChars) {
        $out = Get-PromptParleFidelityTrim -Text $out -MaxChars $MaxChars
    }
    $pct = if ($charsIn -gt 0) { [int][Math]::Round(100.0 * (1.0 - ($out.Length / [double]$charsIn))) } else { 0 }
    $notes.Insert(0, "fidelity fleet −${pct}% ($charsIn→$($out.Length)) · $($parts.Count) files")
    return [pscustomobject]@{
        text      = $out
        notes     = @($notes)
        chars_in  = $charsIn
        chars_out = $out.Length
    }
}

function Get-PromptParleLocalContextBudget {
    <# Dial → hard local context budget (chars) before gateway. Fidelity-aware caps. #>
    param([int]$Dial = 3)
    switch ($Dial) {
        1 { return 72000 }
        2 { return 48000 }
        3 { return 32000 }
        4 { return 20000 }
        5 { return 12000 }
        default { return 32000 }
    }
}

function Get-PromptParleWorkspaceFileIndex {
    param([int]$MaxFiles = 220, [int]$MaxChars = 2200)
    $ws = Get-PromptParleWorkspace
    if (-not $ws.exists) { throw 'No workspace attached. /workspace <path> first.' }
    $root = [string]$ws.path
    $extCount = @{}
    $total = 0
    $bytes = [long]0
    $samples = New-Object System.Collections.Generic.List[string]
    Get-ChildItem -LiteralPath $root -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object {
            $rel = $_.FullName.Substring($root.Length).TrimStart('\', '/')
            $skip = $false
            foreach ($d in $script:PromptParleSkipDirNames) {
                if ($rel -match [regex]::Escape([IO.Path]::DirectorySeparatorChar + $d + [IO.Path]::DirectorySeparatorChar) -or
                    $rel.StartsWith($d + [IO.Path]::DirectorySeparatorChar) -or
                    $rel.StartsWith($d + '/') -or $rel.StartsWith($d + '\')) {
                    $skip = $true; break
                }
            }
            -not $skip
        } |
        Select-Object -First $MaxFiles |
        ForEach-Object {
            $total++
            $bytes += $_.Length
            $ext = if ($_.Extension) { $_.Extension.ToLowerInvariant() } else { '(none)' }
            if (-not $extCount.ContainsKey($ext)) { $extCount[$ext] = 0 }
            $extCount[$ext]++
            if ($samples.Count -lt 12) {
                $rel = $_.FullName.Substring($root.Length).TrimStart('\', '/')
                $samples.Add($rel)
            }
        }
    $extParts = @()
    foreach ($k in ($extCount.Keys | Sort-Object { -$extCount[$_] } | Select-Object -First 10)) {
        $extParts += ("{0}:{1}" -f $k, $extCount[$k])
    }
    $lines = @(
        "IDX $total files ~$([Math]::Round($bytes/1KB, 0))KB",
        ($extParts -join ' '),
        ($samples -join ' · ')
    )
    $text = ($lines -join "`n")
    if ($text.Length -gt $MaxChars) { $text = $text.Substring(0, $MaxChars) + '…' }
    return $text
}

function Get-PromptParleWorkspaceDepsMap {
    param([int]$MaxChars = 3500)
    $ws = Get-PromptParleWorkspace
    if (-not $ws.exists) { throw 'No workspace attached. /workspace <path> first.' }
    $root = [string]$ws.path
    # Prefer lock-free manifests only (brief)
    $names = @(
        'package.json', 'requirements.txt', 'pyproject.toml', 'go.mod', 'Cargo.toml',
        'composer.json', 'Gemfile', 'pom.xml', 'build.gradle', '*.csproj'
    )
    $chunks = New-Object System.Collections.Generic.List[string]
    $chunks.Add("DEPS")
    $found = 0
    foreach ($pat in $names) {
        if ($found -ge 3) { break }
        Get-ChildItem -LiteralPath $root -Recurse -File -Filter $pat -ErrorAction SilentlyContinue |
            Where-Object {
                $rel = $_.FullName.Substring($root.Length).TrimStart('\', '/')
                $skip = $false
                foreach ($d in $script:PromptParleSkipDirNames) {
                    if ($rel -like "*$([IO.Path]::DirectorySeparatorChar)$d$([IO.Path]::DirectorySeparatorChar)*" -or
                        $rel -like "$d$([IO.Path]::DirectorySeparatorChar)*" -or
                        $rel -like "$d/*" -or $rel -like "$d\*") { $skip = $true; break }
                }
                -not $skip
            } |
            Select-Object -First 1 |
            ForEach-Object {
                $found++
                $rel = $_.FullName.Substring($root.Length).TrimStart('\', '/')
                $raw = ''
                try {
                    $raw = Get-Content -LiteralPath $_.FullName -Raw -ErrorAction Stop
                } catch { $raw = '' }
                # Prefer name/version lines only when possible
                $brief = $raw
                if ($rel -match 'package\.json' -and $raw) {
                    $deps = [regex]::Matches($raw, '"([^"]+)":\s*"([^"]+)"') | Select-Object -First 40
                    $pairs = @()
                    foreach ($m in $deps) {
                        $k = $m.Groups[1].Value
                        if ($k -match '^(name|version|dependencies|devDependencies)$') { continue }
                        if ($k -match '^(scripts|main|type|license|private)$') { continue }
                        $pairs += ("{0}@{1}" -f $k, $m.Groups[2].Value)
                    }
                    if ($pairs.Count) { $brief = ($pairs -join ', ') }
                } elseif ($raw.Length -gt 1200) {
                    $brief = $raw.Substring(0, 1200) + '…'
                }
                $chunks.Add("${rel}: $brief")
            }
    }
    if ($found -eq 0) { $chunks.Add('(none)') }
    $text = ($chunks -join "`n")
    if ($text.Length -gt $MaxChars) { $text = $text.Substring(0, $MaxChars) + '…' }
    return $text
}

function Get-PromptParleGitDiffPack {
    param([int]$MaxChars = 24000)
    $ws = Get-PromptParleWorkspace
    if (-not $ws.exists) { throw 'No workspace attached.' }
    if (-not $ws.is_git) { throw 'Workspace is not a git repo.' }
    if (-not (Test-PromptParleCommandAvailable 'git')) { throw 'git not found on PATH' }
    $root = [string]$ws.path
    $parts = New-Object System.Collections.Generic.List[string]
    $parts.Add('DIFF')
    try {
        $status = & git -C $root status -sb 2>&1 | Out-String
        if ($status.Trim()) { $parts.Add($status.Trim()) }
    } catch { }
    try {
        # Prefer stat + short patch
        $stat = & git -C $root diff --stat HEAD 2>&1 | Out-String
        if ($stat.Trim()) { $parts.Add($stat.Trim()) }
    } catch { }
    try {
        $patch = & git -C $root diff --unified=2 HEAD 2>&1 | Out-String
        if ($patch.Trim()) { $parts.Add($patch.Trim()) }
    } catch { }
    $text = ($parts -join "`n")
    if ($text.Length -gt $MaxChars) {
        $text = $text.Substring(0, $MaxChars) + "`n…[diff]"
    }
    return $text
}

function Invoke-PromptParleLocalTool {
    <#
    .SYNOPSIS
      Run a local-first tool on this PC (no AI tokens).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ToolId,
        [string]$Text = '',
        [string]$Arg = ''
    )
    $id = $ToolId.ToLowerInvariant().Trim()
    switch ($id) {
        'secret_scan' {
            $r = Invoke-PromptParleSecretScanLocal -Text $Text
            return [pscustomobject]@{
                ok = $true; tool = $id; local = $true
                text = $r.text; notes = @("secret_scan: masked ~$($r.masked) candidates")
            }
        }
        'code_brief' {
            $r = Invoke-PromptParleCodeBriefLocal -Text $Text
            return [pscustomobject]@{
                ok = $true; tool = $id; local = $true
                text = $r.text; notes = @($r.notes)
                chars_in = $r.chars_in; chars_out = $r.chars_out
            }
        }
        'file_index' {
            $t = Get-PromptParleWorkspaceFileIndex
            return [pscustomobject]@{ ok = $true; tool = $id; local = $true; text = $t; notes = @('file_index: built on this PC') }
        }
        'deps' {
            $t = Get-PromptParleWorkspaceDepsMap
            return [pscustomobject]@{ ok = $true; tool = $id; local = $true; text = $t; notes = @('deps: read manifests on this PC') }
        }
        'git_diff' {
            $t = Get-PromptParleGitDiffPack
            return [pscustomobject]@{ ok = $true; tool = $id; local = $true; text = $t; notes = @('git_diff: local git only') }
        }
        'tree_pack' {
            $depth = 3
            if ($Arg -match '^\d+$') { $depth = [Math]::Min(5, [Math]::Max(1, [int]$Arg)) }
            # Reuse slash workspace tree if available via command path
            $ws = Get-PromptParleWorkspace
            if (-not $ws.exists) { throw 'No workspace attached.' }
            $result = Invoke-PromptParleSlashCommand -Line "/workspace tree $depth"
            $msg = [string](Get-PromptParleProp $result 'message' '')
            return [pscustomobject]@{ ok = $true; tool = $id; local = $true; text = $msg; notes = @("tree_pack: depth $depth") }
        }
        'workspace' {
            $ws = Get-PromptParleWorkspace
            $msg = if ($ws.path) { "Workspace: $($ws.path) ($($ws.kind))" } else { 'No workspace. /workspace <path> or Browse folders.' }
            return [pscustomobject]@{ ok = $true; tool = $id; local = $true; text = $msg; notes = @() }
        }
        'git' {
            $t = Get-PromptParleGitStatusText
            return [pscustomobject]@{ ok = $true; tool = $id; local = $true; text = $t; notes = @() }
        }
        'ssh' {
            $st = Get-PromptParleSessionState
            $tgt = [string](Get-PromptParleProp $st 'ssh_target' '')
            if (-not $tgt) {
                return [pscustomobject]@{ ok = $false; tool = $id; local = $true; text = 'No SSH target. /ssh user@host [cwd]'; notes = @() }
            }
            $cwd = [string](Get-PromptParleProp $st 'ssh_cwd' '')
            $argS = if ($Arg) { [string]$Arg } else { '' }
            if ($argS -and ($argS -match '^(?i)(cat|read|get)\s+(.+)$' -or $argS -match '\.[A-Za-z0-9]{1,12}$' -or $argS -match '[/\\]')) {
                $path = $argS
                if ($argS -match '^(?i)(cat|read|get)\s+(.+)$') { $path = $Matches[2].Trim() }
                $ev = Get-PromptParleSshPromptEvidence -Prompt ("read $path") -MaxFiles 1 -MaxChars 16000
                if ($ev.text) {
                    return [pscustomobject]@{ ok = $true; tool = $id; local = $true; text = $ev.text; notes = @($ev.notes); files = $ev.files }
                }
                return [pscustomobject]@{
                    ok = $false; tool = $id; local = $true
                    text = "SSH file not found under session cwd ($cwd): $path"
                    notes = @($ev.notes)
                }
            }
            $msg = "SSH target: $tgt"
            if ($cwd) { $msg += "`nSSH cwd (live): $cwd`nRelative paths resolve here; name a file to auto-fetch." }
            else { $msg += "`nNo SSH cwd set — /ssh cwd /path/to/project" }
            return [pscustomobject]@{ ok = $true; tool = $id; local = $true; text = $msg; notes = @() }
        }
        'files' {
            return [pscustomobject]@{
                ok = $true; tool = $id; local = $true
                text = 'Use Attach files in the UI or /workspace cat|pack.'
                notes = @()
            }
        }
        'connections' {
            $t = Get-PromptParleProjectConnectionsBrief -Force
            return [pscustomobject]@{ ok = $true; tool = $id; local = $true; text = $t; notes = @('connections: session map') }
        }
        { $_ -in @('web_search', 'web', 'search') } {
            $q = if ($Arg) { $Arg } elseif ($Text) { $Text } else { '' }
            return Invoke-PromptParleWebSearchLocal -Query $q
        }
        'error_brief' {
            $r = Invoke-PromptParleErrorBriefLocal -Text $Text -Prompt $Arg
            return [pscustomobject]@{
                ok = $true; tool = $id; local = $true
                text = $r.text; notes = @($r.notes)
                chars_in = $r.chars_in; chars_out = $r.chars_out
            }
        }
        { $_ -in @('relevant_slice', 'slice') } {
            $q = if ($Arg) { $Arg } elseif ($Text) { $Text } else { '' }
            $r = Get-PromptParleRelevantSlice -Prompt $q
            return [pscustomobject]@{
                ok = $true; tool = $id; local = $true
                text = $r.text; notes = @($r.notes); files = $r.files
            }
        }
        { $_ -in @('chat_memory', 'memory') } {
            $r = Invoke-PromptParleChatMemoryBrief -HistoryText $Text
            return [pscustomobject]@{
                ok = $true; tool = $id; local = $true
                text = $r.text; notes = @($r.notes)
                chars_in = $r.chars_in; chars_out = $r.chars_out
            }
        }
        { $_ -in @('ssh_list', 'list', 'ls') } {
            $path = if ($Arg) { $Arg } else { '' }
            $r = Invoke-PromptParleSshDirListing -RemotePath $path -MaxChars 6000
            return [pscustomobject]@{
                ok = [bool]$r.ok; tool = 'ssh_list'; local = $true
                text = $(if ($r.text) { $r.text } else { "ssh_list failed: $($r.notes -join ', ')" })
                notes = @($r.notes); path = $r.path
            }
        }
        { $_ -in @('ssh_read', 'read') } {
            $path = if ($Arg) { $Arg.Trim() } else { '' }
            if (-not $path) {
                return [pscustomobject]@{ ok = $false; tool = 'ssh_read'; local = $true; text = 'ssh_read needs a path'; notes = @('no-path') }
            }
            $ev = Get-PromptParleSshPromptEvidence -Prompt ("read $path") -MaxFiles 1 -MaxChars 14000
            if ($ev -and $ev.text) {
                return [pscustomobject]@{ ok = $true; tool = 'ssh_read'; local = $true; text = $ev.text; notes = @($ev.notes); files = $ev.files }
            }
            return [pscustomobject]@{ ok = $false; tool = 'ssh_read'; local = $true; text = "ssh_read miss: $path"; notes = @($ev.notes) }
        }
        { $_ -in @('ssh_run', 'run_remote') } {
            $cmd = if ($Arg) { $Arg.Trim() } else { '' }
            if (-not $cmd) {
                return [pscustomobject]@{ ok = $false; tool = 'ssh_run'; local = $true; text = 'ssh_run needs allowlisted command'; notes = @('no-cmd') }
            }
            try {
                $rr = Invoke-PromptParleSshRunCommand -Command $cmd
                $snip = [string]$rr.text
                if ($snip.Length -gt 5000) { $snip = $snip.Substring(0, 5000) + "`n…[run budget]" }
                return [pscustomobject]@{
                    ok = [bool]$rr.ok; tool = 'ssh_run'; local = $true
                    text = ("CMD {0}`nEXIT {1}`n{2}" -f $rr.command, $rr.exit_code, $snip)
                    notes = @('ssh_run'); exit_code = $rr.exit_code
                }
            } catch {
                return [pscustomobject]@{ ok = $false; tool = 'ssh_run'; local = $true; text = "$_"; notes = @('ssh_run-deny') }
            }
        }
        { $_ -in @('web_page', 'page', 'fetch_url') } {
            $u = if ($Arg) { $Arg } elseif ($Text) { $Text } else { '' }
            $r = Invoke-PromptParleWebPageFetch -UrlOrDomain $u -MaxChars 5000
            return [pscustomobject]@{
                ok = [bool]$r.ok; tool = 'web_page'; local = $true
                text = $(if ($r.ok) { "[WEB_PAGE] $($r.url)`n$($r.text)" } else { "web_page failed: $($r.notes -join ', ')" })
                notes = @($r.notes); url = $r.url
            }
        }
        { $_ -in @('workspace_find', 'find', 'glob') } {
            $r = Invoke-PromptParleWorkspaceFind -Spec $Arg -MaxFiles 14 -MaxChars 8000
            return [pscustomobject]@{
                ok = [bool]$r.ok; tool = 'workspace_find'; local = $true
                text = $r.text; notes = @($r.notes); files = $r.files
            }
        }
        default {
            throw "Unknown local tool: $ToolId"
        }
    }
}

function Invoke-PromptParleWorkspaceFind {
    <#
    .SYNOPSIS
      0.19 hands: find files under connected local workspace by type/glob + optional query.
      Token-first: path list + short extracts only.
    #>
    [CmdletBinding()]
    param(
        [string]$Spec = '',
        [int]$MaxFiles = 14,
        [int]$MaxChars = 8000
    )
    $ws = $null
    try { $ws = Get-PromptParleWorkspace } catch { $ws = $null }
    if (-not $ws -or -not $ws.exists) {
        return [pscustomobject]@{ ok = $false; text = 'No local workspace. Browse/attach a folder first.'; notes = @('no-workspace'); files = 0 }
    }
    $root = [string]$ws.path
    $spec = if ($null -eq $Spec) { '' } else { $Spec.Trim() }
    $globs = New-Object System.Collections.Generic.List[string]
    $query = ''
    if ($spec -match '\|') {
        $left = $spec.Substring(0, $spec.IndexOf('|')).Trim()
        $query = $spec.Substring($spec.IndexOf('|') + 1).Trim()
        $spec = $left
    }
    if ($spec -match '(?i)query\s*:\s*(.+)$') {
        $query = $Matches[1].Trim()
        $spec = ($spec -replace '(?i)query\s*:\s*.+$', '').Trim()
    }
    if (-not $spec -or $spec -eq '.' -or $spec -eq '*') {
        [void]$globs.Add('*.*')
    } else {
        foreach ($part in ($spec -split '[,;\s]+')) {
            $g = $part.Trim()
            if (-not $g) { continue }
            if ($g -match '^[a-zA-Z0-9]+$') { $g = '*.' + $g }
            if ($g -notmatch '[\*\?]') { $g = '*' + $g + '*' }
            [void]$globs.Add($g)
        }
    }
    if ($globs.Count -eq 0) { [void]$globs.Add('*.*') }

    $found = New-Object System.Collections.Generic.List[object]
    $seen = @{}
    $skipDir = '(?i)([\\/](\.git|node_modules|vendor|\.next|dist|build|__pycache__|\.venv|venv)([\\/]|$))'
    try {
        foreach ($g in $globs) {
            if ($found.Count -ge ($MaxFiles * 3)) { break }
            Get-ChildItem -LiteralPath $root -Recurse -File -Filter $g -ErrorAction SilentlyContinue |
                Where-Object { $_.FullName -notmatch $skipDir -and $_.Length -lt 2MB } |
                Select-Object -First 80 |
                ForEach-Object {
                    $k = $_.FullName.ToLowerInvariant()
                    if ($seen.ContainsKey($k)) { return }
                    $seen[$k] = $true
                    $rel = $_.FullName.Substring($root.Length).TrimStart('\', '/')
                    $found.Add([pscustomobject]@{
                        path = $rel
                        full = $_.FullName
                        bytes = [int]$_.Length
                        name = $_.Name
                    })
                }
        }
    } catch {
        return [pscustomobject]@{ ok = $false; text = "workspace_find error: $_"; notes = @('find-fail'); files = 0 }
    }

    $q = $query.ToLowerInvariant()
    $picked = New-Object System.Collections.Generic.List[object]
    if ($q) {
        foreach ($f in $found) {
            if ($picked.Count -ge $MaxFiles) { break }
            $hit = $false
            if ($f.path.ToLowerInvariant().Contains($q) -or $f.name.ToLowerInvariant().Contains($q)) { $hit = $true }
            if (-not $hit) {
                try {
                    $head = Get-Content -LiteralPath $f.full -TotalCount 40 -ErrorAction SilentlyContinue | Out-String
                    if ($head -and $head.ToLowerInvariant().Contains($q)) { $hit = $true }
                } catch { }
            }
            if ($hit) { [void]$picked.Add($f) }
        }
        if ($picked.Count -eq 0) {
            foreach ($f in ($found | Select-Object -First $MaxFiles)) { [void]$picked.Add($f) }
        }
    } else {
        foreach ($f in ($found | Select-Object -First $MaxFiles)) { [void]$picked.Add($f) }
    }

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("[WORKSPACE_FIND] root=$root globs=$($globs -join ',') query=$query matches=$($picked.Count)/$($found.Count)")
    $budget = $MaxChars - 200
    $used = 0
    $n = 0
    foreach ($f in $picked) {
        $n++
        $header = "`n--- FILE: $($f.path) ($($f.bytes)b) ---`n"
        $extract = ''
        try {
            $raw = Get-Content -LiteralPath $f.full -Raw -ErrorAction Stop
            if ($null -eq $raw) { $raw = '' }
            $cap = [Math]::Min(900, [Math]::Max(200, [int]($budget / [Math]::Max(1, $picked.Count - $n + 1))))
            if ($raw.Length -gt $cap) { $extract = $raw.Substring(0, $cap) + "`n…[file budget]" }
            else { $extract = $raw }
        } catch {
            $extract = "(unreadable: $_)"
        }
        $chunk = $header + $extract
        if (($used + $chunk.Length) -gt $budget -and $n -gt 1) {
            $lines.Add("…[workspace_find char budget; $($picked.Count - $n + 1) files omitted]")
            break
        }
        $lines.Add($chunk)
        $used += $chunk.Length
    }
    if ($picked.Count -eq 0) {
        $lines.Add('(no files matched)')
    }
    $text = ($lines -join "`n")
    if ($text.Length -gt $MaxChars) { $text = $text.Substring(0, $MaxChars) + "`n…[cap]" }
    return [pscustomobject]@{
        ok = ($picked.Count -gt 0)
        text = $text
        notes = @("workspace_find:$($picked.Count)")
        files = $picked.Count
    }
}

function Get-PromptParleHandsCatalogBrief {
    return @(
        '[HANDS] client tools (0 AI tokens). Request with a hands fence: lines tool: arg',
        'web_search: q | web_page: url|domain | ssh_list: path | ssh_read: path | ssh_run: allowlisted-cmd',
        'workspace_find: *.md,*.pdf | query | relevant_slice: q | file_index | git_diff | git | connections | tree_pack: depth',
        'After [HANDS] results: answer or apply/run/file. Never teach the user the method.'
    ) -join "`n"
}

function Test-PromptParleForeignToolTheater {
    <# True when model dumped foreign tool XML / toolcall markup instead of answering or using ```hands. #>
    param([string]$Text = '')
    if (-not $Text) { return $false }
    if ($Text -match '(?is)<\s*(tool_?call|toolcall|function_?call|invoke|tool_request|xai:tool)\b') { return $true }
    if ($Text -match '(?is)</\s*(tool_?call|toolcall|function_?call)\s*>') { return $true }
    if ($Text -match '(?im)^\s*(tool_?call|function_?call|invoke_tool)\s*$') { return $true }
    if ($Text -match '(?is)```(?:html|xml|tool|json)?\s*\r?\n\s*<\s*(tool_?call|toolcall|function_?call)\b') { return $true }
    return $false
}

function ConvertFrom-PromptParleForeignToolCalls {
    <#
    .SYNOPSIS
      0.21: parse foreign model tool protocols into hands tool/arg requests.
      Handles toolcall / tool_call / function_call XML and "tool\nq is …" bodies.
    #>
    param([string]$Text = '')
    $reqs = New-Object System.Collections.Generic.List[object]
    if (-not $Text) { return @() }

    $normalizeTool = {
        param([string]$Tool)
        if (-not $Tool) { return '' }
        $t = $Tool.ToLowerInvariant().Trim()
        $t = $t -replace '^(tool_|function_|invoke_)', ''
        switch ($t) {
            'search' { return 'web_search' }
            'websearch' { return 'web_search' }
            'web-search' { return 'web_search' }
            'google' { return 'web_search' }
            'search_web' { return 'web_search' }
            'browse' { return 'web_page' }
            'open_url' { return 'web_page' }
            'fetch_url' { return 'web_page' }
            'fetch' { return 'web_page' }
            'page' { return 'web_page' }
            'read_url' { return 'web_page' }
            default { return $t }
        }
    }
    $normalizeArg = {
        param([string]$Arg, [string]$Tool)
        $a = if ($null -eq $Arg) { '' } else { $Arg.Trim() }
        $t = $Tool
        if ($a -match '(?is)^\s*(?:q|query|search|keywords?)\s*(?:is|=|:)\s*(.+)$') { $a = $Matches[1].Trim() }
        if ($a -match '(?is)^\s*(?:url|uri|link|page|domain)\s*(?:is|=|:)\s*(.+)$') {
            $a = $Matches[1].Trim().Trim('"').Trim("'")
        }
        $a = $a.Trim().Trim('"').Trim("'")
        if ($a.Length -gt 500) { $a = $a.Substring(0, 500) }
        return $a
    }

    # <toolcall>...</toolcall> and variants
    foreach ($m in [regex]::Matches($Text, '(?is)<\s*(tool_?call|toolcall|function_?call|invoke|tool_request)\b[^>]*>(.*?)</\s*\1\s*>')) {
        $body = $m.Groups[2].Value.Trim()
        $tool = ''
        $arg = ''
        if ($m.Value -match '(?i)<[^>]+\bname\s*=\s*["'']?([a-z_][a-z0-9_]*)') { $tool = $Matches[1] }
        $lines = @($body -split '\r?\n' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        if (-not $tool -and $lines.Count -gt 0 -and $lines[0] -match '^(?i)([a-z_][a-z0-9_]*)$') {
            $tool = $lines[0]
            $arg = if ($lines.Count -gt 1) { ($lines[1..($lines.Count - 1)] -join ' ').Trim() } else { '' }
        } else {
            if ($body -match '(?im)^\s*(?:name|tool|function)\s*[:=]\s*([a-z_][a-z0-9_]*)') { $tool = $Matches[1] }
            if ($body -match '(?is)(?:q|query|search|input|arguments?|parameters?)\s*(?:is|=|:)\s*(.+)$') {
                $arg = $Matches[1].Trim()
            } elseif ($lines.Count -gt 0) {
                $arg = ($lines -join ' ')
            }
        }
        if (-not $tool -and $body -match '(?i)\b(web_search|web_page|ssh_list|ssh_read|ssh_run|workspace_find|relevant_slice)\b') {
            $tool = $Matches[1]
            if (-not $arg) { $arg = $body }
        }
        $tool = & $normalizeTool $tool
        $arg = & $normalizeArg $arg $tool
        if ($tool) {
            [void]$reqs.Add([pscustomobject]@{ tool = $tool; arg = $arg; index = $m.Index; foreign = $true })
        }
    }

    # Bare / unclosed toolcall bodies
    if ($reqs.Count -eq 0 -and $Text -match '(?is)(?:tool_?call|toolcall|function_?call)') {
        if ($Text -match '(?im)\b(web_search|web_page|websearch|search_web|browse)\b') {
            $tool = & $normalizeTool $Matches[1]
            $arg = ''
            if ($Text -match '(?is)(?:q|query|search)\s*(?:is|=|:)\s*([^\r\n<]+)') { $arg = $Matches[1].Trim() }
            elseif ($Text -match '(?is)(?:url|page|domain)\s*(?:is|=|:)\s*([^\r\n<]+)') {
                $arg = $Matches[1].Trim()
                $tool = 'web_page'
            }
            $arg = & $normalizeArg $arg $tool
            if ($tool) {
                [void]$reqs.Add([pscustomobject]@{ tool = $tool; arg = $arg; index = 0; foreign = $true })
            }
        }
    }

    # fenced json/xml tool payloads
    foreach ($m in [regex]::Matches($Text, '(?ms)```(?:tool|json|xml|html)?[^\n]*\r?\n(.*?)```')) {
        $body = $m.Groups[1].Value
        if ($body -match '(?i)"(?:name|tool)"\s*:\s*"(web_search|web_page|ssh_list|ssh_read|workspace_find)"') {
            $tool = $Matches[1]
            $arg = ''
            if ($body -match '(?i)"(?:q|query|input|url|arguments?)"\s*:\s*"([^"]+)"') { $arg = $Matches[1] }
            $arg = & $normalizeArg $arg $tool
            [void]$reqs.Add([pscustomobject]@{ tool = $tool; arg = $arg; index = $m.Index; foreign = $true })
        }
    }

    return @($reqs.ToArray())
}

function Parse-PromptParleHandsBlocks {
    param([string]$Text = '')
    $reqs = New-Object System.Collections.Generic.List[object]
    if (-not $Text) { return @() }
    $rx = [regex]::new('(?ms)```hands[^\n]*\r?\n(.*?)```')
    foreach ($m in $rx.Matches($Text)) {
        $body = $m.Groups[1].Value
        foreach ($line in ($body -split '\r?\n')) {
            $ln = $line.Trim()
            if (-not $ln -or $ln.StartsWith('#')) { continue }
            $tool = ''
            $arg = ''
            if ($ln -match '^(?i)([a-z_][a-z0-9_]*)\s*:\s*(.*)$') {
                $tool = $Matches[1].Trim()
                $arg = $Matches[2].Trim()
            } elseif ($ln -match '^(?i)([a-z_][a-z0-9_]*)\s*\|\s*(.*)$') {
                $tool = $Matches[1].Trim()
                $arg = $Matches[2].Trim()
            } elseif ($ln -match '^(?i)([a-z_][a-z0-9_]*)\s+(.+)$') {
                $tool = $Matches[1].Trim()
                $arg = $Matches[2].Trim()
            } elseif ($ln -match '^(?i)([a-z_][a-z0-9_]*)$') {
                $tool = $Matches[1].Trim()
            } else { continue }
            $reqs.Add([pscustomobject]@{ tool = $tool.ToLowerInvariant(); arg = $arg; index = $m.Index })
        }
    }
    foreach ($m in [regex]::Matches($Text, '(?i)<<hands\s+([a-z_][a-z0-9_]*)\s*:\s*([^>]+)>>')) {
        $reqs.Add([pscustomobject]@{
            tool = $m.Groups[1].Value.ToLowerInvariant()
            arg = $m.Groups[2].Value.Trim()
            index = $m.Index
        })
    }
    # Foreign tool protocols → treat as hands (never show raw toolcall to user)
    foreach ($fr in @(ConvertFrom-PromptParleForeignToolCalls -Text $Text)) {
        if (-not $fr.tool) { continue }
        $dup = $false
        foreach ($existing in $reqs) {
            if ($existing.tool -eq $fr.tool -and $existing.arg -eq $fr.arg) { $dup = $true; break }
        }
        if (-not $dup) { [void]$reqs.Add($fr) }
    }
    return @($reqs.ToArray())
}

function Invoke-PromptParleHandsRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Tool,
        [string]$Arg = '',
        [int]$MaxChars = 4500
    )
    $id = $Tool.ToLowerInvariant().Trim()
    switch ($id) {
        'ls' { $id = 'ssh_list' }
        'list' { $id = 'ssh_list' }
        'search' { $id = 'web_search' }
        'web' { $id = 'web_search' }
        'fetch' { $id = 'web_page' }
        'page' { $id = 'web_page' }
        'find' { $id = 'workspace_find' }
        'glob' { $id = 'workspace_find' }
        'read' { $id = 'ssh_read' }
        'cat' { $id = 'ssh_read' }
        'run' { $id = 'ssh_run' }
        'slice' { $id = 'relevant_slice' }
        'diff' { $id = 'git_diff' }
        'index' { $id = 'file_index' }
    }
    try {
        $r = Invoke-PromptParleLocalTool -ToolId $id -Arg $Arg -Text $Arg
        $text = [string](Get-PromptParleProp $r 'text' '')
        if ($text.Length -gt $MaxChars) {
            $text = $text.Substring(0, $MaxChars) + "`n…[hands budget $MaxChars]"
        }
        $ok = $true
        try { $ok = [bool](Get-PromptParleProp $r 'ok' $true) } catch { }
        return [pscustomobject]@{
            ok = $ok
            tool = $id
            arg = $Arg
            text = $text
            notes = @(Get-PromptParleProp $r 'notes' @())
        }
    } catch {
        return [pscustomobject]@{
            ok = $false
            tool = $id
            arg = $Arg
            text = "hands error ($id): $_"
            notes = @('hands-fail')
        }
    }
}

function Format-PromptParleHandsPack {
    param(
        [object[]]$Results,
        [int]$MaxChars = 9000
    )
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('[HANDS] client results (already executed — 0 model tokens for these tools). Answer from this. Request more hands only if essential.')
    $i = 0
    foreach ($r in @($Results)) {
        $i++
        $mark = if ($r.ok) { 'ok' } else { 'FAIL' }
        $lines.Add("")
        $lines.Add("### hands#$i $($r.tool) ($mark)")
        if ($r.arg) { $lines.Add("arg: $($r.arg)") }
        $lines.Add([string]$r.text)
    }
    $text = ($lines -join "`n")
    if ($text.Length -gt $MaxChars) {
        $text = $text.Substring(0, $MaxChars) + "`n…[hands pack budget]"
    }
    return $text
}

function Test-PromptParleResponseNeedsHands {
    param([string]$Text = '')
    if (-not $Text) { return $false }
    if ($Text -match '(?ms)```hands') { return $true }
    if ($Text -match '(?i)<<hands\s+') { return $true }
    if (Test-PromptParleForeignToolTheater -Text $Text) { return $true }
    return $false
}

function Remove-PromptParleHandsBlocks {
    param([string]$Text = '')
    if (-not $Text) { return '' }
    $t = [regex]::Replace($Text, '(?ms)```hands[^\n]*\r?\n.*?```', '')
    $t = [regex]::Replace($t, '(?i)<<hands\s+[^>]+>>', '')
    # Strip foreign toolcall theater (never show to user)
    $t = [regex]::Replace($t, '(?is)```(?:html|xml|tool|json)?\s*\r?\n\s*<\s*(?:tool_?call|toolcall|function_?call)\b[\s\S]*?```', '')
    $t = [regex]::Replace($t, '(?is)<\s*(tool_?call|toolcall|function_?call|invoke|tool_request)\b[^>]*>[\s\S]*?</\s*\1\s*>', '')
    $t = [regex]::Replace($t, '(?is)<\s*(tool_?call|toolcall|function_?call)\b[^>]*/\s*>', '')
    $t = [regex]::Replace($t, '(?im)^\s*(tool_?call|function_?call|invoke_tool)\s*$', '')
    return $t.Trim()
}

function Test-PromptParleResponseIsToolTheaterOnly {
    <# True when stripped response has no real user-facing answer (only tool markup residue). #>
    param([string]$Text = '')
    if (-not $Text) { return $true }
    $t = Remove-PromptParleHandsBlocks -Text $Text
    $t = [regex]::Replace($t, '(?is)<[^>]+>', ' ')
    $t = [regex]::Replace($t, '\s+', ' ').Trim()
    if ($t.Length -lt 24) { return $true }
    if ($t -match '(?i)^(web_search|web_page|q is|query is|searching|looking up)\b' -and $t.Length -lt 120) { return $true }
    return $false
}

function Invoke-PromptParleAgentTurn {
    <#
    .SYNOPSIS
      0.20 token-first agent loop: brain (API) + hands (local/SSH/web).
      Max rounds capped by dial. After hands, next round = [HANDS] pack + compact evidence spine
      (PROVENANCE/GROUNDING/OBSERVE excerpt) so confidence is not dropped for tokens.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [string]$Context = '',
        [string]$System = '',
        [string]$Runtime = '',
        [string]$Provider = 'openai',
        [string]$Profile = 'general',
        [int]$CompressionLevel = 3,
        [string]$Model = '',
        [object]$Images = $null,
        [int]$MaxRounds = 0,
        [switch]$OptimizeOnly
    )
    if ($MaxRounds -le 0) {
        $MaxRounds = switch ($CompressionLevel) {
            1 { 4 }
            2 { 3 }
            3 { 3 }
            4 { 2 }
            5 { 2 }
            default { 3 }
        }
    }
    if ($OptimizeOnly) {
        $p = @{
            Prompt = $Prompt; Context = $Context; System = $System; Runtime = $Runtime
            Provider = $Provider; Profile = $Profile; CompressionLevel = $CompressionLevel
            Quiet = $true; Raw = $true; OptimizeOnly = $true
        }
        if ($Model) { $p.Model = $Model }
        return Invoke-PromptParle @p
    }

    $handsCatalog = Get-PromptParleHandsCatalogBrief
    $baseRuntime = if ($Runtime) { $Runtime.Trim() } else { '' }
    $runtime = ($baseRuntime + ' AGENT 0.20 token-first: use hands fence (tool: arg) when you need client evidence; keep requests tiny; when done, final answer with apply/run/file — no method homework. Never invent product facts not in [OBSERVE]/[HANDS]/[EVIDENCE_SPINE].').Trim()

    # Frozen prep evidence for post-pass + spine (agent must not discard confidence for tokens)
    $prepEvidence = if ($Context) { [string]$Context } else { '' }
    $evidenceSpine = ''
    try { $evidenceSpine = Get-PromptParleEvidenceSpine -Context $prepEvidence -MaxChars 3200 } catch { $evidenceSpine = '' }

    $roundContext = $Context
    if ($roundContext) {
        if ($roundContext -notmatch '(?m)^\[HANDS\]') {
            $roundContext = $handsCatalog + "`n`n" + $roundContext
        }
    } else {
        $roundContext = $handsCatalog
    }

    $roundPrompt = $Prompt
    $allHands = New-Object System.Collections.Generic.List[object]
    $sumOrig = 0
    $sumOpt = 0
    $roundsUsed = 0
    $seenKeys = @{}
    $lastResp = ''
    $lastResult = $null

    for ($round = 1; $round -le $MaxRounds; $round++) {
        $roundsUsed = $round
        Write-Host ("  agent: round {0}/{1} (token-first hands loop)" -f $round, $MaxRounds) -ForegroundColor DarkCyan

        $params = @{
            Prompt           = $roundPrompt
            Context          = $roundContext
            System           = $System
            Runtime          = $runtime
            Provider         = $Provider
            Profile          = $Profile
            CompressionLevel = $CompressionLevel
            Quiet            = $true
            Raw              = $true
        }
        if ($Model) { $params.Model = $Model }
        if ($Images -and $round -eq 1) { $params.Images = $Images }

        $result = Invoke-PromptParle @params
        $lastResult = $result
        $meta = Get-PromptParleProp $result 'metadata'
        if ($null -eq $meta) { $meta = Get-PromptParleProp $result 'Metadata' }
        if ($meta) {
            try { $sumOrig += [int](Get-PromptParleProp $meta 'original_tokens' 0) } catch { }
            try { $sumOpt += [int](Get-PromptParleProp $meta 'optimized_tokens' 0) } catch { }
        }
        $resp = [string](Get-PromptParleProp $result 'response' (Get-PromptParleProp $result 'Response' ''))
        $lastResp = $resp

        if (-not (Test-PromptParleResponseNeedsHands -Text $resp)) {
            break
        }

        $reqs = @(Parse-PromptParleHandsBlocks -Text $resp)
        if ($reqs.Count -eq 0) { break }

        $batch = New-Object System.Collections.Generic.List[object]
        foreach ($req in $reqs) {
            if ($batch.Count -ge 6) { break }
            $key = ($req.tool + '|' + $req.arg).ToLowerInvariant()
            if ($seenKeys.ContainsKey($key)) { continue }
            $seenKeys[$key] = $true
            $hr = Invoke-PromptParleHandsRequest -Tool $req.tool -Arg $req.arg -MaxChars 4500
            [void]$batch.Add($hr)
            [void]$allHands.Add($hr)
            Write-Host ("  hands: {0} ({1}) {2}c" -f $hr.tool, $(if ($hr.ok) { 'ok' } else { 'FAIL' }), $hr.text.Length) -ForegroundColor Cyan
        }
        if ($batch.Count -eq 0) {
            $roundPrompt = $Prompt + "`n`n[CLIENT] Hands already provided earlier this turn. Give the final answer now — no more hands requests."
            $packEmpty = Format-PromptParleHandsPack -Results @($allHands.ToArray()) -MaxChars 9000
            $roundContext = if ($evidenceSpine) {
                ($handsCatalog + "`n`n" + $evidenceSpine + "`n`n" + $packEmpty)
            } else {
                ($handsCatalog + "`n`n" + $packEmpty)
            }
            continue
        }

        $pack = Format-PromptParleHandsPack -Results @($allHands.ToArray()) -MaxChars 9000
        $roundContext = if ($evidenceSpine) {
            ($handsCatalog + "`n`n" + $evidenceSpine + "`n`n" + $pack)
        } else {
            ($handsCatalog + "`n`n" + $pack)
        }
        $roundPrompt = @(
            $Prompt.Trim()
            ''
            '[CLIENT DIRECTIVE — hands fulfilled · token-first 0.20]'
            'Client already ran hands tools. Results are in [HANDS] context.'
            'If [PROVENANCE]/[EVIDENCE_SPINE]/[GROUNDING] present, treat as client truth — do not invent product facts beyond them.'
            'Produce the FINAL user-facing answer now (or apply/run/file).'
            'Do not re-request the same tools. Do not dump methods. Be concise.'
        ) -join "`n"

        if ($round -ge $MaxRounds) {
            Write-Host '  agent: max rounds — final synthesis call' -ForegroundColor DarkYellow
            $params2 = @{
                Prompt           = $roundPrompt
                Context          = $roundContext
                System           = $System
                Runtime          = ($runtime + ' FINAL ROUND: answer now, no hands.')
                Provider         = $Provider
                Profile          = $Profile
                CompressionLevel = $CompressionLevel
                Quiet            = $true
                Raw              = $true
            }
            if ($Model) { $params2.Model = $Model }
            $result = Invoke-PromptParle @params2
            $lastResult = $result
            $meta = Get-PromptParleProp $result 'metadata'
            if ($meta) {
                try { $sumOrig += [int](Get-PromptParleProp $meta 'original_tokens' 0) } catch { }
                try { $sumOpt += [int](Get-PromptParleProp $meta 'optimized_tokens' 0) } catch { }
            }
            $lastResp = [string](Get-PromptParleProp $result 'response' (Get-PromptParleProp $result 'Response' ''))
            $roundsUsed++
            break
        }
    }

    # Never show raw hands fences or foreign toolcall XML to the user
    $rawFinal = [string]$lastResp
    $hadToolMarkup = (Test-PromptParleResponseNeedsHands -Text $rawFinal) -or (Test-PromptParleForeignToolTheater -Text $rawFinal) -or (Test-PromptParleResponseIsToolTheaterOnly -Text $rawFinal)

    # Emergency: foreign toolcall never entered the hands loop (parse miss) → run tools now
    if ($hadToolMarkup -and $allHands.Count -eq 0) {
        $emergency = @(ConvertFrom-PromptParleForeignToolCalls -Text $rawFinal)
        if ($emergency.Count -eq 0) { $emergency = @(Parse-PromptParleHandsBlocks -Text $rawFinal) }
        foreach ($req in $emergency) {
            if ($allHands.Count -ge 4) { break }
            if (-not $req.tool) { continue }
            $hr = Invoke-PromptParleHandsRequest -Tool $req.tool -Arg $req.arg -MaxChars 4500
            [void]$allHands.Add($hr)
            Write-Host ("  hands(emergency): {0} ({1})" -f $hr.tool, $(if ($hr.ok) { 'ok' } else { 'FAIL' })) -ForegroundColor Magenta
        }
    }

    if ($hadToolMarkup) {
        $stripped = Remove-PromptParleHandsBlocks -Text $rawFinal
        if ((Test-PromptParleResponseIsToolTheaterOnly -Text $rawFinal) -or (-not $stripped) -or $stripped.Length -lt 24) {
            if ($allHands.Count -gt 0) {
                $lastResp = @(
                    '**Client ran tools (model returned tool markup instead of an answer).**'
                    ''
                    Format-PromptParleHandsPack -Results @($allHands.ToArray()) -MaxChars 6000
                    ''
                    '_Raw toolcall/XML is never shown. Ask a follow-up for a prose summary if needed._'
                ) -join "`n"
            } else {
                $lastResp = @(
                    '**Blocked: model emitted foreign tool markup instead of answering.**'
                    'Client could not map it to hands tools. Retry — research on a .com domain should auto-fetch via observe first.'
                ) -join "`n"
            }
        } else {
            $lastResp = $stripped
        }
    }

    # Evidence for post-pass: prep + hands (so grounding sees web_page results from agent rounds)
    $evidenceContext = $prepEvidence
    if ($allHands.Count -gt 0) {
        try {
            $hp = Format-PromptParleHandsPack -Results @($allHands.ToArray()) -MaxChars 12000
            if ($evidenceContext) { $evidenceContext = $evidenceContext + "`n`n" + $hp }
            else { $evidenceContext = $hp }
        } catch { }
    }

    $metaOut = $null
    if ($lastResult) {
        $metaOut = Get-PromptParleProp $lastResult 'metadata'
        if ($null -eq $metaOut) { $metaOut = Get-PromptParleProp $lastResult 'Metadata' }
    }
    $agentMeta = [ordered]@{
        agent_rounds         = $roundsUsed
        hands_count          = $allHands.Count
        hands_tools          = @($allHands | ForEach-Object { $_.tool } | Select-Object -Unique)
        tokens_sum_original  = $sumOrig
        tokens_sum_optimized = $sumOpt
        token_first          = $true
        architecture         = '0.21-brain-hands-quality'
        has_evidence_spine   = [bool]$evidenceSpine
    }

    if ($null -ne $lastResult) {
        try {
            if ($lastResult.PSObject.Properties['response']) {
                $lastResult.response = $lastResp
            } elseif ($lastResult.PSObject.Properties['Response']) {
                $lastResult.Response = $lastResp
            } else {
                $lastResult | Add-Member -NotePropertyName response -NotePropertyValue $lastResp -Force
            }
            $lastResult | Add-Member -NotePropertyName agent -NotePropertyValue ([pscustomobject]$agentMeta) -Force
            $lastResult | Add-Member -NotePropertyName evidence_context -NotePropertyValue $evidenceContext -Force
            return $lastResult
        } catch {
            return [pscustomobject]@{
                response          = $lastResp
                metadata          = $metaOut
                agent             = [pscustomobject]$agentMeta
                evidence_context  = $evidenceContext
                optimized_prompt  = Get-PromptParleProp $lastResult 'optimized_prompt' $null
            }
        }
    }
    return [pscustomobject]@{
        response         = $lastResp
        metadata         = $metaOut
        agent            = [pscustomobject]$agentMeta
        evidence_context = $evidenceContext
    }
}

function Get-PromptParleSshPathCandidatesFromPrompt {
    <#
    .SYNOPSIS
      Extract file/path tokens from user text for SSH auto-fetch against ssh_cwd.
    #>
    [CmdletBinding()]
    param([string]$Prompt = '')
    $out = New-Object System.Collections.Generic.List[string]
    $seen = @{}
    $add = {
        param([string]$Raw)
        if (-not $Raw) { return }
        $t = $Raw.Trim().Trim('"').Trim("'").Trim('`').TrimEnd('.,);:]')
        if (-not $t) { return }
        if ($t.Length -gt 260) { return }
        if ($t -match '[;|&`$<>]') { return }
        if ($t -match '(?i)^https?://') { return }
        if ($t -match '^\d+\.\d+') { return }
        $isPath = ($t -match '[/\\]') -or ($t -match '^\./') -or ($t -match '^~/') -or ($t -match '\.[A-Za-z0-9]{1,12}$')
        if (-not $isPath) { return }
        if ($t -match '(?i)^(e\.g|i\.e|etc|com|org|net)$') { return }
        $key = $t.ToLowerInvariant()
        if ($seen.ContainsKey($key)) { return }
        $seen[$key] = $true
        [void]$out.Add($t)
    }

    if (-not $Prompt) { return @() }

    foreach ($m in [regex]::Matches($Prompt, '["''`]([^"''`\n]{1,240})["''`]')) {
        & $add $m.Groups[1].Value
    }
    foreach ($m in [regex]::Matches($Prompt, '(?i)\b(?:read|open|cat|fetch|load|review|attach|check|look\s+at|show|get)\s+["''`]?([^\s"''`,;:]+)')) {
        & $add $m.Groups[1].Value
    }
    foreach ($m in [regex]::Matches($Prompt, '(?i)(?<![A-Za-z0-9_])((?:~|/|\./|\.\./)[A-Za-z0-9_./+\-]+|[A-Za-z0-9_.+\-]+\.(?:md|txt|ps1|psm1|psd1|php|js|ts|tsx|jsx|py|json|ya?ml|toml|sh|bash|zsh|go|rs|cs|java|css|html?|xml|sql|log|cfg|conf|ini|env|csv|tsv|c|h|cpp|hpp|rb|pl|swift|kt|gradle|csproj|sln|tf|hcl|proto|rsx|vue|svelte|r|m|mm|asm|s|diff|patch|lock|sum|mod))(?![A-Za-z0-9_])')) {
        & $add $m.Groups[1].Value
    }
    if ($Prompt -match '(?i)handoff|PROMPTPARLE_HANDOFF|session\s+hand') {
        & $add 'PROMPTPARLE_HANDOFF.md'
        & $add 'HANDOFF.md'
    }
    return @($out.ToArray())
}

function Test-PromptParleProductWorkIntent {
    <# True when engineering/product context may need live evidence (broad — deep fetch is turn-kind gated). #>
    param([string]$Prompt = '')
    $p = if ($null -eq $Prompt) { '' } else { $Prompt }
    if (-not $p.Trim()) { return $false }
    # Almost any non-trivial turn with SSH up benefits from product bind status; exclude pure small talk
    if ($p.Trim().Length -lt 8) { return $false }
    if ($p -match '(?is)^(hi|hello|hey|thanks|thank you|ok|okay|sure|got it|k|cool|nice)[.!\s]*$') { return $false }
    return $true
}

function Get-PromptParleSshProductWorkPack {
    <#
    .SYNOPSIS
      0.15 architecture: evidence by product bind + turn kind — not keyword mole packs.
      Always (SSH): live status under product_root + capability index.
      Deep UI/portal snips only on implement (or explicit code-path ask).
    #>
    [CmdletBinding()]
    param(
        [string]$Prompt = '',
        [int]$MaxChars = 14000,
        [string]$TurnKind = 'chat'
    )
    $empty = [pscustomobject]@{ text = ''; notes = @(); ok = $false }
    $ws = $null
    try { $ws = Get-PromptParleWorkspace } catch { return $empty }
    $target = [string](Get-PromptParleProp $ws 'ssh_target' '')
    if (-not $target) { return $empty }

    $bind = Resolve-PromptParleProductBind
    $pp = [string]$bind.root
    $live = [string]$bind.live
    if (-not $TurnKind) { $TurnKind = Get-PromptParleTurnKind -Prompt $Prompt }

    $notes = New-Object System.Collections.Generic.List[string]
    $parts = New-Object System.Collections.Generic.List[string]
    $used = 0

    $ppQ = $pp -replace "'", "'\''"
    $liveQ = $live -replace "'", "'\''"

    $remoteCmd = @"
set +e
PP='$ppQ'
LIVE='$liveQ'
echo "=== PP_HOST `$(hostname) ==="
echo "=== PP_PATH `$PP ==="
echo "=== LIVE `$LIVE ==="
echo "=== TURN $TurnKind ==="
if [ -d "`$PP" ]; then
  cd "`$PP" || exit 0
  echo "=== GIT_STATUS ==="
  git status -sb 2>/dev/null | head -20
  echo "=== GIT_LOG ==="
  git log -5 --oneline 2>/dev/null
  echo "=== VERSION ==="
  grep -E "ModuleVersion" powershell/PromptParle/PromptParle.psd1 2>/dev/null | head -3
  echo "=== CAPABILITY_INDEX ==="
  echo "portal:"; find src/app -maxdepth 3 -type d 2>/dev/null | head -40
  echo "desktop:"; ls powershell/PromptParle/local-ui/index.html powershell/PromptParle/PromptParle.psm1 HANDOFF.md 2>/dev/null
  echo "api:"; ls src/app/api 2>/dev/null | head -20
  echo "lib:"; ls src/lib 2>/dev/null | head -25
  echo "prisma:"; ls prisma 2>/dev/null | head -10
else
  echo "PP_PATH_MISSING"
fi
if [ -d "`$LIVE" ]; then
  echo "=== LIVE_OK ==="
  cat "`$LIVE/public/version.txt" 2>/dev/null
else
  echo "LIVE_PATH_MISSING"
fi
"@
    try {
        $r = Invoke-PromptParleSsh -RemoteCommand $remoteCmd -TimeoutSec 35 -SkipSessionCwd
        $body = [string]$r.text
        if ($body -and $body.Trim()) {
            $room = [Math]::Max(400, $MaxChars - $used - 80)
            if ($body.Length -gt $room) { $body = $body.Substring(0, $room) + "`n…[product evidence truncated]" }
            $parts.Add("[SSH] Live product status under bind (auto)`n$body")
            $used += $body.Length
            $notes.Add('product-bind')
        }
    } catch {
        $notes.Add('product-bind-skip')
        return [pscustomobject]@{ text = ''; notes = @($notes.ToArray()); ok = $false }
    }

    $deep = ($TurnKind -eq 'implement') -or ($Prompt -match '(?i)\b(show code|open |read file|in local-ui|in src/|settings form|v1-auth)\b')
    if ($deep) {
        $wantUi = $Prompt -match '(?i)local-ui|index\.html|composer|activity log|sidebar|attachment|paste|update button|chat title|history'
        $wantPortal = $Prompt -match '(?i)portal|settings|api|cidr|allowlist|auth|login|register|prisma|src/app|/var/www|ip.?restrict|network security'
        if (-not $wantUi -and -not $wantPortal) { $wantPortal = $true; $wantUi = $true }

        if ($wantUi) {
            $uiCmd = @"
set +e
PP='$ppQ'
f="`$PP/powershell/PromptParle/local-ui/index.html"
echo "=== local-ui vanilla HTML (no invent Tailwind) ==="
if [ -f "`$f" ]; then
  grep -n "sideActivityLog\|clearComposer\|form.addEventListener\|menuBtn\|updateBtn\|function addMsg" "`$f" 2>/dev/null | head -40
  tail -n 120 "`$f" 2>/dev/null | head -c 6000
fi
"@
            try {
                $ru = Invoke-PromptParleSsh -RemoteCommand $uiCmd -TimeoutSec 40 -SkipSessionCwd
                $ub = [string]$ru.text
                if ($ub -and $ub.Trim().Length -gt 40) {
                    $room = [Math]::Max(400, $MaxChars - $used - 80)
                    if ($ub.Length -gt $room) { $ub = $ub.Substring(0, $room) + "`n…[truncated]" }
                    $parts.Add("[SSH] Desktop UI evidence`n$ub")
                    $used += $ub.Length
                    $notes.Add('product-ui')
                }
            } catch { $notes.Add('product-ui-skip') }
        }
        if ($wantPortal) {
            $portalCmd = @"
set +e
PP='$ppQ'
LIVE='$liveQ'
echo "=== portal monorepo evidence ==="
ls -la "`$PP/src/app/app/settings" "`$PP/src/app/api/settings" "`$PP/src/app/api/auth" "`$PP/src/app/api/v1" 2>/dev/null
grep -n "model User\|model Session\|model ApiKey" "`$PP/prisma/schema.prisma" 2>/dev/null | head -20
head -n 60 "`$PP/src/app/app/settings/page.tsx" 2>/dev/null
head -n 80 "`$PP/src/app/app/settings/SettingsForm.tsx" 2>/dev/null
head -n 60 "`$PP/src/app/api/settings/route.ts" 2>/dev/null
head -n 60 "`$PP/src/lib/v1-auth.ts" 2>/dev/null
ls -la "`$LIVE" 2>/dev/null | head -12
"@
            try {
                $rp = Invoke-PromptParleSsh -RemoteCommand $portalCmd -TimeoutSec 40 -SkipSessionCwd
                $pb = [string]$rp.text
                if ($pb -and $pb.Trim().Length -gt 40) {
                    $room = [Math]::Max(400, $MaxChars - $used - 80)
                    if ($pb.Length -gt $room) { $pb = $pb.Substring(0, $room) + "`n…[truncated]" }
                    $parts.Add("[SSH] Portal evidence`n$pb")
                    $used += $pb.Length
                    $notes.Add('product-portal')
                }
            } catch { $notes.Add('product-portal-skip') }
        }
    }

    if ($parts.Count -eq 0) {
        return [pscustomobject]@{ text = ''; notes = @($notes.ToArray()); ok = $false }
    }
    return [pscustomobject]@{
        text  = ($parts -join "`n`n")
        notes = @($notes.ToArray())
        ok    = $true
    }
}

function Get-PromptParleSshPromptEvidence {
    <#
    .SYNOPSIS
      When SSH is connected with a cwd, auto-fetch files named in the user prompt
      from that remote working directory into [SSH] evidence blocks.
    .DESCRIPTION
      Doctrine: SSH cwd is a live project root for the session. The model must not
      claim "file does not exist" when the path is under that cwd without a failed fetch.
      Relative names resolve via the existing session ssh_cwd (cd prefix on remote).
    #>
    [CmdletBinding()]
    param(
        [string]$Prompt = '',
        [string]$Profile = '',
        [int]$MaxFiles = 4,
        [int]$MaxChars = 12000
    )
    $empty = [pscustomobject]@{ text = ''; notes = @(); files = 0; paths = @() }
    $ws = $null
    try { $ws = Get-PromptParleWorkspace } catch { return $empty }
    $target = [string](Get-PromptParleProp $ws 'ssh_target' '')
    if (-not $target) { return $empty }

    $cwd = [string](Get-PromptParleProp $ws 'ssh_cwd' '')
    $cands = @(Get-PromptParleSshPathCandidatesFromPrompt -Prompt $Prompt)
    if ($cands.Count -eq 0 -and $Profile -match '(?i)security') {
        if ($Prompt -match '(?i)handoff|PROMPTPARLE|\.md\b') {
            $cands = @('PROMPTPARLE_HANDOFF.md', 'HANDOFF.md')
        }
    }
    if ($cands.Count -eq 0) { return $empty }

    $blocks = New-Object System.Collections.Generic.List[string]
    $notes = New-Object System.Collections.Generic.List[string]
    $got = New-Object System.Collections.Generic.List[string]
    $used = 0
    $n = 0
    $hostLabel = $target
    if ($cwd) { $hostLabel = "$target · $cwd" }

    foreach ($raw in $cands) {
        if ($n -ge $MaxFiles) { break }
        if ($used -ge $MaxChars) { break }
        $q = $raw -replace "'", "'\''"
        $remoteCmd = @"
set +e
p='$q'
if [ -f "`$p" ]; then
  echo __PP_SSH_OK__
  echo "`$p"
  wc -c < "`$p" | tr -d ' \n'
  echo
  cat -- "`$p"
elif [ -n "`${PWD:-}" ] && [ -f "`$PWD/`$p" ]; then
  echo __PP_SSH_OK__
  echo "`$PWD/`$p"
  wc -c < "`$PWD/`$p" | tr -d ' \n'
  echo
  cat -- "`$PWD/`$p"
else
  echo __PP_SSH_MISS__
  echo "`$p"
fi
"@
        $r = $null
        try {
            $r = Invoke-PromptParleSsh -RemoteCommand $remoteCmd -TimeoutSec 30
        } catch {
            $notes.Add("ssh-fetch-err:$raw")
            continue
        }
        $body = [string]$r.text
        if ($body -notmatch '__PP_SSH_OK__') {
            $notes.Add("ssh-miss:$raw")
            continue
        }
        $lines = @($body -split "`n")
        $idx = -1
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match '__PP_SSH_OK__') { $idx = $i; break }
        }
        if ($idx -lt 0) { continue }
        $resolved = if ($idx + 1 -lt $lines.Count) { $lines[$idx + 1].Trim() } else { $raw }
        $contentLines = @()
        if ($idx + 3 -lt $lines.Count) {
            $contentLines = $lines[($idx + 3)..($lines.Count - 1)]
        } elseif ($idx + 2 -lt $lines.Count) {
            $contentLines = $lines[($idx + 2)..($lines.Count - 1)]
        }
        $content = ($contentLines -join "`n")
        if (-not $content) { continue }

        $room = $MaxChars - $used - 80
        if ($room -lt 200) { break }
        if ($content.Length -gt $room) {
            $content = $content.Substring(0, $room) + "`n…[ssh truncated]"
        }
        $leaf = Split-Path -Leaf $resolved
        if (-not $leaf) { $leaf = $raw }
        $block = "===== FILE (SSH): $leaf =====`n# host: $hostLabel`n# path: $resolved`n$content"
        [void]$blocks.Add($block)
        [void]$got.Add($resolved)
        $used += $block.Length
        $n++
        $notes.Add("ssh-ok:$leaf")
    }

    if ($blocks.Count -eq 0) {
        return [pscustomobject]@{
            text  = ''
            notes = @($notes.ToArray())
            files = 0
            paths = @()
        }
    }

    $header = '[SSH] Auto-fetched from session SSH cwd (live evidence — do not invent paths)'
    $textOut = $header + "`n`n" + ($blocks -join "`n`n")
    return [pscustomobject]@{
        text  = $textOut
        notes = @($notes.ToArray())
        files = $blocks.Count
        paths = @($got.ToArray())
    }
}

# =============================================================================
# 0.18 — Obligation pipeline (client-first observe · mutate · deliver)
# Doctrine: if the client can obtain the fact, the model must not answer with the method.
# =============================================================================

function Get-PromptParleOpenObligation {
    <# Sticky open document/implement contract from session.json. #>
    $st = $null
    try { $st = Get-PromptParleSessionState } catch { $st = $null }
    $kind = if ($st) { [string](Get-PromptParleProp $st 'open_obligation_kind' '') } else { '' }
    $art  = if ($st) { [string](Get-PromptParleProp $st 'open_obligation_artifact' '') } else { '' }
    $src  = if ($st) { [string](Get-PromptParleProp $st 'open_obligation_source' '') } else { '' }
    $ref  = if ($st) { [string](Get-PromptParleProp $st 'open_obligation_source_ref' '') } else { '' }
    return [pscustomobject]@{
        kind     = $kind.Trim().ToLowerInvariant()
        artifact = $art.Trim()
        source   = $src.Trim().ToLowerInvariant()
        source_ref = $ref.Trim()
    }
}

function Set-PromptParleOpenObligation {
    param(
        [string]$Kind = '',
        [string]$Artifact = '',
        [string]$Source = '',
        [string]$SourceRef = '',
        [switch]$Clear
    )
    try {
        $st = Get-PromptParleSessionState
        if ($Clear) {
            $st = New-PromptParleSessionSnapshot -Base $st `
                -OpenObligationKind '' -OpenObligationArtifact '' `
                -OpenObligationSource '' -OpenObligationSourceRef ''
        } else {
            $st = New-PromptParleSessionSnapshot -Base $st `
                -OpenObligationKind $Kind -OpenObligationArtifact $Artifact `
                -OpenObligationSource $Source -OpenObligationSourceRef $SourceRef
        }
        Save-PromptParleSessionState -State $st
    } catch { }
}

function Get-PromptParleUrlsFromText {
    param([string]$Text = '')
    $out = New-Object System.Collections.Generic.List[string]
    $seen = @{}
    if (-not $Text) { return @() }
    foreach ($m in [regex]::Matches($Text, 'https?://[^\s<>\"''\)\]]+')) {
        $u = $m.Value.Trim().TrimEnd('.,;:)')
        $k = $u.ToLowerInvariant()
        if (-not $seen.ContainsKey($k)) { $seen[$k] = $true; [void]$out.Add($u) }
    }
    return @($out.ToArray())
}

function Get-PromptParleDomainsFromText {
    <# Structural domain tokens (not file.ext code names). #>
    param([string]$Text = '')
    $out = New-Object System.Collections.Generic.List[string]
    $seen = @{}
    if (-not $Text) { return @() }
    $codeExt = '(?i)\.(?:md|txt|ps1|psm1|psd1|php|js|ts|tsx|jsx|py|json|ya?ml|toml|sh|go|rs|cs|java|css|html?|xml|sql|log|cfg|conf|ini|env|csv|lock|prisma|vue|svelte)$'
    foreach ($m in [regex]::Matches($Text, '(?i)\b(?:www\.)?([a-z0-9](?:[a-z0-9\-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9\-]{0,61}[a-z0-9])?)+)\b')) {
        $d = $m.Groups[1].Value.Trim().TrimEnd('.')
        if (-not $d) { continue }
        if ($d -match $codeExt) { continue }
        if ($d -notmatch '(?i)\.(com|org|net|io|ai|dev|co|info|biz|us|uk|gov|edu|app|cloud|tech)(?:\.[a-z]{2})?$') { continue }
        # skip pure version-like 1.2.3
        if ($d -match '^\d+(\.\d+)+$') { continue }
        $k = $d.ToLowerInvariant()
        if (-not $seen.ContainsKey($k)) { $seen[$k] = $true; [void]$out.Add($d) }
    }
    return @($out.ToArray())
}

function Get-PromptParlePathsFromText {
    <# Absolute or project-looking paths for observe list/read. #>
    param([string]$Text = '')
    $out = New-Object System.Collections.Generic.List[string]
    $seen = @{}
    if (-not $Text) { return @() }
    foreach ($m in [regex]::Matches($Text, '(?i)(?<![A-Za-z0-9_])((?:/home|/var|/opt|/usr|/tmp|/etc|~)[A-Za-z0-9_./+\-]{2,220})')) {
        $p = $m.Groups[1].Value.Trim().TrimEnd('.,);:')
        $k = $p.ToLowerInvariant()
        if (-not $seen.ContainsKey($k)) { $seen[$k] = $true; [void]$out.Add($p) }
    }
    foreach ($m in [regex]::Matches($Text, '(?i)(?<![A-Za-z0-9_])((?:\./|\.\./)[A-Za-z0-9_./+\-]{1,200})')) {
        $p = $m.Groups[1].Value.Trim().TrimEnd('.,);:')
        $k = $p.ToLowerInvariant()
        if (-not $seen.ContainsKey($k)) { $seen[$k] = $true; [void]$out.Add($p) }
    }
    return @($out.ToArray())
}

function Resolve-PromptParleTurnObligation {
    <#
    .SYNOPSIS
      0.18: classify owed outcome for this turn (not phrase theater).
      Modes: observe | mutate | deliver | reason  (primary mode; observe can co-occur with deliver)
    #>
    [CmdletBinding()]
    param(
        [string]$Prompt = '',
        [object[]]$History = @()
    )
    $p = if ($null -eq $Prompt) { '' } else { $Prompt.Trim() }
    $open = Get-PromptParleOpenObligation
    $urls = @(Get-PromptParleUrlsFromText -Text $p)
    $domains = @(Get-PromptParleDomainsFromText -Text $p)
    $paths = @(Get-PromptParlePathsFromText -Text $p)

    $wantWeb = $false
    if ($urls.Count -gt 0) { $wantWeb = $true }
    if (Test-PromptParleWebSearchIntent -Prompt $p) { $wantWeb = $true }
    if ($domains.Count -gt 0 -and ($p -match '(?i)\b(search|website|site|online|web|url|from|of|about|summar|capabilit|strengths?|research|understand|solution|product|overview|features?|one.?page|executive)\b')) {
        $wantWeb = $true
    }
    # Sticky source correction: open document + user points at website/domain
    if ($open.kind -eq 'document' -and (
            $p -match '(?i)\b(from the website|from (their|the) site|from the web|not (from )?memory|I said from)\b' `
            -or $p -match '(?i)\bfrom\b.{0,60}\bwebsite\b' `
            -or $domains.Count -gt 0 -or $urls.Count -gt 0
        )) {
        $wantWeb = $true
    }
    # Any turn that names a public site as the subject to research/understand
    if (-not $wantWeb -and $domains.Count -gt 0 -and $p -match '(?i)\b(website|web site|from|search|summar|capabilit|strengths?|research|understand|solution|product|official|overview)\b') {
        $wantWeb = $true
    }
    # Domain present + "can you / please / I would like" → treat as web observe
    if (-not $wantWeb -and $domains.Count -gt 0 -and $p -match '(?i)\b(can you|please|i would like|help me|tell me)\b') {
        $wantWeb = $true
    }

    $wantList = [bool]($p -match '(?i)\b(list(\s+the)?(\s+dir|\s+directory|\s+files|\s+folder)?|directory listing|dir listing|\bls\b|show (me )?(the )?(files|contents|listing)|what''?s in|whats in|tree\s+(the\s+)?(dir|directory|folder)|contents of)\b')
    $wantRead = [bool]($p -match '(?i)\b(read|cat|show|open|fetch|get)\b.+\.(md|txt|ps1|php|js|ts|json|yml|yaml|log|conf)\b')
    if ($paths.Count -gt 0 -and ($wantList -or $p -match '(?i)\b(list|ls|dir|directory|folder|contents)\b')) {
        $wantList = $true
    }

    $wantDeliver = [bool]($p -match '(?i)\b(one[\s-]?page|one[\s-]?pager|executive summary|write me (a |an )?(article|summary|brief|report|pdf|docx|document)|deliverable|download(able)?|as (a )?(pdf|docx|markdown|md)\b)')
    if ($open.kind -eq 'document' -and $p -match '(?i)\b(from the website|from (their|the) site|do it|generate|again|now|updated|strictly)\b') {
        $wantDeliver = $true
    }

    $wantMutate = $false
    try {
        $tk = Get-PromptParleTurnKind -Prompt $p -History $History
        if ($tk -eq 'implement') { $wantMutate = $true }
    } catch { }
    if ($p -match '(?i)\b(implement|apply path|ship it|get it done|fix the|add the|wire up)\b') { $wantMutate = $true }

    # Primary mode priority: mutate > deliver > observe > reason
    $mode = 'reason'
    if ($wantMutate) { $mode = 'mutate' }
    elseif ($wantDeliver) { $mode = 'deliver' }
    elseif ($wantWeb -or $wantList -or $wantRead) { $mode = 'observe' }

    $artifact = $open.artifact
    if ($wantDeliver) {
        if ($p -match '(?i)one[\s-]?page|executive summary') { $artifact = 'one-page executive summary' }
        elseif ($p -match '(?i)article') { $artifact = 'article' }
        elseif (-not $artifact) { $artifact = 'document' }
    }

    $source = $open.source
    $sourceRef = $open.source_ref
    if ($wantWeb) {
        $source = 'web'
        if ($urls.Count -gt 0) { $sourceRef = $urls[0] }
        elseif ($domains.Count -gt 0) { $sourceRef = $domains[0] }
        elseif ($sourceRef) { }
        else { $sourceRef = '' }
    } elseif ($p -match '\[ATTACHED THIS TURN' -or $p -match '(?i)attached') {
        $source = 'attach'
    }

    $observe = New-Object System.Collections.Generic.List[string]
    if ($wantWeb) { [void]$observe.Add('web') }
    if ($wantList) { [void]$observe.Add('ssh_list') }
    if ($wantRead) { [void]$observe.Add('ssh_read') }

    return [pscustomobject]@{
        mode       = $mode
        observe    = @($observe.ToArray())
        want_web   = $wantWeb
        want_list  = $wantList
        want_read  = $wantRead
        want_deliver = $wantDeliver
        want_mutate  = $wantMutate
        artifact   = $artifact
        source     = $source
        source_ref = $sourceRef
        urls       = $urls
        domains    = $domains
        paths      = $paths
        open_kind  = $open.kind
        sticky     = [bool]$open.kind
    }
}

function Invoke-PromptParleWebPageFetch {
    <#
    .SYNOPSIS
      0.18: fetch a URL/domain page to plain text for [OBSERVE]/[WEB] (client-first).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$UrlOrDomain,
        [int]$MaxChars = 6000
    )
    $raw = $UrlOrDomain.Trim().TrimEnd('/')
    if (-not $raw) {
        return [pscustomobject]@{ ok = $false; text = ''; url = ''; notes = @('empty-url') }
    }
    $url = $raw
    if ($url -notmatch '^https?://') { $url = 'https://' + $url }
    $ua = 'PromptParle/0.18 (desktop observe; +https://promptparle.com)'
    try {
        $resp = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 18 -Headers @{ 'User-Agent' = $ua } -ErrorAction Stop
        $html = [string]$resp.Content
        if (-not $html) {
            return [pscustomobject]@{ ok = $false; text = ''; url = $url; notes = @('empty-body') }
        }
        $t = [regex]::Replace($html, '(?is)<script[^>]*>.*?</script>', ' ')
        $t = [regex]::Replace($t, '(?is)<style[^>]*>.*?</style>', ' ')
        $t = [regex]::Replace($t, '(?is)<noscript[^>]*>.*?</noscript>', ' ')
        $t = [regex]::Replace($t, '(?s)<[^>]+>', ' ')
        try { $t = [System.Net.WebUtility]::HtmlDecode($t) } catch { }
        $t = [regex]::Replace($t, '[ \t]+', ' ')
        $t = [regex]::Replace($t, '(\r?\n\s*){3,}', "`n`n")
        $t = $t.Trim()
        if ($t.Length -gt $MaxChars) { $t = $t.Substring(0, $MaxChars) + "`n…[page budget]" }
        if ($t.Length -lt 40) {
            return [pscustomobject]@{ ok = $false; text = $t; url = $url; notes = @('thin-page') }
        }
        return [pscustomobject]@{ ok = $true; text = $t; url = $url; notes = @('page-fetch'); bytes = $t.Length }
    } catch {
        return [pscustomobject]@{ ok = $false; text = ''; url = $url; notes = @("page-fail: $_") }
    }
}

function Invoke-PromptParleSshDirListing {
    <#
    .SYNOPSIS
      0.18 client-first: list a remote directory over SSH (results, not a command for the user).
    #>
    [CmdletBinding()]
    param(
        [string]$RemotePath = '',
        [int]$MaxChars = 7000
    )
    $bind = $null
    try { $bind = Resolve-PromptParleProductBind } catch { $bind = $null }
    $ws = $null
    try { $ws = Get-PromptParleWorkspace } catch { $ws = $null }
    $target = if ($RemotePath) { $RemotePath.Trim() } else { '' }
    if (-not $target) {
        if ($bind -and $bind.root) { $target = [string]$bind.root }
        elseif ($ws -and (Get-PromptParleProp $ws 'ssh_cwd' '')) { $target = [string](Get-PromptParleProp $ws 'ssh_cwd' '') }
    }
    if (-not $target) {
        return [pscustomobject]@{ ok = $false; text = ''; path = ''; notes = @('no-path') }
    }
    # Expand relative against product root
    if ($target -notmatch '^(?:/|~|[A-Za-z]:)') {
        $root = if ($bind) { [string]$bind.root } else { '' }
        if ($root) { $target = ($root.TrimEnd('/') + '/' + $target.TrimStart('/')) }
    }
    $pathQ = $target -replace "'", "'\''"
    $remote = @"
set +e
path='$pathQ'
if [ -d "`$path" ]; then
  echo "PATH `$path"
  echo "TYPE directory"
  ls -la -- "`$path" 2>&1 | head -n 200
  echo "EXIT 0"
elif [ -e "`$path" ]; then
  echo "PATH `$path"
  echo "TYPE file"
  ls -la -- "`$path" 2>&1
  echo "EXIT 0"
else
  echo "PATH `$path"
  echo "TYPE missing"
  echo "EXIT 1"
fi
"@
    try {
        $r = Invoke-PromptParleSsh -RemoteCommand $remote -TimeoutSec 30 -SkipSessionCwd
        $out = [string]$r.text
        if ($out.Length -gt $MaxChars) { $out = $out.Substring(0, $MaxChars) + "`n…[list budget]" }
        $ok = ($out -match '(?m)^EXIT 0\s*$') -or ($out -match '(?m)^TYPE directory')
        return [pscustomobject]@{
            ok   = $ok
            text = $out
            path = $target
            notes = @($(if ($ok) { 'ssh-list' } else { 'ssh-list-miss' }))
        }
    } catch {
        return [pscustomobject]@{ ok = $false; text = "$_"; path = $target; notes = @("ssh-list-fail: $_") }
    }
}

function Invoke-PromptParleObservePrep {
    <#
    .SYNOPSIS
      0.18: fulfill observe obligations BEFORE model tokens.
      Fills [OBSERVE]/[WEB] with real results. Model must present results, not methods.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Obligation,
        [int]$Dial = 3,
        [int]$Budget = 12000
    )
    $blocks = New-Object System.Collections.Generic.List[string]
    $notes = New-Object System.Collections.Generic.List[string]
    $tools = New-Object System.Collections.Generic.List[string]
    $fulfilled = New-Object System.Collections.Generic.List[string]
    $failed = New-Object System.Collections.Generic.List[string]

    $webBudget = [Math]::Min(3200, [int]($Budget * 0.18))
    $pageBudget = [Math]::Min(6000, [int]($Budget * 0.28))
    $listBudget = [Math]::Min(7000, [int]($Budget * 0.30))
    if ($Dial -ge 4) {
        $webBudget = [Math]::Min(1800, $webBudget)
        $pageBudget = [Math]::Min(3600, $pageBudget)
        $listBudget = [Math]::Min(4000, $listBudget)
    }

    # --- WEB / page ---
    if ($Obligation.want_web) {
        $didPage = $false
        $targets = New-Object System.Collections.Generic.List[string]
        foreach ($u in @($Obligation.urls)) { if ($u) { [void]$targets.Add($u) } }
        foreach ($d in @($Obligation.domains)) { if ($d) { [void]$targets.Add($d) } }
        if ($Obligation.source_ref -and $targets.Count -eq 0) { [void]$targets.Add([string]$Obligation.source_ref) }

        foreach ($t in @($targets | Select-Object -First 3)) {
            $page = Invoke-PromptParleWebPageFetch -UrlOrDomain $t -MaxChars $pageBudget
            if ($page.ok -and $page.text) {
                $blocks.Add("[OBSERVE] kind=web_page client-first (0.18)`nurl: $($page.url)`nrule: Present these results. Do NOT answer with a search command or invent from [MEM].`n---`n$($page.text)")
                [void]$fulfilled.Add("web_page:$($page.url)")
                [void]$notes.Add('observe-page')
                [void]$tools.Add('web_page')
                $didPage = $true
            } else {
                foreach ($n in @($page.notes)) { if ($n) { [void]$notes.Add([string]$n) } }
                [void]$failed.Add("web_page:$t")
            }
        }

        # Always also run a brief search query when web wanted (fills gaps / multi-hit)
        try {
            $wq = ''
            if ($Obligation.source_ref) { $wq = [string]$Obligation.source_ref }
            elseif ($targets.Count -gt 0) { $wq = [string]$targets[0] }
            else {
                $wq = Get-PromptParleWebSearchQuery -Prompt ([string](Get-PromptParleProp $Obligation 'prompt' ''))
            }
            # If obligation carried raw user prompt via note field we may not have it — caller sets query
            if (-not $wq -and $Obligation.PSObject.Properties['query'] -and $Obligation.query) {
                $wq = [string]$Obligation.query
            }
            if ($wq) {
                $web = Invoke-PromptParleWebSearchLocal -Query $wq -MaxResults 4 -MaxChars $webBudget
                if ($web.ok -and $web.text) {
                    $blocks.Add($web.text)
                    [void]$fulfilled.Add("web_search:$wq")
                    [void]$notes.Add($(if ($web.cached) { 'web-cache' } else { 'web' }))
                    [void]$tools.Add('web_search')
                }
            }
        } catch {
            [void]$notes.Add('web-skip')
        }

        if (-not $didPage -and $fulfilled.Count -eq 0) {
            $blocks.Add("[OBSERVE] kind=web_failed client-first (0.18)`nrule: Client could not fetch the website. Do NOT invent site content from [MEM]. State the hard blocker; do not say Generating from the website.")
            [void]$notes.Add('observe-web-empty')
        }
    }

    # --- SSH directory listing ---
    if ($Obligation.want_list) {
        $listPaths = New-Object System.Collections.Generic.List[string]
        foreach ($p in @($Obligation.paths)) {
            # Prefer directories over file-looking paths for list
            if ($p -match '\.[A-Za-z0-9]{1,8}$' -and $p -notmatch '/$') { continue }
            [void]$listPaths.Add($p)
        }
        if ($listPaths.Count -eq 0) { [void]$listPaths.Add('') }  # default product root / ssh_cwd

        $anyList = $false
        foreach ($lp in @($listPaths | Select-Object -First 2)) {
            $listing = Invoke-PromptParleSshDirListing -RemotePath $lp -MaxChars $listBudget
            if ($listing.ok -and $listing.text) {
                $blocks.Add("[OBSERVE] kind=ssh_list client-first (0.18)`npath: $($listing.path)`nrule: Present this listing as the answer. NEVER reply with ```run ls``` or teach the user the command — results are already here.`n---`n$($listing.text)")
                [void]$fulfilled.Add("ssh_list:$($listing.path)")
                [void]$notes.Add('observe-ssh-list')
                [void]$tools.Add('ssh')
                $anyList = $true
            } else {
                foreach ($n in @($listing.notes)) { if ($n) { [void]$notes.Add([string]$n) } }
                [void]$failed.Add("ssh_list:$($listing.path)")
            }
        }
        if (-not $anyList) {
            $blocks.Add("[OBSERVE] kind=ssh_list_failed client-first (0.18)`nrule: Client could not list the remote path. State the hard blocker. Do not invent a directory listing or dump ```run ls``` as homework.")
            [void]$notes.Add('observe-list-empty')
        }
    }

    $text = ($blocks -join "`n`n").Trim()
    return [pscustomobject]@{
        text      = $text
        notes     = @($notes.ToArray())
        tools     = @($tools | Select-Object -Unique)
        fulfilled = @($fulfilled.ToArray())
        failed    = @($failed.ToArray())
        ok        = ($fulfilled.Count -gt 0)
    }
}


# =============================================================================
# 0.20 — Evidence provenance + grounding (structural confidence)
# Client verifies claims against fetched sources and prior assistant text.
# =============================================================================

function Test-PromptParleProvenanceIntent {
    <# True when user is auditing a prior claim against a source (site/doc/memory). #>
    param([string]$Prompt = '')
    if (-not $Prompt) { return $false }
    $p = $Prompt.ToLowerInvariant()
    if ($p -match '(?i)\b(where (on|does|did|in)|where''?s|show me where|point (me )?to|cite|citation|source for|got (this|that|it) from|come from|did you (get|find|invent|make)|is that (on|from|in) (the )?(site|website|page|doc)|not (on|in) (the )?(site|website)|prove|evidence for)\b') {
        return $true
    }
    if ($p -match '(?i)\b(does it (actually )?say|did (the )?(site|page|website) say|said that)\b') { return $true }
    return $false
}

function Get-PromptParleChallengedPhrases {
    <# Extract phrases the user is challenging (quotes, or after say/said/claim). #>
    param([string]$Prompt = '')
    $out = New-Object System.Collections.Generic.List[string]
    $seen = @{}
    if (-not $Prompt) { return @() }
    $add = {
        param([string]$s)
        if (-not $s) { return }
        $s = $s.Trim().Trim('"').Trim("'").Trim()
        $s = [regex]::Replace($s, '(?i)\s+(on|in|at|from|about)\s+(the\s+)?(site|website|page|doc|source).*$', '').Trim()
        $s = [regex]::Replace($s, '(?i)^(that|it|this|the|a|an)\s+', '').Trim()
        if ($s.Length -lt 3 -or $s.Length -gt 120) { return }
        $k = $s.ToLowerInvariant()
        if (-not $seen.ContainsKey($k)) { $seen[$k] = $true; [void]$out.Add($s) }
    }
    foreach ($m in [regex]::Matches($Prompt, '"([^"]{3,120})"')) { & $add $m.Groups[1].Value }
    foreach ($m in [regex]::Matches($Prompt, '''([^'']{3,120})''')) { & $add $m.Groups[1].Value }
    foreach ($m in [regex]::Matches($Prompt, '(?i)\b(?:say|said|claim(?:ed|s)?|mention(?:ed|s)?|wrote|called|named)\s+(.+?)(?:\?|$|,|\.|;)')) {
        $s = $m.Groups[1].Value
        $s = [regex]::Replace($s, '(?i)^(it|that|this|you)\s+', '').Trim()
        & $add $s
    }
    foreach ($m in [regex]::Matches($Prompt, '(?i)\b(?:where (?:does|did|on)|got|source for|evidence for|prove)\s+(.+?)(?:\?|$|,|\.|;)')) {
        $s = $m.Groups[1].Value
        $s = [regex]::Replace($s, '(?i)^(it|that|this|you|the phrase|the claim|the word|the words)\s+', '').Trim()
        $s = [regex]::Replace($s, '(?i)^(say|said|claim)\s+', '').Trim()
        & $add $s
    }
    # known high-value product invention patterns when present unquoted
    if ($Prompt -match '(?i)\bdistributed\s+honeypots?\b') { & $add 'distributed honeypots' }
    if ($Prompt -match '(?i)\bhoneypots?\b' -and $out.Count -eq 0) { & $add 'honeypots' }
    return @($out.ToArray())
}

function Get-PromptParleEvidenceSpine {
    <#
    .SYNOPSIS
      Compact confidence spine for multi-round agent turns.
      Token-first: keep PROVENANCE full, GROUNDING rules, short OBSERVE/WEB excerpt — not full dump.
    #>
    param(
        [string]$Context = '',
        [int]$MaxChars = 3200
    )
    if (-not $Context) { return '' }
    $parts = New-Object System.Collections.Generic.List[string]
    # Full PROVENANCE (small, mandatory)
    foreach ($m in [regex]::Matches($Context, '(?ms)(\[PROVENANCE\][^\n]*(?:\n(?!\[)[^\n]*)*)')) {
        [void]$parts.Add($m.Groups[1].Value.Trim())
    }
    # GROUNDING rules (tiny)
    foreach ($m in [regex]::Matches($Context, '(?ms)(\[GROUNDING\][^\n]*(?:\n(?!\[)[^\n]*)*)')) {
        [void]$parts.Add($m.Groups[1].Value.Trim())
    }
    # OBSERVE / WEB excerpts — head+tail fidelity, not whole page
    $ev = Get-PromptParleEvidenceCorpus -Context $Context
    if ($ev -and $ev.Length -gt 0) {
        $room = [Math]::Max(400, $MaxChars - (($parts -join "`n").Length))
        $excerpt = if ($ev.Length -gt $room) {
            Get-PromptParleFidelityTrim -Text $ev -MaxChars $room -Marker '…[spine]…'
        } else { $ev }
        [void]$parts.Add("[EVIDENCE_SPINE] client-kept (0.20) — do not invent beyond this`n$excerpt")
    }
    if ($parts.Count -eq 0) { return '' }
    $text = ($parts -join "`n`n")
    if ($text.Length -gt $MaxChars) {
        $text = Get-PromptParleFidelityTrim -Text $text -MaxChars $MaxChars -Marker '…[spine cap]…'
    }
    return $text
}

function Get-PromptParleEvidenceCorpus {
    <# Build searchable evidence string from context tags (observe/web/hands/attach/spine). #>
    param([string]$Context = '')
    if (-not $Context) { return '' }
    $parts = New-Object System.Collections.Generic.List[string]
    $tagRx = '(?:OBSERVE|WEB|HANDS|CONN|PROJECT|MEM|SSH|ATTACH|GROUNDING|PROVENANCE|EVIDENCE_SPINE)'
    foreach ($m in [regex]::Matches($Context, "(?ms)\[OBSERVE\][^\n]*\r?\n(.*?)(?=\n\[$tagRx\]|\z)")) {
        [void]$parts.Add($m.Groups[1].Value)
    }
    foreach ($m in [regex]::Matches($Context, "(?ms)\[WEB\][^\n]*\r?\n(.*?)(?=\n\[$tagRx\]|\z)")) {
        [void]$parts.Add($m.Groups[1].Value)
    }
    foreach ($m in [regex]::Matches($Context, "(?ms)\[EVIDENCE_SPINE\][^\n]*\r?\n(.*?)(?=\n\[$tagRx\]|\z)")) {
        [void]$parts.Add($m.Groups[1].Value)
    }
    foreach ($m in [regex]::Matches($Context, '(?ms)\[HANDS\][^\n]*[\s\S]*?(?=\n\[(?:OBSERVE|WEB|CONN|PROJECT|MEM|SSH|ATTACH|GROUNDING|PROVENANCE|EVIDENCE_SPINE)\]|\z)')) {
        [void]$parts.Add($m.Value)
    }
    foreach ($m in [regex]::Matches($Context, '(?ms)===== FILE:[\s\S]{0,20000}')) {
        [void]$parts.Add($m.Value)
    }
    return ($parts -join "`n")
}

function Test-PromptParlePhraseInText {
    param([string]$Phrase = '', [string]$Text = '')
    if (-not $Phrase -or -not $Text) { return $false }
    $p = $Phrase.ToLowerInvariant()
    $t = $Text.ToLowerInvariant()
    if ($t.Contains($p)) { return $true }
    # loose: all significant tokens present near each other
    $tokens = @([regex]::Matches($p, '[a-z0-9]{3,}') | ForEach-Object { $_.Value })
    if ($tokens.Count -eq 0) { return $false }
    $hit = 0
    foreach ($tok in $tokens) {
        if ($t.Contains($tok)) { $hit++ }
    }
    return ($hit -ge $tokens.Count)  # all tokens must appear
}

function Get-PromptParlePriorAssistantBlob {
    param([object[]]$History = @())
    $lines = New-Object System.Collections.Generic.List[string]
    $n = 0
    for ($i = $History.Count - 1; $i -ge 0 -and $n -lt 8; $i--) {
        $hr = [string](Get-PromptParleProp $History[$i] 'role' 'user')
        $ht = [string](Get-PromptParleProp $History[$i] 'text' (Get-PromptParleProp $History[$i] 'content' ''))
        if ($hr -match '(?i)assistant|bot|ai') {
            [void]$lines.Add($ht)
            $n++
        }
    }
    return ($lines -join "`n---`n")
}

function Invoke-PromptParleProvenancePrep {
    <#
    .SYNOPSIS
      0.20: client-side audit of challenged claims vs fetched evidence + prior assistant.
      Structural — not a model guess. Inject [PROVENANCE] before the brain answers.
    #>
    [CmdletBinding()]
    param(
        [string]$Prompt = '',
        [string]$Context = '',
        [object[]]$History = @()
    )
    $phrases = @(Get-PromptParleChallengedPhrases -Prompt $Prompt)
    if ($phrases.Count -eq 0 -and $Prompt -match '(?i)distributed\s+honeypots?') {
        $phrases = @('distributed honeypots')
    }
    # If still empty, use a short window after "say"
    if ($phrases.Count -eq 0 -and $Prompt -match '(?i)\b(?:say|said|claim(?:ed)?|wrote)\s+(.{5,80})') {
        $phrases = @($Matches[1].Trim().TrimEnd('?.!,'))
    }

    $evidence = Get-PromptParleEvidenceCorpus -Context $Context
    $priorAsst = Get-PromptParlePriorAssistantBlob -History $History
    $priorUser = ''
    foreach ($h in @($History)) {
        $hr = [string](Get-PromptParleProp $h 'role' '')
        if ($hr -match '(?i)user') {
            $priorUser += "`n" + [string](Get-PromptParleProp $h 'text' '')
        }
    }

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('[PROVENANCE] client-verified (0.20) — not model opinion. Answer MUST report these facts.')
    if ($phrases.Count -eq 0) {
        $lines.Add('challenged_phrases: (none extracted — still audit any disputed claim against [OBSERVE]/[WEB] vs prior assistant)')
    }
    $anyOnPage = $false
    $anyPriorAsst = $false
    foreach ($ph in $phrases) {
        $onPage = Test-PromptParlePhraseInText -Phrase $ph -Text $evidence
        $inAsst = Test-PromptParlePhraseInText -Phrase $ph -Text $priorAsst
        $inUser = Test-PromptParlePhraseInText -Phrase $ph -Text $priorUser
        if ($onPage) { $anyOnPage = $true }
        if ($inAsst) { $anyPriorAsst = $true }
        $lines.Add(('claim: "{0}"' -f $ph))
        $lines.Add(('  in_fetched_source [OBSERVE]/[WEB]/[HANDS]: {0}' -f $(if ($onPage) { 'YES' } else { 'NO' })))
        $lines.Add(('  in_prior_assistant (this chat): {0}' -f $(if ($inAsst) { 'YES — model said this earlier' } else { 'NO' })))
        $lines.Add(('  in_prior_user: {0}' -f $(if ($inUser) { 'YES' } else { 'NO' })))
        if (-not $onPage -and $inAsst) {
            $lines.Add('  origin: PRIOR ASSISTANT INVENTION (not supported by fetched source)')
        } elseif (-not $onPage -and -not $inAsst) {
            $lines.Add('  origin: NOT IN SOURCE and NOT IN PRIOR ASSISTANT — do not invent a citation')
        } elseif ($onPage) {
            $lines.Add('  origin: supported by fetched source text')
        }
    }
    $lines.Add('RULES (mandatory):')
    $lines.Add('1) State clearly whether the claim appears in the fetched source (yes/no).')
    $lines.Add('2) If NO but prior assistant said it: say so explicitly — "I introduced that phrase in my earlier summary; it was not on the page."')
    $lines.Add('3) Offer closest on-page wording from [OBSERVE] only. Do not defend unsupported claims.')
    $lines.Add('4) Never answer only "nowhere" without provenance when prior assistant originated the claim.')

    $text = ($lines -join "`n")
    return [pscustomobject]@{
        text            = $text
        phrases         = $phrases
        any_on_page     = $anyOnPage
        any_prior_asst  = $anyPriorAsst
        notes           = @('provenance-prep')
    }
}

function Get-PromptParleGroundingBlock {
    <#
    .SYNOPSIS
      0.20: attach strict grounding rules when web/page observe is present.
    #>
    param([string]$Context = '')
    if (-not $Context) { return '' }
    if ($Context -notmatch '(?m)\[OBSERVE\] kind=web' -and $Context -notmatch '(?m)\[WEB\]') { return '' }
    $ev = Get-PromptParleEvidenceCorpus -Context $Context
    if ($ev.Length -lt 40) { return '' }
    return @(
        '[GROUNDING] 0.20 structural — source-backed turn',
        'You may ONLY state product/site facts that appear in [OBSERVE]/[WEB]/[HANDS] evidence above.',
        'If a capability is not in that text, OMIT it. Do not invent honeypots, vendors, certifications, or features.',
        'When summarizing a website: prefer short quotes or close paraphrase of on-page lines. Mark uncertainty explicitly.',
        'If you previously invented a claim, correct it when challenged (see [PROVENANCE] when present).'
    ) -join "`n"
}

function Get-PromptParleUnverifiedPhrases {
    <#
    .SYNOPSIS
      Scan model response for multi-word claims not present in evidence corpus.
      Conservative: flag 2–5 word phrases with substance tokens missing from evidence.
    #>
    param(
        [string]$Response = '',
        [string]$Evidence = '',
        [int]$MaxFlags = 8
    )
    $flags = New-Object System.Collections.Generic.List[string]
    if (-not $Response -or -not $Evidence) { return @() }
    $ev = $Evidence.ToLowerInvariant()
    $stop = @{
        'the'=$true;'and'=$true;'for'=$true;'with'=$true;'that'=$true;'this'=$true;'from'=$true
        'your'=$true;'their'=$true;'have'=$true;'has'=$true;'are'=$true;'was'=$true;'were'=$true
        'will'=$true;'can'=$true;'into'=$true;'onto'=$true;'about'=$true;'using'=$true;'used'=$true
        'also'=$true;'than'=$true;'then'=$true;'when'=$true;'which'=$true;'while'=$true;'over'=$true
        'such'=$true;'more'=$true;'most'=$true;'other'=$true;'only'=$true;'just'=$true;'been'=$true
        'based'=$true;'provides'=$true;'provide'=$true;'platform'=$true;'solution'=$true;'security'=$true
        'network'=$true;'system'=$true;'systems'=$true;'real'=$true;'time'=$true;'designed'=$true
    }
    # Candidate: 2-5 word runs of letters
    foreach ($m in [regex]::Matches($Response, '(?i)\b[a-z][a-z0-9]+(?:\s+[a-z][a-z0-9]+){1,4}\b')) {
        if ($flags.Count -ge $MaxFlags) { break }
        $ph = $m.Value.Trim()
        if ($ph.Length -lt 8 -or $ph.Length -gt 80) { continue }
        $low = $ph.ToLowerInvariant()
        if ($ev.Contains($low)) { continue }
        $toks = @($low -split '\s+')
        $sub = 0
        foreach ($t in $toks) {
            if ($t.Length -ge 4 -and -not $stop.ContainsKey($t)) { $sub++ }
        }
        if ($sub -lt 2) { continue }
        # require at least one distinctive token absent from evidence
        $missingDistinct = $false
        foreach ($t in $toks) {
            if ($t.Length -lt 4 -or $stop.ContainsKey($t)) { continue }
            if (-not $ev.Contains($t)) { $missingDistinct = $true; break }
        }
        if (-not $missingDistinct) { continue }
        # high-value product claim patterns always flag if not in evidence
        $priority = $low -match '(?i)honeypot|decoy|zero.?day|patent|certified|guaranteed|distributed|firewall|ransomware|ai-powered|machine learning'
        if (-not $priority) {
            # skip bland phrases
            if ($sub -lt 3) { continue }
        }
        $dup = $false
        foreach ($f in $flags) { if ($f.ToLowerInvariant() -eq $low) { $dup = $true; break } }
        if (-not $dup) { [void]$flags.Add($ph) }
    }
    return @($flags.ToArray())
}

function Invoke-PromptParleGroundingPostPass {
    <#
    .SYNOPSIS
      0.20: after model answers a source-backed turn, attach client grounding audit.
      User confidence: unverified claims are labeled — not silently trusted.
    #>
    [CmdletBinding()]
    param(
        [string]$ResponseText = '',
        [string]$Context = '',
        [switch]$Force
    )
    $text = if ($null -eq $ResponseText) { '' } else { [string]$ResponseText }
    if (-not $text) {
        return [pscustomobject]@{ text = $text; flagged = @(); applied = $false }
    }
    $hasSource = $Force -or ($Context -match '(?m)\[OBSERVE\]') -or ($Context -match '(?m)\[PROVENANCE\]') -or ($Context -match '(?m)\[GROUNDING\]') -or ($Context -match '(?m)\[WEB\]') -or ($Context -match '(?m)\[HANDS\]') -or ($Context -match '(?m)\[EVIDENCE_SPINE\]')
    if (-not $hasSource) {
        return [pscustomobject]@{ text = $text; flagged = @(); applied = $false }
    }
    $ev = Get-PromptParleEvidenceCorpus -Context $Context
    # also mine EVIDENCE_SPINE / raw OBSERVE bodies if corpus empty
    if ($ev.Length -lt 40) {
        foreach ($m in [regex]::Matches($Context, '(?ms)\[EVIDENCE_SPINE\][^\n]*\r?\n(.*?)(?=\n\[|\z)')) {
            $ev = $ev + "`n" + $m.Groups[1].Value
        }
    }
    if ($ev.Length -lt 40) {
        return [pscustomobject]@{ text = $text; flagged = @(); applied = $false }
    }
    $flags = @(Get-PromptParleUnverifiedPhrases -Response $text -Evidence $ev -MaxFlags 8)
    if ($flags.Count -eq 0) {
        return [pscustomobject]@{ text = $text; flagged = @(); applied = $false }
    }
    $banner = New-Object System.Collections.Generic.List[string]
    $banner.Add('')
    $banner.Add('---')
    $banner.Add('## Grounding (client 0.20) — confidence audit')
    $banner.Add('_The client checked this reply against fetched [OBSERVE]/[WEB]/[HANDS] evidence. These phrases were **not** found in that evidence (treat as unverified / possible invention):_')
    foreach ($f in $flags) {
        $banner.Add(('- `{0}`' -f $f))
    }
    $banner.Add('')
    $banner.Add('_Do not treat flagged phrases as site quotes. Ask "where does it say X" for provenance, or open the primary URL._')
    $out = $text + "`n" + ($banner -join "`n")
    return [pscustomobject]@{
        text    = $out
        flagged = $flags
        applied = $true
    }
}

function Invoke-PromptParleProvenancePostPass {
    <#
    .SYNOPSIS
      0.20 fail-closed for claim audits: if [PROVENANCE] says prior assistant invented
      a claim and the model only says "nowhere"/dodges origin, client appends the facts.
    #>
    [CmdletBinding()]
    param(
        [string]$ResponseText = '',
        [string]$Context = ''
    )
    $text = if ($null -eq $ResponseText) { '' } else { [string]$ResponseText }
    $ctxStr = if ($null -eq $Context) { '' } else { [string]$Context }
    if (-not $text -or $ctxStr -notmatch '(?m)\[PROVENANCE\]') {
        return [pscustomobject]@{ text = $text; applied = $false; reason = 'no-provenance' }
    }
    # Parse claim lines from PROVENANCE block into simple objects
    $claims = New-Object System.Collections.Generic.List[object]
    $phrase = $null
    $onSource = $false
    $inAsst = $false
    $origin = ''
    $pending = $false
    foreach ($line in ($ctxStr -split "`n")) {
        if ($line -match '^\s*claim:\s*"([^"]+)"') {
            if ($pending) {
                [void]$claims.Add([pscustomobject]@{
                    phrase    = [string]$phrase
                    on_source = [bool]$onSource
                    in_asst   = [bool]$inAsst
                    origin    = [string]$origin
                })
            }
            $phrase = [string]$Matches[1]
            $onSource = $false
            $inAsst = $false
            $origin = ''
            $pending = $true
        } elseif ($pending) {
            if ($line -match 'in_fetched_source[^:]*:\s*(YES|NO)') {
                $onSource = ($Matches[1] -eq 'YES')
            } elseif ($line -match 'in_prior_assistant[^:]*:\s*(YES|NO)') {
                $inAsst = ($Matches[1] -eq 'YES')
            } elseif ($line -match '^\s*origin:\s*(.+)$') {
                $origin = [string]$Matches[1].Trim()
            }
        }
    }
    if ($pending) {
        [void]$claims.Add([pscustomobject]@{
            phrase    = [string]$phrase
            on_source = [bool]$onSource
            in_asst   = [bool]$inAsst
            origin    = [string]$origin
        })
    }
    if ($claims.Count -eq 0) {
        return [pscustomobject]@{ text = $text; applied = $false; reason = 'no-claims' }
    }

    $low = $text.ToLowerInvariant()
    $acksInvention = [bool]($low -match 'i (introduced|invented|added|made up|inferred|assumed)|prior (assistant|reply|summary|turn)|not (on|in) (the )?(page|site|website|source)|was not (on|in)|i said that|my earlier')
    $onlyNowhere = [bool]($low -match '\b(nowhere|not (found|present|mentioned)|doesn''t say|does not say|no mention)\b') -and (-not $acksInvention)

    $hasInvented = $false
    $hasUnsupported = $false
    $banner = New-Object System.Collections.Generic.List[string]
    [void]$banner.Add('')
    [void]$banner.Add('---')
    [void]$banner.Add('## Provenance (client 0.20) — structural facts')
    [void]$banner.Add('_Client audited challenged claims against fetched evidence and this chat''s prior assistant text. Model answer was incomplete on origin; facts below are authoritative:_')
    foreach ($c in $claims) {
        $on = [bool]$c.on_source
        $ia = [bool]$c.in_asst
        $invented = (-not $on) -and $ia
        $unsupported = (-not $on) -and (-not $ia)
        if ($invented) { $hasInvented = $true }
        if ($unsupported) { $hasUnsupported = $true }
        $onSrc = if ($on) { 'YES' } else { 'NO' }
        $inA = if ($ia) { 'YES (prior assistant said this)' } else { 'NO' }
        [void]$banner.Add(('- **"{0}"** — on fetched source: **{1}**; in prior assistant: **{2}**' -f [string]$c.phrase, $onSrc, $inA))
        if ($invented) {
            [void]$banner.Add('  - **Origin:** prior assistant invention — not supported by the fetched page/search text.')
        } elseif (-not $on) {
            [void]$banner.Add('  - **Origin:** not found in fetched source and not in prior assistant text.')
        } else {
            [void]$banner.Add('  - **Origin:** supported by fetched source.')
        }
    }
    [void]$banner.Add('')
    [void]$banner.Add('_If a claim is prior-assistant invention: that is where it came from — not the website. Do not treat it as a site quote._')

    # Fail-closed only when model dodged origin (e.g. only "nowhere")
    $needFix = $false
    if ($hasInvented -and (-not $acksInvention)) { $needFix = $true }
    elseif ($hasUnsupported -and $onlyNowhere -and (-not $acksInvention)) { $needFix = $true }
    elseif ($onlyNowhere -and $hasInvented -and (-not $acksInvention)) { $needFix = $true }

    if ($acksInvention -and $hasInvented) {
        return [pscustomobject]@{ text = $text; applied = $false; reason = 'model-ok' }
    }
    if (-not $needFix) {
        return [pscustomobject]@{ text = $text; applied = $false; reason = 'no-fix' }
    }

    $outText = $text + "`n" + ($banner -join "`n")
    return [pscustomobject]@{
        text    = $outText
        applied = $true
        reason  = 'fail-closed'
    }
}

# =============================================================================
# 0.21 — Quality gate (BS detector + corrector, 0 extra AI tokens)
# Extract checkable claims → match evidence → score → flag/correct.
# =============================================================================

function Remove-PromptParleClientAuditSections {
    <# Strip prior client audit banners so re-gates don't score their own text. #>
    param([string]$Text = '')
    if (-not $Text) { return '' }
    $t = [string]$Text
    # Drop from first client audit heading to end (provenance/grounding/quality)
    $t = [regex]::Replace($t, '(?ms)\r?\n---\r?\n## (?:Grounding|Provenance|Quality gate)\b[\s\S]*$', '')
    $t = [regex]::Replace($t, '(?ms)^\s*## (?:Grounding|Provenance|Quality gate)\b[\s\S]*$', '')
    return $t.TrimEnd()
}

function Get-PromptParleCheckableClaims {
    <#
    .SYNOPSIS
      Extract 3–8 factual claims from a model reply for evidence matching.
      Prefers product/site assertions; skips meta/chat/filler.
    #>
    param(
        [string]$Response = '',
        [int]$MaxClaims = 8
    )
    $out = New-Object System.Collections.Generic.List[string]
    $seen = @{}
    if (-not $Response) { return @() }
    $body = Remove-PromptParleClientAuditSections -Text $Response
    # Drop fenced code (apply/file/run/hands) — not product claims
    $body = [regex]::Replace($body, '(?ms)```[\s\S]*?```', ' ')
    $body = [regex]::Replace($body, '(?m)^\s{0,3}#{1,6}\s+.*$', ' ')
    $body = [regex]::Replace($body, '(?m)^\s*[-*+]\s+', '')

    $priorityRx = '(?i)\b(honeypot|decoy|zero-?day|patent|certified|certification|guaranteed|distributed|firewall|ransomware|ai-powered|machine learning|compliance|nist|fips|ot\b|scada|modbus|federation|amtd|vpatch|sensor|deception|capability|capabilities|feature|features|offers|provides|includes|supports|enables|integrates|platform|solution)\b'
    $metaRx = '(?i)^(i (can|will|would|think|believe|am|have)|here''s|heres|let me|sure[,.]|of course|based on (the )?(above|context)|as an ai|hope (this|that)|feel free|please (let|note)|note that|importantly)\b'

    # Sentence-ish splits
    $parts = [regex]::Split($body, '(?<=[.!?])\s+|\r?\n+')
    foreach ($raw in $parts) {
        if ($out.Count -ge $MaxClaims) { break }
        $s = [regex]::Replace(([string]$raw).Trim(), '\s+', ' ')
        if ($s.Length -lt 18 -or $s.Length -gt 220) { continue }
        if ($s -match $metaRx) { continue }
        if ($s -match '(?i)^(what changed|applied|download|hands ran|client )') { continue }
        if ($s -match '^\s*[_*`]') { continue }
        # Must look like a factual assertion
        $isPriority = [bool]($s -match $priorityRx)
        $isAssert = [bool]($s -match '(?i)\b(is|are|was|were|has|have|offers|provides|includes|supports|enables|uses|used|features|allows|can|will|delivers|protects|detects|blocks|prevents)\b')
        $hasNum = [bool]($s -match '\d')
        if (-not ($isPriority -or ($isAssert -and ($hasNum -or $s.Length -ge 40)))) { continue }
        if (-not $isAssert -and -not $isPriority) { continue }
        $k = $s.ToLowerInvariant()
        if ($seen.ContainsKey($k)) { continue }
        $seen[$k] = $true
        [void]$out.Add($s)
    }

    # Fallback: high-value n-grams if few sentences
    if ($out.Count -lt 2) {
        foreach ($m in [regex]::Matches($body, '(?i)\b[a-z][a-z0-9]+(?:\s+[a-z][a-z0-9]+){1,5}\b')) {
            if ($out.Count -ge $MaxClaims) { break }
            $ph = $m.Value.Trim()
            if ($ph.Length -lt 10 -or $ph.Length -gt 80) { continue }
            if ($ph -notmatch $priorityRx) { continue }
            $k = $ph.ToLowerInvariant()
            if ($seen.ContainsKey($k)) { continue }
            $seen[$k] = $true
            [void]$out.Add($ph)
        }
    }
    return @($out.ToArray())
}

function Get-PromptParleClaimMatchStatus {
    <#
    .SYNOPSIS
      Match one claim against evidence corpus.
      Returns: supported | partial | unsupported | skip
    #>
    param(
        [string]$Claim = '',
        [string]$Evidence = ''
    )
    if (-not $Claim) { return 'skip' }
    if (-not $Evidence -or $Evidence.Length -lt 20) { return 'skip' }
    $c = $Claim.ToLowerInvariant()
    $ev = $Evidence.ToLowerInvariant()
    if ($ev.Contains($c)) { return 'supported' }
    # all-token / partial token match
    $stop = @{
        'the'=$true;'and'=$true;'for'=$true;'with'=$true;'that'=$true;'this'=$true;'from'=$true
        'your'=$true;'their'=$true;'have'=$true;'has'=$true;'are'=$true;'was'=$true;'were'=$true
        'will'=$true;'can'=$true;'into'=$true;'onto'=$true;'about'=$true;'using'=$true;'used'=$true
        'also'=$true;'than'=$true;'then'=$true;'when'=$true;'which'=$true;'while'=$true;'over'=$true
        'such'=$true;'more'=$true;'most'=$true;'other'=$true;'only'=$true;'just'=$true;'been'=$true
        'based'=$true;'they'=$true;'them'=$true;'its'=$true;'our'=$true;'you'=$true;'not'=$true
        'does'=$true;'did'=$true;'may'=$true;'might'=$true;'should'=$true;'could'=$true;'would'=$true
        'across'=$true;'through'=$true;'between'=$true;'within'=$true;'without'=$true;'via'=$true
        'including'=$true;'includes'=$true;'include'=$true;'provides'=$true;'provide'=$true
        'offers'=$true;'offer'=$true;'enables'=$true;'enable'=$true;'allows'=$true;'allow'=$true
        'platform'=$true;'solution'=$true;'solutions'=$true;'security'=$true;'network'=$true
        'system'=$true;'systems'=$true;'product'=$true;'products'=$true;'company'=$true
        'examplecorp'=$true;'website'=$true;'page'=$true;'site'=$true;'http'=$true;'https'=$true
    }
    $toks = @([regex]::Matches($c, '[a-z0-9]{3,}') | ForEach-Object { $_.Value } | Where-Object { -not $stop.ContainsKey($_) })
    if ($toks.Count -eq 0) { return 'skip' }
    $hit = 0
    foreach ($t in $toks) { if ($ev.Contains($t)) { $hit++ } }
    $ratio = $hit / [double]$toks.Count
    if ($ratio -ge 0.85 -and $hit -eq $toks.Count) { return 'supported' }
    if ($ratio -ge 0.6 -and $hit -ge 2) { return 'partial' }
    # priority invention keywords missing from evidence → hard unsupported
    $priorityMissing = $false
    foreach ($t in $toks) {
        if ($t -match '^(honeypot|honeypots|decoy|decoys|zero.?day|ransomware|certified|patent|fips|nist)$') {
            if (-not $ev.Contains($t)) { $priorityMissing = $true; break }
        }
    }
    if ($priorityMissing) { return 'unsupported' }
    if ($ratio -lt 0.35 -or $hit -eq 0) { return 'unsupported' }
    return 'partial'
}

function Invoke-PromptParleQualityGate {
    <#
    .SYNOPSIS
      0.21 quality gate — under-the-hood BS detector + corrector (0 AI tokens).
      Extract checkable claims, match against [OBSERVE]/[WEB]/[HANDS] evidence,
      quantify support, flag unverified, soft-correct high-severity inventions.
    .OUTPUTS
      text, applied, claims[], supported, partial, unsupported, score_pct, corrected
    #>
    [CmdletBinding()]
    param(
        [string]$ResponseText = '',
        [string]$Context = '',
        [int]$MaxClaims = 8,
        [switch]$Force,
        [switch]$AlwaysShowScore
    )
    $raw = if ($null -eq $ResponseText) { '' } else { [string]$ResponseText }
    if (-not $raw -or $raw.Length -lt 40) {
        return [pscustomobject]@{
            text = $raw; applied = $false; reason = 'too-short'
            claims = @(); supported = 0; partial = 0; unsupported = 0; score_pct = $null; corrected = $false
        }
    }
    $hasSource = $Force -or ($Context -match '(?m)\[OBSERVE\]') -or ($Context -match '(?m)\[WEB\]') -or ($Context -match '(?m)\[HANDS\]') -or ($Context -match '(?m)\[GROUNDING\]') -or ($Context -match '(?m)\[EVIDENCE_SPINE\]') -or ($Context -match '(?m)\[ATTACH\]') -or ($Context -match '===== FILE:')
    if (-not $hasSource) {
        return [pscustomobject]@{
            text = $raw; applied = $false; reason = 'no-evidence'
            claims = @(); supported = 0; partial = 0; unsupported = 0; score_pct = $null; corrected = $false
        }
    }
    $ev = Get-PromptParleEvidenceCorpus -Context $Context
    if ($ev.Length -lt 40) {
        foreach ($m in [regex]::Matches([string]$Context, '(?ms)\[EVIDENCE_SPINE\][^\n]*\r?\n(.*?)(?=\n\[|\z)')) {
            $ev = $ev + "`n" + $m.Groups[1].Value
        }
    }
    if ($ev.Length -lt 40) {
        return [pscustomobject]@{
            text = $raw; applied = $false; reason = 'empty-evidence'
            claims = @(); supported = 0; partial = 0; unsupported = 0; score_pct = $null; corrected = $false
        }
    }

    $body = Remove-PromptParleClientAuditSections -Text $raw
    # Preserve any already-appended audit tails (provenance) — reattach after gate
    $auditTail = ''
    if ($raw.Length -gt $body.Length -and $raw.StartsWith($body)) {
        $auditTail = $raw.Substring($body.Length)
    } elseif ($raw -ne $body) {
        # body was trimmed; keep original raw for output base if complex
        if ($raw -match '(?ms)(\r?\n---\r?\n## (?:Grounding|Provenance|Quality gate)\b[\s\S]*)$') {
            $auditTail = $Matches[1]
            $body = $raw.Substring(0, $raw.Length - $auditTail.Length).TrimEnd()
        }
    }
    # Drop stale quality/grounding tails (recompute); keep provenance fail-closed
    if ($auditTail -match '(?m)## Quality gate') {
        $auditTail = [regex]::Replace($auditTail, '(?ms)\r?\n---\r?\n## Quality gate\b[\s\S]*$', '')
    }
    if ($auditTail -match '(?m)## Grounding \(client') {
        $auditTail = [regex]::Replace($auditTail, '(?ms)\r?\n---\r?\n## Grounding \(client[\s\S]*$', '')
    }

    $claimTexts = @(Get-PromptParleCheckableClaims -Response $body -MaxClaims $MaxClaims)
    # Supplement with residual unverified n-grams if sparse
    if ($claimTexts.Count -lt 3) {
        $extra = @(Get-PromptParleUnverifiedPhrases -Response $body -Evidence $ev -MaxFlags 6)
        foreach ($e in $extra) {
            if ($claimTexts.Count -ge $MaxClaims) { break }
            $dup = $false
            foreach ($c in $claimTexts) { if ($c.ToLowerInvariant().Contains($e.ToLowerInvariant()) -or $e.ToLowerInvariant().Contains($c.ToLowerInvariant())) { $dup = $true; break } }
            if (-not $dup) { $claimTexts += $e }
        }
    }

    if ($claimTexts.Count -eq 0) {
        return [pscustomobject]@{
            text = $raw; applied = $false; reason = 'no-claims'
            claims = @(); supported = 0; partial = 0; unsupported = 0; score_pct = $null; corrected = $false
        }
    }

    $results = New-Object System.Collections.Generic.List[object]
    $nSup = 0; $nPart = 0; $nUnsup = 0
    foreach ($cl in $claimTexts) {
        $st = Get-PromptParleClaimMatchStatus -Claim $cl -Evidence $ev
        if ($st -eq 'skip') { continue }
        if ($st -eq 'supported') { $nSup++ }
        elseif ($st -eq 'partial') { $nPart++ }
        else { $nUnsup++; $st = 'unsupported' }
        [void]$results.Add([pscustomobject]@{ claim = [string]$cl; status = [string]$st })
    }
    $checked = $nSup + $nPart + $nUnsup
    if ($checked -eq 0) {
        return [pscustomobject]@{
            text = $raw; applied = $false; reason = 'no-scored'
            claims = @(); supported = 0; partial = 0; unsupported = 0; score_pct = $null; corrected = $false
        }
    }
    # partial counts half toward score
    $score = [int][Math]::Round(100.0 * ($nSup + 0.5 * $nPart) / $checked)

    # Soft-correct high-severity unsupported phrases in body (mark, don't invent replacement)
    $corrected = $false
    $work = $body
    $severityRx = '(?i)\b(distributed\s+honeypots?|honeypots?|zero-?days?|guaranteed|patent(?:ed)?|certified\s+for)\b'
    foreach ($r in $results) {
        if ($r.status -ne 'unsupported') { continue }
        $ph = [string]$r.claim
        if ($ph.Length -gt 100) { continue }
        if ($ph -notmatch $severityRx -and $ph -notmatch '(?i)honeypot|zero-?day|guaranteed') { continue }
        # Prefer correcting short distinctive spans inside the claim
        $span = $null
        if ($ph -match '(?i)(distributed\s+honeypots?|honeypots?|zero-?days?)') { $span = $Matches[1] }
        elseif ($ph.Length -le 60) { $span = $ph }
        if (-not $span) { continue }
        $esc = [regex]::Escape($span)
        if ($work -match $esc) {
            $marked = ("~~{0}~~ [unverified]" -f $span)
            $work2 = [regex]::Replace($work, $esc, $marked, 1)
            if ($work2 -ne $work) {
                $work = $work2
                $corrected = $true
            }
        }
    }

    $show = $AlwaysShowScore -or ($nUnsup -gt 0) -or ($nPart -gt 0) -or $corrected -or ($score -lt 100)
    # Always show compact score on source-backed product turns when we scored anything
    if (-not $show -and $checked -ge 1) { $show = $true }

    if (-not $show) {
        return [pscustomobject]@{
            text = $raw; applied = $false; reason = 'clean-silent'
            claims = @($results); supported = $nSup; partial = $nPart; unsupported = $nUnsup
            score_pct = $score; corrected = $false
        }
    }

    $lines = New-Object System.Collections.Generic.List[string]
    [void]$lines.Add('')
    [void]$lines.Add('---')
    [void]$lines.Add(('## Quality gate (client 0.21) — {0}% evidence-backed ({1}/{2} claims)' -f $score, $nSup, $checked))
    [void]$lines.Add(('_Client self-check vs fetched [OBSERVE]/[WEB]/[HANDS] evidence — 0 AI tokens. supported={0} partial={1} unverified={2}_' -f $nSup, $nPart, $nUnsup))
    if ($nUnsup -gt 0 -or $nPart -gt 0) {
        [void]$lines.Add('')
        [void]$lines.Add('| Claim | Status |')
        [void]$lines.Add('| --- | --- |')
        foreach ($r in $results) {
            if ($r.status -eq 'supported') { continue }
            $short = [string]$r.claim
            if ($short.Length -gt 90) { $short = $short.Substring(0, 87) + '...' }
            $short = $short.Replace('|', '/')
            $label = [string]$r.status
            if ($label -eq 'partial') { $label = 'partial (weak match)' }
            elseif ($label -eq 'unsupported') { $label = '**unverified**' }
            [void]$lines.Add(('| {0} | {1} |' -f $short, $label))
        }
    }
    if ($corrected) {
        [void]$lines.Add('')
        [void]$lines.Add('_High-severity unverified product terms were struck through (~~like this~~ [unverified]) in the reply above. Treat them as not source-backed._')
    }
    if ($nUnsup -gt 0) {
        [void]$lines.Add('')
        [void]$lines.Add('_Ask "where does it say X" for provenance, or open the primary source. Do not treat unverified rows as site quotes._')
    } elseif ($score -ge 80) {
        [void]$lines.Add('')
        [void]$lines.Add('_No high-risk unverified product claims detected in this pass. Still prefer primary sources for decisions._')
    }

    $out = [string]$work
    if ($auditTail) { $out = $out + [string]$auditTail }
    $out = $out + "`n" + [string]($lines -join "`n")

    $reasonOut = 'scored'
    if ($nUnsup -gt 0) { $reasonOut = 'unverified' }
    elseif ($corrected) { $reasonOut = 'corrected' }

    $claimArr = @()
    foreach ($r in $results) {
        $claimArr += [pscustomobject]@{
            claim  = [string]$r.claim
            status = [string]$r.status
        }
    }

    $ret = New-Object psobject
    $ret | Add-Member -NotePropertyName text -NotePropertyValue $out
    $ret | Add-Member -NotePropertyName applied -NotePropertyValue $true
    $ret | Add-Member -NotePropertyName reason -NotePropertyValue $reasonOut
    $ret | Add-Member -NotePropertyName claims -NotePropertyValue $claimArr
    $ret | Add-Member -NotePropertyName supported -NotePropertyValue ([int]$nSup)
    $ret | Add-Member -NotePropertyName partial -NotePropertyValue ([int]$nPart)
    $ret | Add-Member -NotePropertyName unsupported -NotePropertyValue ([int]$nUnsup)
    $ret | Add-Member -NotePropertyName score_pct -NotePropertyValue ([int]$score)
    $ret | Add-Member -NotePropertyName corrected -NotePropertyValue ([bool]$corrected)
    $ret | Add-Member -NotePropertyName checked -NotePropertyValue ([int]$checked)
    return $ret
}


function Update-PromptParleOpenObligationFromTurn {
    <#
    .SYNOPSIS
      0.18: maintain sticky open document/implement contract after a turn.
    #>
    param(
        $Obligation,
        [string]$ResponseText = '',
        [int]$ExportCount = 0,
        [int]$ApplyCount = 0,
        [int]$RunCount = 0
    )
    if (-not $Obligation) { return }
    try {
        if ($Obligation.mode -eq 'mutate' -or $Obligation.want_mutate) {
            if (($ApplyCount + $RunCount) -gt 0) {
                # landed work — clear implement sticky
                if ((Get-PromptParleOpenObligation).kind -eq 'implement') {
                    Set-PromptParleOpenObligation -Clear
                }
            } else {
                Set-PromptParleOpenObligation -Kind 'implement' -Artifact 'code change' -Source 'project' -SourceRef ''
            }
            return
        }
        if ($Obligation.mode -eq 'deliver' -or $Obligation.want_deliver) {
            if ($ExportCount -gt 0) {
                Set-PromptParleOpenObligation -Clear
            } else {
                $src = if ($Obligation.source) { $Obligation.source } else { 'none' }
                $ref = if ($Obligation.source_ref) { $Obligation.source_ref } else { '' }
                $art = if ($Obligation.artifact) { $Obligation.artifact } else { 'document' }
                Set-PromptParleOpenObligation -Kind 'document' -Artifact $art -Source $src -SourceRef $ref
            }
            return
        }
        # Source-only correction on existing open document
        $open = Get-PromptParleOpenObligation
        if ($open.kind -eq 'document' -and $Obligation.want_web) {
            $ref = if ($Obligation.source_ref) { $Obligation.source_ref } else { $open.source_ref }
            Set-PromptParleOpenObligation -Kind 'document' -Artifact $open.artifact -Source 'web' -SourceRef $ref
        }
    } catch { }
}

function Test-PromptParleDeliverOwed {
    param($Obligation, [string]$ResponseText = '')
    if (-not $Obligation) { return $false }
    if ($Obligation.mode -eq 'deliver' -or $Obligation.want_deliver) { return $true }
    $open = Get-PromptParleOpenObligation
    if ($open.kind -eq 'document' -and $Obligation.want_web) { return $true }
    # Theater promised a deliverable
    if ($ResponseText -match '(?i)Generating (updated |the )?(deliverable|summary|one-?pager|document)') { return $true }
    return $false
}

function Invoke-PromptParleDeliverFailClosed {
    <# Append fail-closed banner when document was owed but no ```file``` landed. #>
    param(
        [string]$ResponseText = '',
        [int]$ExportCount = 0
    )
    if ($ExportCount -gt 0) {
        return [pscustomobject]@{ text = $ResponseText; fail_closed = $false }
    }
    $hasFile = [bool]($ResponseText -match '(?m)```(?:file|deliver)\s+')
    if ($hasFile) {
        # blocks present but deliver pipeline produced 0 — still fail-closed
        return [pscustomobject]@{
            text = $ResponseText + "`n`n## Deliver incomplete`n_Client saw ``file`` fences but built 0 downloads (empty/unsupported body). Capability=obligation: a document ask is not done until a download exists._`n"
            fail_closed = $true
        }
    }
    $banner = @(
        '## Deliver FAIL-CLOSED (0.18)',
        'Document was owed this turn but no file deliverable was produced (no download built).',
        'Capability=obligation: do not accept "Understood / Generating now" as completion. Re-ask or continue until a real file body lands (or state the single hard blocker, e.g. no WEB evidence).',
        '',
        '---',
        ''
    ) -join "`n"
    return [pscustomobject]@{
        text = $banner + $ResponseText
        fail_closed = $true
    }
}

function Invoke-PromptParleAgentLocalPrep {
    <#
    .SYNOPSIS
      Fidelity-first local shrink before AI tokens (proprietary).
      Doctrine: (0) connections (1) chat memory (2) mask (3) fidelity fleet
      (4) optional web (5) one structure/slice pack if thin (6) head+tail budget.
      Select signal over destroy: error stacks, prompt-hot lines, recent turns stay.
      AgentId is ignored (0.14+) — dial owns aggressiveness; tools are product-wide.
    #>
    [CmdletBinding()]
    param(
        [string]$Prompt = '',
        [string]$Context = '',
        [string]$AgentId,
        [bool]$ToolsEnabled = $true,
        [int]$Dial = 3,
        [string]$Profile = '',
        [object[]]$History = @(),
        [string]$HistoryText = ''
    )
    $notes = New-Object System.Collections.Generic.List[string]
    $ctx = if ($null -eq $Context) { '' } else { [string]$Context }
    $pr = if ($null -eq $Prompt) { '' } else { [string]$Prompt }
    $charsIn = $ctx.Length + $pr.Length
    if ($HistoryText) { $charsIn += $HistoryText.Length }
    elseif ($History) {
        foreach ($h in $History) {
            $ht = [string](Get-PromptParleProp $h 'text' (Get-PromptParleProp $h 'content' ''))
            $charsIn += $ht.Length
        }
    }
    $tools = New-Object System.Collections.Generic.List[string]

    # Prep depth only — model already understands natural language; we must not underrun evidence
    $turnKind = 'chat'
    try { $turnKind = Get-PromptParleTurnKind -Prompt $pr -History $History } catch { $turnKind = 'chat' }
    $notes.Add("turn:$turnKind")

    # Hard implement directive — capability=obligation; forces apply/run channel
    if ($turnKind -eq 'implement') {
        $directive = @(
            '[CLIENT DIRECTIVE — implement turn · capability=obligation]',
            'The user already authorized work in plain English (same as any normal AI eng client).',
            'DO NOT ask questions, permission, or "say the word". DO NOT re-plan. DO NOT dump homework the client can run.',
            'Land now: (1) ```apply path=relative/from/source_root``` FULL file — client reads-before-write, backups, SSH-writes source only.',
            '(2) After schema/deps/build needs, emit ```run``` (e.g. npx prisma migrate deploy) — client executes; never tell the user to run it.',
            'Secure defaults when undecided. Report only after apply/run blocks. Theater ("Ready/Name it and I ship") is a product failure.'
        ) -join ' '
        if ($pr -notmatch '\[CLIENT DIRECTIVE') {
            $pr = $pr + "`n`n" + $directive
            $notes.Add('implement-directive')
        }
    }

    # 0) Always inject Project Connections brief (tiny; model knows PC/Git/SSH)
    try {
        $connMax = 520
        if ($Dial -ge 4) { $connMax = 360 }
        $connBrief = Get-PromptParleProjectConnectionsBrief -MaxChars $connMax
        if ($connBrief) {
            if ($ctx -and $ctx -notmatch '(?m)^\[CONN\]') {
                $ctx = $connBrief + "`n`n" + $ctx
            } elseif (-not $ctx) {
                $ctx = $connBrief
            }
            $notes.Add('conn')
            $tools.Add('connections')
        }
    } catch {
        $notes.Add('conn-skip')
    }

    # 0a) Always-on [PROJECT] bind card — structural map (not keyword pack)
    try {
        $projCard = Get-PromptParleProjectCard -TurnKind $turnKind
        if ($projCard -and $ctx -notmatch '(?m)^\[PROJECT\]') {
            if ($ctx -match '(?s)^(\[CONN\][^\n]*(?:\n(?!\[)[^\n]*)*)\n\n?(.*)$') {
                $ctx = $Matches[1] + "`n`n" + $projCard + "`n`n" + $Matches[2]
            } elseif ($ctx) {
                $ctx = $projCard + "`n`n" + $ctx
            } else {
                $ctx = $projCard
            }
            $notes.Add('project-card')
            $tools.Add('project_bind')
        }
    } catch {
        $notes.Add('project-card-skip')
    }

    # 0b) Continuous chat memory — auto-compact every turn (facts over theater)
    try {
        $memMax = 2800
        if ($Dial -le 2) { $memMax = 4200 }
        if ($Dial -eq 3) { $memMax = 3000 }
        if ($Dial -ge 4) { $memMax = 1800 }
        if ($Dial -ge 5) { $memMax = 1400 }
        $mem = $null
        $histForMem = $History
        $histTextForMem = $HistoryText
        # Always sanitize assistant theater / false blockers so [MEM] does not re-teach lies
        try {
            if ($History -and $History.Count -gt 0) {
                $filtered = New-Object System.Collections.Generic.List[object]
                foreach ($h in @($History)) {
                    $hr = [string](Get-PromptParleProp $h 'role' 'user')
                    $ht = [string](Get-PromptParleProp $h 'text' (Get-PromptParleProp $h 'content' ''))
                    if ($hr -match '(?i)assistant|bot|ai') {
                        if ($ht -match '(?i)Ready for the named addition|Name it and I ship|spine locked|Handoff read\.|Would you like me to actually implement|Just say the word') {
                            $ht = '[prior permission/status theater omitted]'
                        } elseif ($ht -match '(?i)The change was never implemented|only \*described\*|hypothetical') {
                            $ht = '[prior unapplied design essay omitted — implement via apply blocks next]'
                        } elseif ($ht -match '(?i)contain no portal|no portal backend|only the PromptParle desktop|no server-side components|cannot be implemented from the current handoff|no matching paths or code in the evidence') {
                            $ht = '[prior false missing-product claim omitted — use [PROJECT] bind]'
                        } elseif ($ht -match '(?i)do not build|ExecutionPolicy Bypass|ship.?blocker|blocked until|until that change is made') {
                            $ht = '[prior security note compressed]'
                        } elseif ($ht -match '(?i)Edit `prisma/schema|Run the migration|curl -X POST' -and $ht.Length -gt 800) {
                            # Homework dumps that never applied — keep a stub so MEM does not re-teach "paste this"
                            $ht = '[prior homework-style design dump omitted — use ```apply path=``` to land files]'
                        }
                        # Always collapse prior deliverables so doc2 is not summarized as doc1
                        $ht = Reduce-PromptParleTurnTextForMemory -Text $ht -Role 'assistant'
                    } else {
                        $ht = Reduce-PromptParleTurnTextForMemory -Text $ht -Role 'user'
                    }
                    $filtered.Add([pscustomobject]@{ role = $hr; text = $ht })
                }
                $histForMem = @($filtered.ToArray())
            }
        } catch { }
        if ($histForMem -and $histForMem.Count -gt 0) {
            $mem = Invoke-PromptParleChatMemoryBrief -History $histForMem -MaxChars $memMax -Dial $Dial
        } elseif ($histTextForMem -and $histTextForMem.Trim().Length -gt 20) {
            $mem = Invoke-PromptParleChatMemoryBrief -HistoryText $histTextForMem -MaxChars $memMax -Dial $Dial
        }
        # This-turn attachment wins over [MEM] for document asks (place ATTACH priority note)
        $hasThisTurnAttach = $false
        try {
            if ($ctx -match '(?m)^\[ATTACH\]' -or $ctx -match '===== FILE:' -or $pr -match '\[ATTACHED THIS TURN') {
                $hasThisTurnAttach = $true
            }
        } catch { }
        if ($mem -and $mem.text) {
            if ($hasThisTurnAttach) {
                $mem.text = $mem.text + "`n" + 'Priority: THIS turn [ATTACH]/FILE is primary. Do not re-use prior document topics or prior executive summaries from Spine/Recent when a new file is attached.'
                $notes.Add('mem-attach-priority')
            }
            if ($ctx -notmatch '(?m)^\[MEM\]') {
                # Place memory after CONN/PROJECT, before bulky attaches
                if ($ctx -match '(?s)^((?:\[(?:CONN|PROJECT)\][^\n]*(?:\n(?!\[)[^\n]*)*\n\n?)+)(.*)$') {
                    $ctx = $Matches[1] + $mem.text + "`n`n" + $Matches[2]
                } else {
                    $ctx = $mem.text + "`n`n" + $ctx
                }
            }
            foreach ($n in @($mem.notes)) { if ($n) { $notes.Add([string]$n) } }
            $tools.Add('chat_memory')
        }
    } catch {
        $notes.Add('mem-skip')
    }

    if (-not $ToolsEnabled) {
        $notes.Add('tools off')
        return [pscustomobject]@{
            prompt = $pr; context = $ctx; notes = @($notes.ToArray())
            tools = @($tools); agent = 'none'
            tools_enabled = $false
        }
    }

    if ($Dial -lt 1) { $Dial = 1 }
    if ($Dial -gt 5) { $Dial = 5 }
    $prof = if ($Profile) { $Profile } else { 'general' }
    # 0.14: compressor profiles still accepted for API compat, but chat path always sends general
    $budget = Get-PromptParleLocalContextBudget -Dial $Dial
    $tools.Add('secret_scan')
    $tools.Add('code_brief')

    # 1) Mask secrets (always when tools on)
    $r1 = Invoke-PromptParleSecretScanLocal -Text $pr
    $r2 = Invoke-PromptParleSecretScanLocal -Text $ctx
    $pr = $r1.text
    $ctx = $r2.text
    if (($r1.masked + $r2.masked) -gt 0) { $notes.Add("mask $($r1.masked + $r2.masked)") }

    # 2) Fidelity fleet — protect [CONN]/[MEM]; shrink rest with prompt-aware tools
    if ($ctx.Length -gt 200) {
        $headKeep = ''
        $restCtx = $ctx
        # Peel protected headers (CONN + PROJECT + MEM) — never densify the bind map away
        while ($restCtx -match '(?s)^(\[(?:CONN|PROJECT|MEM)\][^\n]*(?:\n(?!\[)[^\n]*)*)\n\n?(.*)$') {
            if ($headKeep) { $headKeep = $headKeep + "`n`n" + $Matches[1] }
            else { $headKeep = $Matches[1] }
            $restCtx = $Matches[2]
        }
        if ($restCtx.Length -gt 200) {
            $room = [Math]::Max(800, $budget - $headKeep.Length - 80)
            $fleet = Invoke-PromptParleFidelityContextLocal -Text $restCtx -Prompt $pr -MaxChars $room -Dial $Dial
            $restCtx = $fleet.text
            foreach ($n in @($fleet.notes)) { if ($n) { $notes.Add([string]$n) } }
            foreach ($fn in @($fleet.notes)) {
                if ($fn -match 'error_brief') { $tools.Add('error_brief'); break }
            }
        }
        if ($headKeep) { $ctx = $headKeep + "`n`n" + $restCtx } else { $ctx = $restCtx }
    }

    # 2.5) SSH cwd auto-evidence — named files in prompt fetch from live remote cwd
    # Doctrine: if [CONN] shows SSH cwd, relative/absolute names must be tried before "not found"
    try {
        $sshMax = [Math]::Min(14000, [int]($budget * 0.48))
        if ($Dial -le 2) { $sshMax = [Math]::Min(20000, [int]($budget * 0.55)) }
        if ($Dial -ge 4) { $sshMax = [Math]::Min(10000, $sshMax) }
        $sshFiles = if ($Dial -le 2) { 6 } else { 4 }
        $sshEv = Get-PromptParleSshPromptEvidence -Prompt $pr -Profile $prof -MaxFiles $sshFiles -MaxChars $sshMax
        if ($sshEv -and $sshEv.text) {
            if ($ctx) { $ctx = $ctx + "`n`n" + $sshEv.text } else { $ctx = [string]$sshEv.text }
            $notes.Add(("ssh-fetch {0}" -f $sshEv.files))
            foreach ($sn in @($sshEv.notes)) {
                if ($sn -and $sn -match '^ssh-ok:') { $notes.Add([string]$sn) }
            }
            $tools.Add('ssh')
        } elseif ($sshEv -and $sshEv.notes) {
            $miss = @($sshEv.notes | Where-Object { $_ -match '^ssh-miss:' } | Select-Object -First 4)
            if ($miss.Count -gt 0) {
                $missNames = @($miss | ForEach-Object { $_ -replace '^ssh-miss:', '' })
                $missBlock = "[SSH] Fetch attempted (not found on remote under session cwd):`n- " + ($missNames -join "`n- ")
                if ($ctx) { $ctx = $ctx + "`n`n" + $missBlock } else { $ctx = $missBlock }
                $notes.Add('ssh-miss')
                $tools.Add('ssh')
            }
        }
    } catch {
        $notes.Add('ssh-fetch-skip')
    }

    # 2.6) Product bind live evidence — always when SSH up (depth by turn kind, not keyword moles)
    try {
        if (Test-PromptParleProductWorkIntent -Prompt $pr) {
            $prodMax = [Math]::Min(12000, [int]($budget * 0.38))
            if ($turnKind -eq 'implement') {
                $prodMax = [Math]::Min(18000, [int]($budget * 0.48))
            } elseif ($turnKind -eq 'question') {
                $prodMax = [Math]::Min(8000, [int]($budget * 0.28))
            }
            if ($Dial -le 2) { $prodMax = [Math]::Min(20000, $prodMax + 3000) }
            $prod = Get-PromptParleSshProductWorkPack -Prompt $pr -MaxChars $prodMax -TurnKind $turnKind
            if ($prod -and $prod.ok -and $prod.text) {
                if ($ctx) { $ctx = $ctx + "`n`n" + $prod.text } else { $ctx = [string]$prod.text }
                foreach ($pn in @($prod.notes)) { if ($pn) { $notes.Add([string]$pn) } }
                $tools.Add('ssh')
                $tools.Add('product_bind')
            }
        }
    } catch {
        $notes.Add('ssh-product-skip')
    }

    # 3) 0.18 obligation resolve + client-first OBSERVE (before model tokens)
    $blob = ("{0} {1}" -f $pr, $prof).ToLowerInvariant()
    $obligation = $null
    try {
        $obligation = Resolve-PromptParleTurnObligation -Prompt $pr -History $History
        $notes.Add(('obligation:' + $obligation.mode))
        if ($obligation.observe -and $obligation.observe.Count -gt 0) {
            $notes.Add(('observe:' + ($obligation.observe -join '+')))
        }
    } catch {
        $notes.Add('obligation-skip')
    }

    if ($obligation -and ($obligation.want_web -or $obligation.want_list)) {
        try {
            # Attach query for web_search fallback
            try { $obligation | Add-Member -NotePropertyName query -NotePropertyValue (Get-PromptParleWebSearchQuery -Prompt $pr) -Force } catch {
                try { $obligation | Add-Member -NotePropertyName query -NotePropertyValue $pr -Force } catch { }
            }
            $obs = Invoke-PromptParleObservePrep -Obligation $obligation -Dial $Dial -Budget $budget
            if ($obs.text) {
                if ($ctx) { $ctx = $ctx + "`n`n" + $obs.text } else { $ctx = [string]$obs.text }
            }
            foreach ($n in @($obs.notes)) { if ($n) { $notes.Add([string]$n) } }
            foreach ($t in @($obs.tools)) { if ($t) { $tools.Add([string]$t) } }
            if ($obs.fulfilled -and $obs.fulfilled.Count -gt 0) {
                $notes.Add(('observe-ok:' + $obs.fulfilled.Count))
                # Hard directive: results already obtained — do not answer with the method
                $obsDir = @(
                    '[CLIENT DIRECTIVE — observe fulfilled · capability=obligation 0.20]',
                    'The client ALREADY obtained the requested facts ([OBSERVE]/[WEB] above).',
                    'Answer from those results only. NEVER invent product capabilities not in the fetch. NEVER emit method homework.',
                    'NEVER emit toolcall/tool_call/function_call XML or any foreign tool protocol — observe is already done.',
                    'If the user also owes a document, emit ```file name=…``` with FULL body in THIS turn — no "Generating now" without the file block.'
                ) -join ' '
                if ($pr -notmatch '\[CLIENT DIRECTIVE — observe') {
                    $pr = $pr + "`n`n" + $obsDir
                    $notes.Add('observe-directive')
                }
            } elseif ($obligation.want_web -or $obligation.want_list) {
                $failDir = @(
                    '[CLIENT DIRECTIVE — observe failed · capability=obligation 0.18]',
                    'Client could not fill required observe evidence. State the single hard blocker.',
                    'Do NOT invent website or directory content from [MEM]. Do NOT dump commands as the answer.'
                ) -join ' '
                if ($pr -notmatch '\[CLIENT DIRECTIVE — observe') {
                    $pr = $pr + "`n`n" + $failDir
                    $notes.Add('observe-fail-directive')
                }
            }
        } catch {
            $notes.Add('observe-prep-skip')
        }
    } elseif (Test-PromptParleWebSearchIntent -Prompt $pr) {
        # Residual thin web brief when obligation resolver missed but structural web intent hit
        try {
            $wq = Get-PromptParleWebSearchQuery -Prompt $pr
            if ($wq) {
                $webBudget = [Math]::Min(2400, [int]($budget * 0.12))
                if ($Dial -ge 4) { $webBudget = [Math]::Min(1400, $webBudget) }
                if ($Dial -le 2) { $webBudget = [Math]::Min(3200, [int]($budget * 0.15)) }
                $web = Invoke-PromptParleWebSearchLocal -Query $wq -MaxResults 4 -MaxChars $webBudget
                if ($web.ok -and $web.text) {
                    if ($ctx) { $ctx = $ctx + "`n`n" + $web.text } else { $ctx = $web.text }
                    $notes.Add($(if ($web.cached) { 'web-cache' } else { 'web' }))
                    $tools.Add('web_search')
                }
            }
        } catch {
            $notes.Add('web-skip')
        }
    }

    # 3b) 0.20 GROUNDING pack when web observe present
    try {
        $gb = Get-PromptParleGroundingBlock -Context $ctx
        if ($gb) {
            if ($ctx) { $ctx = $ctx + "`n`n" + $gb } else { $ctx = $gb }
            $notes.Add('grounding-block')
        }
    } catch { $notes.Add('grounding-skip') }

    # 3c) 0.20 PROVENANCE when user audits a claim (where does it say / where did you get)
    try {
        if (Test-PromptParleProvenanceIntent -Prompt $pr) {
            # Ensure web observe if domain/site mentioned and not already fetched
            if ($pr -match '(?i)website|examplecorp\.com|https?://' -or $pr -match '(?i)\b(site|page)\b') {
                if ($ctx -notmatch '(?m)\[OBSERVE\] kind=web') {
                    try {
                        $dom = ''
                        if ($pr -match '(?i)([a-z0-9.-]+\.(?:com|org|net|io|ai))') { $dom = $Matches[1] }
                        if (-not $dom -and $pr -match '(?i)examplecorp') { $dom = 'examplecorp.com' }
                        if ($dom) {
                            $pg = Invoke-PromptParleWebPageFetch -UrlOrDomain $dom -MaxChars 6000
                            if ($pg.ok -and $pg.text) {
                                $blk = "[OBSERVE] kind=web_page client-first (0.20 provenance)`nurl: $($pg.url)`nrule: Use for claim audit only.`n---`n$($pg.text)"
                                if ($ctx) { $ctx = $ctx + "`n`n" + $blk } else { $ctx = $blk }
                                $notes.Add('provenance-refetch')
                            }
                        }
                    } catch { }
                }
            }
            $prov = Invoke-PromptParleProvenancePrep -Prompt $pr -Context $ctx -History $History
            if ($prov.text) {
                if ($ctx) { $ctx = $ctx + "`n`n" + $prov.text } else { $ctx = $prov.text }
                foreach ($n in @($prov.notes)) { if ($n) { $notes.Add([string]$n) } }
                $pdir = @(
                    '[CLIENT DIRECTIVE — provenance owed · 0.20]',
                    'Client already audited challenged claims in [PROVENANCE].',
                    'Your answer MUST include: (1) on-source yes/no (2) if prior assistant invented it, say that explicitly (3) closest on-page wording only from [OBSERVE].',
                    'Do not stop at "nowhere" without provenance of where the phrase entered this chat.'
                ) -join ' '
                if ($pr -notmatch '\[CLIENT DIRECTIVE — provenance') {
                    $pr = $pr + "`n`n" + $pdir
                    $notes.Add('provenance-directive')
                }
            }
        }
    } catch {
        $notes.Add('provenance-skip')
    }

    # Deliver sticky: if document owed, remind model of post-condition
    if ($obligation -and ($obligation.mode -eq 'deliver' -or $obligation.want_deliver)) {
        $delDir = @(
            '[CLIENT DIRECTIVE — deliver owed · capability=obligation 0.18]',
            'User is owed a real downloadable document this turn.',
            'Emit ```file name=Report.md``` (or .pdf/.docx/.xlsx) with FULL content body NOW.',
            'Never end with "Understood / Generating…" without the file fence. Client builds the download link.'
        ) -join ' '
        if ($pr -notmatch '\[CLIENT DIRECTIVE — deliver') {
            $pr = $pr + "`n`n" + $delDir
            $notes.Add('deliver-directive')
        }
        # Persist sticky early so short follow-ups keep the contract
        try {
            $src = if ($obligation.source) { $obligation.source } else { 'none' }
            $ref = if ($obligation.source_ref) { $obligation.source_ref } else { '' }
            $art = if ($obligation.artifact) { $obligation.artifact } else { 'document' }
            Set-PromptParleOpenObligation -Kind 'document' -Artifact $art -Source $src -SourceRef $ref
        } catch { }
    }

    # 4) At most ONE structure/slice pack when context is empty/thin
    $ws = $null
    try { $ws = Get-PromptParleWorkspace } catch { $ws = $null }
    $extra = $null
    $bodyLen = $ctx.Length
    if ($ctx -match '(?s)^\[CONN\]') {
        $bodyLen = [Math]::Max(0, $ctx.Length - 400)
    }

    $wantSlice = $blob -match 'where is|find function|find class|how does|implement|refactor|in the (code|repo|project|workspace)|look at|show me'
    $wantDiff = $blob -match 'diff|change|pr\b|pull request|commit|patch|what changed'
    $wantDeps = $blob -match 'dependenc|package\.json|npm|pip|upgrade|version'
    $wantMap  = $blob -match 'structure|codebase|file index|layout|tree\b'

    if ($ws -and $ws.exists -and $bodyLen -lt [Math]::Min(1400, [int]($budget * 0.18))) {
        try {
            if ($wantDiff -and $ws.is_git) {
                $extra = Get-PromptParleGitDiffPack -MaxChars ([Math]::Min(18000, [int]($budget * 0.55)))
                if ($extra) { $notes.Add('diff'); $tools.Add('git_diff') }
            } elseif ($wantDeps) {
                $extra = Get-PromptParleWorkspaceDepsMap -MaxChars 2800
                if ($extra) { $notes.Add('deps'); $tools.Add('deps') }
            } elseif ($wantSlice -or ($bodyLen -lt 80 -and -not $wantMap)) {
                # Prefer high-fidelity relevant slices over bare index when we have query tokens
                $sliceBudget = [Math]::Min(14000, [int]($budget * 0.45))
                if ($Dial -le 2) { $sliceBudget = [Math]::Min(20000, [int]($budget * 0.55)) }
                $sl = Get-PromptParleRelevantSlice -Prompt $pr -MaxFiles $(if ($Dial -le 2) { 5 } else { 4 }) -MaxChars $sliceBudget
                if ($sl.text) {
                    $extra = $sl.text
                    foreach ($n in @($sl.notes)) { if ($n) { $notes.Add([string]$n) } }
                    $tools.Add('relevant_slice')
                } elseif ($wantMap -or $bodyLen -lt 40) {
                    $extra = Get-PromptParleWorkspaceFileIndex -MaxChars 1800
                    if ($extra) { $notes.Add('idx'); $tools.Add('file_index') }
                }
            } elseif ($wantMap -or $bodyLen -lt 40) {
                $extra = Get-PromptParleWorkspaceFileIndex -MaxChars 1800
                if ($extra) { $notes.Add('idx'); $tools.Add('file_index') }
            }
        } catch { $extra = $null }
        if ($extra) {
            if ($ctx) { $ctx = $ctx + "`n`n" + $extra } else { $ctx = $extra }
        }
    } elseif ($ws -and $ws.exists -and $wantSlice -and $bodyLen -gt ($budget * 0.65)) {
        # Fat attach + code question: try to replace bulk with ranked slices if smaller & denser
        try {
            $sliceBudget = [Math]::Min(16000, [int]($budget * 0.5))
            $sl = Get-PromptParleRelevantSlice -Prompt $pr -MaxFiles 4 -MaxChars $sliceBudget
            if ($sl.text -and $sl.text.Length -lt [int]($bodyLen * 0.7)) {
                $headKeep = ''
                $rest = $ctx
                while ($rest -match '(?s)^(\[(?:CONN|MEM|WEB)\][^\n]*(?:\n(?!\[)[^\n]*)*)\n\n?(.*)$') {
                    if ($headKeep) { $headKeep = $headKeep + "`n`n" + $Matches[1] }
                    else { $headKeep = $Matches[1] }
                    $rest = $Matches[2]
                }
                $ctx = if ($headKeep) { $headKeep + "`n`n" + $sl.text } else { $sl.text }
                foreach ($n in @($sl.notes)) { if ($n) { $notes.Add([string]$n) } }
                $notes.Add('slice>bulk')
                $tools.Add('relevant_slice')
            }
        } catch { }
    } elseif ($ws -and $ws.exists -and $ws.is_git -and $wantDiff) {
        if ($ctx.Length -gt ($budget * 0.7)) {
            try {
                $gd = Get-PromptParleGitDiffPack -MaxChars ([Math]::Min(20000, $budget))
                if ($gd -and $gd.Length -lt $ctx.Length) {
                    $connKeep = ''
                    if ($ctx -match '(?s)^(\[CONN\][^\n]*(?:\n(?!\[)[^\n]*)*)') { $connKeep = $Matches[1] }
                    $ctx = if ($connKeep) { $connKeep + "`n`n" + $gd } else { $gd }
                    $notes.Add('diff>files')
                    $tools.Add('git_diff')
                }
            } catch { }
        }
    }

    # 5) Hard local budget — head+tail fidelity trim; never drop CONN/MEM; protect PROVENANCE/GROUNDING anywhere
    if ($ctx.Length -gt $budget) {
        $protected = New-Object System.Collections.Generic.List[string]
        $work = $ctx
        foreach ($tag in @('PROVENANCE', 'GROUNDING')) {
            $rx = '(?ms)(\[' + $tag + '\][^\n]*(?:\n(?!\[)[^\n]*)*)'
            foreach ($m in [regex]::Matches($work, $rx)) {
                [void]$protected.Add($m.Groups[1].Value.Trim())
            }
            $work = [regex]::Replace($work, $rx, '')
        }
        $headKeep = ''
        $rest = $work
        while ($rest -match '(?s)^(\[(?:CONN|MEM)\][^\n]*(?:\n(?!\[)[^\n]*)*)\n\n?(.*)$') {
            if ($headKeep) { $headKeep = $headKeep + "`n`n" + $Matches[1] }
            else { $headKeep = $Matches[1] }
            $rest = $Matches[2]
        }
        $protText = if ($protected.Count -gt 0) { ($protected -join "`n`n") } else { '' }
        $room = $budget - $headKeep.Length - $protText.Length - 40
        if ($room -lt 200) { $room = 200 }
        if ($rest.Length -gt $room) {
            $rest = Get-PromptParleFidelityTrim -Text $rest -MaxChars $room -Marker "…[budget d$Dial]…"
        }
        $pieces = @()
        if ($headKeep) { $pieces += $headKeep }
        if ($protText) { $pieces += $protText }
        if ($rest) { $pieces += $rest.Trim() }
        $ctx = ($pieces -join "`n`n")
        $notes.Add("cap $budget")
    }

    $charsOut = $ctx.Length + $pr.Length
    $saved = [Math]::Max(0, $charsIn - $charsOut)
    if ($saved -gt 0) {
        $pct = if ($charsIn -gt 0) { [int][Math]::Round(100.0 * $saved / $charsIn) } else { 0 }
        $notes.Add("local −${pct}%")
    } elseif ($notes.Count -eq 0) {
        $notes.Add('fidelity ok')
    }

    return [pscustomobject]@{
        prompt        = $pr
        context       = $ctx
        notes         = @($notes.ToArray())
        tools         = @($tools | Select-Object -Unique)
        agent         = 'none'
        tools_enabled = $true
        dial          = $Dial
        budget        = $budget
        chars_in      = $charsIn
        chars_out     = $charsOut
        obligation    = $obligation
        turn_kind     = $turnKind
    }
}

function Optimize-PromptParleAgent {
    <#
    .SYNOPSIS
      Suggest local tools, profile, dial, and a tighter system prompt for an agent.
      Runs fully on this PC — no AI tokens.
    #>
    [CmdletBinding()]
    param(
        [string]$Name = 'Custom agent',
        [string]$Description = '',
        [string]$System = '',
        [string]$Profile = 'general',
        [int]$Dial = 3,
        [string[]]$Tools
    )
    $blob = ("{0} {1} {2}" -f $Name, $Description, $System).ToLowerInvariant()
    $suggested = New-Object System.Collections.Generic.List[string]
    foreach ($base in @('files', 'workspace', 'secret_scan')) { $suggested.Add($base) }

    $profile = if ($Profile) { $Profile } else { 'general' }
    $dialOut = if ($Dial -ge 1 -and $Dial -le 5) { $Dial } else { 3 }
    $reasons = New-Object System.Collections.Generic.List[string]

    if ($blob -match 'code|review|refactor|bug|function|class|typescript|python|powershell|developer|api') {
        $profile = 'developer'
        $dialOut = 2
        foreach ($t in @('code_brief', 'git', 'git_diff', 'file_index', 'deps', 'tree_pack')) {
            if (-not ($suggested -contains $t)) { $suggested.Add($t) }
        }
        $reasons.Add('Code-oriented language → developer profile + code_brief / git / deps tools')
    }
    if ($blob -match 'secur|threat|vuln|cve|audit|exploit|firewall|auth') {
        $profile = 'security-review'
        $dialOut = 3
        foreach ($t in @('secret_scan', 'code_brief', 'git_diff', 'file_index')) {
            if (-not ($suggested -contains $t)) { $suggested.Add($t) }
        }
        $reasons.Add('Security language → security-review + secret_scan / git_diff')
    }
    if ($blob -match 'doc|policy|obligat|compliance|summar|manual|spec') {
        if ($profile -eq 'general') { $profile = 'documentation' }
        foreach ($t in @('tree_pack')) {
            if (-not ($suggested -contains $t)) { $suggested.Add($t) }
        }
        $reasons.Add('Document language → documentation profile + tree_pack')
    }
    if ($blob -match 'log|syslog|splunk|siem|trace') {
        $profile = 'log-analysis'
        $dialOut = 4
        $reasons.Add('Log language → log-analysis profile, higher dial for noisy text')
    }
    if ($blob -match 'ssh|remote|server|host') {
        if (-not ($suggested -contains 'ssh')) { $suggested.Add('ssh') }
        $reasons.Add('Remote/server language → ssh tool')
    }
    if ($blob -match 'git|github|pull request|commit|branch') {
        if (-not ($suggested -contains 'git')) { $suggested.Add('git') }
        if (-not ($suggested -contains 'git_diff')) { $suggested.Add('git_diff') }
        $reasons.Add('Git language → git + git_diff')
    }
    if ($blob -match 'search|web|research|look up|news|docs|documentation|internet') {
        if (-not ($suggested -contains 'web_search')) { $suggested.Add('web_search') }
        $reasons.Add('Research language → web_search (brief, cached)')
    }
    # Always keep connections awareness on agent tools list
    if (-not ($suggested -contains 'connections')) { $suggested.Add('connections') }

    # Merge user tools
    if ($Tools) {
        foreach ($t in @($Tools)) {
            if ($t -and -not ($suggested -contains $t)) { $suggested.Add([string]$t) }
        }
    }

    # Tighten system: strip filler, keep intent (local, heuristic)
    $sys = if ($System) { $System.Trim() } else { '' }
    if (-not $sys) {
        $sys = "You are $Name. Be precise, cite evidence from attached local context, and prefer concrete actions."
        if ($Description) { $sys += " Focus: $Description" }
        $reasons.Add('Generated a short system brief (none provided)')
    } else {
        # Collapse whitespace / soft filler phrases
        $sys2 = [regex]::Replace($sys, '\s+', ' ').Trim()
        $sys2 = [regex]::Replace($sys2, '(?i)\b(please|kindly|very carefully|as much as possible)\b', '').Trim()
        $sys2 = [regex]::Replace($sys2, '\s{2,}', ' ').Trim()
        if ($sys2.Length -lt $sys.Length) {
            $reasons.Add("System brief tightened locally ($($sys.Length) → $($sys2.Length) chars)")
            $sys = $sys2
        }
        if ($sys.Length -gt 1200) {
            $sys = $sys.Substring(0, 1200).Trim() + '…'
            $reasons.Add('System brief capped at 1200 chars (local)')
        }
    }

    # Prefer local-first reminder in system
    if ($sys -notmatch '(?i)local|workspace|attached') {
        $sys = $sys.TrimEnd('.') + '. Prefer evidence from attached local workspace/tools; do not invent files.'
        $reasons.Add('Added local-evidence preference to system brief')
    }

    $catalog = @(Get-PromptParleToolCatalog)
    $toolDetails = @()
    foreach ($t in $suggested) {
        $meta = $catalog | Where-Object { $_.id -eq $t } | Select-Object -First 1
        if ($meta) {
            $toolDetails += @{
                id          = $meta.id
                name        = $meta.name
                description = $meta.description
                category    = $meta.category
                auto        = [bool]$meta.auto
            }
        }
    }

    return [pscustomobject]@{
        ok          = $true
        name        = $Name
        description = $Description
        system      = $sys
        profile     = $profile
        dial        = $dialOut
        tools       = @($suggested)
        tool_details = $toolDetails
        reasons     = @($reasons)
        tip         = 'Local tools run on this PC first (connections, memory, error_brief, relevant_slice, code brief) so fewer tokens hit the model without losing signal.'
    }
}

#endregion Local-first tools

#region Workspace / Git / GitHub / SSH (local-only — credentials never leave this PC)

$script:PromptParleMaxWorkspaceFileChars = 400000
$script:PromptParleMaxPackFiles = 12
$script:PromptParleSkipDirNames = @(
    '.git', 'node_modules', '.next', 'dist', 'build', 'out', 'target', 'vendor',
    '.venv', 'venv', '__pycache__', '.turbo', 'coverage', '.cache', 'bin', 'obj'
)

function Test-PromptParleCommandAvailable {
    param([string]$Name)
    return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

function Get-PromptParleHomePath {
    if ($env:USERPROFILE -and "$env:USERPROFILE".Trim()) { return [string]$env:USERPROFILE }
    if ($HOME -and "$HOME".Trim()) { return [string]$HOME }
    if ($env:HOME -and "$env:HOME".Trim()) { return [string]$env:HOME }
    return [string][Environment]::GetFolderPath('UserProfile')
}

function ConvertTo-PromptParleSingleString {
    <#
    .SYNOPSIS
      Coerce PathInfo / arrays / PSObject wrappers to one System.String (avoids "Argument types do not match").
    #>
    param($Value)
    if ($null -eq $Value) { return '' }
    if ($Value -is [string]) { return $Value }
    # Resolve-Path can yield PathInfo or Object[]
    if ($Value -is [System.Management.Automation.PathInfo]) {
        return [string]$Value.Path
    }
    if ($Value -is [System.Array] -or ($Value -is [System.Collections.IEnumerable] -and -not ($Value -is [string]))) {
        foreach ($item in @($Value)) {
            if ($null -eq $item) { continue }
            $s = ConvertTo-PromptParleSingleString $item
            if ($s) { return $s }
        }
        return ''
    }
    if ($Value.PSObject -and $Value.PSObject.Properties['Path']) {
        return [string]$Value.Path
    }
    return [string]$Value
}

function Get-PromptParleTrimPath {
    param([string]$Path)
    $p = ConvertTo-PromptParleSingleString $Path
    if (-not $p) { return '' }
    # Use char[] — string overloads of TrimEnd cause "Argument types do not match" on Windows PS 5.1
    return $p.TrimEnd([char[]]@([char]0x5C, [char]0x2F))
}

function Test-PromptParlePathEqual {
    param([string]$A, [string]$B)
    $a = ConvertTo-PromptParleSingleString $A
    $b = ConvertTo-PromptParleSingleString $B
    return [string]::Equals($a, $b, [StringComparison]::OrdinalIgnoreCase)
}

function Test-PromptParlePathStartsWith {
    param([string]$Path, [string]$Prefix)
    $p = ConvertTo-PromptParleSingleString $Path
    $pre = ConvertTo-PromptParleSingleString $Prefix
    if (-not $p -or -not $pre) { return $false }
    return $p.StartsWith($pre, [StringComparison]::OrdinalIgnoreCase)
}

function Resolve-PromptParleExistingPath {
    <#
    .SYNOPSIS
      Resolve a user path to a single existing full path string.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$DirectoryOnly
    )
    $raw = (ConvertTo-PromptParleSingleString $Path).Trim().Trim([char]'"').Trim([char]"'")
    if (-not $raw) { throw 'Path is empty' }

    $home = Get-PromptParleHomePath
    if ($raw -eq '~' -or $raw -eq '~/' -or $raw -eq '~\') {
        $raw = $home
    } elseif ($raw.Length -ge 2 -and $raw[0] -eq [char]'~' -and ($raw[1] -eq [char]'/' -or $raw[1] -eq [char]'\')) {
        $rest = $raw.Substring(2)
        if ($home) { $raw = [IO.Path]::Combine($home, $rest) }
    }

    # Expand simple env vars like %USERPROFILE%
    if ($raw -match '%[^%]+%') {
        $raw = [Environment]::ExpandEnvironmentVariables($raw)
    }

    $candidate = $raw
    if (-not [IO.Path]::IsPathRooted($candidate)) {
        try {
            $candidate = [IO.Path]::GetFullPath((Join-Path -Path (Get-Location).Path -ChildPath $candidate))
        } catch {
            $candidate = $raw
        }
    } else {
        try {
            $candidate = [IO.Path]::GetFullPath($candidate)
        } catch {
            # keep as-is
        }
    }

    if (-not (Test-Path -LiteralPath $candidate)) {
        # Last chance: Resolve-Path (handles some provider paths)
        try {
            $rp = Resolve-Path -LiteralPath $raw -ErrorAction Stop | Select-Object -First 1
            $candidate = ConvertTo-PromptParleSingleString $rp
        } catch {
            try {
                $rp = Resolve-Path -Path $raw -ErrorAction Stop | Select-Object -First 1
                $candidate = ConvertTo-PromptParleSingleString $rp
            } catch {
                throw "Path not found: $Path"
            }
        }
    }

    $candidate = ConvertTo-PromptParleSingleString $candidate
    if (-not $candidate) { throw "Path not found: $Path" }

    if ($DirectoryOnly -and -not (Test-Path -LiteralPath $candidate -PathType Container)) {
        throw "Workspace must be a directory: $candidate"
    }
    return $candidate
}

function Get-PromptParleDefaultCloneRoot {
    $home = Get-PromptParleHomePath
    $p = Join-Path -Path $home -ChildPath 'src'
    if (-not (Test-Path -LiteralPath $p)) {
        New-Item -ItemType Directory -Path $p -Force | Out-Null
    }
    return $p
}

function Test-PromptParlePathIsGitRepo {
    param($Path)
    $p = ConvertTo-PromptParleSingleString $Path
    if (-not $p) { return $false }
    if (-not (Test-Path -LiteralPath $p)) { return $false }
    $gitDir = Join-Path -Path $p -ChildPath '.git'
    return (Test-Path -LiteralPath $gitDir)
}

function Add-PromptParleWorkspaceRecent {
    param(
        [string]$Path,
        [int]$Max = 12
    )
    $pathStr = ConvertTo-PromptParleSingleString $Path
    if (-not $pathStr) { return [string[]]@() }

    $state = Get-PromptParleSessionState
    $list = New-Object System.Collections.Generic.List[string]
    [void]$list.Add($pathStr)

    $existing = Get-PromptParleProp $state 'workspace_recent'
    if ($null -ne $existing) {
        foreach ($item in @($existing)) {
            $s = ConvertTo-PromptParleSingleString $item
            if (-not $s) { continue }
            if (Test-PromptParlePathEqual -A $s -B $pathStr) { continue }
            if (Test-Path -LiteralPath $s -PathType Container) {
                [void]$list.Add($s)
            }
        }
    }
    while ($list.Count -gt $Max) { $list.RemoveAt($list.Count - 1) }
    # Force array (never unwrap single element to bare string)
    return [string[]]@($list.ToArray())
}

function Set-PromptParleWorkspace {
    <#
    .SYNOPSIS
      Attach a local folder (optionally a git repo) as the coding workspace.
      Path stays on this PC; never uploaded to PromptParle cloud.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Path
    )
    try {
        $resolved = Resolve-PromptParleExistingPath -Path (ConvertTo-PromptParleSingleString $Path) -DirectoryOnly
        $kind = if (Test-PromptParlePathIsGitRepo -Path $resolved) { 'git' } else { 'local' }
        $recent = [string[]]@(Add-PromptParleWorkspaceRecent -Path $resolved)
        $state = Get-PromptParleSessionState
        $state = New-PromptParleSessionSnapshot -Base $state -WorkspacePath $resolved -WorkspaceKind $kind -WorkspaceRecent $recent
        Save-PromptParleSessionState -State $state
        return [pscustomobject]@{
            path   = $resolved
            kind   = $kind
            is_git = [bool]($kind -eq 'git')
            recent = $recent
        }
    } catch {
        throw "Attach folder failed ($Path): $_"
    }
}

function Clear-PromptParleWorkspace {
    $state = Get-PromptParleSessionState
    $state = New-PromptParleSessionSnapshot -Base $state -WorkspacePath '' -WorkspaceKind 'none'
    Save-PromptParleSessionState -State $state
}

function Get-PromptParleWorkspace {
    $state = Get-PromptParleSessionState
    $path = [string](Get-PromptParleProp $state 'workspace_path' '')
    $kind = [string](Get-PromptParleProp $state 'workspace_kind' 'none')
    $exists = $false
    $isGit = $false
    $branch = $null
    $remote = $null
    if ($path -and (Test-Path -LiteralPath $path)) {
        $exists = $true
        $isGit = Test-PromptParlePathIsGitRepo -Path $path
        if ($isGit) { $kind = 'git' }
        if ($isGit -and (Test-PromptParleCommandAvailable -Name 'git')) {
            try {
                $branch = (& git -C $path rev-parse --abbrev-ref HEAD 2>$null | Out-String).Trim()
                $remote = (& git -C $path remote get-url origin 2>$null | Out-String).Trim()
            } catch { }
        }
    } elseif ($path) {
        $kind = 'missing'
    }
    $recent = @()
    $recRaw = Get-PromptParleProp $state 'workspace_recent'
    if ($null -ne $recRaw) {
        foreach ($item in @($recRaw)) {
            $s = [string]$item
            if ($s -and (Test-Path -LiteralPath $s -PathType Container)) { $recent += $s }
        }
    }
    return [pscustomobject]@{
        path       = $path
        kind       = $kind
        exists     = $exists
        is_git     = $isGit
        branch     = $branch
        remote     = $remote
        recent     = $recent
        ssh_target = [string](Get-PromptParleProp $state 'ssh_target' '')
        ssh_port   = [int](Get-PromptParleProp $state 'ssh_port' 22)
        ssh_cwd    = [string](Get-PromptParleProp $state 'ssh_cwd' '')
    }
}

function Get-PromptParleFsRoots {
    <#
    .SYNOPSIS
      Common starting places for the local folder browser (this PC only).
    #>
    $roots = New-Object System.Collections.Generic.List[object]
    $addRoot = {
        param([string]$Label, $PathIn)
        $p = ConvertTo-PromptParleSingleString $PathIn
        if (-not $p) { return }
        if (-not (Test-Path -LiteralPath $p -PathType Container)) { return }
        try {
            $full = ConvertTo-PromptParleSingleString (Resolve-Path -LiteralPath $p | Select-Object -First 1)
        } catch {
            $full = $p
        }
        if (-not $full) { return }
        [void]$roots.Add([pscustomobject]@{ label = [string]$Label; path = [string]$full; kind = 'root' })
    }
    $home = Get-PromptParleHomePath
    & $addRoot 'Home' $home
    if ($home) {
        & $addRoot 'Documents' (Join-Path -Path $home -ChildPath 'Documents')
        & $addRoot 'Desktop' (Join-Path -Path $home -ChildPath 'Desktop')
        & $addRoot 'Downloads' (Join-Path -Path $home -ChildPath 'Downloads')
        & $addRoot 'src' (Join-Path -Path $home -ChildPath 'src')
        & $addRoot 'Projects' (Join-Path -Path $home -ChildPath 'Projects')
        & $addRoot 'repos' (Join-Path -Path $home -ChildPath 'repos')
    }
    if ($script:PromptParleIsWindows) {
        try {
            Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue | ForEach-Object {
                $rootPath = ConvertTo-PromptParleSingleString $_.Root
                if ($rootPath -and (Test-Path -LiteralPath $rootPath)) {
                    & $addRoot ("Drive " + $_.Name + ":") $rootPath
                }
            }
        } catch { }
    } else {
        & $addRoot '/' '/'
        & $addRoot '/home' '/home'
        & $addRoot '/opt' '/opt'
        & $addRoot '/var' '/var'
    }
    $ws = Get-PromptParleWorkspace
    if ($ws.path -and $ws.exists) {
        & $addRoot 'Current workspace' $ws.path
    }
    foreach ($r in @($ws.recent)) {
        $rp = ConvertTo-PromptParleSingleString $r
        if (-not $rp) { continue }
        $leaf = [IO.Path]::GetFileName((Get-PromptParleTrimPath $rp))
        if (-not $leaf) { $leaf = $rp }
        & $addRoot ('Recent: ' + $leaf) $rp
    }
    # de-dupe by path
    $seen = @{}
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($r in $roots) {
        $key = (ConvertTo-PromptParleSingleString $r.path).ToLowerInvariant()
        if (-not $key -or $seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        [void]$out.Add($r)
    }
    return @($out.ToArray())
}

function Get-PromptParleFsList {
    <#
    .SYNOPSIS
      List a local directory for the folder browser (dirs + light file info).
    #>
    param(
        $Path,
        [int]$Max = 400
    )
    $pathStr = ConvertTo-PromptParleSingleString $Path
    if (-not $pathStr -or -not $pathStr.Trim()) {
        $rootEntries = @()
        foreach ($r in @(Get-PromptParleFsRoots)) {
            $rootEntries += [pscustomobject]@{
                name   = [string]$r.label
                path   = [string]$r.path
                is_dir = $true
                is_git = [bool](Test-PromptParlePathIsGitRepo -Path $r.path)
                size   = $null
            }
        }
        return [pscustomobject]@{
            path    = ''
            parent  = $null
            entries = $rootEntries
            roots   = $true
        }
    }

    $full = Resolve-PromptParleExistingPath -Path $pathStr -DirectoryOnly
    $parent = $null
    try {
        $p = Split-Path -Parent $full
        if ($p -and (Test-Path -LiteralPath $p)) {
            $parent = ConvertTo-PromptParleSingleString (Resolve-Path -LiteralPath $p | Select-Object -First 1)
        }
    } catch { }

    $skip = $script:PromptParleSkipDirNames
    $entries = New-Object System.Collections.Generic.List[object]
    $items = @(Get-ChildItem -LiteralPath $full -Force -ErrorAction SilentlyContinue |
        Where-Object {
            if ($_.PSIsContainer -and ($skip -contains $_.Name)) { return $false }
            if (-not $_.PSIsContainer -and ($_.Name -eq '.env' -or $_.Name -like '.env.*')) { return $false }
            return $true
        } |
        Sort-Object @{ Expression = { if ($_.PSIsContainer) { 0 } else { 1 } } }, Name |
        Select-Object -First $Max)

    foreach ($item in $items) {
        $isDir = [bool]$item.PSIsContainer
        [void]$entries.Add([pscustomobject]@{
            name   = [string]$item.Name
            path   = [string]$item.FullName
            is_dir = $isDir
            is_git = if ($isDir) { [bool](Test-PromptParlePathIsGitRepo -Path $item.FullName) } else { $false }
            size   = if (-not $isDir) { [long]$item.Length } else { $null }
        })
    }

    return [pscustomobject]@{
        path    = [string]$full
        parent  = $parent
        entries = @($entries.ToArray())
        roots   = $false
        is_git  = [bool](Test-PromptParlePathIsGitRepo -Path $full)
        count   = [int]$entries.Count
    }
}

function Get-PromptParleDirListingText {
    param(
        [string]$RelativePath = ''
    )
    $ws = Get-PromptParleWorkspace
    if (-not $ws.exists) { throw 'No workspace attached. /workspace <path> or Browse folders in the UI.' }
    $target = $ws.path
    if ($RelativePath -and $RelativePath.Trim() -and $RelativePath.Trim() -ne '.') {
        $target = Resolve-PromptParleWorkspacePath -RelativePath $RelativePath
    }
    if (-not (Test-Path -LiteralPath $target -PathType Container)) {
        throw "Not a directory: $RelativePath"
    }
    $list = Get-PromptParleFsList -Path $target -Max 200
    $lines = @("Directory: $($list.path)")
    if ($list.is_git) { $lines += '(git repository)' }
    foreach ($e in $list.entries) {
        if ($e.is_dir) {
            $mark = if ($e.is_git) { ' [git]' } else { '' }
            $lines += ("  [dir]  {0}/{1}" -f $e.name, $mark)
        } else {
            $kb = if ($null -ne $e.size) { [math]::Round($e.size / 1KB, 1) } else { 0 }
            $lines += ("  [file] {0}  ({1} KB)" -f $e.name, $kb)
        }
    }
    if ($list.entries.Count -eq 0) { $lines += '  (empty)' }
    return ($lines -join "`n")
}

function Resolve-PromptParleWorkspacePath {
    <#
    .SYNOPSIS
      Resolve a relative path under the workspace root (path traversal safe).
    #>
    param(
        [Parameter(Mandatory)][string]$RelativePath,
        [string]$Root
    )
    if (-not $Root) {
        $ws = Get-PromptParleWorkspace
        $Root = $ws.path
    }
    if (-not $Root -or -not (Test-Path -LiteralPath $Root)) {
        throw 'No workspace attached. Use /workspace C:\path\to\repo'
    }
    $rootStr = ConvertTo-PromptParleSingleString $Root
    $rel = (ConvertTo-PromptParleSingleString $RelativePath).Trim().TrimStart([char[]]@([char]0x2F, [char]0x5C))
    $rel = $rel.Replace([char]0x2F, [IO.Path]::DirectorySeparatorChar)
    if ($rel -match '(^|[\\/])\.\.([\\/]|$)') {
        throw 'Path may not contain ..'
    }
    $combined = Join-Path -Path $rootStr -ChildPath $rel
    $full = $null
    try {
        if (Test-Path -LiteralPath $combined) {
            $full = ConvertTo-PromptParleSingleString (Resolve-Path -LiteralPath $combined -ErrorAction Stop | Select-Object -First 1)
        } else {
            $full = [IO.Path]::GetFullPath($combined)
        }
    } catch {
        throw "Invalid path: $RelativePath"
    }
    $rootFull = ConvertTo-PromptParleSingleString (Resolve-Path -LiteralPath $rootStr | Select-Object -First 1)
    $rootPrefix = (Get-PromptParleTrimPath $rootFull) + [string][IO.Path]::DirectorySeparatorChar
    if (-not (Test-PromptParlePathEqual -A $full -B $rootFull) -and -not (Test-PromptParlePathStartsWith -Path $full -Prefix $rootPrefix)) {
        throw "Path escapes workspace: $RelativePath"
    }
    return $full
}

function Get-PromptParleWorkspaceTree {
    param(
        [int]$Depth = 2,
        [int]$MaxEntries = 200
    )
    if ($Depth -lt 1) { $Depth = 1 }
    if ($Depth -gt 5) { $Depth = 5 }
    $ws = Get-PromptParleWorkspace
    if (-not $ws.exists) { throw 'No workspace attached. /workspace <path>' }
    $root = $ws.path
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add(("Workspace: {0}  ({1})" -f $root, $ws.kind))
    if ($ws.branch) { $lines.Add(("Branch: {0}" -f $ws.branch)) }
    if ($ws.remote) { $lines.Add(("Remote: {0}" -f $ws.remote)) }
    $count = 0
    $skip = $script:PromptParleSkipDirNames

    function Walk([string]$Dir, [int]$Level, [string]$Prefix) {
        if ($script:__ppTreeCount -ge $MaxEntries) { return }
        $items = @(Get-ChildItem -LiteralPath $Dir -Force -ErrorAction SilentlyContinue |
            Where-Object {
                if ($_.PSIsContainer -and ($skip -contains $_.Name)) { return $false }
                if ($_.Name -eq '.env' -or $_.Name -like '.env.*') { return $false }
                return $true
            } | Sort-Object { -not $_.PSIsContainer }, Name)
        for ($i = 0; $i -lt $items.Count; $i++) {
            if ($script:__ppTreeCount -ge $MaxEntries) {
                $lines.Add("$Prefix… (truncated)")
                return
            }
            $item = $items[$i]
            $isLast = ($i -eq $items.Count - 1)
            $branch = if ($isLast) { '└─ ' } else { '├─ ' }
            $mark = if ($item.PSIsContainer) { $item.Name + '/' } else { $item.Name }
            $lines.Add($Prefix + $branch + $mark)
            $script:__ppTreeCount++
            if ($item.PSIsContainer -and $Level -lt $Depth) {
                $nextPrefix = $Prefix + $(if ($isLast) { '   ' } else { '│  ' })
                Walk -Dir $item.FullName -Level ($Level + 1) -Prefix $nextPrefix
            }
        }
    }
    $script:__ppTreeCount = 0
    Walk -Dir $root -Level 1 -Prefix ''
    return ($lines -join "`n")
}

function Read-PromptParleTextFileSafe {
    param(
        [Parameter(Mandatory)][string]$Path,
        [int]$MaxChars = 0
    )
    if ($MaxChars -le 0) { $MaxChars = $script:PromptParleMaxWorkspaceFileChars }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Not a file: $Path"
    }
    $item = Get-Item -LiteralPath $Path -ErrorAction Stop
    if ($item.Length -gt 5MB) {
        throw "File too large ($([math]::Round($item.Length/1MB,1)) MB): $($item.Name)"
    }
    # crude binary check
    $fs = [IO.File]::OpenRead($Path)
    try {
        $buf = New-Object byte[] 512
        $n = $fs.Read($buf, 0, 512)
        for ($i = 0; $i -lt $n; $i++) {
            if ($buf[$i] -eq 0) { throw "Binary file skipped: $($item.Name)" }
        }
    } finally { $fs.Close() }

    $text = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
    if ($null -eq $text) { $text = '' }
    $text = [string]$text
    $truncated = $false
    if ($text.Length -gt $MaxChars) {
        $text = $text.Substring(0, $MaxChars) + "`n`n…[truncated at $MaxChars chars]"
        $truncated = $true
    }
    return [pscustomobject]@{
        name      = $item.Name
        path      = $Path
        text      = $text
        truncated = $truncated
        chars     = $text.Length
    }
}

function Get-PromptParleWorkspaceFile {
    param([Parameter(Mandatory)][string]$RelativePath)
    $full = Resolve-PromptParleWorkspacePath -RelativePath $RelativePath
    return Read-PromptParleTextFileSafe -Path $full
}

function Find-PromptParleWorkspaceFiles {
    param(
        [Parameter(Mandatory)][string]$Pattern,
        [int]$Max = 40
    )
    $ws = Get-PromptParleWorkspace
    if (-not $ws.exists) { throw 'No workspace attached.' }
    $skip = $script:PromptParleSkipDirNames
    $wsPath = ConvertTo-PromptParleSingleString $ws.path
    $files = Get-ChildItem -LiteralPath $wsPath -Recurse -File -ErrorAction SilentlyContinue | Where-Object {
        $rel = $_.FullName.Substring($wsPath.Length).TrimStart([char[]]@([char]0x5C, [char]0x2F))
        foreach ($s in $skip) {
            if ($rel -like "$s\*" -or $rel -like "$s/*" -or $rel -eq $s) { return $false }
        }
        if ($_.Name -eq '.env' -or $_.Name -like '.env.*') { return $false }
        return ($_.Name -like $Pattern -or $rel -like $Pattern)
    } | Select-Object -First $Max
    $wsRoot = Get-PromptParleTrimPath $wsPath
    $lines = @("Matches for '$Pattern' (max $Max):")
    foreach ($f in $files) {
        $rel = $f.FullName.Substring($wsRoot.Length).TrimStart([char[]]@([char]0x5C, [char]0x2F))
        $lines += "  $rel  ($([math]::Round($f.Length/1KB,1)) KB)"
    }
    if ($files.Count -eq 0) { $lines += '  (none)' }
    return ($lines -join "`n")
}

function Get-PromptParleWorkspacePack {
    param(
        [Parameter(Mandatory)][string]$Pattern,
        [int]$MaxFiles = 0
    )
    if ($MaxFiles -le 0) { $MaxFiles = $script:PromptParleMaxPackFiles }
    $ws = Get-PromptParleWorkspace
    if (-not $ws.exists) { throw 'No workspace attached.' }
    $skip = $script:PromptParleSkipDirNames
    $wsPath = ConvertTo-PromptParleSingleString $ws.path
    $files = @(Get-ChildItem -LiteralPath $wsPath -Recurse -File -ErrorAction SilentlyContinue | Where-Object {
        $rel = $_.FullName.Substring($wsPath.Length).TrimStart([char[]]@([char]0x5C, [char]0x2F))
        foreach ($s in $skip) {
            if ($rel -like "$s\*" -or $rel -like "$s/*") { return $false }
        }
        if ($_.Name -eq '.env' -or $_.Name -like '.env.*') { return $false }
        if ($_.Length -gt 1.5MB) { return $false }
        return ($_.Name -like $Pattern -or $rel -like $Pattern)
    } | Select-Object -First $MaxFiles)

    $packed = New-Object System.Collections.Generic.List[object]
    $wsRoot = Get-PromptParleTrimPath $wsPath
    foreach ($f in $files) {
        try {
            $read = Read-PromptParleTextFileSafe -Path $f.FullName
            $rel = $f.FullName.Substring($wsRoot.Length).TrimStart([char[]]@([char]0x5C, [char]0x2F))
            [void]$packed.Add([pscustomobject]@{
                name = $rel.Replace([char]0x5C, [char]0x2F)
                text = $read.text
            })
        } catch {
            # skip binary / unreadable
        }
    }
    return @($packed.ToArray())
}

function Invoke-PromptParleGit {
    param(
        [Parameter(Mandatory)][string[]]$GitArgs,
        [string]$Path
    )
    if (-not (Test-PromptParleCommandAvailable -Name 'git')) {
        throw 'git not found. Install Git for Windows: https://git-scm.com/download/win'
    }
    if (-not $Path) {
        $ws = Get-PromptParleWorkspace
        if (-not $ws.exists) { throw 'No workspace. /workspace <path> first.' }
        $Path = $ws.path
    }
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & git -C $Path @GitArgs 2>&1
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prev
    }
    $text = ($output | ForEach-Object { "$_" }) -join "`n"
    if ($code -ne 0 -and -not $text) { $text = "git exit $code" }
    return [pscustomobject]@{ exit_code = $code; text = $text; path = $Path }
}

function Get-PromptParleGitStatusText {
    $ws = Get-PromptParleWorkspace
    if (-not $ws.exists) { throw 'No workspace attached.' }
    if (-not $ws.is_git) { return "Not a git repo: $($ws.path)`nUse /github clone owner/repo or attach a cloned folder." }
    $parts = @()
    $b = Invoke-PromptParleGit -Path $ws.path -GitArgs @('status', '-sb')
    $parts += $b.text
    $r = Invoke-PromptParleGit -Path $ws.path -GitArgs @('remote', '-v')
    if ($r.text) { $parts += "`nRemotes:`n$($r.text)" }
    return ($parts -join "`n")
}

function Invoke-PromptParleGitClone {
    param(
        [Parameter(Mandatory)][string]$UrlOrRepo,
        [string]$Destination
    )
    if (-not (Test-PromptParleCommandAvailable -Name 'git')) {
        throw 'git not found. Install Git for Windows: https://git-scm.com/download/win'
    }
    $url = $UrlOrRepo.Trim()
    # owner/repo → prefer SSH if keys likely, else HTTPS
    if ($url -match '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') {
        $url = "https://github.com/$url.git"
    }
    if (-not $Destination) {
        $name = [IO.Path]::GetFileNameWithoutExtension(($url -split '/')[-1] -replace '\.git$', '')
        if (-not $name) { $name = 'repo' }
        $Destination = Join-Path (Get-PromptParleDefaultCloneRoot) $name
    }
    if (Test-Path -LiteralPath $Destination) {
        throw "Destination already exists: $Destination — use /workspace $Destination"
    }
    $parent = Split-Path -Parent $Destination
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & git clone $url $Destination 2>&1
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prev
    }
    $text = ($output | ForEach-Object { "$_" }) -join "`n"
    if ($code -ne 0) {
        throw "git clone failed (exit $code): $text"
    }
    $ws = Set-PromptParleWorkspace -Path $Destination
    return [pscustomobject]@{
        path = $ws.path
        kind = $ws.kind
        url  = $url
        log  = $text
    }
}

function Get-PromptParleGitHubStatusText {
    $lines = @('GitHub / git tooling (uses YOUR local credentials — never sent to PromptParle):')
    $hasGit = Test-PromptParleCommandAvailable -Name 'git'
    $hasGh = Test-PromptParleCommandAvailable -Name 'gh'
    $lines += ("  git : {0}" -f $(if ($hasGit) { ((& git --version 2>$null | Out-String).Trim()) } else { 'not installed' }))
    $lines += ("  gh  : {0}" -f $(if ($hasGh) { ((& gh --version 2>$null | Select-Object -First 1 | Out-String).Trim()) } else { 'not installed (optional)' }))
    if ($hasGh) {
        $prev = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $auth = & gh auth status 2>&1 | Out-String
        } catch { $auth = "$_" }
        $ErrorActionPreference = $prev
        $lines += '  gh auth:'
        foreach ($ln in ($auth -split "`n")) {
            if ($ln.Trim()) { $lines += "    $($ln.Trim())" }
        }
    } else {
        $lines += '  Tip: install GitHub CLI (gh) for auth status + PR helpers, or use git with SSH keys / credential manager.'
    }
    $ws = Get-PromptParleWorkspace
    if ($ws.exists) {
        $lines += ''
        $lines += "Workspace: $($ws.path) ($($ws.kind))"
        if ($ws.branch) { $lines += "Branch: $($ws.branch)" }
        if ($ws.remote) { $lines += "Remote: $($ws.remote)" }
    } else {
        $lines += ''
        $lines += 'No workspace. Clone: /github clone owner/repo'
        $lines += 'Or attach: /workspace C:\Users\you\src\myproject'
    }
    $lines += ''
    $lines += 'SSH keys / PATs stay on this PC (ssh-agent, gh auth, Windows Credential Manager).'
    return ($lines -join "`n")
}

function Test-PromptParleSshPathSafe {
    param([string]$Path)
    if ($null -eq $Path) { return $true }
    $p = $Path.Trim()
    if (-not $p) { return $true }
    # Reject shell metacharacters — path only
    if ($p -match '[;|&`$<>\n\r]') { return $false }
    return $true
}

function Get-PromptParleSshCdPrefix {
    <#
    .SYNOPSIS
      Bash snippet: expand ~ and cd into path, fail with clear message if missing.
    #>
    param([Parameter(Mandatory)][string]$Path)
    $safe = ($Path.Trim() -replace "'", "'\''")
    # Expand ~ (single-quoted ~ never expands in bash). `$ → literal $ for remote shell.
    return @"
_pp_d='$safe'
case "`$_pp_d" in
  '~') _pp_d="`$HOME" ;;
  '~/'*) _pp_d="`$HOME/`${_pp_d#~/}" ;;
esac
if [ ! -d "`$_pp_d" ]; then
  echo "SSH working directory not found: `$_pp_d" >&2
  echo "Hint: path is case-sensitive; use autocomplete for remote folders." >&2
  exit 1
fi
cd "`$_pp_d" || exit 1
"@
}

function Test-PromptParleSshWorkingDirectory {
    <#
    .SYNOPSIS
      Verify a remote path exists as a directory; return resolved absolute path.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$Target,
        [int]$Port = 0,
        [int]$TimeoutSec = 20
    )
    $p = if ($null -eq $Path) { '' } else { $Path.Trim() }
    if (-not $p) {
        return [pscustomobject]@{ ok = $true; path = ''; resolved = ''; error = $null }
    }
    if (-not (Test-PromptParleSshPathSafe -Path $p)) {
        return [pscustomobject]@{
            ok       = $false
            path     = $p
            resolved = ''
            error    = 'Invalid path characters (no ; | & ` $ < >).'
        }
    }
    $script = (Get-PromptParleSshCdPrefix -Path $p) + "`npwd"
    $r = Invoke-PromptParleSsh -RemoteCommand $script -Target $Target -Port $Port -WorkingDirectory '' -TimeoutSec $TimeoutSec
    $text = [string]$r.text
    if ($r.exit_code -ne 0) {
        $err = $text.Trim()
        if (-not $err) { $err = "Remote directory not found: $p" }
        # Prefer the clear line we print
        if ($err -match 'SSH working directory not found: (.+)') {
            $err = "Directory does not exist on remote host: $($Matches[1].Trim())"
        }
        return [pscustomobject]@{
            ok       = $false
            path     = $p
            resolved = ''
            error    = $err
        }
    }
    $resolved = ($text -split "`n" | Where-Object { $_.Trim() } | Select-Object -Last 1).Trim()
    if (-not $resolved) { $resolved = $p }
    return [pscustomobject]@{
        ok       = $true
        path     = $p
        resolved = $resolved
        error    = $null
    }
}

function Get-PromptParleSshDirCompletions {
    <#
    .SYNOPSIS
      List remote directories matching a partial path (for UI autocomplete).
    #>
    param(
        [string]$Partial = '',
        [string]$Target,
        [int]$Port = 0,
        [int]$TimeoutSec = 15,
        [int]$Limit = 40
    )
    if (-not (Test-PromptParleSshPathSafe -Path $Partial)) {
        return [pscustomobject]@{ ok = $false; path = $Partial; dirs = @(); error = 'Invalid path characters' }
    }
    $p = if ($null -eq $Partial) { '' } else { $Partial.Trim() }
    $lim = [Math]::Max(5, [Math]::Min(80, $Limit))

    # Empty → common roots under home + /
    if (-not $p) {
        $cmd = @"
printf '%s\n' "`$HOME" / /home /var /opt /etc /tmp 2>/dev/null
ls -1A "`$HOME" 2>/dev/null | head -n 30 | while IFS= read -r n; do
  [ -d "`$HOME/`$n" ] && printf '%s\n' "`$HOME/`$n"
done
"@
    } else {
        $safe = ($p -replace "'", "'\''")
        $endsSlash = $p.EndsWith('/') -or $p.EndsWith('\')
        if ($endsSlash) {
            $cmd = @"
_pp_p='$safe'
case "`$_pp_p" in
  '~') _pp_p="`$HOME" ;;
  '~/'*) _pp_p="`$HOME/`${_pp_p#~/}" ;;
esac
_pp_base=`${_pp_p%/}
if [ ! -d "`$_pp_base" ]; then
  echo "Parent not found: `$_pp_base" >&2
  exit 0
fi
ls -1A "`$_pp_base" 2>/dev/null | head -n 80 | while IFS= read -r n; do
  [ -z "`$n" ] && continue
  [ -d "`$_pp_base/`$n" ] && printf '%s\n' "`$_pp_base/`$n"
done
"@
        } else {
            $cmd = @"
_pp_p='$safe'
case "`$_pp_p" in
  '~') _pp_p="`$HOME" ;;
  '~/'*) _pp_p="`$HOME/`${_pp_p#~/}" ;;
esac
if [ -d "`$_pp_p" ]; then
  printf '%s\n' "`$_pp_p"
  ls -1A "`$_pp_p" 2>/dev/null | head -n 40 | while IFS= read -r n; do
    [ -d "`$_pp_p/`$n" ] && printf '%s\n' "`$_pp_p/`$n"
  done
else
  _pp_parent=`$(dirname -- "`$_pp_p")
  _pp_base=`$(basename -- "`$_pp_p")
  [ "`$_pp_parent" = '.' ] && _pp_parent='/'
  if [ ! -d "`$_pp_parent" ]; then
    echo "Parent not found: `$_pp_parent" >&2
    exit 0
  fi
  ls -1A "`$_pp_parent" 2>/dev/null | head -n 200 | while IFS= read -r n; do
    case "`$n" in
      "`$_pp_base"*)
        if [ -d "`$_pp_parent/`$n" ]; then
          if [ "`$_pp_parent" = '/' ]; then printf '/%s\n' "`$n"
          else printf '%s/%s\n' "`$_pp_parent" "`$n"
          fi
        fi
        ;;
    esac
  done
fi
"@
        }
    }

    try {
        $r = Invoke-PromptParleSsh -RemoteCommand $cmd -Target $Target -Port $Port -WorkingDirectory '' -TimeoutSec $TimeoutSec
    } catch {
        return [pscustomobject]@{ ok = $false; path = $p; dirs = @(); error = "$_" }
    }
    $dirs = New-Object System.Collections.Generic.List[string]
    foreach ($line in (@([string]$r.text -split "`n"))) {
        $s = $line.Trim()
        if (-not $s) { continue }
        if ($s -match '^(Parent not found|bash:|ssh:)') { continue }
        if ($dirs.Count -ge $lim) { break }
        if (-not $dirs.Contains($s)) { [void]$dirs.Add($s) }
    }
    return [pscustomobject]@{
        ok    = ($r.exit_code -eq 0 -or $dirs.Count -gt 0)
        path  = $p
        dirs  = @($dirs)
        error = if ($r.exit_code -ne 0 -and $dirs.Count -eq 0) { [string]$r.text } else { $null }
    }
}

function Set-PromptParleSshTarget {
    param(
        [Parameter(Mandatory)][string]$Target,
        [int]$Port = 22,
        [string]$WorkingDirectory = '',
        # Validate remote cwd exists (default true when path provided)
        [bool]$ValidateCwd = $true
    )
    $t = $Target.Trim()
    if ($t -match '^ssh\s+(.+)$') { $t = $Matches[1].Trim() }
    # user@host[:port]
    $port = $Port
    if ($t -match '^(.+):(\d+)$') {
        $t = $Matches[1]
        $port = [int]$Matches[2]
    }
    if ($t -notmatch '@' -and $t -notmatch '^[A-Za-z0-9._-]+$') {
        throw 'SSH target should look like user@host (or host).'
    }
    $cwd = if ($null -eq $WorkingDirectory) { '' } else { $WorkingDirectory.Trim() }
    if ($cwd -and $ValidateCwd) {
        $check = Test-PromptParleSshWorkingDirectory -Path $cwd -Target $t -Port $port
        if (-not $check.ok) {
            throw $check.error
        }
        if ($check.resolved) { $cwd = [string]$check.resolved }
    }
    $state = Get-PromptParleSessionState
    $state = New-PromptParleSessionSnapshot -Base $state -SshTarget $t -SshPort $port -SshCwd $cwd
    Save-PromptParleSessionState -State $state
    return [pscustomobject]@{ target = $t; port = $port; cwd = $cwd }
}

function Clear-PromptParleSshTarget {
    $state = Get-PromptParleSessionState
    $state = New-PromptParleSessionSnapshot -Base $state -SshTarget '' -SshPort 22 -SshCwd ''
    Save-PromptParleSessionState -State $state
}

function Invoke-PromptParleSsh {
    param(
        [Parameter(Mandatory)][string]$RemoteCommand,
        [string]$Target,
        [int]$Port = 0,
        [string]$WorkingDirectory = '',
        [int]$TimeoutSec = 45,
        # When false, do not prepend session ssh_cwd (used for path checks themselves)
        [switch]$SkipSessionCwd
    )
    if (-not (Test-PromptParleCommandAvailable -Name 'ssh')) {
        throw 'ssh not found. On Windows install OpenSSH Client (Optional Features) or Git for Windows.'
    }
    $cwd = $WorkingDirectory
    if (-not $Target) {
        $ws = Get-PromptParleWorkspace
        $Target = $ws.ssh_target
        if ($Port -le 0) { $Port = [int]$ws.ssh_port }
        if (-not $SkipSessionCwd -and -not $cwd) {
            $cwd = [string](Get-PromptParleProp $ws 'ssh_cwd' '')
        }
    }
    if (-not $Target) { throw 'No SSH target. /ssh user@host' }
    if ($Port -le 0) { $Port = 22 }

    $remote = $RemoteCommand
    if ($cwd -and $cwd.Trim()) {
        # Expand ~ and fail clearly if directory missing (single-quoted ~ never expands in bash)
        $remote = (Get-PromptParleSshCdPrefix -Path $cwd.Trim()) + "`n" + $RemoteCommand
    }

    # Non-interactive: use BatchMode so missing keys fail fast (never prompt for password in server)
    $sshArgs = @(
        '-o', 'BatchMode=yes',
        '-o', 'StrictHostKeyChecking=accept-new',
        '-o', "ConnectTimeout=$TimeoutSec",
        '-p', "$Port",
        $Target,
        $remote
    )
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & ssh @sshArgs 2>&1
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prev
    }
    $text = ($output | ForEach-Object { "$_" }) -join "`n"
    if ($text.Length -gt $script:PromptParleMaxWorkspaceFileChars) {
        $text = $text.Substring(0, $script:PromptParleMaxWorkspaceFileChars) + "`n…[truncated]"
    }
    return [pscustomobject]@{
        target    = $Target
        port      = $Port
        exit_code = $code
        text      = $text
        command   = $RemoteCommand
    }
}


function Get-PromptParleSshFileContent {
    <#
    .SYNOPSIS
      Read a file under product source_root over SSH (0.16 read-before-write).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RemotePath,
        [int]$MaxBytes = 400000,
        [int]$TimeoutSec = 45
    )
    $bind = Resolve-PromptParleProductBind
    $root = ([string]$bind.root).TrimEnd('/\')
    $rp = $RemotePath.Trim()
    if (-not $rp) { throw 'Empty remote path' }
    if ($rp -notmatch '^(?:/|[A-Za-z]:)') {
        $rp = ($root + '/' + $rp.TrimStart('/\'))
    }
    $rp = ($rp -replace '/+', '/')
    if (-not $rp.StartsWith($root + '/') -and $rp -ne $root) {
        throw "Refuse read outside product source_root: $rp"
    }
    if ($rp -match '(?i)/(?:\.env|id_rsa|id_ed25519|\.ssh/|shadow|passwd)$') {
        throw "Refuse read of sensitive path: $rp"
    }
    $rpQ = $rp -replace "'", "'\''"
    $rootQ = $root -replace "'", "'\''"
    $remote = @"
set -euo pipefail
path='$rpQ'
root='$rootQ'
case "`$path" in
  "`$root"/*) ;;
  *) echo "REFUSE outside root"; exit 9 ;;
esac
if [ ! -f "`$path" ]; then
  echo "MISSING"
  exit 0
fi
sz=`$(wc -c < "`$path" | tr -d ' ')
echo "SIZE `$sz"
if [ "`$sz" -gt $MaxBytes ]; then
  echo "TOO_LARGE"
  exit 11
fi
echo "BEGIN_B64"
base64 -w0 "`$path" 2>/dev/null || base64 "`$path"
echo
echo "END_B64"
"@
    $r = Invoke-PromptParleSsh -RemoteCommand $remote -TimeoutSec $TimeoutSec -SkipSessionCwd
    $out = [string]$r.text
    if ($r.exit_code -ne 0) {
        if ($out -match 'TOO_LARGE') { throw "Remote file too large to read: $rp" }
        throw "SSH read failed ($($r.exit_code)): $out"
    }
    if ($out -match '(?m)^MISSING\s*$') {
        return [pscustomobject]@{ ok = $true; path = $rp; exists = $false; bytes = 0; content = $null }
    }
    $size = 0
    if ($out -match '(?m)^SIZE\s+(\d+)') { $size = [int]$Matches[1] }
    $b64 = $null
    if ($out -match '(?s)BEGIN_B64\r?\n(.*?)\r?\nEND_B64') {
        $b64 = ($Matches[1] -replace '\s', '')
    }
    if (-not $b64) {
        return [pscustomobject]@{ ok = $true; path = $rp; exists = $true; bytes = $size; content = $null; note = 'no-body' }
    }
    try {
        $bytes = [Convert]::FromBase64String($b64)
        $content = [System.Text.Encoding]::UTF8.GetString($bytes)
    } catch {
        throw "Failed to decode remote file $rp : $_"
    }
    return [pscustomobject]@{
        ok      = $true
        path    = $rp
        exists  = $true
        bytes   = $bytes.Length
        content = $content
    }
}

function Test-PromptParleRunCommandAllowed {
    <#
    .SYNOPSIS
      Allowlist for ```run``` implement-pipeline commands (0.16).
      Deny destructive shells; allow prisma/npm/git status-class ops.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Command)
    $c = ($Command -replace '[\r\n]+', ' ').Trim()
    if (-not $c) { return [pscustomobject]@{ ok = $false; reason = 'empty command' } }
    if ($c.Length -gt 500) { return [pscustomobject]@{ ok = $false; reason = 'command too long' } }

    # Hard denylist (anything resembling shell bombs / data loss)
    $deny = @(
        '(?i)\brm\s+(-[a-zA-Z]*f|-[a-zA-Z]*r)',
        '(?i)\b(mkfs|dd\s+if=|shutdown|reboot|halt|poweroff)\b',
        '(?i)\b(drop\s+(database|table|schema)|truncate\s+table|delete\s+from)\b',
        '(?i)\b(curl|wget|fetch)\b.*\|\s*(ba)?sh',
        '(?i)\b(>|>>)\s*/',
        '(?i)\bchmod\s+777\b',
        '(?i)\b(sudo|su\s)',
        '(?i)\b(kill\s+-9|pkill|killall)\b',
        '(?i)\b(nc\s+-|ncat\s+|bash\s+-i|python\s+-c\s+.*socket)',
        '(?i)`|\$\(|\$\{',
        '(?i);\s*(rm|dd|drop|curl|wget)',
        '(?i)&&\s*(rm|dd|drop)',
        '(?i)\|\s*(ba)?sh\b'
    )
    foreach ($d in $deny) {
        if ($c -match $d) {
            return [pscustomobject]@{ ok = $false; reason = "denied pattern: $d" }
        }
    }

    # Allowlist — single logical command (optional leading cd handled by runner)
    $allow = @(
        '^(?i)npx\s+prisma\s+(migrate\s+(deploy|status|diff)|generate|validate|format|db\s+pull)(\s|$)',
        '^(?i)npx\s+prisma\s+migrate\s+dev(\s+--name\s+[A-Za-z0-9_\-]+)?(\s+--skip-seed)?(\s+--create-only)?(\s|$)',
        '^(?i)npm\s+(run\s+)?(build|test|lint|typecheck|ci)(\s|$)',
        '^(?i)npm\s+ci(\s|$)',
        '^(?i)npm\s+install(\s+--(legacy-peer-deps|omit=dev|no-save|prefer-offline))*(\s|$)',
        '^(?i)npx\s+tsc(\s+--noEmit)?(\s|$)',
        '^(?i)git\s+(status|diff|log|show|branch|rev-parse)(\s|$)',
        '^(?i)node\s+-v(\s|$)',
        '^(?i)npm\s+-v(\s|$)',
        '^(?i)ls(\s+-[a-zA-Z]+)?(\s+\S+)*$',
        '^(?i)pwd(\s|$)',
        '^(?i)cat\s+[A-Za-z0-9_./\-]+$',
        '^(?i)head(\s+-n\s+\d+)?\s+[A-Za-z0-9_./\-]+$',
        '^(?i)wc\s+(-[a-zA-Z]+\s+)*[A-Za-z0-9_./\-]+$'
    )
    foreach ($a in $allow) {
        if ($c -match $a) {
            return [pscustomobject]@{ ok = $true; reason = 'allowlisted'; command = $c }
        }
    }
    return [pscustomobject]@{
        ok     = $false
        reason = 'not on allowlist (prisma migrate/generate, npm build/test, git status/diff/log, …)'
    }
}

function Invoke-PromptParleSshRunCommand {
    <#
    .SYNOPSIS
      Run one allowlisted command under product source_root over SSH (0.16).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Command,
        [int]$TimeoutSec = 180
    )
    $check = Test-PromptParleRunCommandAllowed -Command $Command
    if (-not $check.ok) {
        throw "Refuse run: $($check.reason) — cmd: $Command"
    }
    $bind = Resolve-PromptParleProductBind
    $root = ([string]$bind.root).TrimEnd('/\')
    $rootQ = $root -replace "'", "'\''"
    $cmdB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes([string]$check.command))
    $remote = @"
set -euo pipefail
cd '$rootQ'
cmd=`$(printf '%s' '$cmdB64' | base64 -d)
echo "CWD `$(pwd)"
echo "CMD `$cmd"
set +e
bash -lc "`$cmd"
ec=`$?
set -e
echo "EXIT `$ec"
exit 0
"@
    $r = Invoke-PromptParleSsh -RemoteCommand $remote -TimeoutSec $TimeoutSec -SkipSessionCwd
    $out = [string]$r.text
    $exitCode = 1
    if ($out -match '(?m)^EXIT\s+(\d+)\s*$') { $exitCode = [int]$Matches[1] }
    # Trim noise; keep last ~8k for report
    $clip = $out
    if ($clip.Length -gt 8000) {
        $clip = '…(truncated)…' + $clip.Substring($clip.Length - 7800)
    }
    return [pscustomobject]@{
        ok        = ($exitCode -eq 0)
        command   = [string]$check.command
        cwd       = $root
        exit_code = $exitCode
        text      = $clip
    }
}

function Set-PromptParleSshFileContent {
    <#
    .SYNOPSIS
      Safe write under product SOURCE root only (never live /var/www deploy root).
      0.16: read-before-write (existing size/content snapshot for report + guards)
      - Backup existing file to *.pp-bak-<utc> before overwrite
      - Refuse stubs / destructive shrinks
      - Refuse paths outside product_root (no "trash the server" path)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RemotePath,
        [Parameter(Mandatory)][string]$Content,
        [int]$TimeoutSec = 90,
        [switch]$SkipReadBefore
    )
    $bind = Resolve-PromptParleProductBind
    $root = ([string]$bind.root).TrimEnd('/\')
    $live = ([string]$bind.live).TrimEnd('/\')
    $rp = $RemotePath.Trim()
    if (-not $rp) { throw 'Empty remote path' }
    if ($rp -notmatch '^(?:/|[A-Za-z]:)') {
        $rp = ($root + '/' + $rp.TrimStart('/\'))
    }
    # Normalize //
    $rp = ($rp -replace '/+', '/')

    # HARD: never write live deploy tree via apply (source only; deploy is explicit later)
    if ($live -and ($rp -eq $live -or $rp.StartsWith($live + '/'))) {
        throw "Refuse write to LIVE deploy root ($live). Apply only to source_root ($root). Deploy is a separate, explicit step."
    }
    if (-not $rp.StartsWith($root + '/') -and $rp -ne $root) {
        throw "Refuse write outside product source_root: $rp (allowed under $root only)"
    }
    # Extra denylist: never touch secrets / system
    if ($rp -match '(?i)/(?:\.env|id_rsa|id_ed25519|\.ssh/|shadow|passwd)$') {
        throw "Refuse write to sensitive path: $rp"
    }

    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Content)
    if ($bytes.Length -gt 1500000) { throw "File too large to apply ($($bytes.Length) bytes): $rp" }
    if ($bytes.Length -lt 8) { throw "Refuse empty/tiny apply for: $rp" }

    $bodyTrim = $Content.Trim()
    if ($bodyTrim -match '(?i)\.\.\.\s*rest of|\.\.\.\s*existing|\.\.\.\s*other (fields|models|code)|//\s*\.\.\.|/\*\s*\.\.\.|TODO:\s*implement|placeholder') {
        throw "Refuse stub apply (placeholder / ellipsis body): $rp — emit the FULL file."
    }
    # Truncated prisma / config smell
    if ($rp -match '(?i)schema\.prisma$' -and $bodyTrim -notmatch 'generator\s+client' -and $bodyTrim -notmatch 'datasource\s+') {
        throw "Refuse incomplete prisma schema (missing generator/datasource): $rp"
    }

    # 0.16 read-before-write: snapshot existing file (also feeds local shrink guard)
    $prior = $null
    $priorBytes = 0
    $priorExists = $false
    if (-not $SkipReadBefore) {
        try {
            $prior = Get-PromptParleSshFileContent -RemotePath $rp -TimeoutSec ([Math]::Min(45, $TimeoutSec))
            if ($prior.exists) {
                $priorExists = $true
                $priorBytes = [int]$prior.bytes
                if ($priorBytes -gt 400 -and $bytes.Length -lt [int]($priorBytes * 0.35)) {
                    throw "Refuse destructive shrink of $rp (read-before: old=$priorBytes new=$($bytes.Length)). Emit FULL file contents."
                }
                # Identical content — skip write (idempotent)
                if ($null -ne $prior.content -and $prior.content -eq $Content) {
                    return [pscustomobject]@{
                        ok       = $true
                        path     = $rp
                        bytes    = $bytes.Length
                        backup   = $null
                        prior    = $priorBytes
                        skipped  = $true
                        text     = 'UNCHANGED (read-before-write)'
                    }
                }
            }
        } catch {
            if ("$_" -match 'Refuse destructive') { throw }
            # Non-fatal read failure — remote write still has size guard
            $prior = $null
        }
    }

    $rpQ = $rp -replace "'", "'\''"
    $rootQ = $root -replace "'", "'\''"

    # Size check + backup + write in one remote script
    $b64 = [Convert]::ToBase64String($bytes)
    $newLen = $bytes.Length
    $remote = @"
set -euo pipefail
path='$rpQ'
root='$rootQ'
newlen=$newLen
# must stay under root
case "`$path" in
  "`$root"/*) ;;
  *) echo "REFUSE outside root"; exit 9 ;;
esac
# backup if exists
if [ -f "`$path" ]; then
  old=`$(wc -c < "`$path" | tr -d ' ')
  # destructive shrink guard (35%)
  minkeep=`$(( old * 35 / 100 ))
  if [ "`$old" -gt 400 ] && [ "`$newlen" -lt "`$minkeep" ]; then
    echo "REFUSE destructive shrink old=`$old new=`$newlen"
    exit 10
  fi
  bak="`$path.pp-bak-`$(date -u +%Y%m%d%H%M%S)"
  cp -a "`$path" "`$bak"
  echo "BACKUP `$bak (`$old bytes)"
else
  echo "NEW_FILE"
fi
mkdir -p "`$(dirname "`$path")"
base64 -d > "`$path" <<'PPB64'
$b64
PPB64
echo "WROTE `$path `$(wc -c < "`$path" | tr -d ' ')"
"@
    $r = Invoke-PromptParleSsh -RemoteCommand $remote -TimeoutSec $TimeoutSec -SkipSessionCwd
    $out = [string]$r.text
    if ($r.exit_code -ne 0) {
        if ($out -match 'REFUSE destructive') {
            throw "Refuse destructive shrink of $rp (backup not needed; file unchanged). Emit FULL file contents."
        }
        if ($out -match 'REFUSE outside') {
            throw "Refuse write outside source_root: $rp"
        }
        throw "SSH write failed ($($r.exit_code)): $out"
    }
    $bakPath = $null
    if ($out -match 'BACKUP\s+(\S+)') { $bakPath = $Matches[1] }
    return [pscustomobject]@{
        ok      = $true
        path    = $rp
        bytes   = $bytes.Length
        backup  = $bakPath
        prior   = $priorBytes
        exists  = $priorExists
        skipped = $false
        text    = $out
    }
}

function Get-PromptParleHomeworkCommands {
    <#
    .SYNOPSIS
      0.16.1: scrape "you run this" homework from model text into allowlisted commands.
      Capability=obligation — if the model dumps a command the client can run, the client runs it.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $found = New-Object System.Collections.Generic.List[string]
    if (-not $Text) { return @() }

    # Fenced blocks that are NOT apply/run (bash/sh/shell/powershell/text)
    $rxFence = [regex]::new('(?ms)```(?:bash|sh|shell|zsh|powershell|ps1|console|terminal|text|cmd)?[ \t]*\r?\n(.*?)```')
    foreach ($m in $rxFence.Matches($Text)) {
        $full = $m.Value
        if ($full -match '(?i)^```(?:apply|run)\b') { continue }
        $body = ($m.Groups[1].Value -replace '^\s+|\s+$', '')
        foreach ($line in ($body -split '\r?\n')) {
            $c = ($line -replace '^\s*[$#>]\s*', '').Trim()
            if (-not $c) { continue }
            if ($c -match '^(?i)(cd|export|set)\s') { continue }
            $chk = Test-PromptParleRunCommandAllowed -Command $c
            if ($chk.ok) { $found.Add([string]$chk.command) }
        }
    }

    # Inline backticks: `npx prisma migrate deploy`
    $rxTick = [regex]::new('`([^`\n]{4,200})`')
    foreach ($m in $rxTick.Matches($Text)) {
        $c = $m.Groups[1].Value.Trim()
        if ($c -match '(?i)^(apply path|run\b)') { continue }
        $chk = Test-PromptParleRunCommandAllowed -Command $c
        if ($chk.ok) { $found.Add([string]$chk.command) }
    }

    # "Run: npx prisma ..." single line
    foreach ($line in ($Text -split '\r?\n')) {
        if ($line -match '(?i)\b(?:run this|run the following|please run|you (?:can |should )?run|execute)\b[^:\n]*:\s*(.+)$') {
            $c = $Matches[1].Trim().Trim('`').Trim()
            $chk = Test-PromptParleRunCommandAllowed -Command $c
            if ($chk.ok) { $found.Add([string]$chk.command) }
        }
    }

    # de-dupe preserve order
    $seen = @{}
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($c in $found) {
        $k = $c.ToLowerInvariant()
        if ($seen.ContainsKey($k)) { continue }
        $seen[$k] = $true
        $out.Add($c)
    }
    return @($out.ToArray())
}

function Test-PromptParleTheaterText {
    <#
    .SYNOPSIS
      Detect status theater / permission loops / empty-promise deliver that violate capability=obligation.
    #>
    param([string]$Text = '')
    if (-not $Text) { return $false }
    return [bool]($Text -match '(?i)(Ready for the (named )?task|Name it and I ship|spine locked|Just say the word|Would you like me to (actually )?implement|Say the word and I|Ready when you are|Awaiting (your )?(go|approval)|I can implement (this|that) (if|when)|Generating (updated |the )?(deliverable|summary|document|one-?pager|file) now|I''?ll base .{0,80}(strictly )?on|Understood\.?\s*I''?ll)')
}

function Invoke-PromptParleApplyResponseBlocks {
    <#
    .SYNOPSIS
      0.16.1 implement pipeline: capability=obligation.
      - ```apply path=...``` → read-before-write, backup, SSH write
      - ```run``` → allowlisted command under source_root
      - Homework scrape: model "run this yourself" → client runs if allowlisted
      - Auto follow-through: schema.prisma apply → prisma generate + migrate deploy when missing
      - Fail-closed report on implement turns with zero action
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$ResponseText,
        [string]$TurnKind = 'chat'
    )
    $text = if ($null -eq $ResponseText) { '' } else { [string]$ResponseText }
    $applied = New-Object System.Collections.Generic.List[string]
    $backups = New-Object System.Collections.Generic.List[string]
    $errors = New-Object System.Collections.Generic.List[string]
    $runs = New-Object System.Collections.Generic.List[object]
    $skipped = New-Object System.Collections.Generic.List[string]
    $notes = New-Object System.Collections.Generic.List[string]
    $homeworkRan = New-Object System.Collections.Generic.List[string]

    if (-not $text) {
        return [pscustomobject]@{
            text = $text; applied = @(); errors = @(); backups = @(); runs = @()
            skipped = @(); count = 0; run_count = 0; fail_closed = $false; homework = @()
        }
    }

    # Collect apply + run blocks with document order
    $steps = New-Object System.Collections.Generic.List[object]
    $rxApply = [regex]::new('(?ms)```apply\s+path\s*[=:]\s*([^\s\r\n`]+)[ \t]*\r?\n(.*?)```')
    foreach ($m in $rxApply.Matches($text)) {
        $steps.Add([pscustomobject]@{
            kind   = 'apply'
            index  = $m.Index
            path   = $m.Groups[1].Value.Trim().Trim('"').Trim("'")
            body   = $m.Groups[2].Value
        })
    }
    $rxRun = [regex]::new('(?ms)```run(?:\s+[^\r\n`]*)?[ \t]*\r?\n(.*?)```')
    foreach ($m in $rxRun.Matches($text)) {
        $body = ($m.Groups[1].Value -replace '^\s+|\s+$', '')
        $cmdLine = ($body -split '\r?\n' | Where-Object { $_.Trim() } | Select-Object -First 1)
        if (-not $cmdLine) { continue }
        $steps.Add([pscustomobject]@{
            kind    = 'run'
            index   = $m.Index
            command = $cmdLine.Trim()
            source  = 'block'
        })
    }

    # 0.16.1 homework interceptor — capability=obligation
    $hw = @(Get-PromptParleHomeworkCommands -Text $text)
    $existingRunCmds = @{}
    foreach ($s in $steps) {
        if ($s.kind -eq 'run') { $existingRunCmds[[string]$s.command.ToLowerInvariant()] = $true }
    }
    $hwIdx = 0
    foreach ($c in $hw) {
        $k = $c.ToLowerInvariant()
        if ($existingRunCmds.ContainsKey($k)) { continue }
        $steps.Add([pscustomobject]@{
            kind    = 'run'
            index   = 900000 + $hwIdx
            command = $c
            source  = 'homework'
        })
        $homeworkRan.Add($c)
        $existingRunCmds[$k] = $true
        $hwIdx++
        $notes.Add("homework→run: $c")
    }

    $ordered = @($steps | Sort-Object index)
    foreach ($step in $ordered) {
        if ($step.kind -eq 'apply') {
            $rel = [string]$step.path
            $body = [string]$step.body
            if ($body -notmatch '\r?\n$') { $body = $body + "`n" }
            try {
                $w = Set-PromptParleSshFileContent -RemotePath $rel -Content $body
                if ($w.skipped) {
                    $skipped.Add([string]$w.path)
                } else {
                    $applied.Add([string]$w.path)
                    if ($w.backup) { $backups.Add([string]$w.backup) }
                }
            } catch {
                $errors.Add(("$rel : $_"))
            }
        }
        elseif ($step.kind -eq 'run') {
            $cmd = [string]$step.command
            try {
                $rr = Invoke-PromptParleSshRunCommand -Command $cmd
                $runs.Add($rr)
                if (-not $rr.ok) {
                    $errors.Add(("run ``$cmd`` exit $($rr.exit_code)"))
                }
            } catch {
                $errors.Add(("run ``$cmd`` : $_"))
                $runs.Add([pscustomobject]@{
                    ok = $false; command = $cmd; exit_code = -1; text = "$_"; cwd = $null
                })
            }
        }
    }

    # Auto follow-through: schema.prisma landed without prisma generate/migrate → client runs them
    $touchedSchema = $false
    foreach ($p in @($applied.ToArray() + $skipped.ToArray())) {
        if ($p -match '(?i)schema\.prisma$') { $touchedSchema = $true; break }
    }
    $ranPrisma = $false
    foreach ($rr in $runs) {
        if ([string]$rr.command -match '(?i)prisma') { $ranPrisma = $true; break }
    }
    if ($touchedSchema -and -not $ranPrisma) {
        foreach ($autoCmd in @('npx prisma generate', 'npx prisma migrate deploy')) {
            try {
                $rr = Invoke-PromptParleSshRunCommand -Command $autoCmd
                $runs.Add($rr)
                $notes.Add("auto-follow: $autoCmd")
                if (-not $rr.ok) { $errors.Add(("auto ``$autoCmd`` exit $($rr.exit_code)")) }
            } catch {
                $errors.Add(("auto ``$autoCmd`` : $_"))
                $runs.Add([pscustomobject]@{
                    ok = $false; command = $autoCmd; exit_code = -1; text = "$_"; cwd = $null
                })
            }
        }
    }

    $acted = ($applied.Count -gt 0) -or ($runs.Count -gt 0) -or ($skipped.Count -gt 0)
    $theater = Test-PromptParleTheaterText -Text $text
    $failClosed = $false
    if ($TurnKind -eq 'implement' -and -not $acted) {
        $failClosed = $true
        $notes.Add('fail-closed: implement turn with zero apply/run')
    }

    $headerLines = New-Object System.Collections.Generic.List[string]
    $headerLines.Add('## What changed')
    $headerLines.Add('_Implement pipeline 0.16.1 · capability=obligation · read→apply→run→report (source_root only)._')
    $headerLines.Add('')

    if ($failClosed) {
        $headerLines.Add('**FAIL-CLOSED: implement turn produced no apply/run action.**')
        $headerLines.Add('The client can write source and run allowlisted commands — the model did not use that channel. This is a product failure, not a user homework gap. Re-ask or continue so apply/run blocks land.')
        $headerLines.Add('')
    }
    if ($theater -and -not $acted) {
        $headerLines.Add('**Theater detected** (Ready/Name it and I ship/permission loop) with no landed work — stripped of authority. Capability=obligation requires apply/run, not status speech.')
        $headerLines.Add('')
    }
    if ($applied.Count -gt 0) {
        $headerLines.Add("**Landed on SOURCE tree (not live deploy): $($applied.Count) file(s)**")
        foreach ($p in $applied) { $headerLines.Add("- ``$p``") }
    } elseif ($skipped.Count -eq 0 -and $steps.Count -gt 0) {
        $headerLines.Add('**No files landed** from apply blocks (none, refused, or failed).')
    }
    if ($skipped.Count -gt 0) {
        $headerLines.Add('')
        $headerLines.Add("**Unchanged (read-before-write identical): $($skipped.Count)**")
        foreach ($p in $skipped) { $headerLines.Add("- ``$p``") }
    }
    if ($backups.Count -gt 0) {
        $headerLines.Add('')
        $headerLines.Add('**Backups (auto, before overwrite):**')
        foreach ($b in $backups) { $headerLines.Add("- ``$b``") }
    }
    if ($runs.Count -gt 0) {
        $headerLines.Add('')
        $headerLines.Add("**Remote commands ($($runs.Count)) — client executed (not user homework):**")
        foreach ($rr in $runs) {
            $mark = if ($rr.ok) { 'ok' } else { 'FAIL' }
            $headerLines.Add("- ``$($rr.command)`` → exit $($rr.exit_code) ($mark)")
            if ($rr.text) {
                $snip = [string]$rr.text
                if ($snip.Length -gt 600) { $snip = $snip.Substring(0, 600) + '…' }
                $snip = ($snip -replace '\r?\n', ' | ')
                $headerLines.Add("  - $snip")
            }
        }
    }
    if ($homeworkRan.Count -gt 0) {
        $headerLines.Add('')
        $headerLines.Add("**Homework intercepted** (model told user to run; client ran instead): $($homeworkRan.Count)")
        foreach ($h in $homeworkRan) { $headerLines.Add("- ``$h``") }
    }
    if ($errors.Count -gt 0) {
        $headerLines.Add('')
        $headerLines.Add('**Pipeline errors (refused — no silent trash):**')
        foreach ($e in $errors) { $headerLines.Add("- $e") }
    }
    if ($notes.Count -gt 0 -and ($acted -or $failClosed)) {
        $headerLines.Add('')
        $headerLines.Add('_Pipeline notes: ' + (($notes | Select-Object -First 6) -join '; ') + '_')
    }
    $headerLines.Add('')
    $headerLines.Add('_Not git commit, not /var/www live deploy — unless a successful run/deploy step shows it._')
    $headerLines.Add('')
    $headerLines.Add('---')
    $headerLines.Add('')
    $header = ($headerLines -join "`n")

    # Only prefix report when we acted, fail-closed, theater, or had steps
    $needHeader = $acted -or $failClosed -or $theater -or ($steps.Count -gt 0) -or ($errors.Count -gt 0)
    $outText = if ($needHeader) { $header + $text } else { $text }

    return [pscustomobject]@{
        text         = $outText
        applied      = @($applied.ToArray())
        backups      = @($backups.ToArray())
        skipped      = @($skipped.ToArray())
        runs         = @($runs.ToArray())
        errors       = @($errors.ToArray())
        homework     = @($homeworkRan.ToArray())
        notes        = @($notes.ToArray())
        count        = $applied.Count
        run_count    = $runs.Count
        fail_closed  = $failClosed
        theater      = $theater
    }
}

# ── Document deliverables (0.17): ```file name=…``` → real file + download URL ──

function Get-PromptParleExportsRoot {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) 'promptparle-exports'
    if (-not (Test-Path -LiteralPath $root)) {
        New-Item -ItemType Directory -Path $root -Force | Out-Null
    }
    return $root
}

function Get-PromptParleExportContentType {
    param([string]$Name)
    $ext = [System.IO.Path]::GetExtension($Name).ToLowerInvariant()
    switch ($ext) {
        '.pdf'  { return 'application/pdf' }
        '.docx' { return 'application/vnd.openxmlformats-officedocument.wordprocessingml.document' }
        '.xlsx' { return 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet' }
        '.csv'  { return 'text/csv; charset=utf-8' }
        '.json' { return 'application/json; charset=utf-8' }
        '.html' { return 'text/html; charset=utf-8' }
        '.htm'  { return 'text/html; charset=utf-8' }
        '.md'   { return 'text/markdown; charset=utf-8' }
        '.txt'  { return 'text/plain; charset=utf-8' }
        '.xml'  { return 'application/xml; charset=utf-8' }
        default { return 'application/octet-stream' }
    }
}

function ConvertTo-PromptParleSafeFileName {
    param([string]$Name)
    $n = if ($Name) { $Name.Trim() } else { 'document.txt' }
    $n = $n -replace '[\\/:*?"<>|]+', '_'
    $n = $n.Trim('. ')
    if (-not $n) { $n = 'document.txt' }
    if ($n.Length -gt 120) {
        $ext = [System.IO.Path]::GetExtension($n)
        $base = [System.IO.Path]::GetFileNameWithoutExtension($n)
        if ($base.Length -gt 100) { $base = $base.Substring(0, 100) }
        $n = $base + $ext
    }
    return $n
}

function New-PromptParleZipFromEntries {
    <#
    .SYNOPSIS
      Build a zip (OOXML package) from name→UTF8 text or byte[] entries. Pure .NET.
    #>
    param([hashtable]$Entries)
    try {
        Add-Type -AssemblyName System.IO.Compression -ErrorAction SilentlyContinue | Out-Null
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue | Out-Null
    } catch { }
    $ms = New-Object System.IO.MemoryStream
    $zip = New-Object System.IO.Compression.ZipArchive($ms, [System.IO.Compression.ZipArchiveMode]::Create, $true)
    foreach ($key in $Entries.Keys) {
        $entry = $zip.CreateEntry([string]$key, [System.IO.Compression.CompressionLevel]::Optimal)
        $stream = $entry.Open()
        try {
            $val = $Entries[$key]
            if ($val -is [byte[]]) {
                $stream.Write($val, 0, $val.Length)
            } else {
                $bytes = [System.Text.Encoding]::UTF8.GetBytes([string]$val)
                $stream.Write($bytes, 0, $bytes.Length)
            }
        } finally { $stream.Close() }
    }
    $zip.Dispose()
    $ms.Position = 0
    $out = $ms.ToArray()
    $ms.Dispose()
    return $out
}

function New-PromptParleDocxBytes {
    param([Parameter(Mandatory)][string]$Text)
    $bodyParas = New-Object System.Collections.Generic.List[string]
    foreach ($line in ($Text -replace "`r`n", "`n" -replace "`r", "`n" -split "`n")) {
        $esc = [System.Security.SecurityElement]::Escape($line)
        if ($null -eq $esc) { $esc = '' }
        if ($esc -eq '') {
            $bodyParas.Add('<w:p><w:pPr/><w:r><w:t></w:t></w:r></w:p>')
        } else {
            $bodyParas.Add(('<w:p><w:r><w:t xml:space="preserve">{0}</w:t></w:r></w:p>' -f $esc))
        }
    }
    if ($bodyParas.Count -eq 0) {
        $bodyParas.Add('<w:p><w:r><w:t></w:t></w:r></w:p>')
    }
    $documentXml = @"
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:body>
    $($bodyParas -join "`n    ")
    <w:sectPr><w:pgSz w:w="12240" w:h="15840"/><w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440"/></w:sectPr>
  </w:body>
</w:document>
"@
    $contentTypes = @'
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
  <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
  <Default Extension="xml" ContentType="application/xml"/>
  <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
</Types>
'@
    $rels = @'
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
</Relationships>
'@
    $docRels = @'
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"/>
'@
    return (New-PromptParleZipFromEntries -Entries @{
        '[Content_Types].xml' = $contentTypes
        '_rels/.rels'         = $rels
        'word/document.xml'   = $documentXml
        'word/_rels/document.xml.rels' = $docRels
    })
}

function ConvertFrom-PromptParleCsvRows {
    param([string]$Text)
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($line in ($Text -replace "`r`n", "`n" -split "`n")) {
        if ($line -match '^\s*$') { continue }
        # simple CSV split (quoted fields)
        $fields = New-Object System.Collections.Generic.List[string]
        $cur = New-Object System.Text.StringBuilder
        $inQ = $false
        for ($i = 0; $i -lt $line.Length; $i++) {
            $ch = $line[$i]
            if ($ch -eq '"') {
                if ($inQ -and ($i + 1) -lt $line.Length -and $line[$i + 1] -eq '"') {
                    [void]$cur.Append('"'); $i++
                } else { $inQ = -not $inQ }
            } elseif ($ch -eq ',' -and -not $inQ) {
                $fields.Add($cur.ToString()); [void]$cur.Clear()
            } else {
                [void]$cur.Append($ch)
            }
        }
        $fields.Add($cur.ToString())
        $rows.Add(@($fields.ToArray()))
    }
    if ($rows.Count -eq 0) { $rows.Add(@('Value')); $rows.Add(@($Text)) }
    return @($rows.ToArray())
}

function New-PromptParleXlsxBytes {
    param([Parameter(Mandatory)][string]$Text)
    $table = ConvertFrom-PromptParleCsvRows -Text $Text
    $sheetRows = New-Object System.Collections.Generic.List[string]
    $rIdx = 1
    foreach ($row in $table) {
        $cells = New-Object System.Collections.Generic.List[string]
        $cIdx = 0
        foreach ($cell in @($row)) {
            $col = ''
            $n = $cIdx
            do {
                $col = [char]([int][char]'A' + ($n % 26)) + $col
                $n = [Math]::Floor($n / 26) - 1
            } while ($n -ge 0)
            $ref = "$col$rIdx"
            $esc = [System.Security.SecurityElement]::Escape([string]$cell)
            if ($null -eq $esc) { $esc = '' }
            # inline string
            $cells.Add(('<c r="{0}" t="inlineStr"><is><t xml:space="preserve">{1}</t></is></c>' -f $ref, $esc))
            $cIdx++
        }
        $sheetRows.Add(('<row r="{0}">{1}</row>' -f $rIdx, ($cells -join '')))
        $rIdx++
    }
    $sheetXml = @"
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
  <sheetData>
    $($sheetRows -join "`n    ")
  </sheetData>
</worksheet>
"@
    $workbook = @'
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
  <sheets><sheet name="Sheet1" sheetId="1" r:id="rId1"/></sheets>
</workbook>
'@
    $contentTypes = @'
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
  <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
  <Default Extension="xml" ContentType="application/xml"/>
  <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
  <Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
</Types>
'@
    $rels = @'
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
</Relationships>
'@
    $wbRels = @'
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>
</Relationships>
'@
    return (New-PromptParleZipFromEntries -Entries @{
        '[Content_Types].xml' = $contentTypes
        '_rels/.rels' = $rels
        'xl/workbook.xml' = $workbook
        'xl/_rels/workbook.xml.rels' = $wbRels
        'xl/worksheets/sheet1.xml' = $sheetXml
    })
}

function Escape-PromptParlePdfString {
    param([string]$s)
    if ($null -eq $s) { return '' }
    $t = [string]$s
    $t = $t.Replace('\', '\\')
    $t = $t.Replace('(', '\(')
    $t = $t.Replace(')', '\)')
    # drop non-latin1 for simple Helvetica PDF
    $sb = New-Object System.Text.StringBuilder
    foreach ($ch in $t.ToCharArray()) {
        $code = [int]$ch
        if ($code -ge 32 -and $code -le 126) { [void]$sb.Append($ch) }
        elseif ($code -eq 9) { [void]$sb.Append(' ') }
        else { [void]$sb.Append('?') }
    }
    return $sb.ToString()
}

function New-PromptParlePdfBytes {
    <#
    .SYNOPSIS
      Minimal multi-page text PDF (Helvetica). No external deps.
    #>
    param([Parameter(Mandatory)][string]$Text)
    $lines = @($Text -replace "`r`n", "`n" -replace "`r", "`n" -split "`n")
    if ($lines.Count -eq 0) { $lines = @('') }
    $maxLinesPerPage = 60
    $pages = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt $lines.Count; $i += $maxLinesPerPage) {
        $end = [Math]::Min($i + $maxLinesPerPage - 1, $lines.Count - 1)
        $chunk = $lines[$i..$end]
        $y = 770
        $ops = New-Object System.Collections.Generic.List[string]
        [void]$ops.Add('BT')
        [void]$ops.Add('/F1 11 Tf')
        [void]$ops.Add('14 TL')
        [void]$ops.Add("50 $y Td")
        $first = $true
        foreach ($ln in $chunk) {
            $t = Escape-PromptParlePdfString -s ([string]$ln)
            if ($t.Length -gt 95) { $t = $t.Substring(0, 92) + '...' }
            if ($first) {
                [void]$ops.Add("($t) Tj")
                $first = $false
            } else {
                [void]$ops.Add('T*')
                [void]$ops.Add("($t) Tj")
            }
        }
        [void]$ops.Add('ET')
        [void]$pages.Add(($ops -join "`n"))
    }
    if ($pages.Count -eq 0) { [void]$pages.Add("BT`n/F1 11 Tf`n50 770 Td`n() Tj`nET") }

    $objs = New-Object System.Collections.Generic.List[string]
    $pageCount = $pages.Count
    $fontObj = 3
    $firstPageObj = 4
    $pageObjIds = New-Object System.Collections.Generic.List[int]
    $contentObjIds = New-Object System.Collections.Generic.List[int]
    for ($p = 0; $p -lt $pageCount; $p++) {
        [void]$pageObjIds.Add($firstPageObj + $p * 2)
        [void]$contentObjIds.Add($firstPageObj + $p * 2 + 1)
    }
    $kids = ($pageObjIds | ForEach-Object { "$_ 0 R" }) -join ' '
    [void]$objs.Add('1 0 obj<< /Type /Catalog /Pages 2 0 R >>endobj')
    [void]$objs.Add("2 0 obj<< /Type /Pages /Kids [$kids] /Count $pageCount >>endobj")
    [void]$objs.Add('3 0 obj<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>endobj')
    for ($p = 0; $p -lt $pageCount; $p++) {
        $po = $pageObjIds[$p]
        $co = $contentObjIds[$p]
        $stream = $pages[$p]
        $len = [System.Text.Encoding]::ASCII.GetByteCount($stream)
        [void]$objs.Add("$po 0 obj<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents $co 0 R /Resources << /Font << /F1 $fontObj 0 R >> >> >>endobj")
        [void]$objs.Add("$co 0 obj<< /Length $len >>stream`n$stream`nendstream`nendobj")
    }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append("%PDF-1.4`n")
    $offsets = New-Object System.Collections.Generic.List[int]
    [void]$offsets.Add(0)
    foreach ($o in $objs) {
        [void]$offsets.Add($sb.Length)
        [void]$sb.Append($o)
        if (-not $o.EndsWith("`n")) { [void]$sb.Append("`n") }
    }
    $xrefPos = $sb.Length
    $nObj = $offsets.Count
    [void]$sb.Append("xref`n0 $nObj`n")
    [void]$sb.Append("0000000000 65535 f `n")
    for ($i = 1; $i -lt $nObj; $i++) {
        [void]$sb.Append(('{0:D10} 00000 n `n' -f $offsets[$i]))
    }
    [void]$sb.Append("trailer<< /Size $nObj /Root 1 0 R >>`nstartxref`n$xrefPos`n%%EOF`n")
    return [System.Text.Encoding]::ASCII.GetBytes($sb.ToString())
}

function New-PromptParleDocumentBytes {
    param(
        [Parameter(Mandatory)][string]$FileName,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Content
    )
    $ext = [System.IO.Path]::GetExtension($FileName).ToLowerInvariant()
    switch ($ext) {
        '.docx' { return ,(New-PromptParleDocxBytes -Text $Content) }
        '.xlsx' { return ,(New-PromptParleXlsxBytes -Text $Content) }
        '.pdf'  { return ,(New-PromptParlePdfBytes -Text $Content) }
        default {
            # text-like
            $utf8 = New-Object System.Text.UTF8Encoding $true # BOM helps Excel open CSV
            if ($ext -eq '.csv') {
                return ,($utf8.GetBytes($Content))
            }
            return ,([System.Text.Encoding]::UTF8.GetBytes($Content))
        }
    }
}

function Register-PromptParleExport {
    param(
        [Parameter(Mandatory)][string]$FileName,
        [Parameter(Mandatory)][byte[]]$Bytes
    )
    $safe = ConvertTo-PromptParleSafeFileName -Name $FileName
    $token = -join ((1..16) | ForEach-Object { '{0:x2}' -f (Get-Random -Maximum 256) })
    $root = Get-PromptParleExportsRoot
    $dir = Join-Path $root $token
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $path = Join-Path $dir $safe
    [System.IO.File]::WriteAllBytes($path, $Bytes)
    # StrictMode-safe: unset script var throws on bare read
    $idx = $null
    try {
        $idx = Get-Variable -Name PromptParleExportIndex -Scope Script -ValueOnly -ErrorAction Stop
    } catch { $idx = $null }
    if ($null -eq $idx) {
        $idx = @{}
        Set-Variable -Name PromptParleExportIndex -Scope Script -Value $idx
    }
    $idx[$token] = [pscustomobject]@{
        token        = $token
        name         = $safe
        path         = $path
        bytes        = $Bytes.Length
        content_type = (Get-PromptParleExportContentType -Name $safe)
        created      = (Get-Date).ToUniversalTime()
    }
    return [pscustomobject]@{
        token        = $token
        name         = $safe
        bytes        = $Bytes.Length
        content_type = (Get-PromptParleExportContentType -Name $safe)
        url          = ('/api/exports/' + $token)
        download_url = ('/api/exports/' + $token + '?download=1')
    }
}

function Get-PromptParleExport {
    param([Parameter(Mandatory)][string]$Token)
    $t = $Token.Trim() -replace '[^a-fA-F0-9]', ''
    if (-not $t) { return $null }
    $idx = $null
    try {
        $idx = Get-Variable -Name PromptParleExportIndex -Scope Script -ValueOnly -ErrorAction Stop
    } catch { $idx = $null }
    if (($null -ne $idx) -and $idx.ContainsKey($t)) {
        $e = $idx[$t]
        if (Test-Path -LiteralPath $e.path) { return $e }
    }
    # recover from disk if index lost (same process temp)
    $pathDir = Join-Path (Get-PromptParleExportsRoot) $t
    if (Test-Path -LiteralPath $pathDir) {
        $file = Get-ChildItem -LiteralPath $pathDir -File | Select-Object -First 1
        if ($file) {
            return [pscustomobject]@{
                token = $t
                name = $file.Name
                path = $file.FullName
                bytes = $file.Length
                content_type = (Get-PromptParleExportContentType -Name $file.Name)
            }
        }
    }
    return $null
}

function Invoke-PromptParleDeliverResponseBlocks {
    <#
    .SYNOPSIS
      0.17: Parse ```file name=…``` / ```deliver name=…``` blocks, build real docs, download URLs.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$ResponseText
    )
    $text = if ($null -eq $ResponseText) { '' } else { [string]$ResponseText }
    $delivered = New-Object System.Collections.Generic.List[object]
    $errors = New-Object System.Collections.Generic.List[string]
    if (-not $text) {
        return [pscustomobject]@{ text = $text; exports = @(); count = 0; errors = @() }
    }

    $rx = [regex]::new('(?ms)```(?:file|deliver)\s+(?:name|path|filename)\s*[=:]\s*([^\s\r\n`]+)[ \t]*\r?\n(.*?)```')
    $ms = $rx.Matches($text)
    if ($ms.Count -eq 0) {
        # also accept ```file report.docx
        $rx2 = [regex]::new('(?ms)```(?:file|deliver)\s+([A-Za-z0-9._\- ]+\.(?:pdf|docx|xlsx|csv|md|txt|html|htm|json|xml))[ \t]*\r?\n(.*?)```')
        $ms = $rx2.Matches($text)
    }
    if ($ms.Count -eq 0) {
        return [pscustomobject]@{ text = $text; exports = @(); count = 0; errors = @() }
    }

    $allowed = @('.pdf', '.docx', '.xlsx', '.csv', '.md', '.txt', '.html', '.htm', '.json', '.xml')
    foreach ($m in $ms) {
        $name = ConvertTo-PromptParleSafeFileName -Name $m.Groups[1].Value
        $body = $m.Groups[2].Value
        # strip one trailing newline noise
        if ($body.EndsWith("`n")) { $body = $body.Substring(0, $body.Length - 1) }
        if ($body.EndsWith("`r")) { $body = $body.Substring(0, $body.Length - 1) }
        $ext = [System.IO.Path]::GetExtension($name).ToLowerInvariant()
        if ($allowed -notcontains $ext) {
            $errors.Add("Unsupported type for deliverable: $name (use pdf/docx/xlsx/csv/md/txt/html/json)")
            continue
        }
        if ($body.Length -lt 1) {
            $errors.Add("Empty body for $name")
            continue
        }
        if ($body.Length -gt 2MB) {
            $errors.Add("Body too large for $name")
            continue
        }
        try {
            $bytes = New-PromptParleDocumentBytes -FileName $name -Content $body
            $reg = Register-PromptParleExport -FileName $name -Bytes $bytes
            $delivered.Add($reg)
        } catch {
            $errors.Add("$name : $_")
        }
    }

    if ($delivered.Count -eq 0 -and $errors.Count -eq 0) {
        return [pscustomobject]@{ text = $text; exports = @(); count = 0; errors = @() }
    }

    $hdr = New-Object System.Collections.Generic.List[string]
    $hdr.Add('## Downloads ready')
    $hdr.Add('_Client built real files from ```file name=…``` blocks — click to download._')
    $hdr.Add('')
    foreach ($d in $delivered) {
        $kb = [Math]::Max(1, [int][Math]::Ceiling($d.bytes / 1024.0))
        $hdr.Add(("- **[{0}]({1})** · {2} KB · ``{3}``" -f $d.name, $d.download_url, $kb, $d.content_type))
    }
    if ($errors.Count -gt 0) {
        $hdr.Add('')
        $hdr.Add('**Deliver errors:**')
        foreach ($e in $errors) { $hdr.Add("- $e") }
    }
    $hdr.Add('')
    $hdr.Add('---')
    $hdr.Add('')
    $out = ($hdr -join "`n") + $text
    return [pscustomobject]@{
        text    = $out
        exports = @($delivered.ToArray())
        count   = $delivered.Count
        errors  = @($errors.ToArray())
    }
}

function Test-PromptParleSsh {
    param([string]$Target, [int]$Port = 0)
    $r = Invoke-PromptParleSsh -Target $Target -Port $Port -RemoteCommand 'echo promptparle-ssh-ok && uname -a 2>/dev/null || ver' -TimeoutSec 15 -WorkingDirectory ''
    return $r
}

function Invoke-PromptParleTerminal {
    <#
    .SYNOPSIS
      Run a shell command in the local workspace or on the SSH target (desktop terminal panel).
    #>
    param(
        [Parameter(Mandatory)][string]$Command,
        [ValidateSet('local', 'ssh')][string]$Target = 'local',
        [int]$TimeoutSec = 60
    )
    $cmd = if ($null -eq $Command) { '' } else { $Command.Trim() }
    if (-not $cmd) { throw 'Empty command' }
    if ($cmd.Length -gt 8000) { throw 'Command too long' }

    $maxOut = 120000
    if ($Target -eq 'ssh') {
        $ws = Get-PromptParleWorkspace
        if (-not $ws.ssh_target) { throw 'No SSH target. Connect SSH first.' }
        $r = Invoke-PromptParleSsh -RemoteCommand $cmd -TimeoutSec $TimeoutSec
        $text = [string]$r.text
        if ($text.Length -gt $maxOut) { $text = $text.Substring(0, $maxOut) + "`n…[truncated]" }
        $cwd = [string](Get-PromptParleProp $ws 'ssh_cwd' '')
        return [pscustomobject]@{
            ok        = ($r.exit_code -eq 0)
            target    = 'ssh'
            host      = [string]$r.target
            cwd       = $cwd
            command   = $cmd
            exit_code = [int]$r.exit_code
            text      = $text
        }
    }

    $ws = Get-PromptParleWorkspace
    $cwd = [string]$ws.path
    if (-not $cwd) { throw 'No local folder. Browse / attach This PC first.' }
    if (-not (Test-Path -LiteralPath $cwd -PathType Container)) {
        throw "Local folder missing: $cwd"
    }

    $code = 0
    $text = ''
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        if ($script:PromptParleIsWindows) {
            # Run via cmd so PATH tools work; WorkingDirectory = project folder
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = 'cmd.exe'
            $psi.Arguments = '/d /c ' + $cmd
            $psi.WorkingDirectory = $cwd
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            $psi.UseShellExecute = $false
            $psi.CreateNoWindow = $true
            $p = New-Object System.Diagnostics.Process
            $p.StartInfo = $psi
            [void]$p.Start()
            $stdout = $p.StandardOutput.ReadToEnd()
            $stderr = $p.StandardError.ReadToEnd()
            if (-not $p.WaitForExit([Math]::Max(1000, $TimeoutSec * 1000))) {
                try { $p.Kill() } catch { }
                throw "Command timed out after ${TimeoutSec}s"
            }
            $code = $p.ExitCode
            $text = (($stdout, $stderr) | Where-Object { $_ }) -join "`n"
        } else {
            $safeCwd = ($cwd -replace "'", "'\''")
            $safeCmd = ($cmd -replace "'", "'\''")
            $raw = & bash -lc "cd '$safeCwd' && $safeCmd" 2>&1
            $code = $LASTEXITCODE
            if ($null -eq $code) { $code = 0 }
            $text = ($raw | ForEach-Object { "$_" }) -join "`n"
        }
    } catch {
        $code = 1
        $text = "$_"
    } finally {
        $ErrorActionPreference = $prevEap
    }
    if ($text.Length -gt $maxOut) { $text = $text.Substring(0, $maxOut) + "`n…[truncated]" }
    return [pscustomobject]@{
        ok        = ($code -eq 0)
        target    = 'local'
        host      = 'This PC'
        cwd       = $cwd
        command   = $cmd
        exit_code = [int]$code
        text      = $text
    }
}

function Get-PromptParleSlashHelpText {
    return @"
Commands (type in chat instead of a normal message):

  /help                 This help
  /status               Session: provider, dial, tools, workspace, ssh
  /tools [on|off]       Session local tools (default ON — auto before tokens)
  /tool <id> [arg]      Run a local tool now (file_index, deps, git_diff, web_search, …)
  /search <query>       Brief web search (local; injects results into next chat)
  /dial [1-5]           Shrink aggressiveness (always optimizes; 1 fidelity … 5 savings)
  /provider [id]        openai | anthropic | gemini | grok
  /optimize             Toggle optimize-only (no model call — debug shrink)
  /usage                Cloud token savings summary
  /clear                Clear chat (UI) / screen (CLI)
  /quit                 Stop (CLI)

Product (0.14+): continuous chat like a normal assistant, with an optimizer
  between you and the model. Dial is the only shrink knob. Agents retired.

Local-first tools (run before AI tokens when Tools ON):
  connections  chat_memory  secret_scan  code_brief  error_brief  relevant_slice
  file_index  deps  git_diff  tree_pack  web_search
  + workspace / git / ssh / files
  Fidelity-first: keep errors/stacks, prompt-hot code, recent turns; drop noise.
  Every chat gets [CONN] + optional [MEM] from prior turns.
  Web search auto-runs on search intent; or use /search <query>.

Workspace & local directories (paths stay on this PC):
  /workspace            Show attached folder/repo
  /workspace <path>     Attach any local directory (git-aware if .git)
  /workspace ~\src\app  ~ expands to your home folder
  /workspace clear      Detach
  /workspace recent     Recently attached folders
  /workspace ls [sub]   List directory (local)
  /workspace cd <sub>   Attach a subfolder of the current workspace
  /workspace tree [n]   File tree (depth 1–5)
  /workspace cat <file> Load file into chat attachments
  /workspace find <pat> Find files (e.g. *.ps1)
  /workspace pack <pat> Attach up to 12 matching files
  /ws                   Alias for /workspace
  UI: Browse folders button opens a local directory picker

Git / GitHub (uses git + your SSH keys / gh auth on this PC):
  /git status|diff|log|branch
  /github               Tooling + auth status
  /github clone owner/repo [dir]
  /gh                   Alias for /github

SSH (OpenSSH on this PC — private keys never leave the machine):
  /ssh                  Show target / help
  /ssh user@host [cwd]  Set target (+ optional remote working dir) + test
  /ssh cwd <path>       Set/clear remote working directory
  /ssh ls [path]        List remote directory (uses cwd when set)
  /ssh cat <path>       Fetch remote file → attachment
  /ssh run <command>    Run remote command (output → chat)
  /ssh disconnect       Clear target

Agent shortcuts: if the active agent defines commands, type /name
  e.g. security agent:  /audit   /threats
  docs agent:           /summary /risks
  code agent:           /review  /explain

Product surface:
  Free desktop: agents, / commands, workspace, git, ssh, PS module, local UI
  Paid cloud: optimization gateway, team workspaces, shared libraries,
              analytics, savings reports, enterprise, API, CI/CD
"@
}

function Invoke-PromptParleSlashCommand {
    <#
    .SYNOPSIS
      Run a /command against session state. Shared by CLI and local UI.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Line,
        # Optional session overrides from UI (provider/profile/dial already shown in UI)
        [string]$Provider,
        [string]$Profile,
        [int]$Dial = -1,
        [string]$Model,
        [bool]$OptimizeOnly = $false,
        $ToolsEnabled = $null
    )

    $line = $Line.Trim()
    if (-not $line.StartsWith('/')) {
        return [pscustomobject]@{
            handled = $false
            message = $null
            send    = $false
            prompt  = $null
            quit    = $false
            clear   = $false
            session = $null
        }
    }

    $baseState = Get-PromptParleSessionState
    $state = New-PromptParleSessionSnapshot -Base $baseState `
        -Provider $(if ($Provider) { $Provider } else { $null }) `
        -Profile $(if ($Profile) { $Profile } else { $null }) `
        -Dial $Dial `
        -OptimizeOnly $OptimizeOnly `
        -ToolsEnabled $ToolsEnabled
    if ($PSBoundParameters.ContainsKey('Model')) {
        $state = New-PromptParleSessionSnapshot -Base $state -Model $Model
    }

    $parts = $line -split '\s+', 2
    $cmd = $parts[0].ToLowerInvariant()
    $arg = if ($parts.Count -gt 1) { $parts[1].Trim() } else { '' }

    $message = ''
    $send = $false
    $prompt = $null
    $quit = $false
    $clear = $false
    $handled = $true
    $files = @()

    switch -Regex ($cmd) {
        '^/(help|\?)$' {
            $message = Get-PromptParleSlashHelpText
        }
        '^/status$' {
            $ws = Get-PromptParleWorkspace
            $wsLine = if ($ws.path) {
                if ($ws.exists) {
                    $extra = @($ws.kind)
                    if ($ws.branch) { $extra += $ws.branch }
                    "$($ws.path) ($($extra -join ' · '))"
                } else { "$($ws.path) (missing)" }
            } else { '(none — /workspace <path>)' }
            $sshLine = if ($ws.ssh_target) {
                $s = "$($ws.ssh_target):$($ws.ssh_port)"
                $sc = [string](Get-PromptParleProp $ws 'ssh_cwd' '')
                if ($sc) { $s = "$s  cwd $sc" }
                $s
            } else { '(none — /ssh user@host [/path])' }
            $message = @"
Session
  Mode      : chat + optimizer (agents retired 0.14)
  Provider  : $($state.provider)
  Dial      : $($state.dial)/5  (only shrink aggressiveness knob)
  Model     : $(if ($state.model) { $state.model } else { '(default)' })
  Optimize  : $(if ($state.optimize_only) { 'optimize-only (no model call)' } else { 'always (then model)' })
  Tools     : $(if ($state.tools_enabled) { 'ON (local prep before tokens)' } else { 'off' })
  Workspace : $wsLine
  SSH       : $sshLine
"@
        }
        '^/agents$' {
            $message = 'Agents retired in 0.14. Product is: you → optimizer (dial) → model. Use the Dial for shrink aggressiveness.'
        }
        '^/agent$' {
            $message = 'Agents retired in 0.14. No agent switcher — continuous chat + dial. See /status and /help.'
        }
        '^/dial$' {
            if ($arg -match '^([1-5])$') {
                $state.dial = [int]$Matches[1]
                $message = "Dial set to $($state.dial)/5 (shrink aggressiveness; always optimizes)"
            } else {
                $message = "Dial is $($state.dial)/5 (1 max fidelity … 5 max savings). Usage: /dial 3"
            }
        }
        '^/profile$' {
            $message = 'Optimization profiles no longer switch chat persona (0.14). Use Dial for shrink aggressiveness. Chat always uses high-fidelity general optimize path.'
        }
        '^/provider$' {
            $ok = @('openai', 'anthropic', 'gemini', 'grok')
            if ($arg -and $ok -contains $arg.ToLowerInvariant()) {
                $state.provider = $arg.ToLowerInvariant()
                $message = "Provider set to $($state.provider)"
            } elseif ($arg) {
                $message = "Unknown provider. Use: $($ok -join ', ')"
            } else {
                $message = "Provider is $($state.provider). Set with /provider openai"
            }
        }
        '^/optimize$' {
            $state.optimize_only = -not [bool]$state.optimize_only
            $message = if ($state.optimize_only) { 'Optimize-only ON (no AI spend until toggled off)' } else { 'Optimize-only OFF (full AI calls)' }
        }
        '^/tools$' {
            if ($arg -match '^(on|1|true|enable)$') {
                $state.tools_enabled = $true
                $message = 'Tools ON — local prep (connections, secret scan, code brief, web search, git diff, …) runs automatically before AI tokens. Dial still applies.'
            } elseif ($arg -match '^(off|0|false|disable)$') {
                $state.tools_enabled = $false
                $message = 'Tools OFF — connections brief still injected; other local packs skipped. Dial/gateway compression still applies.'
            } else {
                $onOff = if ($state.tools_enabled) { 'ON' } else { 'OFF' }
                $lines = @(
                    "Session Tools: $onOff (sidebar checkbox next to Dial; default ON)",
                    'When ON, useful local tools run automatically before tokens — you do not force each one.',
                    'Every chat includes a brief [CONN] Project connections map (PC / Git / SSH).',
                    'Toggle: /tools on  ·  /tools off',
                    '',
                    'Catalog (0 AI tokens on this PC for local tools):'
                )
                foreach ($t in @(Get-PromptParleToolCatalog)) {
                    $auto = if ($t.auto) { 'auto' } else { 'manual' }
                    $lines += ("  {0,-12} [{1}] {2}" -f $t.id, $auto, $t.description)
                }
                $lines += 'Manual run: /tool relevant_slice <q> · /tool error_brief · /tool web_search <q> · /tool connections'
                $message = $lines -join "`n"
            }
        }
        '^/search$' {
            if (-not $arg) {
                $message = 'Usage: /search <query>   e.g. /search PowerShell 7 release notes'
            } else {
                try {
                    $web = Invoke-PromptParleWebSearchLocal -Query $arg -MaxResults 4 -MaxChars 2400
                    $note = if ($web.notes) { ($web.notes -join '; ') } else { '' }
                    $message = "Web search (local, optimized)`n$note`n`n$($web.text)"
                    if ($web.text) {
                        $files = @(@{ name = 'web_search.txt'; content = [string]$web.text })
                    }
                } catch {
                    $message = "Search error: $_"
                }
            }
        }
        '^/tool$' {
            if (-not $arg) {
                $message = 'Usage: /tool <id> [arg]   e.g. /tool file_index · /tool web_search PowerShell · /tool connections'
            } else {
                $tParts = $arg -split '\s+', 2
                $tid = $tParts[0]
                $targ = if ($tParts.Count -gt 1) { $tParts[1] } else { '' }
                try {
                    # For code_brief/secret_scan without text, hint to attach files
                    $run = Invoke-PromptParleLocalTool -ToolId $tid -Text '' -Arg $targ
                    $note = if ($run.notes) { ($run.notes -join '; ') } else { '' }
                    $message = "Tool $($run.tool) (local)`n$note`n`n$($run.text)"
                    if ($run.text -and $tid -match '^(file_index|deps|git_diff|tree_pack|git|workspace|connections|web_search|web|search|error_brief|relevant_slice|slice|chat_memory|memory)$') {
                        # Surface as attachable context via files array when supported
                        $files = @(@{ name = "$tid.txt"; content = [string]$run.text })
                    }
                } catch {
                    $message = "Tool error: $_"
                }
            }
        }
        '^/usage$' {
            try {
                $u = Get-PromptParleUsage
                $message = "Usage (cloud): requests=$($u.RequestCount) · tokens saved=$($u.TokensSaved) ($($u.ReductionPercent)%)"
            } catch {
                $message = "Usage error: $_"
            }
        }
        '^/clear$' {
            $clear = $true
            $message = 'Chat cleared.'
        }
        '^/(workspace|ws)$' {
            try {
                if (-not $arg) {
                    $ws = Get-PromptParleWorkspace
                    if (-not $ws.path) {
                        $message = @"
No local folder attached.

  Browse folders in the UI, or:
  /workspace C:\path\to\project     any local directory
  /workspace ~\Documents\code       ~ = home
  /workspace recent                 re-open recent folders
  /github clone owner/repo          clone then attach
  /workspace ls · tree · cat · pack

Paths and credentials stay on this PC.
"@
                    } else {
                        $message = Get-PromptParleGitStatusText
                        if (-not $ws.is_git) {
                            $message = "Workspace: $($ws.path) ($($ws.kind))`nNot a git repo. /github clone or attach a cloned folder."
                        }
                    }
                } elseif ($arg -match '^(clear|none|off|detach)$') {
                    Clear-PromptParleWorkspace
                    $state = New-PromptParleSessionSnapshot -Base $state -WorkspacePath '' -WorkspaceKind 'none'
                    $message = 'Workspace detached.'
                } elseif ($arg -match '^(status)$') {
                    $message = Get-PromptParleGitStatusText
                } elseif ($arg -match '^(recent)$') {
                    $ws = Get-PromptParleWorkspace
                    if (-not $ws.recent -or @($ws.recent).Count -eq 0) {
                        $message = "No recent folders yet.`nAttach with /workspace C:\path or use Browse folders in the UI."
                    } else {
                        $lines = @('Recent local folders (re-attach: /workspace <path>):')
                        $i = 1
                        foreach ($r in @($ws.recent)) {
                            $kind = if (Test-PromptParlePathIsGitRepo -Path $r) { 'git' } else { 'local' }
                            $lines += ("  {0}. [{1}] {2}" -f $i, $kind, $r)
                            $i++
                        }
                        $message = $lines -join "`n"
                    }
                } elseif ($arg -match '^(ls|dir)(?:\s+(.+))?$') {
                    $sub = if ($Matches[2]) { $Matches[2].Trim().Trim('"').Trim("'") } else { '' }
                    $message = Get-PromptParleDirListingText -RelativePath $sub
                } elseif ($arg -match '^(cd)\s+(.+)$') {
                    $sub = $Matches[2].Trim().Trim('"').Trim("'")
                    $ws = Get-PromptParleWorkspace
                    if (-not $ws.exists) { throw 'No workspace yet. Attach a parent folder first, or /workspace C:\full\path' }
                    $full = Resolve-PromptParleWorkspacePath -RelativePath $sub
                    if (-not (Test-Path -LiteralPath $full -PathType Container)) {
                        throw "Not a directory: $sub"
                    }
                    $wsSet = Set-PromptParleWorkspace -Path $full
                    $state = New-PromptParleSessionSnapshot -Base $state -WorkspacePath $wsSet.path -WorkspaceKind $wsSet.kind -WorkspaceRecent $wsSet.recent
                    $message = "Workspace now: $($wsSet.path) ($($wsSet.kind))"
                } elseif ($arg -match '^(tree)(?:\s+(\d+))?$') {
                    $depth = 2
                    if ($Matches[2]) { $depth = [int]$Matches[2] }
                    $message = Get-PromptParleWorkspaceTree -Depth $depth
                } elseif ($arg -match '^(cat|read|open)\s+(.+)$') {
                    $rel = $Matches[2].Trim().Trim('"').Trim("'")
                    $file = Get-PromptParleWorkspaceFile -RelativePath $rel
                    $files = @(@{ name = $file.name; text = $file.text })
                    # also use relative name when under workspace
                    try {
                        $ws = Get-PromptParleWorkspace
                        $wsP = ConvertTo-PromptParleSingleString $ws.path
                        $fp = ConvertTo-PromptParleSingleString $file.path
                        if ($wsP -and (Test-PromptParlePathStartsWith -Path $fp -Prefix $wsP)) {
                            $relName = $fp.Substring($wsP.Length).TrimStart([char[]]@([char]0x5C, [char]0x2F)).Replace([char]0x5C, [char]0x2F)
                            $files = @(@{ name = $relName; text = $file.text })
                        }
                    } catch { }
                    $message = "Attached $($files[0].name) ($($file.chars) chars)$(if ($file.truncated) { ' truncated' } else { '' }). Send a question or /review."
                } elseif ($arg -match '^(find|search)\s+(.+)$') {
                    $pat = $Matches[2].Trim().Trim('"').Trim("'")
                    $message = Find-PromptParleWorkspaceFiles -Pattern $pat
                } elseif ($arg -match '^(pack|attach)\s+(.+)$') {
                    $pat = $Matches[2].Trim().Trim('"').Trim("'")
                    $packed = @(Get-PromptParleWorkspacePack -Pattern $pat)
                    if ($packed.Count -eq 0) {
                        $message = "No readable text files matched '$pat'."
                    } else {
                        $files = @($packed | ForEach-Object { @{ name = $_.name; text = $_.text } })
                        $message = "Attached $($packed.Count) file(s) matching '$pat'. Ask a question or /review."
                    }
                } else {
                    # Treat arg as path to attach (any local directory)
                    $pathArg = $arg.Trim().Trim('"').Trim("'")
                    $wsSet = Set-PromptParleWorkspace -Path $pathArg
                    $state = New-PromptParleSessionSnapshot -Base $state -WorkspacePath $wsSet.path -WorkspaceKind $wsSet.kind -WorkspaceRecent $wsSet.recent
                    $extra = ''
                    if ($wsSet.is_git) {
                        try { $extra = "`n" + (Get-PromptParleGitStatusText) } catch { }
                    } else {
                        try { $extra = "`n" + (Get-PromptParleDirListingText) } catch { }
                    }
                    $message = "Local folder attached: $($wsSet.path) ($($wsSet.kind))$extra"
                }
            } catch {
                $message = "Workspace error: $_"
            }
        }
        '^/git$' {
            try {
                if (-not $arg -or $arg -match '^(status|st)$') {
                    $message = Get-PromptParleGitStatusText
                } elseif ($arg -match '^(diff)(?:\s+(.*))?$') {
                    $diffArgs = @('diff', '--stat')
                    if ($Matches[2]) { $diffArgs = @('diff'); $diffArgs += ($Matches[2] -split '\s+') }
                    $r = Invoke-PromptParleGit -GitArgs $diffArgs
                    $message = $r.text
                    if (-not $message) { $message = '(empty diff)' }
                } elseif ($arg -match '^(log)(?:\s+(\d+))?$') {
                    $n = 12
                    if ($Matches[2]) { $n = [int]$Matches[2] }
                    $r = Invoke-PromptParleGit -GitArgs @('log', "-$n", '--oneline', '--decorate')
                    $message = $r.text
                } elseif ($arg -match '^(branch|br)$') {
                    $r = Invoke-PromptParleGit -GitArgs @('branch', '-vv')
                    $message = $r.text
                } elseif ($arg -match '^(remote)$') {
                    $r = Invoke-PromptParleGit -GitArgs @('remote', '-v')
                    $message = $r.text
                } else {
                    $message = "Usage: /git status | diff | log [n] | branch | remote"
                }
            } catch {
                $message = "Git error: $_"
            }
        }
        '^/(github|gh)$' {
            try {
                if (-not $arg -or $arg -match '^(status)$') {
                    $message = Get-PromptParleGitHubStatusText
                } elseif ($arg -match '^(clone)\s+(\S+)(?:\s+(.+))?$') {
                    $repo = $Matches[2]
                    $dest = if ($Matches[3]) { $Matches[3].Trim().Trim('"').Trim("'") } else { $null }
                    $cloned = Invoke-PromptParleGitClone -UrlOrRepo $repo -Destination $dest
                    $state = New-PromptParleSessionSnapshot -Base $state -WorkspacePath $cloned.path -WorkspaceKind $cloned.kind
                    $message = "Cloned $repo → $($cloned.path)`nAttached as workspace ($($cloned.kind)).`n$($cloned.log)"
                } elseif ($arg -match '^(pr|prs|pulls)$') {
                    if (-not (Test-PromptParleCommandAvailable -Name 'gh')) {
                        $message = 'GitHub CLI (gh) not installed. Install from https://cli.github.com/ or use /git.'
                    } else {
                        $ws = Get-PromptParleWorkspace
                        if (-not $ws.exists) { throw 'Attach a repo workspace first.' }
                        $prev = $ErrorActionPreference
                        $ErrorActionPreference = 'Continue'
                        Push-Location $ws.path
                        try {
                            $out = & gh pr list --limit 15 2>&1 | Out-String
                        } finally {
                            Pop-Location
                            $ErrorActionPreference = $prev
                        }
                        $message = if ($out.Trim()) { $out.Trim() } else { '(no open PRs or gh not authenticated)' }
                    }
                } else {
                    $message = @"
Usage:
  /github                 status (git/gh + workspace)
  /github clone owner/repo [dir]
  /github prs             list PRs (requires gh)

Uses your local git remotes / SSH keys / gh auth — PromptParle never stores them.
"@
                }
            } catch {
                $message = "GitHub error: $_"
            }
        }
        '^/ssh$' {
            try {
                if (-not $arg) {
                    $ws = Get-PromptParleWorkspace
                    if ($ws.ssh_target) {
                        $cwdShow = [string](Get-PromptParleProp $ws 'ssh_cwd' '')
                        if (-not $cwdShow) { $cwdShow = '(login home — set with /ssh cwd /path)' }
                        $message = @"
SSH target: $($ws.ssh_target) port $($ws.ssh_port)
Working dir: $cwdShow

  /ssh ls [path]       list remote dir (relative to cwd when set)
  /ssh cat <path>      fetch file → attachment
  /ssh run <command>   run remote command (in cwd when set)
  /ssh cwd <path>      set remote working directory (empty to clear)
  /ssh disconnect      clear target
  /ssh user@other [cwd]  switch host

Keys: ssh-agent / ~/.ssh — never uploaded to PromptParle.
"@
                    } else {
                        $message = @"
No SSH target.

  /ssh user@host [cwd]     set target + optional remote working dir + test
  /ssh user@host:2222      custom port
  /ssh cwd /var/www        set working directory (after connect)
  /ssh ls /var/www         list remote
  /ssh cat /etc/hosts      pull file into chat
  /ssh run uptime          run command

Requires OpenSSH client on this PC. Private keys stay local.
"@
                    }
                } elseif ($arg -match '^(disconnect|clear|off|none)$') {
                    Clear-PromptParleSshTarget
                    $state = New-PromptParleSessionSnapshot -Base $state -SshTarget '' -SshPort 22 -SshCwd ''
                    $message = 'SSH target cleared.'
                } elseif ($arg -match '^(cwd|cd|dir)(?:\s+(.*))?$') {
                    $ws = Get-PromptParleWorkspace
                    if (-not $ws.ssh_target) { throw 'No SSH target. /ssh user@host first.' }
                    $cwdIn = if ($null -ne $Matches[2]) { $Matches[2].Trim().Trim('"').Trim("'") } else { '' }
                    if ($cwdIn -match '^(clear|none|off)$') { $cwdIn = '' }
                    if ($cwdIn -and $cwdIn -match '[;|&`$]') { throw 'Invalid remote path' }
                    # Validates remote dir exists; stores resolved absolute path
                    $set = Set-PromptParleSshTarget -Target $ws.ssh_target -Port ([int]$ws.ssh_port) -WorkingDirectory $cwdIn -ValidateCwd $true
                    $state = New-PromptParleSessionSnapshot -Base $state -SshTarget $set.target -SshPort $set.port -SshCwd $set.cwd
                    if ($set.cwd) {
                        $message = "SSH working directory OK: $($set.cwd) (on $($set.target))"
                    } else {
                        $message = "SSH working directory cleared (login home on $($set.target))."
                    }
                } elseif ($arg -match '^(ls|list)(?:\s+(.+))?$') {
                    $rpath = if ($Matches[2]) { $Matches[2].Trim() } else { '.' }
                    # sanitize remote path slightly
                    if ($rpath -match '[;|&`$]') { throw 'Invalid remote path' }
                    $r = Invoke-PromptParleSsh -RemoteCommand "ls -la -- $rpath"
                    $cwdNote = ''
                    $wsNow = Get-PromptParleWorkspace
                    $sc = [string](Get-PromptParleProp $wsNow 'ssh_cwd' '')
                    if ($sc) { $cwdNote = " cwd $sc" }
                    $message = "ssh $($r.target):$($r.port)$cwdNote ls $rpath (exit $($r.exit_code))`n$($r.text)"
                } elseif ($arg -match '^(cat|read|get)\s+(.+)$') {
                    $rpath = $Matches[2].Trim().Trim('"').Trim("'")
                    if ($rpath -match '[;|&`$]') { throw 'Invalid remote path' }
                    $r = Invoke-PromptParleSsh -RemoteCommand "cat -- $rpath"
                    if ($r.exit_code -ne 0) {
                        $message = "ssh cat failed (exit $($r.exit_code)):`n$($r.text)"
                    } else {
                        $name = Split-Path -Leaf $rpath
                        if (-not $name) { $name = 'remote.txt' }
                        $text = $r.text
                        if ($text.Length -gt $script:PromptParleMaxWorkspaceFileChars) {
                            $text = $text.Substring(0, $script:PromptParleMaxWorkspaceFileChars) + "`n…[truncated]"
                        }
                        $files = @(@{ name = "ssh:$($r.target):$name"; text = $text })
                        $message = "Attached remote file $name from $($r.target) ($($text.Length) chars)."
                    }
                } elseif ($arg -match '^(run|exec)\s+(.+)$') {
                    $remoteCmd = $Matches[2].Trim()
                    $r = Invoke-PromptParleSsh -RemoteCommand $remoteCmd
                    $name = 'ssh-output.txt'
                    $body = "### SSH $($r.target)`n### `$ $remoteCmd`n### exit $($r.exit_code)`n`n$($r.text)"
                    $files = @(@{ name = $name; text = $body })
                    $message = "Remote command finished (exit $($r.exit_code)). Output attached as $name."
                } elseif ($arg -match '^(test|ping)$') {
                    $r = Test-PromptParleSsh
                    $message = "SSH test $($r.target):$($r.port) exit $($r.exit_code)`n$($r.text)"
                } else {
                    # user@host[:port] [optional remote working directory]
                    $rest = $arg.Trim()
                    $targetArg = $rest
                    $cwdArg = ''
                    if ($rest -match '^(\S+)(?:\s+(.+))?$') {
                        $targetArg = $Matches[1]
                        if ($Matches[2]) { $cwdArg = $Matches[2].Trim().Trim('"').Trim("'") }
                    }
                    $port = 22
                    if ($targetArg -match '^(.+):(\d+)$') {
                        $targetArg = $Matches[1]
                        $port = [int]$Matches[2]
                    }
                    if ($cwdArg -and $cwdArg -match '[;|&`$]') { throw 'Invalid remote working directory' }
                    # Save host first (cwd validated when non-empty)
                    $set = Set-PromptParleSshTarget -Target $targetArg -Port $port -WorkingDirectory $cwdArg -ValidateCwd ([bool]$cwdArg)
                    $state = New-PromptParleSessionSnapshot -Base $state -SshTarget $set.target -SshPort $set.port -SshCwd $set.cwd
                    $r = Test-PromptParleSsh -Target $set.target -Port $set.port
                    $cwdMsg = if ($set.cwd) { "`nWorking dir: $($set.cwd)" } else { '' }
                    if ($r.exit_code -eq 0) {
                        $message = "SSH target set: $($set.target):$($set.port)$cwdMsg`nOK`n$($r.text)"
                    } else {
                        $message = @"
SSH target saved: $($set.target):$($set.port)$cwdMsg
Connectivity test failed (exit $($r.exit_code)):
$($r.text)

Check: ssh-agent loaded? key in ~/.ssh? host allows key auth?
  ssh -p $($set.port) $($set.target)
"@
                    }
                }
            } catch {
                $message = "SSH error: $_"
            }
        }
        '^/(quit|exit|q)$' {
            $quit = $true
            $message = 'Bye.'
        }
        default {
            # Agent-defined command: /audit etc.
            $short = $cmd.TrimStart('/')
            $ag = Get-PromptParleAgent -Name $state.active_agent
            $resolved = $null
            if ($ag -and $ag.commands -and $ag.commands.ContainsKey($short)) {
                $resolved = [string]$ag.commands[$short]
            }
            if ($resolved) {
                $send = $true
                $prompt = if ($arg) { "$resolved`n`n$arg" } else { $resolved }
                $message = "Running agent command /$short"
            } else {
                $handled = $true
                $message = "Unknown command: $cmd  (try /help)"
            }
        }
    }

    # Re-read workspace/ssh from disk if commands updated via helpers
    $fresh = Get-PromptParleSessionState
    $state = New-PromptParleSessionSnapshot -Base $state `
        -WorkspacePath ([string](Get-PromptParleProp $fresh 'workspace_path' '')) `
        -WorkspaceKind ([string](Get-PromptParleProp $fresh 'workspace_kind' 'none')) `
        -SshTarget ([string](Get-PromptParleProp $fresh 'ssh_target' '')) `
        -SshPort ([int](Get-PromptParleProp $fresh 'ssh_port' 22))

    Save-PromptParleSessionState -State $state
    $agentOut = Get-PromptParleAgent -Name $state.active_agent
    $wsOut = Get-PromptParleWorkspace
    $sessionOut = [ordered]@{
        active_agent    = $state.active_agent
        provider        = $state.provider
        profile         = $state.profile
        dial            = [int]$state.dial
        model           = $state.model
        optimize_only   = [bool]$state.optimize_only
        tools_enabled   = if ($null -ne (Get-PromptParleProp $state 'tools_enabled' $null)) { [bool]$state.tools_enabled } else { $true }
        workspace_path   = [string]$wsOut.path
        workspace_kind   = [string]$wsOut.kind
        workspace_branch = $wsOut.branch
        workspace_remote = $wsOut.remote
        workspace_recent = @($wsOut.recent)
        ssh_target       = [string]$wsOut.ssh_target
        ssh_port         = [int]$wsOut.ssh_port
        agent_name      = if ($agentOut) { $agentOut.name } else { $state.active_agent }
        agent_system    = if ($agentOut) { $agentOut.system } else { '' }
        agent_commands  = @()
    }
    if ($agentOut -and $agentOut.commands) {
        foreach ($k in $agentOut.commands.Keys) {
            $sessionOut.agent_commands += [string]$k
        }
    }

    return [pscustomobject]@{
        handled = $handled
        message = $message
        send    = $send
        prompt  = $prompt
        quit    = $quit
        clear   = $clear
        files   = @($files)
        session = [pscustomobject]$sessionOut
    }
}

function Show-PromptParleSessionHelp {
    Write-Host ''
    Write-Host (Get-PromptParleSlashHelpText) -ForegroundColor Cyan
    Write-Host ''
}
#endregion

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

    .PARAMETER CompressionLevel
      Dial 1-5: 1 max fidelity, 3 balanced (default), 5 max savings.

    .PARAMETER Context
      Extra material (code, logs, configs) as ONE string.
      Must be [string] - not object[] - because PowerShell unrolls a string
      into char[] when bound to object[], which freezes/bloats local chat.

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

        [Parameter()]
        [Alias('Dial', 'Fidelity')]
        [ValidateRange(1, 5)]
        [int]$CompressionLevel = 3,

        # Named blob - always a single string (local UI path)
        [Parameter()]
        [AllowEmptyString()]
        [string]$Context,

        # 0.14.12+: native role:system (product brief) — not baked into user prompt
        [Parameter()]
        [AllowEmptyString()]
        [string]$System,

        # Per-turn runtime note (tools/prep) — sent with system, not in usage Before
        [Parameter()]
        [AllowEmptyString()]
        [Alias('RuntimeNote')]
        [string]$Runtime,

        # Pipeline lines / FileInfo (Get-Content, Get-Item, etc.)
        [Parameter(ValueFromPipeline)]
        [object]$InputObject,

        [Parameter()]
        [Alias('ContextFile')]
        [string]$Path,

        # Vision images: array of @{ media_type='image/png'; data_base64='...' ; name='x.png' }
        [Parameter()]
        [object]$Images,

        [switch]$OptimizeOnly,

        [switch]$Quiet,

        [switch]$Raw
    )

    begin {
        $contextChunks = New-Object System.Collections.Generic.List[string]
    }

    process {
        if ($null -eq $InputObject) { return }
        if ($InputObject -is [System.IO.FileInfo]) {
            $leaf = $InputObject.Name
            $raw = Get-Content -LiteralPath $InputObject.FullName -Raw -ErrorAction Stop
            $contextChunks.Add("===== FILE: $leaf =====`n$raw")
        } elseif ($InputObject -is [string]) {
            $contextChunks.Add($InputObject)
        } else {
            $contextChunks.Add([string]$InputObject)
        }
    }

    end {
        # Named -Context is one blob (do not treat as char array)
        if ($PSBoundParameters.ContainsKey('Context') -and -not [string]::IsNullOrEmpty($Context)) {
            $contextChunks.Add($Context)
        }

        if ($Path) {
            if (-not (Test-Path -LiteralPath $Path)) {
                throw "Context file not found: $Path"
            }
            $leaf = Split-Path -Leaf $Path
            $raw = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
            $contextChunks.Add("===== FILE: $leaf =====`n$raw")
        }

        $contextText = $null
        if ($contextChunks.Count -gt 0) {
            $contextText = ($contextChunks -join "`n")
        }

        # Always plain CLR types — avoid char[] / PSObject surprises that 400 Zod
        $promptText = if ($null -eq $Prompt) { '' } else { [string]$Prompt }
        if ([string]::IsNullOrWhiteSpace($promptText)) {
            throw 'Prompt is empty after local prep.'
        }
        $body = [ordered]@{
            provider              = [string]$Provider
            prompt                = $promptText
            optimization_profile  = [string]$Profile
            compression_level     = [int]$CompressionLevel
            return_metadata       = $true
        }
        if ($Model) { $body.model = [string]$Model }
        if ($contextText) { $body.context = [string]$contextText }
        # Native system role — portal adapters put this in role:system (+ cache when supported)
        if ($PSBoundParameters.ContainsKey('System') -and -not [string]::IsNullOrWhiteSpace($System)) {
            $body.system = [string]$System
        }
        if ($PSBoundParameters.ContainsKey('Runtime') -and -not [string]::IsNullOrWhiteSpace($Runtime)) {
            $body.runtime = [string]$Runtime
        }
        if ($OptimizeOnly) { $body.optimize_only = $true }

        $imageList = @(ConvertTo-PromptParleImageList -Images $Images)
        if ($imageList.Count -gt 0 -and -not $OptimizeOnly) {
            # Explicit Object[] of hashtables — never a single nested array element
            $body.images = [object[]]$imageList
        }

        $result = Invoke-PromptParleApi -Method POST -Path '/api/v1/prompt' -Body $body

        if ($Raw) {
            return $result
        }

        $meta = Get-PromptParleProp $result 'metadata'
        if (-not $Quiet) {
            Write-PromptParleMetadata -Metadata $meta
        }

        if ($OptimizeOnly) {
            if (-not $Quiet) {
                Write-Host 'Optimized prompt:' -ForegroundColor Cyan
            }
            return [pscustomobject]@{
                OptimizedPrompt = Get-PromptParleProp $result 'optimized_prompt'
                Metadata        = $meta
                Provider        = $Provider
                Profile         = $Profile
                OptimizeOnly    = $true
            }
        }

        if (-not $Quiet) {
            Write-Host 'AI Response:' -ForegroundColor Cyan
        }

        $responseText = [string](Get-PromptParleProp $result 'response' '')
        # Also emit response text for simple capture: $out = Invoke-PromptParle ... ; $out.Response
        [pscustomobject]@{
            Response = $responseText
            Metadata = $meta
            Provider = if (Get-PromptParleProp $meta 'provider') { Get-PromptParleProp $meta 'provider' } else { $Provider }
            Model    = if (Get-PromptParleProp $meta 'model') { Get-PromptParleProp $meta 'model' } else { $Model }
            Profile  = if (Get-PromptParleProp $meta 'optimization_profile') { Get-PromptParleProp $meta 'optimization_profile' } else { $Profile }
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

        [Parameter()]
        [string]$Context,

        [Parameter(ValueFromPipeline)]
        [object]$InputObject,

        [string]$Path,

        [switch]$OptimizeOnly,
        [switch]$Quiet,
        [switch]$Raw
    )

    begin {
        $pipe = New-Object System.Collections.Generic.List[object]
    }

    process {
        if ($null -ne $InputObject) { [void]$pipe.Add($InputObject) }
    }

    end {
        $params = @{
            Prompt       = $Prompt
            Provider     = $Provider
            Profile      = 'security-review'
            OptimizeOnly = $OptimizeOnly
            Quiet        = $Quiet
            Raw          = $Raw
        }
        if ($Model) { $params.Model = $Model }
        if ($Path) { $params.Path = $Path }
        if (-not [string]::IsNullOrEmpty($Context)) { $params.Context = $Context }

        if ($pipe.Count -gt 0) {
            $pipe | Invoke-PromptParle @params
        } else {
            Invoke-PromptParle @params
        }
    }
}

function Get-PromptParleModuleRoot {
    if ($PSScriptRoot) { return $PSScriptRoot }
    $mod = Get-Module PromptParle
    if ($mod -and $mod.ModuleBase) { return $mod.ModuleBase }
    return $null
}

function Get-PromptParleUserModulesDir {
    if ($PSVersionTable.PSEdition -eq 'Core') {
        $dir = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'PowerShell\Modules'
    } else {
        $dir = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'WindowsPowerShell\Modules'
    }
    $docs = [Environment]::GetFolderPath('MyDocuments')
    if (-not $docs -or -not (Test-Path -LiteralPath $docs)) {
        $dir = Join-Path $HOME '.local/share/powershell/Modules'
    }
    return $dir
}

function Read-PromptParleVersionFromManifest {
    param([string]$ManifestPath)
    if (-not $ManifestPath -or -not (Test-Path -LiteralPath $ManifestPath)) {
        return $null
    }
    try {
        if (Get-Command Import-PowerShellDataFile -ErrorAction SilentlyContinue) {
            $m = Import-PowerShellDataFile -Path $ManifestPath
            if ($m.ModuleVersion) { return [string]$m.ModuleVersion }
        }
    } catch { }
    try {
        $raw = Get-Content -LiteralPath $ManifestPath -Raw -ErrorAction Stop
        if ($raw -match "ModuleVersion\s*=\s*'([^']+)'") { return $Matches[1] }
    } catch { }
    return $null
}

function Get-PromptParleClientVersion {
    <#
    .SYNOPSIS
      Installed / loaded PromptParle client version.
    #>
    [CmdletBinding()]
    param()
    $loaded = Get-Module PromptParle -ErrorAction SilentlyContinue
    if ($loaded -and $loaded.Version) {
        return [string]$loaded.Version
    }
    $root = Get-PromptParleModuleRoot
    if ($root) {
        $v = Read-PromptParleVersionFromManifest -ManifestPath (Join-Path $root 'PromptParle.psd1')
        if ($v) { return $v }
    }
    $dest = Join-Path (Get-PromptParleUserModulesDir) 'PromptParle\PromptParle.psd1'
    $v2 = Read-PromptParleVersionFromManifest -ManifestPath $dest
    if ($v2) { return $v2 }
    return '0.0.0'
}

function ConvertTo-PromptParleWebText {
    <# Decode Invoke-WebRequest Content that may be [string] or [byte[]] (PS 5.1 + octet-stream). #>
    param($Content)
    if ($null -eq $Content) { return '' }
    if ($Content -is [byte[]]) {
        try { return [System.Text.Encoding]::UTF8.GetString($Content) } catch {
            try { return [System.Text.Encoding]::ASCII.GetString($Content) } catch { return '' }
        }
    }
    # Char[] / other
    if ($Content -is [System.Array] -and -not ($Content -is [string])) {
        try {
            if ($Content.Length -gt 0 -and $Content[0] -is [byte]) {
                return [System.Text.Encoding]::UTF8.GetString([byte[]]$Content)
            }
        } catch { }
    }
    $s = [string]$Content
    # Classic failure: [string][byte[]] => "System.Byte[]"
    if ($s -eq 'System.Byte[]') { return '' }
    return $s
}

function Get-PromptParleVersionFromRemoteText {
    param([string]$Raw)
    if (-not $Raw) { return $null }
    $t = $Raw.Trim()
    # Plain version.txt / PromptParle.version
    if ($t -match '^(?i)v?(\d+\.\d+(?:\.\d+){0,3})\s*$') {
        return [string]$Matches[1]
    }
    if ($t -match "(?im)ModuleVersion\s*=\s*'([^']+)'") {
        return [string]$Matches[1]
    }
    if ($t -match '(?im)ModuleVersion\s*=\s*"([^"]+)"') {
        return [string]$Matches[1]
    }
    # JSON { "version": "0.14.9" }
    if ($t -match '(?i)"version"\s*:\s*"([^"]+)"') {
        return [string]$Matches[1]
    }
    return $null
}

function Get-PromptParleRemoteClientVersion {
    <#
    .SYNOPSIS
      Latest client version from portal (deployed) then GitHub main.
      Robust on Windows PowerShell 5.1: byte[] body decode + plain version.txt.
    #>
    [CmdletBinding()]
    param()
    # TLS 1.2 required on older Windows PowerShell for promptparle.com
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    } catch { }

    # Unix-seconds cache bust (PS 5.1 safe — avoid ToUnixTimeSeconds)
    $bust = [int]((Get-Date).ToUniversalTime() - [datetime]'1970-01-01').TotalSeconds
    # Plain version first (text/plain — never byte[]-mangled). Portal is ship authority.
    $urls = @(
        "https://promptparle.com/version.txt?v=$bust",
        "https://promptparle.com/PromptParle.version?v=$bust",
        "https://promptparle.com/PromptParle.psd1?v=$bust",
        "https://raw.githubusercontent.com/exiled4disco/promptparle/main/powershell/PromptParle/PromptParle.psd1?v=$bust"
    )
    $lastErr = $null
    $found = New-Object System.Collections.Generic.List[string]
    foreach ($url in $urls) {
        try {
            $resp = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 20 -Headers @{
                'Cache-Control' = 'no-cache'
                'Pragma'        = 'no-cache'
                'Accept'        = 'text/plain, application/octet-stream, */*'
            }
            $raw = ConvertTo-PromptParleWebText -Content $resp.Content
            if (-not $raw) {
                # Fallback: some hosts put text in RawContentStream
                try {
                    if ($resp.RawContentStream) {
                        $sr = New-Object System.IO.StreamReader($resp.RawContentStream, [System.Text.Encoding]::UTF8, $true)
                        $raw = $sr.ReadToEnd()
                    }
                } catch { }
            }
            $ver = Get-PromptParleVersionFromRemoteText -Raw $raw
            if ($ver) {
                [void]$found.Add($ver)
                # Prefer first hit that is a portal plain version or any parseable
                # Continue briefly to allow max() if multiple differ
            } else {
                $lastErr = "No version in response from $url (len=$(if ($raw) { $raw.Length } else { 0 }))"
            }
        } catch {
            $lastErr = "$_"
            continue
        }
    }
    if ($found.Count -eq 0) {
        if ($lastErr) {
            Write-Verbose "Remote version check failed: $lastErr"
        }
        return $null
    }
    # Highest version among sources (portal plain + psd1 + github)
    $best = $found[0]
    foreach ($v in $found) {
        if ((Compare-PromptParleVersion -A $best -B $v) -lt 0) { $best = $v }
    }
    return [string]$best
}

function Compare-PromptParleVersion {
    param([string]$A, [string]$B)
    try {
        $sa = (($A -replace '[^0-9.]', '') -replace '^\.', '0.')
        $sb = (($B -replace '[^0-9.]', '') -replace '^\.', '0.')
        if (-not $sa) { $sa = '0.0.0' }
        if (-not $sb) { $sb = '0.0.0' }
        # Normalize to at least Major.Minor.Build so "0.12" vs "0.12.5" compares cleanly
        $pa = @($sa.Split('.') | ForEach-Object { $_ })
        $pb = @($sb.Split('.') | ForEach-Object { $_ })
        while ($pa.Count -lt 3) { $pa += '0' }
        while ($pb.Count -lt 3) { $pb += '0' }
        $va = [version](($pa[0..2] -join '.'))
        $vb = [version](($pb[0..2] -join '.'))
        return $va.CompareTo($vb)
    } catch {
        if ("$A" -eq "$B") { return 0 }
        return -1
    }
}

function Get-PromptParleUpdateStatus {
    <#
    .SYNOPSIS
      Local vs remote client version for the local UI / CLI.
    #>
    [CmdletBinding()]
    param()
    # Prefer on-disk manifest (what Update installs) over in-memory module version
    $local = $null
    $root = $null
    try { $root = Get-PromptParleModuleRoot } catch { $root = $null }
    if ($root) {
        $local = Read-PromptParleVersionFromManifest -ManifestPath (Join-Path $root 'PromptParle.psd1')
    }
    if (-not $local) {
        $dest = Join-Path (Get-PromptParleUserModulesDir) 'PromptParle\PromptParle.psd1'
        $local = Read-PromptParleVersionFromManifest -ManifestPath $dest
    }
    if (-not $local) {
        try { $local = Get-PromptParleClientVersion } catch { $local = '0.0.0' }
    }
    if (-not $local) { $local = '0.0.0' }

    $remote = $null
    $err = $null
    try {
        $remote = Get-PromptParleRemoteClientVersion
    } catch {
        $err = "$_"
    }
    if (-not $remote -and -not $err) {
        $err = 'Could not read remote version from portal (version.txt / PromptParle.psd1) or GitHub'
    }
    $updateAvailable = $false
    if ($remote) {
        $updateAvailable = (Compare-PromptParleVersion -A $local -B $remote) -lt 0
    }
    # If remote check failed, do NOT claim "up to date" — UI should still offer Update
    $checkOk = [bool]$remote
    return [pscustomobject]@{
        local_version    = [string]$local
        remote_version   = if ($remote) { [string]$remote } else { $null }
        update_available = [bool]$updateAvailable
        check_error      = $err
        check_ok         = $checkOk
        module_root      = $root
    }
}

function Test-PromptParleModulePackage {
    <#
    .SYNOPSIS
      Validate a PromptParle module folder before/after install.
      Doctrine: never promote a package that cannot parse/import.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ModuleDir,
        [switch]$TryImport
    )
    $psd1 = Join-Path $ModuleDir 'PromptParle.psd1'
    $psm1 = Join-Path $ModuleDir 'PromptParle.psm1'
    $ui   = Join-Path $ModuleDir 'local-ui\index.html'
    if (-not (Test-Path -LiteralPath $ui)) { $ui = Join-Path $ModuleDir 'local-ui/index.html' }

    if (-not (Test-Path -LiteralPath $psd1)) {
        return [pscustomobject]@{ ok = $false; message = 'Package missing PromptParle.psd1' }
    }
    if (-not (Test-Path -LiteralPath $psm1)) {
        return [pscustomobject]@{ ok = $false; message = 'Package missing PromptParle.psm1' }
    }
    if (-not (Test-Path -LiteralPath $ui)) {
        return [pscustomobject]@{ ok = $false; message = 'Package missing local-ui/index.html' }
    }

    $ver = Read-PromptParleVersionFromManifest -ManifestPath $psd1
    if (-not $ver) {
        return [pscustomobject]@{ ok = $false; message = 'Package manifest has no ModuleVersion' }
    }

    try {
        $parseErrs = $null
        $parseTok = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile(
            $psm1,
            [ref]$parseTok,
            [ref]$parseErrs
        )
        if ($parseErrs -and $parseErrs.Count -gt 0) {
            $first = $parseErrs[0]
            $where = if ($first.Extent) {
                "line $($first.Extent.StartLineNumber): $($first.Message)"
            } else { [string]$first.Message }
            return [pscustomobject]@{
                ok      = $false
                message = "Module parse failed ($where)"
                version = $ver
            }
        }
    } catch {
        return [pscustomobject]@{
            ok      = $false
            message = "Module parse could not run: $_"
            version = $ver
        }
    }

    if ($TryImport) {
        # Isolated process — never Import-Module into the live server session
        $psExe = if (Get-Command pwsh -ErrorAction SilentlyContinue) {
            (Get-Command pwsh).Source
        } elseif (Get-Command powershell -ErrorAction SilentlyContinue) {
            (Get-Command powershell).Source
        } else {
            $null
        }
        if ($psExe) {
            $psd1Esc = $psd1 -replace "'", "''"
            $probe = @"
`$ErrorActionPreference = 'Stop'
try {
  Import-Module '$psd1Esc' -Force -ErrorAction Stop
  if (-not (Get-Command Start-PromptParleLocalServer -ErrorAction SilentlyContinue)) { exit 3 }
  if (-not (Get-Command Get-PromptParleClientVersion -ErrorAction SilentlyContinue)) { exit 4 }
  exit 0
} catch {
  [Console]::Error.WriteLine(`$_.Exception.Message)
  exit 2
}
"@
            $outFile = Join-Path ([System.IO.Path]::GetTempPath()) ('pp-import-probe-' + [guid]::NewGuid().ToString('n') + '.out.txt')
            $errFile = Join-Path ([System.IO.Path]::GetTempPath()) ('pp-import-probe-' + [guid]::NewGuid().ToString('n') + '.err.txt')
            try {
                $sp = @{
                    FilePath               = $psExe
                    ArgumentList           = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', $probe)
                    Wait                   = $true
                    PassThru               = $true
                    RedirectStandardOutput = $outFile
                    RedirectStandardError  = $errFile
                }
                # -WindowStyle only on Windows Desktop PowerShell / Win-capable hosts
                if ($script:PromptParleIsWindows) {
                    $sp.WindowStyle = 'Hidden'
                }
                $p = Start-Process @sp
                $code = 1
                try { $code = [int]$p.ExitCode } catch { $code = 1 }
                $errText = ''
                foreach ($f in @($errFile, $outFile)) {
                    if (Test-Path -LiteralPath $f) {
                        try {
                            $chunk = Get-Content -LiteralPath $f -Raw -ErrorAction SilentlyContinue
                            if ($chunk) { $errText = ($errText + ' ' + $chunk).Trim() }
                        } catch { }
                    }
                }
                if ($code -ne 0) {
                    $detail = if ($errText) { $errText.Trim() } else { "exit $code" }
                    if ($detail.Length -gt 240) { $detail = $detail.Substring(0, 237) + '…' }
                    return [pscustomobject]@{
                        ok      = $false
                        message = "Module import probe failed: $detail"
                        version = $ver
                    }
                }
            } catch {
                return [pscustomobject]@{
                    ok      = $false
                    message = "Module import probe could not run: $_"
                    version = $ver
                }
            } finally {
                foreach ($f in @($outFile, $errFile)) {
                    try { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue } catch { }
                }
            }
        }
    }

    return [pscustomobject]@{ ok = $true; message = 'ok'; version = $ver }
}

function Restore-PromptParleModuleInstall {
    <# Restore install directory from a full backup folder. #>
    param(
        [Parameter(Mandatory)][string]$BackupDir,
        [Parameter(Mandatory)][string]$DestDir
    )
    if (-not (Test-Path -LiteralPath $BackupDir)) {
        throw "Backup not found: $BackupDir"
    }
    if (Test-Path -LiteralPath $DestDir) {
        Remove-Item -LiteralPath $DestDir -Recurse -Force -ErrorAction Stop
    }
    $parent = Split-Path -Parent $DestDir
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    Copy-Item -LiteralPath $BackupDir -Destination $DestDir -Recurse -Force -ErrorAction Stop
}

function Install-PromptParleModuleTree {
    <#
    .SYNOPSIS
      Overlay-install module files without deleting the whole tree first.
    .DESCRIPTION
      Avoids Windows file-lock failures when the running server still has
      PromptParle.psm1 mapped. Copies source over dest file-by-file, then
      removes orphan files that are no longer in the package.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SourceDir,
        [Parameter(Mandatory)][string]$DestDir
    )
    if (-not (Test-Path -LiteralPath $SourceDir)) {
        throw "Source not found: $SourceDir"
    }
    if (-not (Test-Path -LiteralPath $DestDir)) {
        New-Item -ItemType Directory -Path $DestDir -Force | Out-Null
    }

    $sourceRoot = (Resolve-Path -LiteralPath $SourceDir).Path.TrimEnd('\', '/')
    $destRoot = (Resolve-Path -LiteralPath $DestDir).Path.TrimEnd('\', '/')
    $wanted = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)

    Get-ChildItem -LiteralPath $SourceDir -Recurse -File -Force -ErrorAction Stop | ForEach-Object {
        $full = $_.FullName
        $rel = $full.Substring($sourceRoot.Length).TrimStart('\', '/')
        if (-not $rel) { return }
        [void]$wanted.Add(($rel -replace '/', '\'))
        $target = Join-Path $DestDir $rel
        $parent = Split-Path -Parent $target
        if ($parent -and -not (Test-Path -LiteralPath $parent)) {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }
        $copied = $false
        try {
            Copy-Item -LiteralPath $full -Destination $target -Force -ErrorAction Stop
            $copied = $true
        } catch {
            # Locked file: stage beside target, swap via rename
            $tmp = "$target.__ppnew"
            $bak = "$target.__ppold"
            try {
                if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
                if (Test-Path -LiteralPath $bak) { Remove-Item -LiteralPath $bak -Force -ErrorAction SilentlyContinue }
                Copy-Item -LiteralPath $full -Destination $tmp -Force -ErrorAction Stop
                if (Test-Path -LiteralPath $target) {
                    Rename-Item -LiteralPath $target -NewName (Split-Path -Leaf $bak) -ErrorAction Stop
                }
                Rename-Item -LiteralPath $tmp -NewName (Split-Path -Leaf $target) -ErrorAction Stop
                try { Remove-Item -LiteralPath $bak -Force -ErrorAction SilentlyContinue } catch { }
                $copied = $true
            } catch {
                try {
                    if ((Test-Path -LiteralPath $bak) -and -not (Test-Path -LiteralPath $target)) {
                        Rename-Item -LiteralPath $bak -NewName (Split-Path -Leaf $target) -ErrorAction SilentlyContinue
                    }
                } catch { }
                throw "Could not write $rel : $_"
            } finally {
                try { if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue } } catch { }
            }
        }
        if (-not $copied) { throw "Could not install file: $rel" }
    }

    # Remove orphans (files in dest not in package) — never remove __pp* temps mid-flight
    Get-ChildItem -LiteralPath $DestDir -Recurse -File -Force -ErrorAction SilentlyContinue | ForEach-Object {
        $full = $_.FullName
        if ($full -match '\.__pp(new|old)$') {
            try { Remove-Item -LiteralPath $full -Force -ErrorAction SilentlyContinue } catch { }
            return
        }
        $rel = $full.Substring($destRoot.Length).TrimStart('\', '/')
        $norm = ($rel -replace '/', '\')
        if ($norm -and -not $wanted.Contains($norm)) {
            try { Remove-Item -LiteralPath $full -Force -ErrorAction SilentlyContinue } catch { }
        }
    }
}

function Write-PromptParleRestartScript {
    <# Write durable restart .ps1 used after self-update (never inline -Command). #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$ManifestPath,
        [Parameter(Mandatory)][int]$Port,
        [Parameter(Mandatory)][string]$LogPath
    )
    $manifestEsc = $ManifestPath -replace "'", "''"
    $logEsc = $LogPath -replace "'", "''"
    $content = @"
# PromptParle post-update restart — generated; safe to delete after success
param(
    [int]`$Port = $Port,
    [string]`$ManifestPath = '$manifestEsc',
    [string]`$LogPath = '$logEsc'
)
`$ErrorActionPreference = 'Continue'
function Write-PpRestartLog([string]`$Message) {
    try {
        `$line = ('{0}  {1}' -f (Get-Date -Format o), `$Message)
        Add-Content -LiteralPath `$LogPath -Value `$line -Encoding UTF8 -ErrorAction SilentlyContinue
        Write-Host `$line
    } catch { }
}
try {
    if (Test-Path -LiteralPath `$LogPath) {
        '' | Set-Content -LiteralPath `$LogPath -Encoding UTF8
    }
} catch { }
Write-PpRestartLog 'restart begin'
try {
    # Wait for previous local server to release the port (up to ~30s)
    `$free = `$false
    for (`$i = 0; `$i -lt 60; `$i++) {
        `$busy = `$false
        try {
            if (Get-Command Get-NetTCPConnection -ErrorAction SilentlyContinue) {
                `$c = @(Get-NetTCPConnection -LocalPort `$Port -State Listen -ErrorAction SilentlyContinue)
                if (`$c.Count -gt 0) { `$busy = `$true }
            }
        } catch { }
        if (-not `$busy) {
            try {
                `$client = New-Object System.Net.Sockets.TcpClient
                `$iar = `$client.BeginConnect('127.0.0.1', `$Port, `$null, `$null)
                `$ok = `$iar.AsyncWaitHandle.WaitOne(200, `$false)
                if (`$ok -and `$client.Connected) { `$busy = `$true }
                try { `$client.Close() } catch { }
            } catch { }
        }
        if (-not `$busy) { `$free = `$true; break }
        Start-Sleep -Milliseconds 500
    }
    Write-PpRestartLog ("port {0} free={1}" -f `$Port, `$free)

    if (-not (Test-Path -LiteralPath `$ManifestPath)) {
        throw "Module manifest missing: `$ManifestPath"
    }
    Import-Module `$ManifestPath -Force -Global -ErrorAction Stop
    `$ver = '?'
    try { `$ver = Get-PromptParleClientVersion } catch { }
    Write-PpRestartLog ("import ok version=`$ver")

    Write-Host ''
    Write-Host 'PromptParle updated — starting local chat...' -ForegroundColor Cyan
    Write-Host ("  http://127.0.0.1:{0}/" -f `$Port) -ForegroundColor Green
    Write-Host ''

    # Blocking when healthy. Early return (no key / bind fail) must not silent-exit.
    `$before = Get-Date
    try {
        Start-PromptParleLocalServer -Port `$Port
    } catch {
        Write-PpRestartLog ("Start-PromptParleLocalServer threw: `$_")
        throw
    }
    `$elapsed = ((Get-Date) - `$before).TotalSeconds
    Write-PpRestartLog ("server returned after {0:N1}s" -f `$elapsed)
    if (`$elapsed -lt 4) {
        throw "Local server exited immediately (port busy, missing API key, or UI missing). See log: `$LogPath"
    }
    Write-Host 'Local server stopped.' -ForegroundColor DarkGray
    Write-Host 'Run  pp  to start again.' -ForegroundColor Cyan
} catch {
    Write-PpRestartLog ("RESTART FAILED: `$_")
    Write-Host ''
    Write-Host '========================================' -ForegroundColor Red
    Write-Host '  PromptParle restart failed' -ForegroundColor Red
    Write-Host '========================================' -ForegroundColor Red
    Write-Host `$_ -ForegroundColor Yellow
    Write-Host ''
    Write-Host "Log: `$LogPath" -ForegroundColor DarkGray
    Write-Host 'Recover with:' -ForegroundColor Cyan
    Write-Host '  Import-Module PromptParle -Force' -ForegroundColor White
    Write-Host '  pp' -ForegroundColor White
    Write-Host ''
    try { Read-Host 'Press Enter to close this window' } catch { Start-Sleep -Seconds 30 }
    exit 1
}
"@
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    Set-Content -LiteralPath $Path -Value $content -Encoding UTF8
}

function Update-PromptParleClient {
    <#
    .SYNOPSIS
      Download latest PromptParle module and install into the user Modules folder.

    .DESCRIPTION
      Safe update: validate package → snapshot current → install → re-validate.
      On ANY failure after install starts, restore previous install and do NOT restart.
      Used by the local chat "Update" button and:
        Update-PromptParleClient
    #>
    [CmdletBinding()]
    param(
        [switch]$Force,
        [int]$RestartPort = 0
    )

    # Prefer manifest on disk — safer if module is mid-reload or partially loaded
    $before = $null
    try { $before = Get-PromptParleClientVersion } catch { $before = $null }
    if (-not $before -or $before -eq '0.0.0') {
        $rootGuess = $null
        try { $rootGuess = Get-PromptParleModuleRoot } catch { }
        if (-not $rootGuess) {
            $rootGuess = Join-Path (Get-PromptParleUserModulesDir) 'PromptParle'
        }
        $before = Read-PromptParleVersionFromManifest -ManifestPath (Join-Path $rootGuess 'PromptParle.psd1')
    }
    if (-not $before) { $before = '0.0.0' }

    $remote = $null
    try { $remote = Get-PromptParleRemoteClientVersion } catch { }

    # Version-aware gate (default): never download/install when already current.
    # -Force is repair/reinstall only — UI must ask before sending force=1.
    if (-not $Force) {
        if ($remote -and (Compare-PromptParleVersion -A $before -B $remote) -ge 0) {
            Write-Host ("  update: already current v{0} (portal v{1}) — skip download" -f $before, $remote) -ForegroundColor DarkGreen
            return [pscustomobject]@{
                ok               = $true
                updated          = $false
                previous_version = $before
                version          = $before
                remote_version   = $remote
                message          = "Already up to date (v$before). Portal also reports v$remote — no download."
                restart_required = $false
                rolled_back      = $false
                skipped_reason   = 'already-current'
            }
        }
        if ($remote -and (Compare-PromptParleVersion -A $before -B $remote) -lt 0) {
            Write-Host ("  update: v{0} → v{1} available" -f $before, $remote) -ForegroundColor Cyan
        }
    } else {
        Write-Host ("  update: force reinstall (local v{0}, portal v{1})" -f $before, $(if ($remote) { $remote } else { '?' })) -ForegroundColor Yellow
    }

    $temp = Join-Path ([System.IO.Path]::GetTempPath()) ('pp-update-' + [guid]::NewGuid().ToString('n'))
    New-Item -ItemType Directory -Path $temp -Force | Out-Null
    $zipPath = Join-Path $temp 'promptparle-main.zip'
    $tgzPath = Join-Path $temp 'PromptParle-PowerShell.tgz'
    $extract = Join-Path $temp 'extract'
    # Durable backup OUTSIDE $temp (temp is deleted in finally)
    $backupRoot = Join-Path ([System.IO.Path]::GetTempPath()) 'promptparle-safe-update'
    $backup = $null
    $installed = $false
    $userModules = Get-PromptParleUserModulesDir
    $dest = Join-Path $userModules 'PromptParle'

    function New-PromptParleUpdateFail {
        param(
            [string]$Message,
            [string]$Version = $before,
            [bool]$RolledBack = $false,
            [string]$Stage = 'preflight'
        )
        Write-Host ("  update aborted: {0}" -f $Message) -ForegroundColor Red
        return [pscustomobject]@{
            ok               = $false
            updated          = $false
            previous_version = $before
            version          = $Version
            remote_version   = $remote
            message          = $Message
            restart_required = $false
            rolled_back      = $RolledBack
            kept_version     = $before
            stage            = $Stage
            module_path      = $dest
        }
    }

    try {
        Write-Host 'Downloading latest PromptParle client...' -ForegroundColor Cyan
        $tgzUrl = 'https://promptparle.com/PromptParle-PowerShell.tgz'
        $zipUrl = 'https://github.com/exiled4disco/promptparle/archive/refs/heads/main.zip'
        $used = $null
        $source = $null
        New-Item -ItemType Directory -Path $extract -Force | Out-Null

        # 1) Portal .tgz
        try {
            Invoke-WebRequest -Uri $tgzUrl -OutFile $tgzPath -UseBasicParsing -TimeoutSec 120
            if ((Test-Path -LiteralPath $tgzPath) -and ((Get-Item -LiteralPath $tgzPath).Length -gt 1000)) {
                Write-Host 'Extracting portal package...' -ForegroundColor DarkGray
                $tarOk = $false
                if (Get-Command tar -ErrorAction SilentlyContinue) {
                    try {
                        & tar -xzf $tgzPath -C $extract 2>$null
                        if ($LASTEXITCODE -eq 0) { $tarOk = $true }
                    } catch { $tarOk = $false }
                }
                if ($tarOk) {
                    $tgzCandidates = @(
                        (Join-Path $extract 'PromptParle'),
                        (Join-Path $extract 'powershell\PromptParle'),
                        (Join-Path $extract 'powershell/PromptParle')
                    )
                    Get-ChildItem -LiteralPath $extract -Directory -ErrorAction SilentlyContinue | ForEach-Object {
                        if ($_.Name -eq 'PromptParle') { $tgzCandidates = @($_.FullName) + $tgzCandidates }
                    }
                    foreach ($c in $tgzCandidates) {
                        if ($c -and (Test-Path -LiteralPath (Join-Path $c 'PromptParle.psd1'))) {
                            $source = $c
                            $used = 'portal-tgz'
                            break
                        }
                    }
                }
            }
        } catch {
            Write-Host ("Portal package unavailable ({0}); trying GitHub..." -f $_) -ForegroundColor DarkYellow
        }

        # 2) GitHub zip fallback
        if (-not $source) {
            try {
                Invoke-WebRequest -Uri $zipUrl -OutFile $zipPath -UseBasicParsing -TimeoutSec 120
                $used = 'github-zip'
            } catch {
                return (New-PromptParleUpdateFail -Message "Download failed (portal + GitHub): $_. Kept previous version ($before)." -Stage 'download')
            }

            Write-Host 'Extracting GitHub archive...' -ForegroundColor DarkGray
            if (Get-Command Expand-Archive -ErrorAction SilentlyContinue) {
                try {
                    Expand-Archive -LiteralPath $zipPath -DestinationPath $extract -Force
                } catch {
                    return (New-PromptParleUpdateFail -Message "Extract failed: $_. Kept previous version ($before)." -Stage 'extract')
                }
            } else {
                return (New-PromptParleUpdateFail -Message "Expand-Archive not available. Kept previous version ($before)." -Stage 'extract')
            }

            $candidates = @(
                (Join-Path $extract 'promptparle-main\powershell\PromptParle'),
                (Join-Path $extract 'promptparle-main/powershell/PromptParle')
            )
            Get-ChildItem -LiteralPath $extract -Directory -ErrorAction SilentlyContinue | ForEach-Object {
                $candidates += (Join-Path $_.FullName 'powershell\PromptParle')
                $candidates += (Join-Path $_.FullName 'powershell/PromptParle')
            }
            foreach ($c in $candidates) {
                if ($c -and (Test-Path -LiteralPath (Join-Path $c 'PromptParle.psd1'))) {
                    $source = $c
                    break
                }
            }
        }

        if (-not $source) {
            return (New-PromptParleUpdateFail -Message "Downloaded archive did not contain PromptParle module. Kept previous version ($before)." -Stage 'extract')
        }
        Write-Host ("Source: {0}" -f $used) -ForegroundColor DarkGray

        # --- PREFLIGHT: never touch install until package is proven good ---
        Write-Host 'Validating package (parse + import probe)...' -ForegroundColor DarkGray
        $pre = Test-PromptParleModulePackage -ModuleDir $source -TryImport
        if (-not $pre.ok) {
            return (New-PromptParleUpdateFail -Message (
                "Update blocked — package failed checks: $($pre.message). Kept previous version ($before)."
            ) -Stage 'preflight')
        }
        $newVer = if ($pre.version) { [string]$pre.version } else { 'unknown' }
        Write-Host ("  package ok · v{0}" -f $newVer) -ForegroundColor DarkGray

        # Second gate: package itself not newer than installed (covers remote-check miss / CDN lag)
        if (-not $Force -and $newVer -and $newVer -ne 'unknown' -and (Compare-PromptParleVersion -A $before -B $newVer) -ge 0) {
            Write-Host ("  update: package v{0} is not newer than installed v{1} — skip install" -f $newVer, $before) -ForegroundColor DarkGreen
            return [pscustomobject]@{
                ok               = $true
                updated          = $false
                previous_version = $before
                version          = $before
                remote_version   = if ($remote) { $remote } else { $newVer }
                package_version  = $newVer
                message          = "Already up to date (v$before). Downloaded package is v$newVer — not newer; install skipped."
                restart_required = $false
                rolled_back      = $false
                skipped_reason   = 'package-not-newer'
            }
        }

        New-Item -ItemType Directory -Path $userModules -Force | Out-Null
        New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null

        # Snapshot current install (required if dest exists — refuse update without backup)
        if (Test-Path -LiteralPath $dest) {
            $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
            $backup = Join-Path $backupRoot ("PromptParle-v$before-$stamp")
            try {
                if (Test-Path -LiteralPath $backup) {
                    Remove-Item -LiteralPath $backup -Recurse -Force -ErrorAction SilentlyContinue
                }
                Copy-Item -LiteralPath $dest -Destination $backup -Recurse -Force -ErrorAction Stop
                Write-Host ("  backup: {0}" -f $backup) -ForegroundColor DarkGray
            } catch {
                return (New-PromptParleUpdateFail -Message (
                    "Could not back up current install — update aborted to protect v$before. ($_)"
                ) -Stage 'backup')
            }
            # Prune old backups (keep last 3)
            try {
                Get-ChildItem -LiteralPath $backupRoot -Directory -ErrorAction SilentlyContinue |
                    Sort-Object LastWriteTime -Descending |
                    Select-Object -Skip 3 |
                    ForEach-Object {
                        try { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue } catch { }
                    }
            } catch { }
        }

        Write-Host ("Installing PromptParle {0} -> {1}" -f $newVer, $dest) -ForegroundColor Cyan

        # --- INSTALL (transactional, overlay — never delete whole tree while loaded) ---
        try {
            if (Test-Path -LiteralPath $dest) {
                Install-PromptParleModuleTree -SourceDir $source -DestDir $dest
            } else {
                New-Item -ItemType Directory -Path $dest -Force | Out-Null
                Copy-Item -LiteralPath (Join-Path $source '*') -Destination $dest -Recurse -Force -ErrorAction Stop
            }
            $installed = $true
        } catch {
            $rolled = $false
            if ($backup -and (Test-Path -LiteralPath $backup)) {
                try {
                    Write-Host '  install failed — restoring previous version...' -ForegroundColor Yellow
                    Restore-PromptParleModuleInstall -BackupDir $backup -DestDir $dest
                    $rolled = $true
                } catch {
                    return (New-PromptParleUpdateFail -Message (
                        "Install failed AND restore failed: $_. Manual recovery: copy backup from $backup to $dest"
                    ) -Stage 'install' -RolledBack $false)
                }
            }
            return (New-PromptParleUpdateFail -Message (
                "Install failed: $_. Kept previous version ($before)."
            ) -Stage 'install' -RolledBack $rolled)
        }

        Get-ChildItem -LiteralPath $dest -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
            try { Unblock-File -LiteralPath $_.FullName -ErrorAction SilentlyContinue } catch { }
        }

        # --- POSTFLIGHT: must pass or roll back ---
        Write-Host 'Validating installed module...' -ForegroundColor DarkGray
        $post = Test-PromptParleModulePackage -ModuleDir $dest -TryImport
        if (-not $post.ok) {
            $rolled = $false
            if ($backup -and (Test-Path -LiteralPath $backup)) {
                try {
                    Write-Host '  post-check failed — restoring previous version...' -ForegroundColor Yellow
                    Restore-PromptParleModuleInstall -BackupDir $backup -DestDir $dest
                    $rolled = $true
                    $installed = $false
                } catch {
                    return (New-PromptParleUpdateFail -Message (
                        "New version failed checks ($($post.message)) and restore failed: $_. Backup at $backup"
                    ) -Version $newVer -Stage 'postflight' -RolledBack $false)
                }
            }
            $keepMsg = if ($rolled) {
                "Update failed validation ($($post.message)). Restored previous version ($before). App left running."
            } else {
                "Update failed validation ($($post.message)). No backup available — install may be broken. Re-run install from https://promptparle.com"
            }
            return (New-PromptParleUpdateFail -Message $keepMsg -Version $(if ($rolled) { $before } else { $newVer }) -Stage 'postflight' -RolledBack $rolled)
        }

        $manifestPath = Join-Path $dest 'PromptParle.psd1'
        $after = if ($post.version) { [string]$post.version } else { $newVer }
        if (-not $after) { $after = 'unknown' }

        # CLI path only: re-import into this session (never mid-server when RestartPort set)
        if ($RestartPort -le 0) {
            try {
                Remove-Module PromptParle -Force -ErrorAction SilentlyContinue
                Import-Module $manifestPath -Force -Global -ErrorAction Stop
            } catch {
                # Roll back — live session cannot load new module
                if ($backup -and (Test-Path -LiteralPath $backup)) {
                    try {
                        Restore-PromptParleModuleInstall -BackupDir $backup -DestDir $dest
                        try {
                            Remove-Module PromptParle -Force -ErrorAction SilentlyContinue
                            Import-Module (Join-Path $dest 'PromptParle.psd1') -Force -Global -ErrorAction SilentlyContinue
                        } catch { }
                        return (New-PromptParleUpdateFail -Message (
                            "New module would not load into this session: $_. Restored previous version ($before)."
                        ) -Stage 'session-import' -RolledBack $true)
                    } catch { }
                }
                return (New-PromptParleUpdateFail -Message (
                    "Updated files but session import failed: $_. Restart with: Import-Module PromptParle -Force; pp"
                ) -Version $after -Stage 'session-import')
            }
        }

        $msg = "Updated $before → $after"
        Write-Host $msg -ForegroundColor Green
        if ($used) { Write-Host ("  source: {0}" -f $used) -ForegroundColor DarkGray }

        # Restart ONLY after full success — durable .ps1 (never fragile -Command)
        if ($RestartPort -gt 0) {
            $psExe = if (Get-Command pwsh -ErrorAction SilentlyContinue) {
                (Get-Command pwsh).Source
            } elseif (Get-Command powershell -ErrorAction SilentlyContinue) {
                (Get-Command powershell).Source
            } else {
                'powershell'
            }
            $logPath = Join-Path ([System.IO.Path]::GetTempPath()) 'promptparle-restart.log'
            $restartScript = Join-Path ([System.IO.Path]::GetTempPath()) 'promptparle-restart.ps1'
            try {
                Write-PromptParleRestartScript -Path $restartScript -ManifestPath $manifestPath -Port $RestartPort -LogPath $logPath
            } catch {
                Write-Host ("  warning: could not write restart script: {0}" -f $_) -ForegroundColor Yellow
                Write-Host '  Module files updated. Close this window and run:  pp' -ForegroundColor Cyan
                return [pscustomobject]@{
                    ok               = $true
                    updated          = $true
                    previous_version = $before
                    version          = $after
                    remote_version   = $remote
                    message          = "$msg — restart script missing; run  pp  manually"
                    restart_required = $false
                    rolled_back      = $false
                    kept_version     = $null
                    stage            = 'done-manual-restart'
                    module_path      = $dest
                    backup_path      = $backup
                }
            }

            Write-Host ("Restarting local chat on port {0}..." -f $RestartPort) -ForegroundColor Cyan
            Write-Host ("  restart script: {0}" -f $restartScript) -ForegroundColor DarkGray
            Write-Host ("  restart log:    {0}" -f $logPath) -ForegroundColor DarkGray

            $spawned = $null
            try {
                $argList = @(
                    '-NoProfile',
                    '-ExecutionPolicy', 'Bypass',
                    '-NoExit',
                    '-File', $restartScript,
                    '-Port', "$RestartPort",
                    '-ManifestPath', $manifestPath,
                    '-LogPath', $logPath
                )
                $sp = @{
                    FilePath     = $psExe
                    ArgumentList = $argList
                    PassThru     = $true
                }
                if ($script:PromptParleIsWindows) {
                    $sp.WorkingDirectory = $dest
                    # New visible console — do not hide; -NoExit keeps window if start fails
                    $sp.WindowStyle = 'Normal'
                }
                $spawned = Start-Process @sp
            } catch {
                Write-Host ("  restart spawn failed: {0}" -f $_) -ForegroundColor Red
                Write-Host '  Module is updated on disk. Run:  pp' -ForegroundColor Cyan
                return [pscustomobject]@{
                    ok               = $true
                    updated          = $true
                    previous_version = $before
                    version          = $after
                    remote_version   = $remote
                    message          = "$msg — could not auto-restart ($_); run  pp"
                    restart_required = $false
                    rolled_back      = $false
                    kept_version     = $null
                    stage            = 'done-manual-restart'
                    module_path      = $dest
                    backup_path      = $backup
                    restart_log      = $logPath
                }
            }

            # Brief settle — if child dies instantly, keep this server alive
            Start-Sleep -Milliseconds 600
            $childDead = $false
            try {
                if ($null -eq $spawned) { $childDead = $true }
                elseif ($spawned.HasExited) { $childDead = $true }
            } catch { $childDead = $false }

            if ($childDead) {
                Write-Host '  restart process exited immediately — keeping this server running' -ForegroundColor Yellow
                Write-Host ("  check log: {0}" -f $logPath) -ForegroundColor DarkGray
                Write-Host '  Or run:  pp' -ForegroundColor Cyan
                return [pscustomobject]@{
                    ok               = $true
                    updated          = $true
                    previous_version = $before
                    version          = $after
                    remote_version   = $remote
                    message          = "$msg — auto-restart did not stay up; this window kept open. Run  pp  if needed."
                    restart_required = $false
                    rolled_back      = $false
                    kept_version     = $null
                    stage            = 'done-manual-restart'
                    module_path      = $dest
                    backup_path      = $backup
                    restart_log      = $logPath
                }
            }

            Write-Host ("  restart PID {0} started" -f $spawned.Id) -ForegroundColor DarkGray
        }

        $restartLogPath = $null
        try {
            if ($RestartPort -gt 0) {
                $restartLogPath = Join-Path ([System.IO.Path]::GetTempPath()) 'promptparle-restart.log'
            }
        } catch { }
        return [pscustomobject]@{
            ok               = $true
            updated          = $true
            previous_version = $before
            version          = $after
            remote_version   = $remote
            message          = $msg
            restart_required = ($RestartPort -gt 0)
            rolled_back      = $false
            kept_version     = $null
            stage            = 'done'
            module_path      = $dest
            backup_path      = $backup
            restart_log      = $restartLogPath
        }
    } catch {
        # Last-resort safety net: if we wrote files, try restore
        $rolled = $false
        if ($installed -and $backup -and (Test-Path -LiteralPath $backup)) {
            try {
                Write-Host '  unexpected error — restoring previous version...' -ForegroundColor Yellow
                Restore-PromptParleModuleInstall -BackupDir $backup -DestDir $dest
                $rolled = $true
            } catch { }
        }
        $keep = if ($rolled) { " Restored previous version ($before)." } else { " Kept previous version ($before)." }
        return (New-PromptParleUpdateFail -Message ("Update error: $_.$keep") -Stage 'exception' -RolledBack $rolled)
    } finally {
        try { Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue } catch { }
    }
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
        [string]$Body = '',
        # Optional raw bytes (logo / static assets / exports). When set, Body is ignored.
        [byte[]]$Bytes = $null,
        [string]$ContentDisposition = ''
    )

    if ($null -ne $Bytes) {
        $buffer = $Bytes
    } else {
        $buffer = [System.Text.Encoding]::UTF8.GetBytes($Body)
    }
    $Context.Response.StatusCode = $StatusCode
    $Context.Response.ContentType = $ContentType
    $Context.Response.ContentLength64 = $buffer.Length
    $Context.Response.Headers.Add('Cache-Control', 'no-store')
    if ($ContentDisposition) {
        try { $Context.Response.Headers.Add('Content-Disposition', $ContentDisposition) } catch {
            try { $Context.Response.AddHeader('Content-Disposition', $ContentDisposition) } catch { }
        }
    }
    if ($buffer.Length -gt 0) {
        $Context.Response.OutputStream.Write($buffer, 0, $buffer.Length)
    }
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
    # When true, process exits after stop (successful Update handoff closes this window).
    # Always assign under StrictMode — never read an unset $script: var.
    $script:PromptParleExitProcessAfterStop = $false
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

                # Static assets next to index.html (logo, etc.)
                # 0.17 document downloads from chat ```file name=…``` deliverables
                if ($req.HttpMethod -eq 'GET' -and $path -match '^/api/exports/([a-fA-F0-9]+)$') {
                    try {
                        $tok = $Matches[1]
                        $exp = Get-PromptParleExport -Token $tok
                        if (-not $exp) {
                            Write-PromptParleHttpResponse -Context $ctx -StatusCode 404 -ContentType 'text/plain; charset=utf-8' -Body 'Export not found or expired'
                        } else {
                            $bytes = [System.IO.File]::ReadAllBytes([string]$exp.path)
                            $dl = $true
                            try {
                                $qdl = [string]$req.QueryString['download']
                                if ($qdl -eq '0' -or $qdl -eq 'false') { $dl = $false }
                            } catch { $dl = $true }
                            $dispName = [string]$exp.name
                            $disp = if ($dl) {
                                'attachment; filename="' + ($dispName -replace '"', '') + '"'
                            } else {
                                'inline; filename="' + ($dispName -replace '"', '') + '"'
                            }
                            Write-PromptParleHttpResponse -Context $ctx -ContentType ([string]$exp.content_type) -Bytes $bytes -ContentDisposition $disp
                        }
                    } catch {
                        Write-PromptParleHttpResponse -Context $ctx -StatusCode 500 -ContentType 'text/plain; charset=utf-8' -Body "$_"
                    }
                    continue
                }

                if ($req.HttpMethod -eq 'GET' -and ($path -eq '/logo.png' -or $path -eq '/local-ui/logo.png')) {
                    $logoPath = Join-Path $root 'local-ui\logo.png'
                    if (-not (Test-Path -LiteralPath $logoPath)) {
                        $logoPath = Join-Path $root 'local-ui/logo.png'
                    }
                    if (Test-Path -LiteralPath $logoPath) {
                        $bytes = [System.IO.File]::ReadAllBytes($logoPath)
                        Write-PromptParleHttpResponse -Context $ctx -ContentType 'image/png' -Bytes $bytes
                    } else {
                        Write-PromptParleHttpResponse -Context $ctx -StatusCode 404 -ContentType 'text/plain; charset=utf-8' -Body 'logo not found'
                    }
                    continue
                }

                if ($req.HttpMethod -eq 'GET' -and $path -eq '/api/version') {
                    try {
                        $st = Get-PromptParleUpdateStatus
                        $locV = [string](Get-PromptParleProp $st 'local_version' '0.0.0')
                        $remV = Get-PromptParleProp $st 'remote_version' $null
                        if ($null -ne $remV) { $remV = [string]$remV }
                        $upd = $false
                        try { $upd = [bool](Get-PromptParleProp $st 'update_available' $false) } catch { $upd = $false }
                        # Re-derive if remote present (defensive — UI depends on this flag)
                        if ($remV -and -not $upd) {
                            if ((Compare-PromptParleVersion -A $locV -B $remV) -lt 0) { $upd = $true }
                        }
                        # Force real JSON boolean (not string "True"/"False")
                        $updJson = if ($upd) { 'true' } else { 'false' }
                        $remJson = if ($remV) { '"' + ($remV -replace '\\', '\\\\' -replace '"', '\"') + '"' } else { 'null' }
                        $errV = [string](Get-PromptParleProp $st 'check_error' '')
                        $errJson = if ($errV) { '"' + ($errV -replace '\\', '\\\\' -replace '"', '\"' -replace "`n", ' ' -replace "`r", '') + '"' } else { 'null' }
                        $rootV = [string](Get-PromptParleProp $st 'module_root' '')
                        $checkOk = $false
                        try { $checkOk = [bool](Get-PromptParleProp $st 'check_ok' $false) } catch { $checkOk = [bool]$remV }
                        $checkOkJson = if ($checkOk) { 'true' } else { 'false' }
                        $payload = @"
{"ok":true,"local_version":"$($locV -replace '"','')","remote_version":$remJson,"update_available":$updJson,"check_ok":$checkOkJson,"check_error":$errJson,"module_root":"$($rootV -replace '\\','\\\\' -replace '"','')","port":$Port}
"@
                        Write-PromptParleHttpResponse -Context $ctx -ContentType 'application/json; charset=utf-8' -Body $payload.Trim()
                    } catch {
                        $err = @{ ok = $false; error = "$_" } | ConvertTo-Json -Compress
                        Write-PromptParleHttpResponse -Context $ctx -StatusCode 500 -ContentType 'application/json; charset=utf-8' -Body $err
                    }
                    continue
                }

                if ($req.HttpMethod -eq 'POST' -and $path -eq '/api/update') {
                    try {
                        # Version-aware by default. force=1 only for explicit reinstall (UI confirms).
                        $forceUpd = $false
                        try {
                            $q = [string]$req.Url.Query
                            if ($q -match '(?i)(?:^|[?&])force=(1|true|yes)\b') { $forceUpd = $true }
                        } catch { }
                        if (-not $forceUpd) {
                            try {
                                if ($req.HasEntityBody) {
                                    $srBody = New-Object System.IO.StreamReader($req.InputStream, $req.ContentEncoding)
                                    $rawBody = $srBody.ReadToEnd()
                                    if ($rawBody -and $rawBody -match '(?i)"force"\s*:\s*true') { $forceUpd = $true }
                                }
                            } catch { }
                        }
                        if ($forceUpd) {
                            Write-Host '  update: FORCE reinstall (validate → backup → install → re-validate)...' -ForegroundColor Yellow
                            $result = Update-PromptParleClient -Force -RestartPort $Port
                        } else {
                            Write-Host '  update: version-aware (skip if already current)...' -ForegroundColor Cyan
                            $result = Update-PromptParleClient -RestartPort $Port
                        }

                        $ok = $true
                        try { $ok = [bool](Get-PromptParleProp $result 'ok' $true) } catch { $ok = $true }
                        $updated = $false
                        try { $updated = [bool](Get-PromptParleProp $result 'updated' $false) } catch { $updated = $false }
                        $restartReq = $false
                        try { $restartReq = [bool](Get-PromptParleProp $result 'restart_required' $false) } catch { $restartReq = $false }
                        $rolled = $false
                        try { $rolled = [bool](Get-PromptParleProp $result 'rolled_back' $false) } catch { $rolled = $false }
                        $msg = [string](Get-PromptParleProp $result 'message' '')
                        $ver = [string](Get-PromptParleProp $result 'version' '')
                        $prev = [string](Get-PromptParleProp $result 'previous_version' '')
                        $kept = [string](Get-PromptParleProp $result 'kept_version' '')

                        if (-not $ok) {
                            # FAILURE: previous install restored (or never touched) — keep this server running
                            Write-Host ("  update: FAILED — {0}" -f $msg) -ForegroundColor Red
                            $payload = @{
                                ok               = $false
                                updated          = $false
                                previous_version = $prev
                                version          = if ($kept) { $kept } else { $prev }
                                kept_version     = if ($kept) { $kept } else { $prev }
                                remote_version   = Get-PromptParleProp $result 'remote_version' $null
                                message          = if ($msg) { $msg } else { 'Update failed. Previous version kept.' }
                                restart_required = $false
                                rolled_back      = $rolled
                                stage            = [string](Get-PromptParleProp $result 'stage' 'failed')
                                error            = if ($msg) { $msg } else { 'Update failed' }
                            } | ConvertTo-Json -Compress
                            Write-PromptParleHttpResponse -Context $ctx -StatusCode 422 -ContentType 'application/json; charset=utf-8' -Body $payload
                            continue
                        }

                        $restartLog = $null
                        try { $restartLog = Get-PromptParleProp $result 'restart_log' $null } catch { $restartLog = $null }
                        $skipReason = $null
                        try { $skipReason = Get-PromptParleProp $result 'skipped_reason' $null } catch { $skipReason = $null }
                        $payload = @{
                            ok               = $true
                            updated          = $updated
                            previous_version = $prev
                            version          = $ver
                            remote_version   = Get-PromptParleProp $result 'remote_version' $null
                            message          = $msg
                            restart_required = $restartReq
                            restart_port     = $Port
                            url              = "http://127.0.0.1:$Port/"
                            rolled_back      = $false
                            restart_log      = $restartLog
                            skipped_reason   = $skipReason
                            forced           = [bool]$forceUpd
                        } | ConvertTo-Json -Compress
                        Write-PromptParleHttpResponse -Context $ctx -ContentType 'application/json; charset=utf-8' -Body $payload

                        if ($updated -and $restartReq) {
                            Write-Host ("  update: {0} — restarting server..." -f $msg) -ForegroundColor Green
                            Write-Host '  New window starting; this window will close.' -ForegroundColor DarkGray
                            # Let the response flush, then stop listener and exit this process
                            # (new process already spawned and is waiting for the port)
                            Start-Sleep -Milliseconds 500
                            $script:PromptParleExitProcessAfterStop = $true
                            $script:PromptParleShouldStop = $true
                            $script:PromptParleStopAnnounced = $true
                            try { $listener.Stop() } catch { }
                            break
                        }

                        # Success but no restart (e.g. already up to date)
                        Write-Host ("  update: {0}" -f $msg) -ForegroundColor Green
                    } catch {
                        Write-Host ("  update: error - {0}" -f $_) -ForegroundColor Red
                        # Do NOT restart with unknown disk state — keep this process alive
                        $err = @{
                            ok               = $false
                            updated          = $false
                            restart_required = $false
                            rolled_back      = $false
                            error            = "$_"
                            message          = "Update failed: $_. Previous version kept; local chat still running."
                        } | ConvertTo-Json -Compress
                        Write-PromptParleHttpResponse -Context $ctx -StatusCode 500 -ContentType 'application/json; charset=utf-8' -Body $err
                    }
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

                # Lightweight cloud proxies for local UI modals (JSON only — no portal HTML/SSR)
                if ($req.HttpMethod -eq 'GET' -and $path -eq '/api/usage') {
                    try {
                        $result = Invoke-PromptParleApi -Method GET -Path '/api/v1/usage?recent=5'
                        $json = ($result | ConvertTo-Json -Depth 8 -Compress)
                        Write-PromptParleHttpResponse -Context $ctx -ContentType 'application/json; charset=utf-8' -Body $json
                    } catch {
                        $err = @{ error = "$_" } | ConvertTo-Json -Compress
                        Write-PromptParleHttpResponse -Context $ctx -StatusCode 502 -ContentType 'application/json; charset=utf-8' -Body $err
                    }
                    continue
                }

                if ($req.HttpMethod -eq 'GET' -and $path -eq '/api/api-keys') {
                    try {
                        $result = Invoke-PromptParleApi -Method GET -Path '/api/v1/api-keys'
                        $json = ($result | ConvertTo-Json -Depth 8 -Compress)
                        Write-PromptParleHttpResponse -Context $ctx -ContentType 'application/json; charset=utf-8' -Body $json
                    } catch {
                        $err = @{ error = "$_" } | ConvertTo-Json -Compress
                        Write-PromptParleHttpResponse -Context $ctx -StatusCode 502 -ContentType 'application/json; charset=utf-8' -Body $err
                    }
                    continue
                }

                # Desktop entitlements + concurrent client seat (Free = 1)
                if ($req.HttpMethod -eq 'GET' -and $path -eq '/api/entitlements') {
                    try {
                        $clientId = Get-PromptParleDesktopClientId
                        $ver = try { Get-PromptParleClientVersion } catch { 'unknown' }
                        $hostName = if ($env:COMPUTERNAME) { $env:COMPUTERNAME } elseif ($env:HOSTNAME) { $env:HOSTNAME } else { 'desktop' }
                        $plat = if ($script:PromptParleIsWindows) { 'windows' } else { 'unix' }
                        $body = @{
                            client_id   = $clientId
                            hostname    = [string]$hostName
                            platform    = [string]$plat
                            app_version = [string]$ver
                        }
                        $result = Invoke-PromptParleApi -Method POST -Path '/api/v1/desktop/heartbeat' -Body $body
                        $json = ($result | ConvertTo-Json -Depth 8 -Compress)
                        Write-PromptParleHttpResponse -Context $ctx -ContentType 'application/json; charset=utf-8' -Body $json
                    } catch {
                        $msg = "$_"
                        $status = 502
                        $allowed = $true
                        if ($msg -match 'limit|client|seat|403|Forbidden') {
                            $status = 403
                            $allowed = $false
                        }
                        $err = @{
                            error                = $msg
                            allowed              = $allowed
                            project_pc           = $true
                            project_ssh          = $true
                            project_git          = $true
                            max_desktop_clients  = 1
                            message              = if (-not $allowed) { $msg } else { $null }
                        } | ConvertTo-Json -Compress
                        Write-PromptParleHttpResponse -Context $ctx -StatusCode $status -ContentType 'application/json; charset=utf-8' -Body $err
                    }
                    continue
                }

                if ($req.HttpMethod -eq 'GET' -and $path -eq '/api/session') {
                    try {
                        $st = Get-PromptParleSessionState
                        $ag = Get-PromptParleAgent -Name $st.active_agent
                        $ws = Get-PromptParleWorkspace
                        $cmdList = @()
                        if ($ag -and $ag.commands) {
                            foreach ($k in $ag.commands.Keys) { $cmdList += [string]$k }
                        }
                        $payload = @{
                            ok               = $true
                            active_agent     = $st.active_agent
                            provider         = $st.provider
                            profile          = $st.profile
                            dial             = [int]$st.dial
                            model            = $st.model
                            optimize_only    = [bool]$st.optimize_only
                            tools_enabled    = if ($null -ne (Get-PromptParleProp $st 'tools_enabled' $null)) { [bool]$st.tools_enabled } else { $true }
                            workspace_path   = [string]$ws.path
                            workspace_kind   = [string]$ws.kind
                            workspace_branch = $ws.branch
                            workspace_remote = $ws.remote
                            workspace_recent = @($ws.recent)
                            ssh_target       = [string]$ws.ssh_target
                            ssh_port         = [int]$ws.ssh_port
                            ssh_cwd          = [string](Get-PromptParleProp $ws 'ssh_cwd' '')
                            agent_name       = if ($ag) { $ag.name } else { $st.active_agent }
                            agent_system     = if ($ag) { $ag.system } else { '' }
                            agent_commands   = $cmdList
                        } | ConvertTo-Json -Depth 6 -Compress
                        Write-PromptParleHttpResponse -Context $ctx -ContentType 'application/json; charset=utf-8' -Body $payload
                    } catch {
                        $err = @{ ok = $false; error = "$_" } | ConvertTo-Json -Compress
                        Write-PromptParleHttpResponse -Context $ctx -StatusCode 500 -ContentType 'application/json; charset=utf-8' -Body $err
                    }
                    continue
                }

                # Local filesystem browser (this PC only — never sent to cloud)
                if ($req.HttpMethod -eq 'GET' -and $path -eq '/api/fs/list') {
                    try {
                        $q = [string]$req.Url.Query
                        $fsPath = ''
                        if ($q -and $q -match '(?:^|[?&])path=([^&]*)') {
                            $fsPath = [Uri]::UnescapeDataString(($Matches[1] -replace '\+', ' '))
                        }
                        $listing = Get-PromptParleFsList -Path $fsPath
                        $json = ($listing | ConvertTo-Json -Depth 6 -Compress)
                        Write-PromptParleHttpResponse -Context $ctx -ContentType 'application/json; charset=utf-8' -Body $json
                    } catch {
                        $err = @{ ok = $false; error = "$_" } | ConvertTo-Json -Compress
                        Write-PromptParleHttpResponse -Context $ctx -StatusCode 400 -ContentType 'application/json; charset=utf-8' -Body $err
                    }
                    continue
                }

                if ($req.HttpMethod -eq 'GET' -and $path -eq '/api/fs/roots') {
                    try {
                        $roots = @(Get-PromptParleFsRoots)
                        $payload = @{ ok = $true; roots = $roots } | ConvertTo-Json -Depth 5 -Compress
                        Write-PromptParleHttpResponse -Context $ctx -ContentType 'application/json; charset=utf-8' -Body $payload
                    } catch {
                        $err = @{ ok = $false; error = "$_" } | ConvertTo-Json -Compress
                        Write-PromptParleHttpResponse -Context $ctx -StatusCode 500 -ContentType 'application/json; charset=utf-8' -Body $err
                    }
                    continue
                }

                # SSH remote directory autocomplete (working-dir field + terminal)
                if ($req.HttpMethod -eq 'GET' -and $path -eq '/api/ssh/complete') {
                    try {
                        $q = [string]$req.Url.Query
                        $partial = ''
                        $tgtQ = ''
                        $portQ = 0
                        if ($q -and $q -match '(?:^|[?&])path=([^&]*)') {
                            $partial = [Uri]::UnescapeDataString(($Matches[1] -replace '\+', ' '))
                        }
                        if ($q -and $q -match '(?:^|[?&])target=([^&]*)') {
                            $tgtQ = [Uri]::UnescapeDataString(($Matches[1] -replace '\+', ' '))
                        }
                        if ($q -and $q -match '(?:^|[?&])port=(\d+)') {
                            try { $portQ = [int]$Matches[1] } catch { $portQ = 0 }
                        }
                        $paramsC = @{ Partial = $partial }
                        if ($tgtQ) { $paramsC.Target = $tgtQ }
                        if ($portQ -gt 0) { $paramsC.Port = $portQ }
                        $resultC = Get-PromptParleSshDirCompletions @paramsC
                        $jsonC = ($resultC | ConvertTo-Json -Depth 5 -Compress)
                        Write-PromptParleHttpResponse -Context $ctx -ContentType 'application/json; charset=utf-8' -Body $jsonC
                    } catch {
                        $err = @{ ok = $false; error = "$_"; dirs = @() } | ConvertTo-Json -Compress
                        Write-PromptParleHttpResponse -Context $ctx -StatusCode 400 -ContentType 'application/json; charset=utf-8' -Body $err
                    }
                    continue
                }

                # Desktop terminal panel (local workspace or SSH) — stays on this PC
                if ($req.HttpMethod -eq 'POST' -and $path -eq '/api/terminal') {
                    try {
                        $encT = $req.ContentEncoding
                        if (-not $encT) { $encT = [System.Text.Encoding]::UTF8 }
                        $readerT = New-Object System.IO.StreamReader($req.InputStream, $encT)
                        $rawT = $readerT.ReadToEnd()
                        $readerT.Close()
                        $bodyT = ConvertFrom-PromptParleJson -Json $rawT
                        $cmdT = ConvertTo-PromptParleSingleString (Get-PromptParleProp $bodyT 'command' '')
                        $tgtT = ConvertTo-PromptParleSingleString (Get-PromptParleProp $bodyT 'target' 'local')
                        if (-not $tgtT) { $tgtT = 'local' }
                        $tgtT = $tgtT.ToLowerInvariant()
                        if ($tgtT -ne 'ssh') { $tgtT = 'local' }
                        $resultT = Invoke-PromptParleTerminal -Command $cmdT -Target $tgtT
                        $jsonT = ($resultT | ConvertTo-Json -Depth 4 -Compress)
                        Write-PromptParleHttpResponse -Context $ctx -ContentType 'application/json; charset=utf-8' -Body $jsonT
                    } catch {
                        $err = @{ ok = $false; error = "$_"; text = "$_"; exit_code = 1 } | ConvertTo-Json -Compress
                        Write-PromptParleHttpResponse -Context $ctx -StatusCode 400 -ContentType 'application/json; charset=utf-8' -Body $err
                    }
                    continue
                }

                if (($req.HttpMethod -eq 'GET' -or $req.HttpMethod -eq 'POST') -and $path -eq '/api/workspace') {
                    try {
                        if ($req.HttpMethod -eq 'GET') {
                            $ws = Get-PromptParleWorkspace
                            $payload = @{
                                ok       = $true
                                path     = $ws.path
                                kind     = $ws.kind
                                exists   = $ws.exists
                                is_git   = $ws.is_git
                                branch   = $ws.branch
                                remote   = $ws.remote
                                recent   = @($ws.recent)
                            } | ConvertTo-Json -Depth 5 -Compress
                            Write-PromptParleHttpResponse -Context $ctx -ContentType 'application/json; charset=utf-8' -Body $payload
                        } else {
                            $encW = $req.ContentEncoding
                            if (-not $encW) { $encW = [System.Text.Encoding]::UTF8 }
                            $readerW = New-Object System.IO.StreamReader($req.InputStream, $encW)
                            $rawW = $readerW.ReadToEnd()
                            $readerW.Close()
                            $bodyW = ConvertFrom-PromptParleJson -Json $rawW
                            $action = ConvertTo-PromptParleSingleString (Get-PromptParleProp $bodyW 'action' 'set')
                            if (-not $action) { $action = 'set' }
                            if ($action -eq 'clear') {
                                Clear-PromptParleWorkspace
                                $payload = @{ ok = $true; path = ''; kind = 'none'; message = 'Workspace detached.' } | ConvertTo-Json -Compress
                            } else {
                                $wp = ConvertTo-PromptParleSingleString (Get-PromptParleProp $bodyW 'path' '')
                                if (-not $wp) { throw 'Missing path' }
                                $wsSet = Set-PromptParleWorkspace -Path $wp
                                $wsFull = Get-PromptParleWorkspace
                                $recentOut = @()
                                foreach ($r in @($wsSet.recent)) {
                                    $rs = ConvertTo-PromptParleSingleString $r
                                    if ($rs) { $recentOut += $rs }
                                }
                                $payload = @{
                                    ok      = $true
                                    path    = [string]$wsSet.path
                                    kind    = [string]$wsSet.kind
                                    is_git  = [bool]$wsSet.is_git
                                    branch  = $wsFull.branch
                                    remote  = $wsFull.remote
                                    recent  = $recentOut
                                    message = "Attached $($wsSet.path)"
                                } | ConvertTo-Json -Depth 5 -Compress
                            }
                            Write-PromptParleHttpResponse -Context $ctx -ContentType 'application/json; charset=utf-8' -Body $payload
                        }
                    } catch {
                        $err = @{ ok = $false; error = "$_" } | ConvertTo-Json -Compress
                        Write-PromptParleHttpResponse -Context $ctx -StatusCode 400 -ContentType 'application/json; charset=utf-8' -Body $err
                    }
                    continue
                }

                if ($req.HttpMethod -eq 'GET' -and $path -eq '/api/tools') {
                    try {
                        $tools = @(Get-PromptParleToolCatalog)
                        $items = @()
                        foreach ($t in $tools) {
                            $items += @{
                                id          = [string]$t.id
                                name        = [string]$t.name
                                category    = [string]$t.category
                                local       = [bool]$t.local
                                auto        = [bool]$t.auto
                                description = [string]$t.description
                            }
                        }
                        $payload = @{ ok = $true; tools = $items } | ConvertTo-Json -Depth 6 -Compress
                        Write-PromptParleHttpResponse -Context $ctx -ContentType 'application/json; charset=utf-8' -Body $payload
                    } catch {
                        $err = @{ ok = $false; error = "$_" } | ConvertTo-Json -Compress
                        Write-PromptParleHttpResponse -Context $ctx -StatusCode 500 -ContentType 'application/json; charset=utf-8' -Body $err
                    }
                    continue
                }

                if ($req.HttpMethod -eq 'POST' -and $path -eq '/api/tools/run') {
                    try {
                        $encT = $req.ContentEncoding
                        if (-not $encT) { $encT = [System.Text.Encoding]::UTF8 }
                        $readerT = New-Object System.IO.StreamReader($req.InputStream, $encT)
                        $rawT = $readerT.ReadToEnd()
                        $readerT.Close()
                        $bodyT = ConvertFrom-PromptParleJson -Json $rawT
                        $toolId = [string](Get-PromptParleProp $bodyT 'tool' (Get-PromptParleProp $bodyT 'id' ''))
                        if (-not $toolId) { throw 'Missing tool id' }
                        $textT = [string](Get-PromptParleProp $bodyT 'text' '')
                        $argT = [string](Get-PromptParleProp $bodyT 'arg' '')
                        $run = Invoke-PromptParleLocalTool -ToolId $toolId -Text $textT -Arg $argT
                        $payload = ($run | ConvertTo-Json -Depth 6 -Compress)
                        Write-PromptParleHttpResponse -Context $ctx -ContentType 'application/json; charset=utf-8' -Body $payload
                    } catch {
                        $err = @{ ok = $false; error = "$_" } | ConvertTo-Json -Compress
                        Write-PromptParleHttpResponse -Context $ctx -StatusCode 400 -ContentType 'application/json; charset=utf-8' -Body $err
                    }
                    continue
                }

                if ($req.HttpMethod -eq 'GET' -and $path -eq '/api/agents') {
                    try {
                        $list = @(Get-PromptParleAgentList)
                        $items = @()
                        foreach ($a in $list) {
                            $cmdList = @()
                            $cmdMap = [ordered]@{}
                            if ($a.commands) {
                                foreach ($k in $a.commands.Keys) {
                                    $cmdList += [string]$k
                                    $cmdMap[[string]$k] = [string]$a.commands[$k]
                                }
                            }
                            $toolList = @()
                            if ($a.tools) { foreach ($t in @($a.tools)) { if ($t) { $toolList += [string]$t } } }
                            $items += @{
                                id          = $a.id
                                name        = $a.name
                                description = $a.description
                                system      = $a.system
                                profile     = $a.profile
                                dial        = [int]$a.dial
                                commands    = $cmdList
                                command_map = $cmdMap
                                tools       = $toolList
                                builtin     = [bool](Get-PromptParleProp $a 'builtin' $false)
                            }
                        }
                        $payload = @{
                            ok           = $true
                            agents       = $items
                            active_agent = (Get-PromptParleActiveAgentId)
                            tools        = @(Get-PromptParleToolCatalog | ForEach-Object {
                                @{
                                    id = $_.id; name = $_.name; category = $_.category
                                    local = [bool]$_.local; auto = [bool]$_.auto
                                    description = $_.description
                                }
                            })
                        } | ConvertTo-Json -Depth 8 -Compress
                        Write-PromptParleHttpResponse -Context $ctx -ContentType 'application/json; charset=utf-8' -Body $payload
                    } catch {
                        $err = @{ ok = $false; error = "$_" } | ConvertTo-Json -Compress
                        Write-PromptParleHttpResponse -Context $ctx -StatusCode 500 -ContentType 'application/json; charset=utf-8' -Body $err
                    }
                    continue
                }

                if ($req.HttpMethod -eq 'POST' -and $path -eq '/api/agents') {
                    try {
                        $encA = $req.ContentEncoding
                        if (-not $encA) { $encA = [System.Text.Encoding]::UTF8 }
                        $readerA = New-Object System.IO.StreamReader($req.InputStream, $encA)
                        $rawA = $readerA.ReadToEnd()
                        $readerA.Close()
                        $bodyA = ConvertFrom-PromptParleJson -Json $rawA
                        $nameA = [string](Get-PromptParleProp $bodyA 'name' '')
                        if (-not $nameA) { throw 'Missing name' }
                        $idA = [string](Get-PromptParleProp $bodyA 'id' '')
                        $sysA = [string](Get-PromptParleProp $bodyA 'system' '')
                        $descA = [string](Get-PromptParleProp $bodyA 'description' '')
                        $profA = [string](Get-PromptParleProp $bodyA 'profile' 'general')
                        $dialA = 3
                        $dRaw = Get-PromptParleProp $bodyA 'dial' $null
                        if ($null -ne $dRaw) { try { $dialA = [int]$dRaw } catch { $dialA = 3 } }
                        $toolsA = @()
                        $toolsRaw = Get-PromptParleProp $bodyA 'tools' $null
                        if ($null -ne $toolsRaw) {
                            foreach ($t in @($toolsRaw)) { if ($t) { $toolsA += [string]$t } }
                        }
                        $cmds = @{}
                        $cmdRaw = Get-PromptParleProp $bodyA 'commands' $null
                        if ($null -eq $cmdRaw) { $cmdRaw = Get-PromptParleProp $bodyA 'command_map' $null }
                        if ($null -ne $cmdRaw) {
                            if ($cmdRaw -is [hashtable]) {
                                foreach ($k in $cmdRaw.Keys) { $cmds[[string]$k] = [string]$cmdRaw[$k] }
                            } else {
                                $cmdRaw.PSObject.Properties | ForEach-Object {
                                    $cmds[[string]$_.Name] = [string]$_.Value
                                }
                            }
                        }
                        # Optional slash command pairs: [{name,prompt}]
                        $cmdListRaw = Get-PromptParleProp $bodyA 'command_list' $null
                        if ($null -ne $cmdListRaw) {
                            foreach ($c in @($cmdListRaw)) {
                                $cn = [string](Get-PromptParleProp $c 'name' (Get-PromptParleProp $c 'id' ''))
                                $cp = [string](Get-PromptParleProp $c 'prompt' (Get-PromptParleProp $c 'text' ''))
                                if ($cn -and $cp) {
                                    $ck = ($cn.ToLowerInvariant() -replace '[^a-z0-9]+', '').Trim()
                                    if ($ck) { $cmds[$ck] = $cp }
                                }
                            }
                        }
                        $saveParams = @{
                            Name        = $nameA
                            System      = $sysA
                            Description = $descA
                            Profile     = $profA
                            Dial        = $dialA
                            Commands    = $cmds
                            Tools       = $toolsA
                        }
                        if ($idA) { $saveParams.Id = $idA }
                        $saved = Save-PromptParleAgent @saveParams
                        $activate = Get-PromptParleProp $bodyA 'activate' $false
                        if ($activate -eq $true) {
                            Set-PromptParleActiveAgent -Name $saved.id | Out-Null
                        }
                        $payload = @{
                            ok     = $true
                            agent  = @{
                                id          = $saved.id
                                name        = $saved.name
                                description = $saved.description
                                system      = $saved.system
                                profile     = $saved.profile
                                dial        = [int]$saved.dial
                                tools       = @($saved.tools)
                            }
                            active_agent = (Get-PromptParleActiveAgentId)
                            message = "Saved agent '$($saved.name)' ($($saved.id))"
                        } | ConvertTo-Json -Depth 6 -Compress
                        Write-PromptParleHttpResponse -Context $ctx -ContentType 'application/json; charset=utf-8' -Body $payload
                    } catch {
                        $err = @{ ok = $false; error = "$_" } | ConvertTo-Json -Compress
                        Write-PromptParleHttpResponse -Context $ctx -StatusCode 400 -ContentType 'application/json; charset=utf-8' -Body $err
                    }
                    continue
                }

                if ($req.HttpMethod -eq 'POST' -and $path -eq '/api/agents/optimize') {
                    try {
                        $encO = $req.ContentEncoding
                        if (-not $encO) { $encO = [System.Text.Encoding]::UTF8 }
                        $readerO = New-Object System.IO.StreamReader($req.InputStream, $encO)
                        $rawO = $readerO.ReadToEnd()
                        $readerO.Close()
                        $bodyO = ConvertFrom-PromptParleJson -Json $rawO
                        $toolsO = @()
                        $trO = Get-PromptParleProp $bodyO 'tools' $null
                        if ($null -ne $trO) { foreach ($t in @($trO)) { if ($t) { $toolsO += [string]$t } } }
                        $opt = Optimize-PromptParleAgent `
                            -Name ([string](Get-PromptParleProp $bodyO 'name' 'Custom agent')) `
                            -Description ([string](Get-PromptParleProp $bodyO 'description' '')) `
                            -System ([string](Get-PromptParleProp $bodyO 'system' '')) `
                            -Profile ([string](Get-PromptParleProp $bodyO 'profile' 'general')) `
                            -Dial $(
                                $d = Get-PromptParleProp $bodyO 'dial' 3
                                try { [int]$d } catch { 3 }
                            ) `
                            -Tools $toolsO
                        $payload = ($opt | ConvertTo-Json -Depth 8 -Compress)
                        Write-PromptParleHttpResponse -Context $ctx -ContentType 'application/json; charset=utf-8' -Body $payload
                    } catch {
                        $err = @{ ok = $false; error = "$_" } | ConvertTo-Json -Compress
                        Write-PromptParleHttpResponse -Context $ctx -StatusCode 400 -ContentType 'application/json; charset=utf-8' -Body $err
                    }
                    continue
                }

                if ($req.HttpMethod -eq 'DELETE' -and $path -eq '/api/agents') {
                    try {
                        $delId = [string]$req.QueryString['id']
                        if (-not $delId) { $delId = [string]$req.QueryString['name'] }
                        if (-not $delId) { throw 'Missing id query param' }
                        Remove-PromptParleAgent -Name $delId | Out-Null
                        $payload = @{
                            ok           = $true
                            message      = "Deleted agent '$delId'"
                            active_agent = (Get-PromptParleActiveAgentId)
                        } | ConvertTo-Json -Compress
                        Write-PromptParleHttpResponse -Context $ctx -ContentType 'application/json; charset=utf-8' -Body $payload
                    } catch {
                        $err = @{ ok = $false; error = "$_" } | ConvertTo-Json -Compress
                        Write-PromptParleHttpResponse -Context $ctx -StatusCode 400 -ContentType 'application/json; charset=utf-8' -Body $err
                    }
                    continue
                }

                if ($req.HttpMethod -eq 'POST' -and $path -eq '/api/command') {
                    try {
                        $encC = $req.ContentEncoding
                        if (-not $encC) { $encC = [System.Text.Encoding]::UTF8 }
                        $readerC = New-Object System.IO.StreamReader($req.InputStream, $encC)
                        $rawBodyC = $readerC.ReadToEnd()
                        $readerC.Close()
                        $bodyC = ConvertFrom-PromptParleJson -Json $rawBodyC
                        $lineC = [string](Get-PromptParleProp $bodyC 'line' (Get-PromptParleProp $bodyC 'command' ''))
                        if (-not $lineC) { throw 'Missing line (e.g. /help)' }
                        $provC = [string](Get-PromptParleProp $bodyC 'provider' '')
                        $profC = [string](Get-PromptParleProp $bodyC 'profile' '')
                        $dialRawC = Get-PromptParleProp $bodyC 'compression_level' (Get-PromptParleProp $bodyC 'dial' $null)
                        $dialC = -1
                        if ($null -ne $dialRawC) { try { $dialC = [int]$dialRawC } catch { $dialC = -1 } }
                        $optOnlyC = $false
                        $optFlagC = Get-PromptParleProp $bodyC 'optimize_only' (Get-PromptParleProp $bodyC 'optimizeOnly' $null)
                        if ($optFlagC -eq $true) { $optOnlyC = $true }
                        $toolsEnC = $null
                        $teFlagC = Get-PromptParleProp $bodyC 'tools_enabled' (Get-PromptParleProp $bodyC 'toolsEnabled' $null)
                        if ($null -ne $teFlagC) { $toolsEnC = [bool]$teFlagC }
                        $cmdParams = @{ Line = $lineC; OptimizeOnly = $optOnlyC }
                        if ($provC) { $cmdParams.Provider = $provC }
                        if ($profC) { $cmdParams.Profile = $profC }
                        if ($dialC -ge 1) { $cmdParams.Dial = $dialC }
                        if ($null -ne $toolsEnC) { $cmdParams.ToolsEnabled = $toolsEnC }
                        $resultC = Invoke-PromptParleSlashCommand @cmdParams
                        $jsonC = ($resultC | ConvertTo-Json -Depth 8 -Compress)
                        Write-PromptParleHttpResponse -Context $ctx -ContentType 'application/json; charset=utf-8' -Body $jsonC
                    } catch {
                        $err = @{ ok = $false; handled = $true; message = "$_"; error = "$_" } | ConvertTo-Json -Compress
                        Write-PromptParleHttpResponse -Context $ctx -StatusCode 400 -ContentType 'application/json; charset=utf-8' -Body $err
                    }
                    continue
                }

                if ($req.HttpMethod -eq 'POST' -and $path -eq '/api/chat') {
                    $enc = $req.ContentEncoding
                    if (-not $enc) { $enc = [System.Text.Encoding]::UTF8 }
                    $reader = New-Object System.IO.StreamReader($req.InputStream, $enc)
                    $rawBody = $reader.ReadToEnd()
                    $reader.Close()
                    try {
                        if ([string]::IsNullOrWhiteSpace($rawBody)) { throw 'Empty request body' }
                        $body = ConvertFrom-PromptParleJson -Json $rawBody
                        # StrictMode: never touch $body.foo if foo may be absent
                        $prompt = [string](Get-PromptParleProp $body 'prompt' '')
                        if (-not $prompt) { throw 'Missing prompt (type in the bottom box)' }
                        $provider = [string](Get-PromptParleProp $body 'provider' 'openai')
                        if (-not $provider) { $provider = 'openai' }
                        # Product 0.14: dial is the only aggressiveness knob (no agent/profile router)
                        $profile = 'general'
                        $dialRaw = Get-PromptParleProp $body 'compression_level' $null
                        if ($null -eq $dialRaw) { $dialRaw = Get-PromptParleProp $body 'compressionLevel' $null }
                        $dial = 3
                        if ($null -ne $dialRaw) {
                            try { $dial = [int]$dialRaw } catch { $dial = 3 }
                        }
                        if ($dial -lt 1) { $dial = 1 }
                        if ($dial -gt 5) { $dial = 5 }
                        $context = Get-PromptParleProp $body 'context' $null
                        if ($null -ne $context) { $context = [string]$context }
                        $optOnly = $false
                        $optFlag = Get-PromptParleProp $body 'optimize_only' $null
                        if ($null -eq $optFlag) { $optFlag = Get-PromptParleProp $body 'optimizeOnly' $null }
                        if ($optFlag -eq $true) { $optOnly = $true }

                        $images = @(ConvertTo-PromptParleImageList -Images (Get-PromptParleProp $body 'images' $null))

                        # Optional prior-turn history for [MEM] brief (UI multi-turn fidelity)
                        $histArr = @()
                        $histRaw = Get-PromptParleProp $body 'history' $null
                        if ($null -eq $histRaw) { $histRaw = Get-PromptParleProp $body 'History' $null }
                        if ($null -ne $histRaw) {
                            foreach ($h in @($histRaw)) {
                                if ($null -eq $h) { continue }
                                $hr = [string](Get-PromptParleProp $h 'role' (Get-PromptParleProp $h 'Role' 'user'))
                                $ht = [string](Get-PromptParleProp $h 'text' (Get-PromptParleProp $h 'content' (Get-PromptParleProp $h 'Content' '')))
                                if (-not $ht) { continue }
                                $histArr += [pscustomobject]@{ role = $hr; text = $ht }
                            }
                        }
                        $histText = [string](Get-PromptParleProp $body 'history_text' (Get-PromptParleProp $body 'historyText' ''))

                        # Session Tools (default ON) + dial: local prep before AI tokens
                        $localNotes = @()
                        $toolsEnChat = $true
                        $teBody = Get-PromptParleProp $body 'tools_enabled' (Get-PromptParleProp $body 'toolsEnabled' $null)
                        if ($null -ne $teBody) {
                            $toolsEnChat = [bool]$teBody
                        } else {
                            try {
                                $stChat = Get-PromptParleSessionState
                                if ($null -ne (Get-PromptParleProp $stChat 'tools_enabled' $null)) {
                                    $toolsEnChat = [bool]$stChat.tools_enabled
                                }
                            } catch { $toolsEnChat = $true }
                        }
                        # Persist tools toggle from UI each chat
                        try {
                            $stSave = Get-PromptParleSessionState
                            $stSave = New-PromptParleSessionSnapshot -Base $stSave -ToolsEnabled $toolsEnChat -Dial $dial -Profile $profile -Provider $provider -OptimizeOnly $optOnly
                            Save-PromptParleSessionState -State $stSave
                        } catch { }

                        # You → local prep → cloud optimize (dial) → model. No agent router.
                        $prep = $null
                        $groundingContext = if ($context) { [string]$context } else { '' }
                        try {
                            $prepParams = @{
                                Prompt       = $prompt
                                Context      = $(if ($context) { $context } else { '' })
                                ToolsEnabled = $toolsEnChat
                                Dial         = $dial
                                Profile      = $profile
                            }
                            if ($histArr.Count -gt 0) { $prepParams.History = $histArr }
                            elseif ($histText) { $prepParams.HistoryText = $histText }
                            $prep = Invoke-PromptParleAgentLocalPrep @prepParams
                            $prompt = [string]$prep.prompt
                            if ($null -ne $prep.context) { $context = [string]$prep.context }
                            if ($prep.notes) { $localNotes = @($localNotes) + @($prep.notes) }
                        } catch {
                            Write-Host ("  chat: local prep warning - {0}" -f $_) -ForegroundColor DarkYellow
                        }
                        # 0.20: freeze prep evidence for grounding/provenance post-pass
                        # (agent rounds may compress context; post-pass must still see OBSERVE/PROVENANCE)
                        $groundingContext = if ($context) { [string]$context } else { $groundingContext }
                        # Native system role (0.14.12+) — product brief + runtime stay out of user prompt / usage Before
                        $turnForRt = 'chat'
                        try { $turnForRt = Get-PromptParleTurnKind -Prompt $prompt -History $histArr } catch { }
                        $oblForRt = $null
                        try { $oblForRt = Get-PromptParleProp $prep 'obligation' $null } catch { $oblForRt = $null }
                        if (-not $oblForRt) {
                            try { $oblForRt = Resolve-PromptParleTurnObligation -Prompt $prompt -History $histArr } catch { }
                        }
                        $rtNote = 'Prep ran (0.20). Tags may include [PROJECT][CONN][SSH][MEM][ATTACH][WEB][OBSERVE][GROUNDING][PROVENANCE]. Doctrine: if client can obtain the fact, do not answer with the method; if document owed, emit ```file``` this turn; never invent product facts not in evidence.'
                        if ($oblForRt -and $oblForRt.mode -eq 'mutate') {
                            $rtNote = 'MUTATE TURN 0.20 · capability=obligation. Emit full-file ```apply path=...```; ```run``` only for pipeline cmds client executes. NEVER dump homework. No Ready/Name-it theater.'
                            $turnForRt = 'implement'
                        } elseif ($oblForRt -and $oblForRt.mode -eq 'deliver') {
                            $rtNote = 'DELIVER TURN 0.20 · document owed. Emit ```file name=…``` with FULL body NOW. Use [WEB]/[OBSERVE]/[ATTACH] as source — never [MEM] invention when observe evidence exists. Never "Generating now" without the file fence.'
                        } elseif ($oblForRt -and $oblForRt.mode -eq 'observe') {
                            $rtNote = 'OBSERVE TURN 0.20 · client already filled [OBSERVE]/[WEB] when possible. Present results only; invent nothing beyond evidence. NEVER ```run ls``` or search-homework as the answer.'
                        } elseif ($turnForRt -eq 'implement') {
                            $rtNote = 'IMPLEMENT TURN · capability=obligation. Emit full-file ```apply path=...```; ```run``` for migrate/build client executes. NEVER tell the user to run npx. No theater.'
                        } elseif ($turnForRt -eq 'question') {
                            $rtNote = 'QUESTION TURN 0.20. Answer from [PROJECT]/[OBSERVE]/[WEB]/[PROVENANCE] evidence first. Client-first observe already ran when applicable — do not answer with methods/commands. Never invent capabilities.'
                        }
                        if ($groundingContext -match '(?m)\[PROVENANCE\]') {
                            $rtNote = $rtNote + ' PROVENANCE OWED: report client YES/NO on-source and prior-assistant origin. Never only "nowhere".'
                        }
                        # Document turns: this-turn attachment beats prior MEM summaries
                        try {
                            $ctxHasAttach = $context -and ($context -match '(?m)^\[ATTACH\]' -or $context -match '===== FILE:')
                            $prHasAttach = $prompt -match '\[ATTACHED THIS TURN'
                            if ($ctxHasAttach -or $prHasAttach) {
                                $rtNote = $rtNote + ' ATTACH PRIMARY: summarize/create deliverables from THIS turn FILE only. Do not reuse prior [MEM] document topic or prior executive summary when a new file is attached.'
                            }
                        } catch { }
                        if ($localNotes -and $localNotes.Count -gt 0) {
                            $rtNote = $rtNote + ' Notes: ' + (($localNotes | Select-Object -First 8) -join ',') + '.'
                        }
                        $frame = Get-PromptParleChatFraming -Prompt $prompt -RuntimeNote $rtNote

                        $ctxLen = if ($context) { $context.Length } else { 0 }
                        Write-Host ("  chat: provider={0} profile={1} dial={2} tools={3} optimize_only={4} prompt={5}c system={6}c context={7}c images={8} local_notes={9}" -f `
                            $provider, $profile, $dial, $toolsEnChat, $optOnly, $frame.Prompt.Length, $frame.System.Length, $ctxLen, $images.Count, $localNotes.Count) -ForegroundColor DarkGray

                        $params = @{
                            Prompt            = [string]$frame.Prompt
                            System            = [string]$frame.System
                            Runtime           = [string]$frame.Runtime
                            Provider          = $provider
                            Profile           = $profile
                            CompressionLevel  = $dial
                        }
                        # Pass as single string - never as char-unrolled array
                        if ($context) { $params.Context = [string]$context }
                        if ($optOnly) { $params.OptimizeOnly = $true }
                        if ($images.Count -gt 0) { $params.Images = $images }

                        # 0.19: token-first brain+hands agent loop
                        $result = Invoke-PromptParleAgentTurn @params
                        # Normalize metadata keys for the browser UI (always snake_case numbers)
                        $metaIn = Get-PromptParleProp $result 'metadata'
                        if ($null -eq $metaIn) { $metaIn = Get-PromptParleProp $result 'Metadata' }
                        $metaOut = $null
                        if ($null -ne $metaIn) {
                            $origT = Get-PromptParleProp $metaIn 'original_tokens'
                            if ($null -eq $origT) { $origT = Get-PromptParleProp $metaIn 'originalTokens' }
                            $optT = Get-PromptParleProp $metaIn 'optimized_tokens'
                            if ($null -eq $optT) { $optT = Get-PromptParleProp $metaIn 'optimizedTokens' }
                            $pctT = Get-PromptParleProp $metaIn 'token_reduction_percent'
                            if ($null -eq $pctT) { $pctT = Get-PromptParleProp $metaIn 'tokenReductionPercent' }
                            $dialT = Get-PromptParleProp $metaIn 'compression_level'
                            if ($null -eq $dialT) { $dialT = Get-PromptParleProp $metaIn 'compressionLevel' }
                            $metaOut = [ordered]@{
                                original_tokens         = if ($null -ne $origT) { [int]$origT } else { 0 }
                                optimized_tokens        = if ($null -ne $optT) { [int]$optT } else { 0 }
                                token_reduction_percent = if ($null -ne $pctT) { [int]$pctT } else { 0 }
                                tokens_saved            = 0
                                expanded                = $false
                                provider                = [string](Get-PromptParleProp $metaIn 'provider' '')
                                model                   = [string](Get-PromptParleProp $metaIn 'model' '')
                                optimization_profile    = [string](Get-PromptParleProp $metaIn 'optimization_profile' (Get-PromptParleProp $metaIn 'optimizationProfile' ''))
                                compression_level       = if ($null -ne $dialT) { [int]$dialT } else { $dial }
                                strategy                = [string](Get-PromptParleProp $metaIn 'strategy' '')
                                secrets_masked          = [bool](Get-PromptParleProp $metaIn 'secrets_masked' $false)
                                notes                   = @(Get-PromptParleProp $metaIn 'notes' @())
                                signals                 = Get-PromptParleProp $metaIn 'signals' @{}
                                image_count             = 0
                                local_tools             = @($localNotes)
                            }
                            $imgC = Get-PromptParleProp $metaIn 'image_count'
                            if ($null -eq $imgC) { $imgC = Get-PromptParleProp $metaIn 'imageCount' }
                            if ($null -ne $imgC) { $metaOut.image_count = [int]$imgC }
                            $expF = Get-PromptParleProp $metaIn 'expanded'
                            if ($null -ne $expF) { $metaOut.expanded = [bool]$expF }
                            elseif ($metaOut.optimized_tokens -gt $metaOut.original_tokens) { $metaOut.expanded = $true }
                            $metaOut.tokens_saved = [Math]::Max(0, $metaOut.original_tokens - $metaOut.optimized_tokens)
                            if ($metaOut.token_reduction_percent -eq 0 -and $metaOut.original_tokens -gt 0 -and -not $metaOut.expanded) {
                                $metaOut.token_reduction_percent = [int][Math]::Round(100.0 * $metaOut.tokens_saved / $metaOut.original_tokens)
                            }
                            if ($localNotes -and $localNotes.Count -gt 0) {
                                $mergedNotes = @()
                                foreach ($n in @($metaOut.notes)) { if ($n) { $mergedNotes += [string]$n } }
                                foreach ($n in @($localNotes)) { if ($n) { $mergedNotes += [string]$n } }
                                $metaOut.notes = $mergedNotes
                            }
                            try {
                                $ag = Get-PromptParleProp $result 'agent' $null
                                if ($ag) {
                                    $metaOut.agent_rounds = [int](Get-PromptParleProp $ag 'agent_rounds' 0)
                                    $metaOut.hands_count = [int](Get-PromptParleProp $ag 'hands_count' 0)
                                    $metaOut.hands_tools = @(Get-PromptParleProp $ag 'hands_tools' @())
                                    $metaOut.architecture = [string](Get-PromptParleProp $ag 'architecture' '0.19-brain-hands')
                                    $sumO = Get-PromptParleProp $ag 'tokens_sum_original' $null
                                    $sumZ = Get-PromptParleProp $ag 'tokens_sum_optimized' $null
                                    if ($null -ne $sumO) {
                                        $metaOut.original_tokens = [int]$sumO
                                        $metaOut.tokens_sum_original = [int]$sumO
                                    }
                                    if ($null -ne $sumZ) {
                                        $metaOut.optimized_tokens = [int]$sumZ
                                        $metaOut.tokens_sum_optimized = [int]$sumZ
                                    }
                                    if ($metaOut.original_tokens -gt 0) {
                                        $metaOut.tokens_saved = [Math]::Max(0, $metaOut.original_tokens - $metaOut.optimized_tokens)
                                        $metaOut.token_reduction_percent = [int][Math]::Round(100.0 * $metaOut.tokens_saved / $metaOut.original_tokens)
                                    }
                                }
                            } catch { }
                        }
                        $respText = [string](Get-PromptParleProp $result 'response' (Get-PromptParleProp $result 'Response' ''))
                        # 0.16.1: always run implement pipeline post-pass when implement OR any apply/run/homework signal
                        $applyInfo = $null
                        $pipeTrigger = $false
                        if ($respText) {
                            if ($turnForRt -eq 'implement') { $pipeTrigger = $true }
                            elseif ($respText -match '(?m)```apply\s+path' -or $respText -match '(?m)```run\b') { $pipeTrigger = $true }
                            elseif ($respText -match '(?i)\b(run this|please run|npx prisma|npm run (build|test))\b') { $pipeTrigger = $true }
                        }
                        if ($pipeTrigger) {
                            try {
                                $applyInfo = Invoke-PromptParleApplyResponseBlocks -ResponseText $respText -TurnKind $turnForRt
                                if ($applyInfo -and $applyInfo.text) { $respText = [string]$applyInfo.text }
                                if ($applyInfo -and $applyInfo.count -gt 0) {
                                    Write-Host ("  chat: applied {0} file(s) via SSH" -f $applyInfo.count) -ForegroundColor Green
                                    if ($metaOut) {
                                        $metaOut.applied_files = @($applyInfo.applied)
                                        $metaOut.applied_count = [int]$applyInfo.count
                                    }
                                }
                                if ($applyInfo -and $applyInfo.run_count -gt 0) {
                                    Write-Host ("  chat: ran {0} remote command(s)" -f $applyInfo.run_count) -ForegroundColor Cyan
                                    if ($metaOut) {
                                        $metaOut.run_count = [int]$applyInfo.run_count
                                        $metaOut.runs = @($applyInfo.runs | ForEach-Object {
                                            [ordered]@{ command = $_.command; exit_code = $_.exit_code; ok = [bool]$_.ok }
                                        })
                                    }
                                }
                                if ($applyInfo -and $applyInfo.homework -and $applyInfo.homework.Count -gt 0) {
                                    Write-Host ("  chat: intercepted {0} homework command(s)" -f $applyInfo.homework.Count) -ForegroundColor Magenta
                                    if ($metaOut) { $metaOut.homework_intercepted = @($applyInfo.homework) }
                                }
                                if ($applyInfo -and $applyInfo.fail_closed) {
                                    Write-Host '  chat: FAIL-CLOSED implement turn (no apply/run)' -ForegroundColor Yellow
                                    if ($metaOut) { $metaOut.fail_closed = $true }
                                }
                                if ($applyInfo -and $applyInfo.errors -and $applyInfo.errors.Count -gt 0) {
                                    Write-Host ("  chat: pipeline errors: {0}" -f ($applyInfo.errors -join '; ')) -ForegroundColor Yellow
                                }
                            } catch {
                                Write-Host ("  chat: implement pipeline failed: {0}" -f $_) -ForegroundColor Yellow
                                $respText = $respText + "`n`n**Implement pipeline failed:** $_"
                            }
                        }
                        # 0.17/0.18: document deliverables — ```file name=Report.docx``` → real file + download URL
                        $deliverInfo = $null
                        if ($respText -and ($respText -match '(?m)```(?:file|deliver)\s+')) {
                            try {
                                $deliverInfo = Invoke-PromptParleDeliverResponseBlocks -ResponseText $respText
                                if ($deliverInfo -and $deliverInfo.text) { $respText = [string]$deliverInfo.text }
                                if ($deliverInfo -and $deliverInfo.count -gt 0) {
                                    Write-Host ("  chat: delivered {0} downloadable file(s)" -f $deliverInfo.count) -ForegroundColor Green
                                    if ($metaOut) {
                                        $metaOut.exports = @($deliverInfo.exports | ForEach-Object {
                                            [ordered]@{
                                                name         = $_.name
                                                url          = $_.url
                                                download_url = $_.download_url
                                                bytes        = $_.bytes
                                                content_type = $_.content_type
                                            }
                                        })
                                        $metaOut.export_count = [int]$deliverInfo.count
                                    }
                                }
                                if ($deliverInfo -and $deliverInfo.errors -and $deliverInfo.errors.Count -gt 0) {
                                    Write-Host ("  chat: deliver errors: {0}" -f ($deliverInfo.errors -join '; ')) -ForegroundColor Yellow
                                }
                            } catch {
                                Write-Host ("  chat: deliver pipeline failed: {0}" -f $_) -ForegroundColor Yellow
                                $respText = $respText + "`n`n**Document deliver failed:** $_"
                            }
                        }
                        # 0.18: deliver fail-closed when document was owed but no export
                        try {
                            $expN = 0
                            if ($deliverInfo) { $expN = [int]$deliverInfo.count }
                            $oweDeliver = $false
                            if ($oblForRt) { $oweDeliver = Test-PromptParleDeliverOwed -Obligation $oblForRt -ResponseText $respText }
                            if ($oweDeliver) {
                                $fc = Invoke-PromptParleDeliverFailClosed -ResponseText $respText -ExportCount $expN
                                if ($fc.fail_closed) {
                                    $respText = [string]$fc.text
                                    Write-Host '  chat: FAIL-CLOSED deliver turn (no file artifact)' -ForegroundColor Yellow
                                    if ($metaOut) { $metaOut.deliver_fail_closed = $true }
                                }
                            }
                            # sticky open obligation update
                            $appN = 0; $runN = 0
                            if ($applyInfo) {
                                try { $appN = [int]$applyInfo.count } catch { }
                                try { $runN = [int]$applyInfo.run_count } catch { }
                            }
                            if ($oblForRt) {
                                Update-PromptParleOpenObligationFromTurn -Obligation $oblForRt -ResponseText $respText -ExportCount $expN -ApplyCount $appN -RunCount $runN
                            }
                        } catch {
                            Write-Host ("  chat: obligation post-pass warning: {0}" -f $_) -ForegroundColor DarkYellow
                        }
                        # 0.20/0.21: provenance fail-closed + quality gate (BS detector/corrector, 0 AI tokens)
                        try {
                            $gctx = if ($groundingContext) { [string]$groundingContext } elseif ($context) { [string]$context } else { '' }
                            try {
                                $evFromAgent = Get-PromptParleProp $result 'evidence_context' $null
                                if ($evFromAgent -and [string]$evFromAgent) { $gctx = [string]$evFromAgent }
                            } catch { }
                            $pp = Invoke-PromptParleProvenancePostPass -ResponseText $respText -Context $gctx
                            if ($pp.applied) {
                                $respText = [string]$pp.text
                                Write-Host '  chat: provenance FAIL-CLOSED (client origin facts appended)' -ForegroundColor Yellow
                                if ($metaOut) {
                                    $metaOut.provenance_fail_closed = $true
                                    $metaOut.provenance_reason = [string]$pp.reason
                                }
                            }
                            # Quality gate supersedes separate grounding banner (includes claim score + soft-correct)
                            $qg = Invoke-PromptParleQualityGate -ResponseText $respText -Context $gctx
                            if ($qg.applied) {
                                $respText = [string]$qg.text
                                Write-Host ("  chat: quality gate {0}% ({1} supported, {2} unverified, corrected={3})" -f `
                                    $qg.score_pct, $qg.supported, $qg.unsupported, $qg.corrected) -ForegroundColor Yellow
                                if ($metaOut) {
                                    $metaOut.quality_gate = $true
                                    $metaOut.quality_score_pct = [int]$qg.score_pct
                                    $metaOut.quality_supported = [int]$qg.supported
                                    $metaOut.quality_partial = [int]$qg.partial
                                    $metaOut.quality_unsupported = [int]$qg.unsupported
                                    $metaOut.quality_corrected = [bool]$qg.corrected
                                    $metaOut.quality_reason = [string]$qg.reason
                                    try {
                                        $metaOut.quality_claims = @($qg.claims | ForEach-Object {
                                            [ordered]@{ claim = [string]$_.claim; status = [string]$_.status }
                                        })
                                    } catch { }
                                }
                            } else {
                                # Fallback: thin grounding flags when gate had nothing to score
                                $gp = Invoke-PromptParleGroundingPostPass -ResponseText $respText -Context $gctx
                                if ($gp.applied) {
                                    $respText = [string]$gp.text
                                    Write-Host ("  chat: grounding flagged {0} phrase(s)" -f $gp.flagged.Count) -ForegroundColor Yellow
                                    if ($metaOut) {
                                        $metaOut.grounding_flagged = @($gp.flagged)
                                        $metaOut.grounding_audit = $true
                                    }
                                }
                            }
                        } catch {
                            Write-Host ("  chat: quality/provenance post-pass warning: {0}" -f $_) -ForegroundColor DarkYellow
                        }
                        $payload = [ordered]@{
                            response         = $respText
                            optimized_prompt = Get-PromptParleProp $result 'optimized_prompt' (Get-PromptParleProp $result 'OptimizedPrompt' $null)
                            metadata         = $metaOut
                        }
                        # Keep error field if present
                        $errField = Get-PromptParleProp $result 'error'
                        if ($errField) { $payload.error = [string]$errField }
                        $json = ($payload | ConvertTo-Json -Depth 10 -Compress)
                        Write-PromptParleHttpResponse -Context $ctx -ContentType 'application/json; charset=utf-8' -Body $json
                        if ($metaOut) {
                            Write-Host ("  chat: ok  {0} → {1} tokens (−{2}%) dial={3} strat={4}" -f `
                                $metaOut.original_tokens, $metaOut.optimized_tokens, $metaOut.token_reduction_percent, `
                                $metaOut.compression_level, $metaOut.strategy) -ForegroundColor DarkGreen
                        } else {
                            Write-Host '  chat: ok (no metadata)' -ForegroundColor DarkGreen
                        }
                    } catch {
                        Write-Host ("  chat: error - {0}" -f $_) -ForegroundColor Red
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
        $exitAfter = $false
        try {
            $gv = Get-Variable -Name PromptParleExitProcessAfterStop -Scope Script -ErrorAction SilentlyContinue
            if ($null -ne $gv) { $exitAfter = [bool]$gv.Value }
        } catch { $exitAfter = $false }
        try { $script:PromptParleExitProcessAfterStop = $false } catch { }
        if ($exitAfter) {
            Write-Host 'Local PromptParle server stopped — update handoff complete.' -ForegroundColor Green
            Write-Host 'Closing this window (new server is in the other PowerShell window)...' -ForegroundColor Cyan
            Start-Sleep -Milliseconds 400
            # Hard exit so the console window closes (return alone leaves an idle PS window)
            try {
                [System.Environment]::Exit(0)
            } catch {
                exit 0
            }
        }
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
    $sessionDial = 3
    $sessionContext = $null
    $optimizeOnlyNext = $false
    # Restore last agent session if present
    try {
        $saved = Get-PromptParleSessionState
        if ($saved.profile) { $sessionProfile = [string]$saved.profile }
        if ($saved.dial) { $sessionDial = [int]$saved.dial }
        if ($saved.provider -and -not $Provider) { $sessionProvider = [string]$saved.provider }
    } catch { }

    Write-Host ''
    Write-Host ("Ready. Talking to {0}." -f $selected.Name) -ForegroundColor Green
    Write-Host 'Type a message, /help, /dial 1-5, /status …  /quit to leave. (Optimizer always on; dial = shrink.)' -ForegroundColor DarkGray
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

            # CLI-only context helpers
            if ($cmd -eq '/browser') {
                Write-Host 'Start a second window and run:  pp' -ForegroundColor Cyan
                continue
            }
            if ($cmd -eq '/model') {
                if ($arg) { $sessionModel = $arg; Write-Host ("Model set to {0}." -f $sessionModel) -ForegroundColor Green }
                else { $sessionModel = $null; Write-Host 'Model cleared (provider default).' -ForegroundColor Green }
                continue
            }
            if ($cmd -eq '/context') {
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
            if ($cmd -eq '/file') {
                if (-not $arg) { Write-Host 'Usage: /file C:\path\to\file.txt' -ForegroundColor Yellow; continue }
                if (-not (Test-Path -LiteralPath $arg)) { Write-Host "File not found: $arg" -ForegroundColor Red; continue }
                try {
                    $rawFile = Get-Content -LiteralPath $arg -Raw -ErrorAction Stop
                    $leaf = Split-Path -Leaf $arg
                    $tagged = "===== FILE: $leaf =====`n$rawFile"
                    if ($sessionContext) { $sessionContext = "$sessionContext`n`n$tagged" }
                    else { $sessionContext = $tagged }
                    Write-Host ("Loaded $leaf ({0} chars)." -f $rawFile.Length) -ForegroundColor Green
                } catch { Write-Host "Could not read file: $_" -ForegroundColor Red }
                continue
            }
            if ($cmd -eq '/clearcontext') {
                $sessionContext = $null
                Write-Host 'Context cleared.' -ForegroundColor Green
                continue
            }

            # Shared slash router (agents, dial, profile, help, …)
            $cmdLine = $trimmed
            if ($cmd -eq '/dial' -and -not $arg) { $cmdLine = "/dial $sessionDial" }
            $r = Invoke-PromptParleSlashCommand -Line $cmdLine -Provider $sessionProvider -Profile $sessionProfile -Dial $sessionDial -OptimizeOnly $optimizeOnlyNext
            if ($r.session) {
                if ($r.session.provider) { $sessionProvider = [string]$r.session.provider }
                if ($r.session.profile) { $sessionProfile = [string]$r.session.profile }
                if ($null -ne $r.session.dial) { $sessionDial = [int]$r.session.dial }
                if ($null -ne $r.session.optimize_only) { $optimizeOnlyNext = [bool]$r.session.optimize_only }
            }
            if ($r.message) { Write-Host $r.message -ForegroundColor Cyan }
            if ($r.quit) { return }
            if ($r.clear) { Clear-Host; continue }
            if ($r.send -and $r.prompt) {
                $trimmed = [string]$r.prompt
            } else {
                continue
            }
        }

        Write-Host 'thinking...' -ForegroundColor DarkGray
        try {
            $cliCtx = if ($sessionContext) { [string]$sessionContext } else { '' }
            # 0.14: dial-only optimize path; no agent turn-lens
            $sessionProfile = 'general'
            try {
                $cliPrepParams = @{
                    Prompt       = $trimmed
                    Context      = $cliCtx
                    Dial         = $sessionDial
                    Profile      = $sessionProfile
                    ToolsEnabled = $true
                }
                $cliPrep = Invoke-PromptParleAgentLocalPrep @cliPrepParams
                $trimmed = [string]$cliPrep.prompt
                if ($null -ne $cliPrep.context) { $cliCtx = [string]$cliPrep.context }
                if ($cliPrep.notes) {
                    Write-Host ("  local: {0}" -f ($cliPrep.notes -join ', ')) -ForegroundColor DarkGray
                }
            } catch {
                Write-Host ("  local prep warning: {0}" -f $_) -ForegroundColor DarkYellow
            }
            $cliGroundingCtx = if ($cliCtx) { [string]$cliCtx } else { '' }
            $cliRt = 'Prep ran. AGENT 0.20 token-first brain+hands+grounding. [PROJECT][CONN][SSH][HANDS][PROVENANCE] when present.'
            $cliFrame = Get-PromptParleChatFraming -Prompt $trimmed -RuntimeNote $cliRt
            $params = @{
                Prompt           = [string]$cliFrame.Prompt
                System           = [string]$cliFrame.System
                Runtime          = [string]$cliFrame.Runtime
                Provider         = $sessionProvider
                Profile          = $sessionProfile
                CompressionLevel = $sessionDial
            }
            if ($sessionModel) { $params.Model = $sessionModel }
            if ($cliCtx) { $params.Context = [string]$cliCtx }
            if ($optimizeOnlyNext) {
                $params.OptimizeOnly = $true
                $optimizeOnlyNext = $false
            }

            $result = Invoke-PromptParleAgentTurn @params

            $isOpt = $false
            try { $isOpt = [bool](Get-PromptParleProp $result 'OptimizeOnly' $false) } catch { }
            if (-not $isOpt) {
                try { $isOpt = [bool](Get-PromptParleProp (Get-PromptParleProp $result 'metadata' @{}) 'optimize_only' $false) } catch { }
            }
            if ($isOpt -or $params.ContainsKey('OptimizeOnly')) {
                Write-Host 'optimized prompt>' -ForegroundColor Cyan
                $op = Get-PromptParleProp $result 'OptimizedPrompt' (Get-PromptParleProp $result 'optimized_prompt' '')
                Write-Host $op
            } else {
                Write-Host ("{0}>" -f $sessionProvider) -ForegroundColor Magenta
                $txt = [string](Get-PromptParleProp $result 'response' (Get-PromptParleProp $result 'Response' ''))
                try {
                    $gctxCli = $cliGroundingCtx
                    $evCli = Get-PromptParleProp $result 'evidence_context' $null
                    if ($evCli) { $gctxCli = [string]$evCli }
                    $ppCli = Invoke-PromptParleProvenancePostPass -ResponseText $txt -Context $gctxCli
                    if ($ppCli.applied) { $txt = [string]$ppCli.text; Write-Host '  provenance: fail-closed' -ForegroundColor Yellow }
                    $qgCli = Invoke-PromptParleQualityGate -ResponseText $txt -Context $gctxCli
                    if ($qgCli.applied) {
                        $txt = [string]$qgCli.text
                        Write-Host ("  quality: {0}% supported={1} unverified={2} corrected={3}" -f `
                            $qgCli.score_pct, $qgCli.supported, $qgCli.unsupported, $qgCli.corrected) -ForegroundColor Yellow
                    } else {
                        $gpCli = Invoke-PromptParleGroundingPostPass -ResponseText $txt -Context $gctxCli
                        if ($gpCli.applied) { $txt = [string]$gpCli.text; Write-Host ("  grounding: {0} flag(s)" -f $gpCli.flagged.Count) -ForegroundColor Yellow }
                    }
                } catch { }
                Write-Host $txt
                $ag = Get-PromptParleProp $result 'agent' $null
                if ($ag) {
                    Write-Host ("  agent: rounds={0} hands={1}" -f (Get-PromptParleProp $ag 'agent_rounds' 0), (Get-PromptParleProp $ag 'hands_count' 0)) -ForegroundColor DarkGray
                }
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
    'Uninstall-PromptParle',
    'Get-PromptParleClientVersion',
    'Get-PromptParleUpdateStatus',
    'Update-PromptParleClient',
    'Get-PromptParleAgent',
    'Get-PromptParleAgentList',
    'Save-PromptParleAgent',
    'Remove-PromptParleAgent',
    'Set-PromptParleActiveAgent',
    'Get-PromptParleToolCatalog',
    'Invoke-PromptParleLocalTool',
    'Invoke-PromptParleAgentLocalPrep',
    'Resolve-PromptParleTurnLens',
    'Get-PromptParleDeterministicLens',
    'Test-PromptParleAutoRouterAgent',
    'Get-PromptParlePromptIntent',
    'Optimize-PromptParleAgent',
    'Invoke-PromptParleSlashCommand',
    'Get-PromptParleWorkspace',
    'Set-PromptParleWorkspace',
    'Clear-PromptParleWorkspace',
    'Get-PromptParleGitHubStatusText',
    'Set-PromptParleSshTarget',
    'Clear-PromptParleSshTarget',
    'Invoke-PromptParleSsh',
    'Test-PromptParleSshWorkingDirectory',
    'Get-PromptParleSshDirCompletions',
    'Invoke-PromptParleTerminal',
    'Invoke-PromptParleGitClone'
) -Alias @(
    'pp',
    'promptparle'
)
