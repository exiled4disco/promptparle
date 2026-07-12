# Local-first runtime: provider keys + optimize + model calls on the PC.
# Portal is licensing only (pp_live_ entitlement). Dot-sourced from PromptParle.psm1.
# IMPORTANT: Windows PowerShell 5.1 — one hashtable property per line; no try/catch inside @{ }.

function Get-PromptParleConfigRawObject {
    if (-not (Test-Path -LiteralPath $script:PromptParleConfigPath)) {
        return [pscustomobject]@{}
    }
    try {
        return (Get-Content -LiteralPath $script:PromptParleConfigPath -Raw -ErrorAction Stop | ConvertFrom-Json)
    } catch {
        return [pscustomobject]@{}
    }
}

function Save-PromptParleConfigRawObject {
    param(
        [Parameter(Mandatory)]
        $Object
    )
    if (-not (Test-Path -LiteralPath $script:PromptParleConfigDir)) {
        New-Item -ItemType Directory -Path $script:PromptParleConfigDir -Force | Out-Null
    }
    $Object | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $script:PromptParleConfigPath -Encoding UTF8
    Set-PromptParleConfigAcl -Path $script:PromptParleConfigPath
}

function Get-PromptParleSecretPolicy {
    $raw = Get-PromptParleConfigRawObject
    $p = [string](Get-PromptParleProp $raw 'SecretPolicy' 'strict')
    if ($p -notin @('strict', 'mask', 'off')) {
        $p = 'strict'
    }
    return $p
}

function Set-PromptParleSecretPolicy {
    <#
    .SYNOPSIS
      strict = block send if residual high-confidence secrets remain after mask
      mask   = always mask, never block
      off    = no client gate (debug only; not recommended)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('strict', 'mask', 'off')]
        [string]$Policy
    )
    $raw = Get-PromptParleConfigRawObject
    $ht = [ordered]@{}
    foreach ($prop in $raw.PSObject.Properties) {
        $ht[$prop.Name] = $prop.Value
    }
    $ht['SecretPolicy'] = $Policy
    $ht['UpdatedAt'] = (Get-Date).ToUniversalTime().ToString('o')
    Save-PromptParleConfigRawObject -Object (ConvertTo-PromptParleCustomObject $ht)
    Write-Host "Secret policy set to $Policy" -ForegroundColor Green
}

function Invoke-PromptParleSecretGate {
    <#
    .SYNOPSIS
      Mandatory local secret scrub before any model network call.
    #>
    [CmdletBinding()]
    param(
        [string]$Prompt = '',
        [string]$Context = '',
        [string]$System = '',
        [string]$Runtime = '',
        [string]$Policy = ''
    )
    if (-not $Policy) {
        $Policy = Get-PromptParleSecretPolicy
    }
    if ($Policy -eq 'off') {
        $emptyDrops = @()
        $emptyFindings = @()
        return [pscustomobject]@{
            Prompt       = $Prompt
            Context      = $Context
            System       = $System
            Runtime      = $Runtime
            MaskedCount  = 0
            Findings     = $emptyFindings
            ResidualHigh = $false
            Policy       = $Policy
            Drops        = $emptyDrops
        }
    }

    $partNames = @('prompt', 'context', 'system', 'runtime')
    $partTexts = @($Prompt, $Context, $System, $Runtime)
    $totalMasked = 0
    # ArrayList not List[string] — PS wrappers throw "Argument types do not match" on List[string].Add
    $findings = New-Object System.Collections.ArrayList
    $drops = New-Object System.Collections.ArrayList
    $outMap = @{}

    for ($i = 0; $i -lt $partNames.Count; $i++) {
        $name = $partNames[$i]
        $textIn = [string]$partTexts[$i]
        $r = Invoke-PromptParleSecretScanLocal -Text $textIn
        $outMap[$name] = $r.text
        try { $totalMasked = $totalMasked + [int]$r.masked } catch { }
        if ($r.masked -gt 0) {
            [void]$findings.Add([string]("$name" + ':~' + $r.masked))
            $dropItem = @{
                kind   = 'secret_mask'
                field  = [string]$name
                count  = 0
                sample = 'credential-shaped pattern'
            }
            try { $dropItem.count = [int]$r.masked } catch { $dropItem.count = 1 }
            [void]$drops.Add($dropItem)
        }
    }

    $combined = (@($outMap['prompt'], $outMap['context'], $outMap['system'], $outMap['runtime']) -join "`n")
    $residual = Test-PromptParleResidualSecrets -Text $combined
    $residualB = $false
    try { $residualB = [System.Convert]::ToBoolean($residual) } catch { $residualB = [bool]$residual }

    if ($residualB -and $Policy -eq 'strict') {
        throw "Secret gate (strict): high-confidence secret pattern still present after mask. Remove production secrets from the prompt/context, or Set-PromptParleSecretPolicy mask."
    }

    return [pscustomobject]@{
        Prompt       = [string]$outMap['prompt']
        Context      = [string]$outMap['context']
        System       = [string]$outMap['system']
        Runtime      = [string]$outMap['runtime']
        MaskedCount  = $totalMasked
        Findings     = @($findings.ToArray())
        ResidualHigh = $residualB
        Policy       = $Policy
        Drops        = @($drops.ToArray())
    }
}

