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
      Normalize UI/API image objects into API-shaped hashtables.
    #>
    param($Images)

    $out = New-Object System.Collections.Generic.List[hashtable]
    if ($null -eq $Images) { return @() }

    $items = @($Images)
    foreach ($img in $items) {
        if ($null -eq $img) { continue }
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
    return ,$out.ToArray()
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
        # Avoid silent hangs in local UI when the cloud API is slow/unreachable
        # (vision + large context can take longer than plain text)
        TimeoutSec  = 180
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
        [string]$Description = ''
    )
    if ($Dial -lt 1) { $Dial = 1 }
    if ($Dial -gt 5) { $Dial = 5 }
    if (-not $Commands) { $Commands = @{} }
    return [pscustomobject]@{
        id          = $Id
        name        = $Name
        description = $Description
        system      = $System
        profile     = $Profile
        dial        = $Dial
        commands    = $Commands
        tools       = @('files', 'workspace', 'git', 'ssh')
        updated_at  = (Get-Date).ToString('o')
    }
}

function Initialize-PromptParleDefaultAgents {
    $dir = Get-PromptParleAgentsDir
    $defaults = @(
        (New-PromptParleAgentObject -Id 'default' -Name 'Default' -Description 'General assistant' -Profile 'general' -Dial 3 -System ''),
        (New-PromptParleAgentObject -Id 'security' -Name 'Security reviewer' -Description 'Hostile security review' -Profile 'security-review' -Dial 3 `
            -System 'You are a hostile security reviewer. Prioritize risk, exploitability, and concrete fixes. Prefer evidence from the attached material. Do not invent findings.' `
            -Commands @{ audit = 'Find the highest risk items and recommend actions with severity.'; threats = 'Map attack surface and threat scenarios from the material.' }),
        (New-PromptParleAgentObject -Id 'docs' -Name 'Doc analyst' -Description 'Document coverage + obligations' -Profile 'documentation' -Dial 3 `
            -System 'You are a careful document analyst. Preserve structure and obligations. Lead with the most useful findings, then cover gaps.' `
            -Commands @{ summary = 'Summarize with section coverage and hard requirements.'; risks = 'Extract risks, must/shall obligations, and deadlines.' }),
        (New-PromptParleAgentObject -Id 'code' -Name 'Code reviewer' -Description 'Code-focused review' -Profile 'developer' -Dial 2 `
            -System 'You are a senior code reviewer. Focus on bugs, security, and maintainability. Cite symbols and files when possible.' `
            -Commands @{ review = 'Review the attached code for bugs, risks, and improvements.'; explain = 'Explain the attached code structure and control flow.' })
    )
    foreach ($a in $defaults) {
        $path = Join-Path $dir ($a.id + '.json')
        if (-not (Test-Path -LiteralPath $path)) {
            ($a | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $path -Encoding UTF8
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
        return [pscustomobject]@{
            id          = $id
            name        = [string](Get-PromptParleProp $obj 'name' $id)
            description = [string](Get-PromptParleProp $obj 'description' '')
            system      = [string](Get-PromptParleProp $obj 'system' '')
            profile     = [string](Get-PromptParleProp $obj 'profile' 'general')
            dial        = $dial
            commands    = $cmds
            tools       = @(Get-PromptParleProp $obj 'tools' @('files'))
            path        = $Path
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
      Create or update a local agent definition.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [string]$System = '',
        [string]$Profile = 'general',
        [ValidateRange(1, 5)][int]$Dial = 3,
        [hashtable]$Commands,
        [string]$Description = '',
        [string]$Id
    )
    Initialize-PromptParleDefaultAgents
    if (-not $Id) { $Id = ConvertTo-PromptParleAgentId $Name }
    if (-not $Commands) { $Commands = @{} }
    $agent = New-PromptParleAgentObject -Id $Id -Name $Name -System $System -Profile $Profile -Dial $Dial -Commands $Commands -Description $Description
    $path = Join-Path (Get-PromptParleAgentsDir) ($Id + '.json')
    # Convert commands hashtable cleanly
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
        tools       = @('files')
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
            if ($id) { return [string]$id }
        } catch { }
    }
    return 'default'
}

function Get-PromptParleSessionState {
    $path = Get-PromptParleSessionStatePath
    $state = [ordered]@{
        active_agent      = 'default'
        provider          = 'openai'
        profile           = 'general'
        dial              = 3
        model             = $null
        optimize_only     = $false
        workspace_path    = ''
        workspace_kind    = 'none'
        workspace_recent  = @()
        ssh_target        = ''
        ssh_port          = 22
    }
    if (Test-Path -LiteralPath $path) {
        try {
            $s = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
            foreach ($k in @('active_agent', 'provider', 'profile', 'model', 'workspace_path', 'workspace_kind', 'ssh_target')) {
                $v = Get-PromptParleProp $s $k
                if ($null -ne $v -and "$v" -ne '') { $state[$k] = [string]$v }
            }
            $d = Get-PromptParleProp $s 'dial'
            if ($null -ne $d) { try { $state.dial = [int]$d } catch { } }
            $o = Get-PromptParleProp $s 'optimize_only'
            if ($null -ne $o) { $state.optimize_only = [bool]$o }
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
    # Apply agent defaults when agent selected
    $agent = Get-PromptParleAgent -Name $state.active_agent
    if ($agent) {
        $state.agent = [ordered]@{
            id          = $agent.id
            name        = $agent.name
            description = $agent.description
            system      = $agent.system
            profile     = $agent.profile
            dial        = $agent.dial
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
        [string]$WorkspacePath,
        [string]$WorkspaceKind,
        $WorkspaceRecent = $null,
        [string]$SshTarget,
        $SshPort = $null
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
    $out = [ordered]@{
        active_agent     = if ($PSBoundParameters.ContainsKey('ActiveAgent') -and $ActiveAgent) { $ActiveAgent } else { [string](Get-PromptParleProp $Base 'active_agent' 'default') }
        provider         = if ($PSBoundParameters.ContainsKey('Provider') -and $Provider) { $Provider } else { [string](Get-PromptParleProp $Base 'provider' 'openai') }
        profile          = if ($PSBoundParameters.ContainsKey('Profile') -and $Profile) { $Profile } else { [string](Get-PromptParleProp $Base 'profile' 'general') }
        dial             = if ($Dial -ge 1) { $Dial } else { [int](Get-PromptParleProp $Base 'dial' 3) }
        model            = if ($PSBoundParameters.ContainsKey('Model')) { $Model } else { Get-PromptParleProp $Base 'model' $null }
        optimize_only    = if ($null -ne $OptimizeOnly) { [bool]$OptimizeOnly } else { [bool](Get-PromptParleProp $Base 'optimize_only' $false) }
        workspace_path   = if ($PSBoundParameters.ContainsKey('WorkspacePath')) { [string]$WorkspacePath } else { [string](Get-PromptParleProp $Base 'workspace_path' '') }
        workspace_kind   = if ($PSBoundParameters.ContainsKey('WorkspaceKind')) { [string]$WorkspaceKind } else { [string](Get-PromptParleProp $Base 'workspace_kind' 'none') }
        workspace_recent = $recent
        ssh_target       = if ($PSBoundParameters.ContainsKey('SshTarget')) { [string]$SshTarget } else { [string](Get-PromptParleProp $Base 'ssh_target' '') }
        ssh_port         = if ($null -ne $SshPort) { [int]$SshPort } else { [int](Get-PromptParleProp $Base 'ssh_port' 22) }
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
    $out = [ordered]@{
        active_agent     = [string](Get-PromptParleProp $State 'active_agent' 'default')
        provider         = [string](Get-PromptParleProp $State 'provider' 'openai')
        profile          = [string](Get-PromptParleProp $State 'profile' 'general')
        dial             = [int](Get-PromptParleProp $State 'dial' 3)
        model            = Get-PromptParleProp $State 'model' $null
        optimize_only    = [bool](Get-PromptParleProp $State 'optimize_only' $false)
        workspace_path   = [string](Get-PromptParleProp $State 'workspace_path' '')
        workspace_kind   = [string](Get-PromptParleProp $State 'workspace_kind' 'none')
        workspace_recent = $recent
        ssh_target       = [string](Get-PromptParleProp $State 'ssh_target' '')
        ssh_port         = [int](Get-PromptParleProp $State 'ssh_port' 22)
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

function Format-PromptParleAgentPrompt {
    <#
    .SYNOPSIS
      Prepend agent system brief to the user prompt (local; free tier).
    #>
    param(
        [string]$Prompt,
        [string]$AgentId
    )
    if (-not $AgentId) { $AgentId = Get-PromptParleActiveAgentId }
    $agent = Get-PromptParleAgent -Name $AgentId
    if (-not $agent) { return $Prompt }
    $sys = ($agent.system | ForEach-Object { $_ }) -join ''
    if (-not $sys -or -not $sys.Trim()) { return $Prompt }
    $sys = $sys.Trim()
    return ("[AGENT: {0}]`n{1}`n`n[USER]`n{2}" -f $agent.name, $sys, $Prompt)
}

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

function Set-PromptParleSshTarget {
    param(
        [Parameter(Mandatory)][string]$Target,
        [int]$Port = 22
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
    $state = Get-PromptParleSessionState
    $state = New-PromptParleSessionSnapshot -Base $state -SshTarget $t -SshPort $port
    Save-PromptParleSessionState -State $state
    return [pscustomobject]@{ target = $t; port = $port }
}

function Clear-PromptParleSshTarget {
    $state = Get-PromptParleSessionState
    $state = New-PromptParleSessionSnapshot -Base $state -SshTarget '' -SshPort 22
    Save-PromptParleSessionState -State $state
}

function Invoke-PromptParleSsh {
    param(
        [Parameter(Mandatory)][string]$RemoteCommand,
        [string]$Target,
        [int]$Port = 0,
        [int]$TimeoutSec = 45
    )
    if (-not (Test-PromptParleCommandAvailable -Name 'ssh')) {
        throw 'ssh not found. On Windows install OpenSSH Client (Optional Features) or Git for Windows.'
    }
    if (-not $Target) {
        $ws = Get-PromptParleWorkspace
        $Target = $ws.ssh_target
        if ($Port -le 0) { $Port = [int]$ws.ssh_port }
    }
    if (-not $Target) { throw 'No SSH target. /ssh user@host' }
    if ($Port -le 0) { $Port = 22 }

    # Non-interactive: use BatchMode so missing keys fail fast (never prompt for password in server)
    $sshArgs = @(
        '-o', 'BatchMode=yes',
        '-o', 'StrictHostKeyChecking=accept-new',
        '-o', "ConnectTimeout=$TimeoutSec",
        '-p', "$Port",
        $Target,
        $RemoteCommand
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

function Test-PromptParleSsh {
    param([string]$Target, [int]$Port = 0)
    $r = Invoke-PromptParleSsh -Target $Target -Port $Port -RemoteCommand 'echo promptparle-ssh-ok && uname -a 2>/dev/null || ver' -TimeoutSec 15
    return $r
}

function Get-PromptParleSlashHelpText {
    return @"
Commands (type in chat instead of a normal message):

  /help                 This help
  /status               Session: agent, provider, dial, workspace, ssh
  /agents               List local agents
  /agent [name]         Show or switch agent
  /agent new <name> | system text…   Create agent (system after |)
  /agent delete <name>  Delete a custom agent
  /dial [1-5]           Compression dial
  /profile [name]       Optimization profile
  /provider [id]        openai | anthropic | gemini | grok
  /optimize             Toggle optimize-only (no AI spend)
  /usage                Cloud token savings summary
  /clear                Clear chat (UI) / screen (CLI)
  /quit                 Stop (CLI)

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
  /ssh user@host        Set target + connectivity test
  /ssh ls [path]        List remote directory
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
        [bool]$OptimizeOnly = $false
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
        -OptimizeOnly $OptimizeOnly
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
            $ag = Get-PromptParleAgent -Name $state.active_agent
            $agName = if ($ag) { $ag.name } else { $state.active_agent }
            $cmds = @()
            if ($ag -and $ag.commands) {
                foreach ($k in $ag.commands.Keys) { $cmds += "/$k" }
            }
            $ws = Get-PromptParleWorkspace
            $wsLine = if ($ws.path) {
                if ($ws.exists) {
                    $extra = @($ws.kind)
                    if ($ws.branch) { $extra += $ws.branch }
                    "$($ws.path) ($($extra -join ' · '))"
                } else { "$($ws.path) (missing)" }
            } else { '(none — /workspace <path>)' }
            $sshLine = if ($ws.ssh_target) { "$($ws.ssh_target):$($ws.ssh_port)" } else { '(none — /ssh user@host)' }
            $message = @"
Session
  Agent     : $agName ($($state.active_agent))
  Provider  : $($state.provider)
  Profile   : $($state.profile)
  Dial      : $($state.dial)/5
  Model     : $(if ($state.model) { $state.model } else { '(default)' })
  Optimize  : $($state.optimize_only)
  Workspace : $wsLine
  SSH       : $sshLine
  Commands  : $(if ($cmds.Count) { $cmds -join ' ' } else { '(none)' })
"@
        }
        '^/agents$' {
            $list = @(Get-PromptParleAgentList)
            $lines = @('Local agents (free desktop):')
            foreach ($a in $list) {
                $mark = if ($a.id -eq $state.active_agent) { '*' } else { ' ' }
                $cmdKeys = @()
                if ($a.commands) { foreach ($k in $a.commands.Keys) { $cmdKeys += "/$k" } }
                $cmdStr = if ($cmdKeys.Count) { ' · ' + ($cmdKeys -join ' ') } else { '' }
                $lines += ("  [{0}] {1}  ({2})  dial {3}  {4}{5}" -f $mark, $a.name, $a.id, $a.dial, $a.profile, $cmdStr)
            }
            $lines += 'Switch: /agent <name>   Create: /agent new <name> | system prompt…'
            $message = $lines -join "`n"
        }
        '^/agent$' {
            if (-not $arg) {
                $ag = Get-PromptParleAgent -Name $state.active_agent
                if ($ag) {
                    $message = "Active agent: $($ag.name) ($($ag.id))`nProfile: $($ag.profile) · Dial: $($ag.dial)`n$($ag.description)`n$($ag.system)"
                } else {
                    $message = 'No active agent. Try /agents'
                }
            } elseif ($arg -match '^(new|create)\s+(\S+)(?:\s*\|\s*(.*))?$') {
                $newName = $Matches[2]
                $sys = if ($Matches[3]) { $Matches[3].Trim() } else { '' }
                $created = Save-PromptParleAgent -Name $newName -System $sys -Profile $state.profile -Dial $state.dial -Description 'Custom agent'
                Set-PromptParleActiveAgent -Name $created.id | Out-Null
                $state.active_agent = $created.id
                $state.profile = $created.profile
                $state.dial = $created.dial
                $message = "Created and activated agent '$($created.name)' ($($created.id)). Edit system later with /agent new again or edit ~/.promptparle/agents/$($created.id).json"
            } elseif ($arg -match '^(delete|rm|remove)\s+(\S+)$') {
                $delName = $Matches[2]
                try {
                    Remove-PromptParleAgent -Name $delName | Out-Null
                    $state.active_agent = Get-PromptParleActiveAgentId
                    $ag2 = Get-PromptParleAgent -Name $state.active_agent
                    if ($ag2) {
                        $state.profile = $ag2.profile
                        $state.dial = $ag2.dial
                    }
                    $message = "Deleted agent '$delName'."
                } catch {
                    $message = "$_"
                }
            } else {
                try {
                    $switched = Set-PromptParleActiveAgent -Name $arg
                    $state.active_agent = $switched.id
                    $state.profile = $switched.profile
                    $state.dial = $switched.dial
                    $message = "Agent set to $($switched.name) · profile $($switched.profile) · dial $($switched.dial)/5"
                } catch {
                    $message = "$_  Try /agents"
                }
            }
        }
        '^/dial$' {
            if ($arg -match '^([1-5])$') {
                $state.dial = [int]$Matches[1]
                $message = "Dial set to $($state.dial)/5"
            } else {
                $message = "Dial is $($state.dial)/5 (1 max fidelity … 5 max savings). Usage: /dial 3"
            }
        }
        '^/profile$' {
            $profiles = @('general', 'developer', 'security-review', 'log-analysis', 'documentation', 'executive-summary')
            if ($arg -and $profiles -contains $arg) {
                $state.profile = $arg
                $message = "Profile set to $arg"
            } elseif ($arg) {
                $message = "Unknown profile '$arg'. Use: $($profiles -join ', ')"
            } else {
                $message = "Profile is $($state.profile). Set with /profile <name>"
            }
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
                        $message = @"
SSH target: $($ws.ssh_target) port $($ws.ssh_port)

  /ssh ls [path]       list remote dir
  /ssh cat <path>      fetch file → attachment
  /ssh run <command>   run remote command
  /ssh disconnect      clear target
  /ssh user@other      switch host

Keys: ssh-agent / ~/.ssh — never uploaded to PromptParle.
"@
                    } else {
                        $message = @"
No SSH target.

  /ssh user@host           set target + test (BatchMode / key auth)
  /ssh user@host:2222      custom port
  /ssh ls /var/www         list remote
  /ssh cat /etc/hosts      pull file into chat
  /ssh run uptime          run command

Requires OpenSSH client on this PC. Private keys stay local.
"@
                    }
                } elseif ($arg -match '^(disconnect|clear|off|none)$') {
                    Clear-PromptParleSshTarget
                    $state = New-PromptParleSessionSnapshot -Base $state -SshTarget '' -SshPort 22
                    $message = 'SSH target cleared.'
                } elseif ($arg -match '^(ls|list)(?:\s+(.+))?$') {
                    $rpath = if ($Matches[2]) { $Matches[2].Trim() } else { '.' }
                    # sanitize remote path slightly
                    if ($rpath -match '[;|&`$]') { throw 'Invalid remote path' }
                    $r = Invoke-PromptParleSsh -RemoteCommand "ls -la -- $rpath"
                    $message = "ssh $($r.target):$($r.port) ls $rpath (exit $($r.exit_code))`n$($r.text)"
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
                    # treat as user@host[:port]
                    $targetArg = $arg.Trim()
                    $port = 22
                    if ($targetArg -match '^(.+):(\d+)$') {
                        $targetArg = $Matches[1]
                        $port = [int]$Matches[2]
                    }
                    $set = Set-PromptParleSshTarget -Target $targetArg -Port $port
                    $state = New-PromptParleSessionSnapshot -Base $state -SshTarget $set.target -SshPort $set.port
                    $r = Test-PromptParleSsh -Target $set.target -Port $set.port
                    if ($r.exit_code -eq 0) {
                        $message = "SSH target set: $($set.target):$($set.port)`nOK`n$($r.text)"
                    } else {
                        $message = @"
SSH target saved: $($set.target):$($set.port)
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
                $message = "Unknown command: $cmd  (try /help or /agents)"
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

        $body = [ordered]@{
            provider              = $Provider
            prompt                = $Prompt
            optimization_profile  = $Profile
            compression_level     = [int]$CompressionLevel
            return_metadata       = $true
        }
        if ($Model) { $body.model = $Model }
        if ($contextText) { $body.context = $contextText }
        if ($OptimizeOnly) { $body.optimize_only = $true }

        $imageList = @(ConvertTo-PromptParleImageList -Images $Images)
        if ($imageList.Count -gt 0 -and -not $OptimizeOnly) {
            $body.images = $imageList
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

function Get-PromptParleRemoteClientVersion {
    <#
    .SYNOPSIS
      Latest client version published on GitHub main.
    #>
    [CmdletBinding()]
    param()
    $urls = @(
        'https://raw.githubusercontent.com/exiled4disco/promptparle/main/powershell/PromptParle/PromptParle.psd1',
        'https://promptparle.com/PromptParle.psd1'
    )
    foreach ($url in $urls) {
        try {
            $resp = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 20
            $raw = [string]$resp.Content
            if ($raw -match "ModuleVersion\s*=\s*'([^']+)'") {
                return $Matches[1]
            }
        } catch {
            continue
        }
    }
    return $null
}

function Compare-PromptParleVersion {
    param([string]$A, [string]$B)
    try {
        $va = [version](($A -replace '[^0-9.]', '') -replace '^\.', '0.')
        $vb = [version](($B -replace '[^0-9.]', '') -replace '^\.', '0.')
        return $va.CompareTo($vb)
    } catch {
        if ($A -eq $B) { return 0 }
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
    $local = Get-PromptParleClientVersion
    $remote = $null
    $err = $null
    try {
        $remote = Get-PromptParleRemoteClientVersion
    } catch {
        $err = "$_"
    }
    $updateAvailable = $false
    if ($remote) {
        $updateAvailable = (Compare-PromptParleVersion -A $local -B $remote) -lt 0
    }
    return [pscustomobject]@{
        local_version    = $local
        remote_version   = $remote
        update_available = $updateAvailable
        check_error      = $err
        module_root      = Get-PromptParleModuleRoot
    }
}

function Update-PromptParleClient {
    <#
    .SYNOPSIS
      Download latest PromptParle module from GitHub and install into the user Modules folder.

    .DESCRIPTION
      Used by the local chat "Update" button and can be run from PowerShell:
        Update-PromptParleClient
      Does not touch your API key. After update, restart local chat (pp) to load new code.
    #>
    [CmdletBinding()]
    param(
        # Skip version check and always reinstall from main
        [switch]$Force,
        # After install, start local chat on this port (used by UI self-update)
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

    if (-not $Force -and $remote -and (Compare-PromptParleVersion -A $before -B $remote) -ge 0) {
        return [pscustomobject]@{
            ok               = $true
            updated          = $false
            previous_version = $before
            version          = $before
            remote_version   = $remote
            message          = "Already up to date ($before)."
            restart_required = $false
        }
    }

    $temp = Join-Path ([System.IO.Path]::GetTempPath()) ('pp-update-' + [guid]::NewGuid().ToString('n'))
    New-Item -ItemType Directory -Path $temp -Force | Out-Null
    $zipPath = Join-Path $temp 'promptparle-main.zip'
    $extract = Join-Path $temp 'extract'

    try {
        Write-Host 'Downloading latest PromptParle client...' -ForegroundColor Cyan
        $zipUrl = 'https://github.com/exiled4disco/promptparle/archive/refs/heads/main.zip'
        # Prefer site tarball if present (faster); fall back to GitHub zip
        $tgzUrl = 'https://promptparle.com/PromptParle-PowerShell.tgz'
        $used = $null
        try {
            Invoke-WebRequest -Uri $zipUrl -OutFile $zipPath -UseBasicParsing -TimeoutSec 120
            $used = 'github-zip'
        } catch {
            throw "Download failed: $_"
        }

        Write-Host 'Extracting...' -ForegroundColor DarkGray
        New-Item -ItemType Directory -Path $extract -Force | Out-Null
        if (Get-Command Expand-Archive -ErrorAction SilentlyContinue) {
            Expand-Archive -LiteralPath $zipPath -DestinationPath $extract -Force
        } else {
            throw 'Expand-Archive not available. Update PowerShell or install manually.'
        }

        $source = $null
        $candidates = @(
            (Join-Path $extract 'promptparle-main\powershell\PromptParle'),
            (Join-Path $extract 'promptparle-main/powershell/PromptParle')
        )
        # Also scan one level deep
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
        if (-not $source) {
            throw 'Downloaded archive did not contain powershell/PromptParle'
        }

        $newVer = Read-PromptParleVersionFromManifest -ManifestPath (Join-Path $source 'PromptParle.psd1')
        if (-not $newVer) { $newVer = $remote }
        if (-not $newVer) { $newVer = 'unknown' }

        $userModules = Get-PromptParleUserModulesDir
        $dest = Join-Path $userModules 'PromptParle'
        New-Item -ItemType Directory -Path $userModules -Force | Out-Null

        Write-Host ("Installing PromptParle {0} -> {1}" -f $newVer, $dest) -ForegroundColor Cyan

        # Copy into place (replace files; keep folder if locked bits fail partially)
        if (Test-Path -LiteralPath $dest) {
            Get-ChildItem -LiteralPath $source -Force | ForEach-Object {
                $target = Join-Path $dest $_.Name
                if ($_.PSIsContainer) {
                    if (Test-Path -LiteralPath $target) {
                        Copy-Item -LiteralPath $_.FullName -Destination $dest -Recurse -Force
                    } else {
                        Copy-Item -LiteralPath $_.FullName -Destination $target -Recurse -Force
                    }
                } else {
                    Copy-Item -LiteralPath $_.FullName -Destination $target -Force
                }
            }
        } else {
            Copy-Item -LiteralPath $source -Destination $dest -Recurse -Force
        }

        Get-ChildItem -LiteralPath $dest -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
            try { Unblock-File -LiteralPath $_.FullName -ErrorAction SilentlyContinue } catch { }
        }

        # Version from files on disk — never call module cmdlets after a possible unload.
        # (UI self-update runs inside the loaded module; Remove-Module would kill Get-PromptParleClientVersion mid-request.)
        $manifestPath = Join-Path $dest 'PromptParle.psd1'
        $after = Read-PromptParleVersionFromManifest -ManifestPath $manifestPath
        if (-not $after) { $after = $newVer }
        if (-not $after) { $after = 'unknown' }

        # Only re-import when updating from an interactive CLI (no live local-server restart).
        # When -RestartPort is set, a NEW process loads the new module; this process must keep running
        # until it returns the HTTP response and exits cleanly.
        if ($RestartPort -le 0) {
            try {
                Remove-Module PromptParle -Force -ErrorAction SilentlyContinue
                Import-Module $manifestPath -Force -Global -ErrorAction Stop
            } catch {
                Write-Host ("  note: module reloaded from disk after restart (import: {0})" -f $_) -ForegroundColor DarkGray
            }
        }

        $msg = "Updated $before → $after"
        Write-Host $msg -ForegroundColor Green
        if ($used) { Write-Host ("  source: {0}" -f $used) -ForegroundColor DarkGray }

        if ($RestartPort -gt 0) {
            $psExe = if (Get-Command pwsh -ErrorAction SilentlyContinue) {
                (Get-Command pwsh).Source
            } elseif (Get-Command powershell -ErrorAction SilentlyContinue) {
                (Get-Command powershell).Source
            } else {
                'powershell'
            }
            $destEsc = $manifestPath -replace "'", "''"
            $cmd = @"
Start-Sleep -Seconds 2
Import-Module '$destEsc' -Force -Global
try { Start-PromptParleLocalServer -Port $RestartPort } catch { Start-PromptParle }
"@
            Write-Host ("Restarting local chat on port {0}..." -f $RestartPort) -ForegroundColor Cyan
            Start-Process -FilePath $psExe -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', $cmd) | Out-Null
        }

        return [pscustomobject]@{
            ok               = $true
            updated          = $true
            previous_version = $before
            version          = $after
            remote_version   = $remote
            message          = $msg
            restart_required = $true
            module_path      = $dest
        }
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

                if ($req.HttpMethod -eq 'GET' -and $path -eq '/api/version') {
                    try {
                        $st = Get-PromptParleUpdateStatus
                        $payload = @{
                            ok               = $true
                            local_version    = $st.local_version
                            remote_version   = $st.remote_version
                            update_available = [bool]$st.update_available
                            check_error      = $st.check_error
                            module_root      = $st.module_root
                            port             = $Port
                        } | ConvertTo-Json -Compress
                        Write-PromptParleHttpResponse -Context $ctx -ContentType 'application/json; charset=utf-8' -Body $payload
                    } catch {
                        $err = @{ ok = $false; error = "$_" } | ConvertTo-Json -Compress
                        Write-PromptParleHttpResponse -Context $ctx -StatusCode 500 -ContentType 'application/json; charset=utf-8' -Body $err
                    }
                    continue
                }

                if ($req.HttpMethod -eq 'POST' -and $path -eq '/api/update') {
                    try {
                        Write-Host '  update: downloading latest client...' -ForegroundColor Cyan
                        $result = Update-PromptParleClient -Force -RestartPort $Port
                        $payload = @{
                            ok               = [bool]$result.ok
                            updated          = [bool]$result.updated
                            previous_version = $result.previous_version
                            version          = $result.version
                            remote_version   = $result.remote_version
                            message          = $result.message
                            restart_required = $true
                            restart_port     = $Port
                            url              = "http://127.0.0.1:$Port/"
                        } | ConvertTo-Json -Compress
                        Write-PromptParleHttpResponse -Context $ctx -ContentType 'application/json; charset=utf-8' -Body $payload
                        Write-Host ("  update: {0} — restarting server..." -f $result.message) -ForegroundColor Green
                        # Let the response flush, then stop this process (new one already spawned)
                        Start-Sleep -Milliseconds 400
                        $script:PromptParleShouldStop = $true
                        $script:PromptParleStopAnnounced = $true
                        try { $listener.Stop() } catch { }
                        break
                    } catch {
                        Write-Host ("  update: error - {0}" -f $_) -ForegroundColor Red
                        # If files were written but post-install threw (old bug: Remove-Module mid-server),
                        # still spawn a fresh process from the on-disk module so the user is not stuck.
                        $recovered = $false
                        try {
                            $modDir = Join-Path (Get-PromptParleUserModulesDir) 'PromptParle'
                            $psd1 = Join-Path $modDir 'PromptParle.psd1'
                            if (Test-Path -LiteralPath $psd1) {
                                $verOnDisk = Read-PromptParleVersionFromManifest -ManifestPath $psd1
                                $psExe = if (Get-Command pwsh -ErrorAction SilentlyContinue) {
                                    (Get-Command pwsh).Source
                                } elseif (Get-Command powershell -ErrorAction SilentlyContinue) {
                                    (Get-Command powershell).Source
                                } else { 'powershell' }
                                $destEsc = $psd1 -replace "'", "''"
                                $cmd = @"
Start-Sleep -Seconds 2
Import-Module '$destEsc' -Force -Global
try { Start-PromptParleLocalServer -Port $Port } catch { Start-PromptParle }
"@
                                Start-Process -FilePath $psExe -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', $cmd) | Out-Null
                                $payload = @{
                                    ok               = $true
                                    updated          = $true
                                    version          = $verOnDisk
                                    message          = "Updated to $verOnDisk (recovered after reload glitch). Restarting…"
                                    restart_required = $true
                                    restart_port     = $Port
                                    url              = "http://127.0.0.1:$Port/"
                                    recovered        = $true
                                    prior_error      = "$_"
                                } | ConvertTo-Json -Compress
                                Write-PromptParleHttpResponse -Context $ctx -ContentType 'application/json; charset=utf-8' -Body $payload
                                Write-Host ("  update: recovered — restarting with on-disk v{0}" -f $verOnDisk) -ForegroundColor Yellow
                                Start-Sleep -Milliseconds 400
                                $script:PromptParleShouldStop = $true
                                $script:PromptParleStopAnnounced = $true
                                try { $listener.Stop() } catch { }
                                $recovered = $true
                            }
                        } catch {
                            Write-Host ("  update: recovery failed - {0}" -f $_) -ForegroundColor Red
                        }
                        if ($recovered) { break }
                        $err = @{ ok = $false; error = "$_" } | ConvertTo-Json -Compress
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
                            workspace_path   = [string]$ws.path
                            workspace_kind   = [string]$ws.kind
                            workspace_branch = $ws.branch
                            workspace_remote = $ws.remote
                            workspace_recent = @($ws.recent)
                            ssh_target       = [string]$ws.ssh_target
                            ssh_port         = [int]$ws.ssh_port
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

                if ($req.HttpMethod -eq 'GET' -and $path -eq '/api/agents') {
                    try {
                        $list = @(Get-PromptParleAgentList)
                        $items = @()
                        foreach ($a in $list) {
                            $cmdList = @()
                            if ($a.commands) {
                                foreach ($k in $a.commands.Keys) { $cmdList += [string]$k }
                            }
                            $items += @{
                                id          = $a.id
                                name        = $a.name
                                description = $a.description
                                profile     = $a.profile
                                dial        = [int]$a.dial
                                commands    = $cmdList
                            }
                        }
                        $payload = @{
                            ok           = $true
                            agents       = $items
                            active_agent = (Get-PromptParleActiveAgentId)
                        } | ConvertTo-Json -Depth 6 -Compress
                        Write-PromptParleHttpResponse -Context $ctx -ContentType 'application/json; charset=utf-8' -Body $payload
                    } catch {
                        $err = @{ ok = $false; error = "$_" } | ConvertTo-Json -Compress
                        Write-PromptParleHttpResponse -Context $ctx -StatusCode 500 -ContentType 'application/json; charset=utf-8' -Body $err
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
                        $cmdParams = @{ Line = $lineC; OptimizeOnly = $optOnlyC }
                        if ($provC) { $cmdParams.Provider = $provC }
                        if ($profC) { $cmdParams.Profile = $profC }
                        if ($dialC -ge 1) { $cmdParams.Dial = $dialC }
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
                        # Apply active agent system brief (local free feature)
                        $skipAgent = Get-PromptParleProp $body 'skip_agent' $false
                        if ($skipAgent -ne $true) {
                            $prompt = Format-PromptParleAgentPrompt -Prompt $prompt
                        }
                        $provider = [string](Get-PromptParleProp $body 'provider' 'openai')
                        if (-not $provider) { $provider = 'openai' }
                        $profile = [string](Get-PromptParleProp $body 'profile' 'general')
                        if (-not $profile) { $profile = 'general' }
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

                        $ctxLen = if ($context) { $context.Length } else { 0 }
                        Write-Host ("  chat: provider={0} profile={1} dial={2} optimize_only={3} prompt={4}c context={5}c images={6}" -f `
                            $provider, $profile, $dial, $optOnly, $prompt.Length, $ctxLen, $images.Count) -ForegroundColor DarkGray

                        $params = @{
                            Prompt            = $prompt
                            Provider          = $provider
                            Profile           = $profile
                            CompressionLevel  = $dial
                            Quiet             = $true
                            Raw               = $true
                        }
                        # Pass as single string - never as char-unrolled array
                        if ($context) { $params.Context = [string]$context }
                        if ($optOnly) { $params.OptimizeOnly = $true }
                        if ($images.Count -gt 0) { $params.Images = $images }

                        $result = Invoke-PromptParle @params
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
                        }
                        $payload = [ordered]@{
                            response         = Get-PromptParleProp $result 'response' (Get-PromptParleProp $result 'Response' $null)
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
    Write-Host 'Type a message, /help, /agents, /agent security, /audit …  /quit to leave.' -ForegroundColor DarkGray
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
            $sendPrompt = Format-PromptParleAgentPrompt -Prompt $trimmed
            $params = @{
                Prompt           = $sendPrompt
                Provider         = $sessionProvider
                Profile          = $sessionProfile
                CompressionLevel = $sessionDial
                Quiet            = $false
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
    'Uninstall-PromptParle',
    'Get-PromptParleClientVersion',
    'Get-PromptParleUpdateStatus',
    'Update-PromptParleClient',
    'Get-PromptParleAgent',
    'Get-PromptParleAgentList',
    'Save-PromptParleAgent',
    'Remove-PromptParleAgent',
    'Set-PromptParleActiveAgent',
    'Invoke-PromptParleSlashCommand',
    'Get-PromptParleWorkspace',
    'Set-PromptParleWorkspace',
    'Clear-PromptParleWorkspace',
    'Get-PromptParleGitHubStatusText',
    'Set-PromptParleSshTarget',
    'Clear-PromptParleSshTarget',
    'Invoke-PromptParleSsh',
    'Invoke-PromptParleGitClone'
) -Alias @(
    'pp',
    'promptparle'
)