function Test-PromptParleResidualSecrets {
    param([string]$Text)
    if (-not $Text) {
        return $false
    }
    $high = @(
        'sk-ant-[A-Za-z0-9\-_]{16,}',
        'sk-[A-Za-z0-9]{20,}',
        'xai-[A-Za-z0-9]{20,}',
        'AIza[0-9A-Za-z\-_]{20,}',
        'AKIA[0-9A-Z]{16}',
        'ghp_[A-Za-z0-9]{20,}',
        'github_pat_[A-Za-z0-9_]{20,}',
        'pp_live_[A-Za-z0-9]{16,}',
        '-----BEGIN (?:RSA |OPENSSH |EC )?PRIVATE KEY-----'
    )
    foreach ($re in $high) {
        if ([regex]::IsMatch($Text, $re)) {
            return $true
        }
    }
    return $false
}

function Get-PromptParleLocalProviderMap {
    <#
    .SYNOPSIS
      Returns hashtable providerId -> entry with ApiKey, LastFour, UpdatedAt.
    #>
    $raw = Get-PromptParleConfigRawObject
    $map = @{}
    $prov = Get-PromptParleProp $raw 'Providers' $null
    if ($null -eq $prov) {
        return $map
    }
    foreach ($p in $prov.PSObject.Properties) {
        $id = [string]$p.Name
        $val = $p.Value
        $stored = [string](Get-PromptParleProp $val 'ApiKey' '')
        if (-not $stored) {
            continue
        }
        $plain = Unprotect-PromptParleSecret -Stored $stored
        if (-not $plain) {
            continue
        }
        $entry = @{}
        $entry['ApiKey'] = $plain
        $entry['LastFour'] = [string](Get-PromptParleProp $val 'LastFour' '')
        $entry['UpdatedAt'] = [string](Get-PromptParleProp $val 'UpdatedAt' '')
        $map[$id] = $entry
    }
    return $map
}

function Get-PromptParleLocalProviderKey {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('openai', 'anthropic', 'gemini', 'grok')]
        [string]$Provider
    )
    $map = Get-PromptParleLocalProviderMap
    if ($map.ContainsKey($Provider)) {
        $ent = $map[$Provider]
        if ($ent -and $ent['ApiKey']) {
            return [string]$ent['ApiKey']
        }
    }
    $envName = 'PROMPTPARLE_' + $Provider.ToUpperInvariant() + '_API_KEY'
    $envVal = [Environment]::GetEnvironmentVariable($envName)
    if ($envVal) {
        return $envVal.Trim()
    }
    return $null
}

function Set-PromptParleProviderKey {
    <#
    .SYNOPSIS
      Store a provider API key on this PC only (DPAPI on Windows). Never sent to PromptParle.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('openai', 'anthropic', 'gemini', 'grok')]
        [string]$Provider,

        [Parameter(Mandatory)]
        [string]$ApiKey
    )
    $ApiKey = $ApiKey.Trim()
    if ($ApiKey.Length -lt 8) {
        throw 'API key too short'
    }

    $raw = Get-PromptParleConfigRawObject
    $ht = [ordered]@{}
    foreach ($prop in $raw.PSObject.Properties) {
        if ($prop.Name -eq 'Providers') {
            continue
        }
        $ht[$prop.Name] = $prop.Value
    }

    $providers = @{}
    $existing = Get-PromptParleProp $raw 'Providers' $null
    if ($null -ne $existing) {
        foreach ($p in $existing.PSObject.Properties) {
            $providers[$p.Name] = $p.Value
        }
    }

    $last4 = '****'
    if ($ApiKey.Length -gt 4) {
        $last4 = $ApiKey.Substring($ApiKey.Length - 4)
    }

    $provEntry = [ordered]@{}
    $provEntry['ApiKey'] = (Protect-PromptParleSecret -PlainText $ApiKey)
    $provEntry['LastFour'] = $last4
    $provEntry['UpdatedAt'] = (Get-Date).ToUniversalTime().ToString('o')
    $providers[$Provider] = $provEntry

    $ht['Providers'] = (ConvertTo-PromptParleCustomObject $providers)
    $ht['UpdatedAt'] = (Get-Date).ToUniversalTime().ToString('o')
    if (-not $ht['SecretPolicy']) {
        $ht['SecretPolicy'] = 'strict'
    }
    Save-PromptParleConfigRawObject -Object (ConvertTo-PromptParleCustomObject $ht)
    Write-Host ("Provider key saved locally for {0} (...{1}). Never uploaded to PromptParle." -f $Provider, $last4) -ForegroundColor Green
}

function Remove-PromptParleProviderKey {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('openai', 'anthropic', 'gemini', 'grok')]
        [string]$Provider
    )
    $raw = Get-PromptParleConfigRawObject
    $ht = [ordered]@{}
    foreach ($prop in $raw.PSObject.Properties) {
        if ($prop.Name -eq 'Providers') {
            continue
        }
        $ht[$prop.Name] = $prop.Value
    }
    $providers = @{}
    $existing = Get-PromptParleProp $raw 'Providers' $null
    if ($null -ne $existing) {
        foreach ($p in $existing.PSObject.Properties) {
            if ($p.Name -ne $Provider) {
                $providers[$p.Name] = $p.Value
            }
        }
    }
    $ht['Providers'] = (ConvertTo-PromptParleCustomObject $providers)
    $ht['UpdatedAt'] = (Get-Date).ToUniversalTime().ToString('o')
    Save-PromptParleConfigRawObject -Object (ConvertTo-PromptParleCustomObject $ht)
    Write-Host "Removed local provider key for $Provider" -ForegroundColor Yellow
}

function Get-PromptParleLocalProvidersPublic {
    <#
    .SYNOPSIS
      Shape similar to portal /api/v1/providers for the local UI.
      Uses only pscustomobject + plain arrays so ConvertTo-Json works on PS 5.1/7
      (ordered hashtables + Generic.List broke /api/providers → empty dropdown).
    #>
    # Plain hashtables — one property per line for PS 5.1 safety
    $defOpenAi = @{}
    $defOpenAi['name'] = 'OpenAI'
    $defOpenAi['default_model'] = 'gpt-4o'
    $defOpenAi['models'] = @('gpt-4o', 'gpt-4.1', 'gpt-4o-mini', 'o4-mini', 'gpt-5.4')

    $defAnthropic = @{}
    $defAnthropic['name'] = 'Anthropic Claude'
    $defAnthropic['default_model'] = 'claude-sonnet-4-5-20250929'
    $defAnthropic['models'] = @('claude-sonnet-4-5-20250929', 'claude-opus-4-5-20251101', 'claude-haiku-4-5-20251001')

    $defGemini = @{}
    $defGemini['name'] = 'Google Gemini'
    $defGemini['default_model'] = 'gemini-2.5-flash'
    $defGemini['models'] = @('gemini-2.5-flash', 'gemini-2.5-pro', 'gemini-2.0-flash')

    $defGrok = @{}
    $defGrok['name'] = 'xAI Grok'
    $defGrok['default_model'] = 'grok-4.5'
    $defGrok['models'] = @('grok-4.5', 'grok-4', 'grok-3')

    $defaults = @{}
    $defaults['openai'] = $defOpenAi
    $defaults['anthropic'] = $defAnthropic
    $defaults['gemini'] = $defGemini
    $defaults['grok'] = $defGrok

    $map = @{}
    try {
        $map = Get-PromptParleLocalProviderMap
    } catch {
        $map = @{}
    }
    if ($null -eq $map) {
        $map = @{}
    }

    $list = @()
    foreach ($id in @('openai', 'anthropic', 'gemini', 'grok')) {
        $d = $defaults[$id]
        $configured = $false
        try {
            $configured = [bool]$map.ContainsKey($id)
        } catch {
            $configured = $false
        }
        $last4 = $null
        if ($configured) {
            try {
                $last4 = [string]$map[$id]['LastFour']
            } catch {
                $last4 = $null
            }
        }
        $keySource = 'none'
        if ($configured) {
            $keySource = 'local'
        }

        $modelObjs = @()
        foreach ($m in @($d['models'])) {
            $modelObjs += [pscustomobject]@{
                id   = [string]$m
                name = [string]$m
            }
        }

        $list += [pscustomobject]@{
            id            = $id
            name          = [string]$d['name']
            configured    = $configured
            has_key       = $configured
            last_four     = $last4
            key_source    = $keySource
            default_model = [string]$d['default_model']
            models        = $modelObjs
            routing       = $true
            local_first   = $true
        }
    }

    return [pscustomobject]@{
        providers   = $list
        local_first = $true
        message     = 'Provider keys live on this PC only. Portal is licensing only.'
    }
}

function Get-PromptParleDefaultModelLocal {
    param([string]$Provider)
    switch ($Provider) {
        'openai' { return 'gpt-4o' }
        'anthropic' { return 'claude-sonnet-4-5-20250929' }
        'gemini' { return 'gemini-2.5-flash' }
        'grok' { return 'grok-4.5' }
        default { return 'gpt-4o' }
    }
}

function Estimate-PromptParleTokensLocal {
    param([string]$Text)
    if (-not $Text) {
        return 0
    }
    return [Math]::Max(1, [int][Math]::Ceiling($Text.Length / 4.0))
}

function Invoke-PromptParleLocalOptimizeCore {
    <#
    .SYNOPSIS
      Deterministic local optimize. Emits drop journal.
    #>
    [CmdletBinding()]
    param(
        [string]$Prompt,
        [string]$Context = '',
        [string]$Profile = 'general',
        [int]$CompressionLevel = 3
    )
    $dial = $CompressionLevel
    if ($dial -lt 1) { $dial = 1 }
    if ($dial -gt 5) { $dial = 5 }

    # ArrayList not List[string]/List[object] — avoids "Argument types do not match" on .Add
    $drops = New-Object System.Collections.ArrayList
    $notes = New-Object System.Collections.ArrayList
    $promptStr = if ($null -eq $Prompt) { '' } else { [string]$Prompt }
    $ctx = if ($null -eq $Context) { '' } else { [string]$Context }
    if ($ctx) {
        $origText = $promptStr + "`n`n" + $ctx
    } else {
        $origText = $promptStr
    }
    $origTokens = Estimate-PromptParleTokensLocal -Text $origText

    if ($ctx -and $dial -ge 2) {
        $lines = $ctx -split "`r?`n"
        $seen = @{}
        $outLines = New-Object System.Collections.ArrayList
        $dupCount = 0
        foreach ($line in $lines) {
            $lineStr = [string]$line
            $key = $lineStr.Trim()
            if ($key.Length -gt 8) {
                $hk = $key.ToLowerInvariant()
                if ($seen.ContainsKey($hk)) {
                    try { $seen[$hk] = [int]$seen[$hk] + 1 } catch { $seen[$hk] = 2 }
                    $dupCount++
                    if ($dial -ge 3 -and $seen[$hk] -eq 2) {
                        [void]$outLines.Add([string]('... (' + $seen[$hk] + '+ similar lines collapsed)'))
                    }
                    continue
                }
                $seen[$hk] = 1
            }
            [void]$outLines.Add($lineStr)
        }
        if ($dupCount -gt 0) {
            $ctx = ($outLines.ToArray() -join "`n")
            [void]$notes.Add([string]"dedup collapsed ~$dupCount repeated lines")
            [void]$drops.Add(@{
                    kind   = 'duplicate_line'
                    count  = $dupCount
                    sample = 'repeated / near-identical lines'
                })
        }
    }

    if ($ctx -and $dial -ge 3) {
        $before = $ctx
        $ctx = [regex]::Replace($ctx, '(?ms)^#{0,3}\s*Apache License.*?(?=^#{0,3}\s|\z)', '')
        $ctx = [regex]::Replace($ctx, '(?ms)^Copyright \(c\).{0,80}\r?\n', '')
        $ctx = [regex]::Replace($ctx, '(?m)^[-=*]{8,}\s*$', '')
        if ($ctx.Length -lt ($before.Length - 40)) {
            $cut = $before.Length - $ctx.Length
            [void]$notes.Add([string]"boilerplate stripped ~$cut chars")
            [void]$drops.Add(@{
                    kind   = 'boilerplate'
                    count  = 1
                    sample = 'license / banner / separators'
                })
        }
    }

    $budget = 60000
    switch ($dial) {
        1 { $budget = 200000 }
        2 { $budget = 120000 }
        3 { $budget = 60000 }
        4 { $budget = 28000 }
        5 { $budget = 14000 }
    }
    if ($Profile -eq 'security-review') {
        if ($budget -lt 80000) { $budget = 80000 }
        if ($dial -le 2) { $budget = 200000 }
    }
    if ($ctx -and $ctx.Length -gt $budget) {
        $head = [int]($budget * 0.7)
        $tail = [int]($budget * 0.25)
        $cut = $ctx.Length - $head - $tail
        $ctx = $ctx.Substring(0, $head) + "`n... [truncated $cut chars for dial $dial] ...`n" + $ctx.Substring($ctx.Length - $tail)
        [void]$notes.Add([string]"truncated to dial $dial budget")
        [void]$drops.Add(@{
                kind       = 'truncated'
                tokens_cut = [int]($cut / 4)
                sample     = "dial $dial char budget"
            })
    }

    $promptOut = [regex]::Replace(($promptStr -replace "`r`n", "`n"), '\n{3,}', "`n`n").Trim()
    if ($ctx) {
        $ctx = [regex]::Replace(($ctx -replace "`r`n", "`n"), '\n{3,}', "`n`n").Trim()
    }

    if ($ctx) {
        $optimized = $promptOut + "`n`n" + $ctx
    } else {
        $optimized = $promptOut
    }
    $optTokens = Estimate-PromptParleTokensLocal -Text $optimized
    $saved = [Math]::Max(0, $origTokens - $optTokens)
    $pct = 0
    if ($origTokens -gt 0) {
        $pct = [int][Math]::Round(100.0 * $saved / $origTokens)
    }

    return [pscustomobject]@{
        OptimizedPrompt  = $optimized
        Prompt           = $promptOut
        Context          = $ctx
        OriginalTokens   = $origTokens
        OptimizedTokens  = $optTokens
        ReductionPercent = $pct
        Notes            = @($notes.ToArray())
        Drops            = @($drops.ToArray())
        Profile          = $Profile
        CompressionLevel = $dial
        Strategy         = 'local-first'
    }
}

function Invoke-PromptParleJsonPost {
    <#
    .SYNOPSIS
      UTF-8-safe JSON POST that behaves the same on Windows PowerShell 5.1 and
      PowerShell 7. Sends the body as UTF-8 BYTES and decodes the response from
      raw UTF-8 bytes before parsing.
    .DESCRIPTION
      Invoke-RestMethod on PS 5.1 encodes a string -Body per the caller's default
      codepage and decodes the response per the server's (often absent) charset,
      which turns multi-byte UTF-8 (—, “ ”, emoji) into mojibake like "â€"" / "â□□".
      This helper avoids that on every version.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$Json,
        [hashtable]$Headers = @{},
        [int]$TimeoutSec = 180
    )
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Json)
    $resp = Invoke-WebRequest -Method POST -Uri $Uri -Headers $Headers `
        -Body $bytes -ContentType 'application/json; charset=utf-8' `
        -UseBasicParsing -TimeoutSec $TimeoutSec
    # Decode the response body explicitly as UTF-8 (do not trust IWR's charset guess).
    $text = $null
    try {
        if ($resp.RawContentStream) {
            $resp.RawContentStream.Position = 0
            $ms = New-Object System.IO.MemoryStream
            $resp.RawContentStream.CopyTo($ms)
            $text = [System.Text.Encoding]::UTF8.GetString($ms.ToArray())
        }
    } catch { $text = $null }
    if (-not $text) {
        # Fallback: re-encode IWR's Content back to bytes then UTF-8-decode.
        $c = $resp.Content
        if ($c -is [byte[]]) {
            $text = [System.Text.Encoding]::UTF8.GetString($c)
        } else {
            try {
                $raw = [System.Text.Encoding]::GetEncoding(28591).GetBytes([string]$c) # latin1 → bytes
                $text = [System.Text.Encoding]::UTF8.GetString($raw)
            } catch { $text = [string]$c }
        }
    }
    return ($text | ConvertFrom-Json)
}

function Invoke-PromptParleProviderDirect {
    <#
    .SYNOPSIS
      Call AI provider from this PC with a local key. Never sends the key to PromptParle.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('openai', 'anthropic', 'gemini', 'grok')]
        [string]$Provider,

        [Parameter(Mandatory)]
        [string]$ApiKey,

        [Parameter(Mandatory)]
        [string]$Model,

        [Parameter(Mandatory)]
        [string]$Prompt,

        [string]$System = '',
        [string]$Runtime = '',
        [int]$MaxTokens = 4096,
        [object]$Images = $null
    )

    $sysCombined = $System
    if ($Runtime) {
        if ($sysCombined) {
            $sysCombined = $sysCombined + "`n`n[RT] " + $Runtime
        } else {
            $sysCombined = "[RT] " + $Runtime
        }
    }

    switch ($Provider) {
        'openai' {
            return Invoke-PromptParleOpenAiCompatible -BaseUrl 'https://api.openai.com/v1' -ApiKey $ApiKey -Model $Model -Prompt $Prompt -System $sysCombined -MaxTokens $MaxTokens -Images $Images
        }
        'grok' {
            return Invoke-PromptParleOpenAiCompatible -BaseUrl 'https://api.x.ai/v1' -ApiKey $ApiKey -Model $Model -Prompt $Prompt -System $sysCombined -MaxTokens $MaxTokens -Images $Images
        }
        'anthropic' {
            return Invoke-PromptParleAnthropicDirect -ApiKey $ApiKey -Model $Model -Prompt $Prompt -System $System -Runtime $Runtime -MaxTokens $MaxTokens -Images $Images
        }
        'gemini' {
            return Invoke-PromptParleGeminiDirect -ApiKey $ApiKey -Model $Model -Prompt $Prompt -System $sysCombined -MaxTokens $MaxTokens
        }
    }
}

function Test-PromptParleOpenAiReasoningModel {
    <#
    .SYNOPSIS
      OpenAI o-series / gpt-5 reject max_tokens and often reject custom temperature.
    #>
    param([string]$Model)
    $m = ([string]$Model).ToLowerInvariant()
    if (-not $m) { return $false }
    # o1, o1-mini, o3, o3-mini, o4-mini, gpt-5, gpt-5-mini, …
    if ($m -match '(^|/)(o[1-9]([\w.-]*)?|gpt-5([\w.-]*)?)') { return $true }
    return $false
}

function Invoke-PromptParleOpenAiCompatible {
    param(
        [string]$BaseUrl,
        [string]$ApiKey,
        [string]$Model,
        [string]$Prompt,
        [string]$System = '',
        [int]$MaxTokens = 4096,
        [object]$Images = $null
    )
    $messages = New-Object System.Collections.ArrayList
    if ($System) {
        [void]$messages.Add(@{ role = 'system'; content = [string]$System })
    }
    $imgList = @()
    try {
        $imgList = @(ConvertTo-PromptParleImageList -Images $Images)
    } catch {
        $imgList = @()
    }
    if ($imgList.Count -gt 0) {
        $parts = New-Object System.Collections.ArrayList
        [void]$parts.Add(@{ type = 'text'; text = [string]$Prompt })
        foreach ($img in $imgList) {
            $mt = [string](Get-PromptParleProp $img 'media_type' (Get-PromptParleProp $img 'mediaType' 'image/png'))
            $b64 = [string](Get-PromptParleProp $img 'data_base64' (Get-PromptParleProp $img 'dataBase64' ''))
            if (-not $b64) { continue }
            [void]$parts.Add(@{
                    type      = 'image_url'
                    image_url = @{ url = ("data:{0};base64,{1}" -f $mt, $b64) }
                })
        }
        [void]$messages.Add(@{ role = 'user'; content = @($parts.ToArray()) })
    } else {
        [void]$messages.Add(@{ role = 'user'; content = [string]$Prompt })
    }

    $baseTrim = [string]$BaseUrl
    while ($baseTrim.Length -gt 0 -and ($baseTrim[$baseTrim.Length - 1] -eq [char]'/' -or $baseTrim[$baseTrim.Length - 1] -eq [char]'\')) {
        $baseTrim = $baseTrim.Substring(0, $baseTrim.Length - 1)
    }

    # Ordered body so JSON field order is stable; param names differ by provider/model.
    $body = [ordered]@{
        model    = [string]$Model
        messages = @($messages.ToArray())
    }
    $isOpenAiHost = $baseTrim -match 'api\.openai\.com'
    $isReasoning = Test-PromptParleOpenAiReasoningModel -Model $Model
    if ($isOpenAiHost) {
        # o1/o3/o4/gpt-5: max_tokens rejected → max_completion_tokens required.
        # Other OpenAI chat models accept max_completion_tokens as well.
        $body['max_completion_tokens'] = [int]$MaxTokens
        if (-not $isReasoning) {
            $body['temperature'] = 0.2
        }
        # Reasoning models only allow default temperature — omit the field.
    } else {
        # xAI Grok and other OpenAI-compatible hosts still use max_tokens.
        $body['temperature'] = 0.2
        $body['max_tokens'] = [int]$MaxTokens
    }

    $uri = $baseTrim + '/chat/completions'
    $headers = @{
        Authorization = "Bearer $ApiKey"
        Accept        = 'application/json'
        'User-Agent'  = 'PromptParle-LocalFirst/0.26.14'
    }
    try {
        $json = ConvertTo-PromptParleJson -InputObject $body -Depth 12
    } catch {
        $json = ($body | ConvertTo-Json -Depth 12 -Compress)
    }
    try {
        $resp = Invoke-PromptParleJsonPost -Uri $uri -Headers $headers -Json $json -TimeoutSec 180
    } catch {
        $msg = "$_"
        # One automatic retry if a host still wants the other token-limit field name.
        if ($msg -match 'max_completion_tokens' -and $body.Contains('max_tokens')) {
            try {
                $body.Remove('max_tokens')
                $body['max_completion_tokens'] = [int]$MaxTokens
                if ($isReasoning -and $body.Contains('temperature')) { $body.Remove('temperature') }
                try { $json = ConvertTo-PromptParleJson -InputObject $body -Depth 12 } catch { $json = ($body | ConvertTo-Json -Depth 12 -Compress) }
                $resp = Invoke-PromptParleJsonPost -Uri $uri -Headers $headers -Json $json -TimeoutSec 180
            } catch {
                throw "Provider $uri failed: $_"
            }
        } elseif ($msg -match 'max_tokens' -and $body.Contains('max_completion_tokens') -and $msg -match 'Unsupported parameter|not supported') {
            try {
                $body.Remove('max_completion_tokens')
                $body['max_tokens'] = [int]$MaxTokens
                try { $json = ConvertTo-PromptParleJson -InputObject $body -Depth 12 } catch { $json = ($body | ConvertTo-Json -Depth 12 -Compress) }
                $resp = Invoke-PromptParleJsonPost -Uri $uri -Headers $headers -Json $json -TimeoutSec 180
            } catch {
                throw "Provider $uri failed: $_"
            }
        } else {
            throw "Provider $uri failed: $msg"
        }
    }
    $choice = $null
    try { $choice = $resp.choices[0] } catch { }
    $text = ''
    if ($choice) {
        $text = [string](Get-PromptParleProp $choice.message 'content' '')
        if (-not $text) {
            $text = [string](Get-PromptParleProp $choice 'text' '')
        }
    }
    $usage = Get-PromptParleProp $resp 'usage' $null
    $inTok = 0
    $outTok = 0
    if ($usage) {
        $inTok = [int](Get-PromptParleProp $usage 'prompt_tokens' 0)
        $outTok = [int](Get-PromptParleProp $usage 'completion_tokens' 0)
    }
    return [pscustomobject]@{
        Response         = $text
        InputTokens      = $inTok
        OutputTokens     = $outTok
        Model            = $Model
        ProviderResponse = $resp
    }
}

function Invoke-PromptParleAnthropicDirect {
    <#
    .SYNOPSIS
      Anthropic Messages API — PS 5.1 safe (ArrayList + plain hashtables only).
      Never @($orderedDict) for messages (unrolls DictionaryEntry → broken body /
      ArgumentException on some hosts). Never List[string]/List[hashtable].Add.
    #>
    param(
        [string]$ApiKey,
        [string]$Model,
        [string]$Prompt,
        [string]$System = '',
        [string]$Runtime = '',
        [int]$MaxTokens = 4096,
        [object]$Images = $null
    )
    # ArrayList — List[T].Add throws "Argument types do not match" with PS wrappers
    $content = New-Object System.Collections.ArrayList
    $imgList = @()
    try {
        $imgList = @(ConvertTo-PromptParleImageList -Images $Images)
    } catch {
        $imgList = @()
    }
    foreach ($img in $imgList) {
        $mt = [string](Get-PromptParleProp $img 'media_type' (Get-PromptParleProp $img 'mediaType' 'image/png'))
        $b64 = [string](Get-PromptParleProp $img 'data_base64' (Get-PromptParleProp $img 'dataBase64' ''))
        if (-not $b64) { continue }
        $src = @{}
        $src['type'] = 'base64'
        $src['media_type'] = $mt
        $src['data'] = $b64
        $imgBlock = @{}
        $imgBlock['type'] = 'image'
        $imgBlock['source'] = $src
        [void]$content.Add($imgBlock)
    }
    $textBlock = @{}
    $textBlock['type'] = 'text'
    $textBlock['text'] = [string]$Prompt
    [void]$content.Add($textBlock)

    $userMsg = @{}
    $userMsg['role'] = 'user'
    $userMsg['content'] = @($content.ToArray())

    # Build messages as ArrayList then ToArray — never @($hashtable) alone
    # (@($dict) enumerates DictionaryEntry on PS 5.1)
    $messages = New-Object System.Collections.ArrayList
    [void]$messages.Add($userMsg)

    $body = @{}
    $body['model'] = [string]$Model
    $body['max_tokens'] = [int]$MaxTokens
    $body['messages'] = @($messages.ToArray())
    $body['temperature'] = 0.2

    # System as a single string (simplest Anthropic form; avoids List/block cast issues)
    $sysCombined = ''
    if ($System) { $sysCombined = [string]$System }
    if ($Runtime) {
        $rt = '[RT] ' + [string]$Runtime
        if ($sysCombined) { $sysCombined = $sysCombined + "`n`n" + $rt }
        else { $sysCombined = $rt }
    }
    if ($sysCombined) {
        $body['system'] = $sysCombined
    }

    $headers = @{}
    $headers['x-api-key'] = [string]$ApiKey
    $headers['anthropic-version'] = '2023-06-01'
    $headers['Accept'] = 'application/json'
    $headers['User-Agent'] = 'PromptParle-LocalFirst/0.26.26'
    try {
        $json = ConvertTo-PromptParleJson -InputObject $body -Depth 12
    } catch {
        $json = ($body | ConvertTo-Json -Depth 12 -Compress)
    }
    try {
        $resp = Invoke-PromptParleJsonPost -Uri 'https://api.anthropic.com/v1/messages' -Headers $headers -Json $json -TimeoutSec 180
    } catch {
        throw "Anthropic failed: $_"
    }
    $text = ''
    try {
        foreach ($block in @($resp.content)) {
            if ((Get-PromptParleProp $block 'type' '') -eq 'text') {
                $text = $text + [string](Get-PromptParleProp $block 'text' '')
            }
        }
    } catch { }
    $usage = Get-PromptParleProp $resp 'usage' $null
    $inTok = 0
    $outTok = 0
    if ($usage) {
        $inTok = [int](Get-PromptParleProp $usage 'input_tokens' 0)
        $outTok = [int](Get-PromptParleProp $usage 'output_tokens' 0)
    }
    return [pscustomobject]@{
        Response         = $text
        InputTokens      = $inTok
        OutputTokens     = $outTok
        Model            = $Model
        ProviderResponse = $resp
    }
}

function Invoke-PromptParleGeminiDirect {
    param(
        [string]$ApiKey,
        [string]$Model,
        [string]$Prompt,
        [string]$System = '',
        [int]$MaxTokens = 4096
    )
    $full = $Prompt
    if ($System) {
        $full = $System + "`n`n" + $Prompt
    }
    $part = [ordered]@{}
    $part['text'] = $full
    $content = [ordered]@{}
    $content['role'] = 'user'
    $content['parts'] = @($part)
    $gen = [ordered]@{}
    $gen['maxOutputTokens'] = $MaxTokens
    $gen['temperature'] = 0.2
    $body = [ordered]@{}
    $body['contents'] = @($content)
    $body['generationConfig'] = $gen

    $uri = "https://generativelanguage.googleapis.com/v1beta/models/$([Uri]::EscapeDataString($Model)):generateContent?key=$([Uri]::EscapeDataString($ApiKey))"
    $json = $body | ConvertTo-Json -Depth 10 -Compress
    try {
        $resp = Invoke-PromptParleJsonPost -Uri $uri -Json $json -TimeoutSec 180
    } catch {
        throw "Gemini failed: $_"
    }
    $text = ''
    try {
        $text = [string]$resp.candidates[0].content.parts[0].text
    } catch { }
    $usage = Get-PromptParleProp $resp 'usageMetadata' $null
    $inTok = 0
    $outTok = 0
    if ($usage) {
        $inTok = [int](Get-PromptParleProp $usage 'promptTokenCount' 0)
        $outTok = [int](Get-PromptParleProp $usage 'candidatesTokenCount' 0)
    }
    return [pscustomobject]@{
        Response         = $text
        InputTokens      = $inTok
        OutputTokens     = $outTok
        Model            = $Model
        ProviderResponse = $resp
    }
}

function Invoke-PromptParleLocalFirst {
    <#
    .SYNOPSIS
      Full local path: secret gate, local optimize, direct provider (or optimize-only).
      Does not send prompt/context/provider keys to PromptParle.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Prompt,

        [string]$Context = '',
        [string]$System = '',
        [string]$Runtime = '',

        [ValidateSet('openai', 'anthropic', 'gemini', 'grok')]
        [string]$Provider = 'openai',

        [string]$Model = '',
        [string]$Profile = 'general',
        [int]$CompressionLevel = 3,
        [switch]$OptimizeOnly,
        [object]$Images = $null,
        [switch]$Quiet
    )

    $gate = Invoke-PromptParleSecretGate -Prompt $Prompt -Context $Context -System $System -Runtime $Runtime
    $opt = Invoke-PromptParleLocalOptimizeCore -Prompt $gate.Prompt -Context $gate.Context -Profile $Profile -CompressionLevel $CompressionLevel

    $allDrops = @($gate.Drops) + @($opt.Drops)
    $allNotes = @()
    if ($gate.MaskedCount -gt 0) {
        $allNotes += "client secret mask: $($gate.MaskedCount)"
    }
    $allNotes += @($opt.Notes)

    $meta = @{}  # plain HT — never cast OrderedDictionary to PSCustomObject
    $meta['original_tokens'] = $opt.OriginalTokens
    $meta['optimized_tokens'] = $opt.OptimizedTokens
    $meta['token_reduction_percent'] = $opt.ReductionPercent
    $meta['tokens_saved'] = [Math]::Max(0, [int]$opt.OriginalTokens - [int]$opt.OptimizedTokens)
    $meta['expanded'] = ([int]$opt.OptimizedTokens -gt [int]$opt.OriginalTokens -and [int]$opt.OriginalTokens -gt 0)
    $meta['optimization_profile'] = $Profile
    $meta['compression_level'] = $opt.CompressionLevel
    $meta['secrets_masked'] = ($gate.MaskedCount -gt 0)
    $meta['secret_findings'] = @($gate.Findings)
    $meta['notes'] = $allNotes
    $meta['strategy'] = 'local-first'
    $meta['local_first'] = $true
    $meta['drops'] = $allDrops
    $meta['provider'] = $Provider
    $meta['model'] = $Model
    $meta['key_source'] = 'local'

    if ($OptimizeOnly) {
        if (-not $Quiet) {
            Write-Host ("  local-first optimize: {0} -> {1} tok (-{2}%)" -f $opt.OriginalTokens, $opt.OptimizedTokens, $opt.ReductionPercent) -ForegroundColor Green
        }
        # PS hashtable keys are case-insensitive — only one casing per name
        return [pscustomobject]@{
            OptimizedPrompt = $opt.OptimizedPrompt
            Metadata        = (ConvertTo-PromptParleCustomObject $meta)
            Response        = $null
            Provider        = $Provider
            Profile         = $Profile
            OptimizeOnly    = $true
            LocalFirst      = $true
        }
    }

    $apiKey = Get-PromptParleLocalProviderKey -Provider $Provider
    if (-not $apiKey) {
        throw "No local $Provider key on this PC. Run: Set-PromptParleProviderKey -Provider $Provider -ApiKey '...'  (keys stay on this machine; portal is licensing only)."
    }
    if (-not $Model) {
        $Model = Get-PromptParleDefaultModelLocal -Provider $Provider
    }
    $meta['model'] = $Model

    if (-not $Quiet) {
        Write-Host ("  local-first: provider={0} model={1} {2}->{3} tok (-{4}%) [no portal hop]" -f `
                $Provider, $Model, $opt.OriginalTokens, $opt.OptimizedTokens, $opt.ReductionPercent) -ForegroundColor Cyan
    }

    $direct = Invoke-PromptParleProviderDirect `
        -Provider $Provider `
        -ApiKey $apiKey `
        -Model $Model `
        -Prompt $opt.OptimizedPrompt `
        -System $gate.System `
        -Runtime $gate.Runtime `
        -Images $Images

    if ($direct.InputTokens -gt 0) {
        $meta['provider_input_tokens'] = $direct.InputTokens
        $meta['provider_output_tokens'] = $direct.OutputTokens
    }
    $meta['model'] = $direct.Model

    return [pscustomobject]@{
        Response        = $direct.Response
        OptimizedPrompt = $opt.OptimizedPrompt
        Metadata        = (ConvertTo-PromptParleCustomObject $meta)
        Provider        = $Provider
        Model           = $direct.Model
        Profile         = $Profile
        OptimizeOnly    = $false
        LocalFirst      = $true
    }
}

function Test-PromptParleLocalFirstReady {
    param([string]$Provider = 'openai')
    $k = Get-PromptParleLocalProviderKey -Provider $Provider
    return [bool]$k
}
