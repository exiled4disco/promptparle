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
$script:PromptParleConsoleRestart = $false
$script:PromptParleConsoleBusy = $false
$script:PromptParlePostStopExit = $false
$script:PromptParlePostStopRestart = $false
$script:PromptParlePostStopPort = 7788

#region Private helpers

function ConvertTo-PromptParleCustomObject {
    <#
    .SYNOPSIS
      Hashtable / OrderedDictionary → PSCustomObject without cast.
      [pscustomobject]$orderedDict throws System.ArgumentException
      "Argument types do not match" on Windows PS 5.1 and PS 7.x.
    #>
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [System.Management.Automation.PSCustomObject]) { return $Value }
    # Already a pure PSObject with note properties (not a dictionary wrapper)
    if ($Value -is [System.Management.Automation.PSObject] -and -not ($Value -is [System.Collections.IDictionary])) {
        # If it already behaves like a bag of note props, keep it
        if ($Value.PSObject -and $Value.PSObject.Properties -and @($Value.PSObject.Properties).Count -gt 0) {
            return $Value
        }
    }
    if ($Value -is [System.Collections.IDictionary]) {
        $o = New-Object -TypeName System.Management.Automation.PSObject
        foreach ($key in @($Value.Keys)) {
            if ($null -eq $key) { continue }
            $name = [string]$key
            if ([string]::IsNullOrEmpty($name)) { continue }
            $val = $null
            try { $val = $Value[$key] } catch {
                try { $val = $Value[$name] } catch { $val = $null }
            }
            try {
                Add-Member -InputObject $o -MemberType NoteProperty -Name $name -Value $val -Force -ErrorAction Stop
            } catch {
                # Skip bad key/value pairs rather than fail the whole session load
            }
        }
        return $o
    }
    return $Value
}

function Get-PromptParleProp {
    <#
    .SYNOPSIS
      Read a note property under Set-StrictMode (missing props must not throw).
      Also supports IDictionary / OrderedDictionary (session state builders).
    #>
    param(
        $Object,
        [Parameter(Mandatory)][string]$Name,
        $Default = $null
    )
    if ($null -eq $Object) { return $Default }
    try {
        # Hashtable / OrderedDictionary / Dictionary — do not use PSObject.Properties alone
        if ($Object -is [System.Collections.IDictionary]) {
            # Prefer ContainsKey when present (generic Dictionary); Contains can throw on key type mismatch
            $has = $false
            try {
                if ($Object -is [System.Collections.IDictionary]) {
                    foreach ($k in @($Object.Keys)) {
                        if ([string]$k -eq $Name) {
                            return $Object[$k]
                        }
                    }
                    return $Default
                }
            } catch {
                return $Default
            }
            return $Default
        }
        $prop = $null
        try { $prop = $Object.PSObject.Properties[$Name] } catch { $prop = $null }
        if ($null -eq $prop) {
            # Case-insensitive fallback
            foreach ($p in @($Object.PSObject.Properties)) {
                if ($p -and [string]$p.Name -eq $Name) { return $p.Value }
            }
            return $Default
        }
        return $prop.Value
    } catch {
        return $Default
    }
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

    # Dictionary from JavaScriptSerializer — never [pscustomobject]$ordered (Argument types do not match)
    if ($Value -is [System.Collections.IDictionary]) {
        $ht = @{}
        foreach ($key in $Value.Keys) {
            $ht[[string]$key] = ConvertTo-PromptParlePsObject $Value[$key]
        }
        return (ConvertTo-PromptParleCustomObject $ht)
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
      Normalize UI/API image objects into a flat object[] of hashtables.
      Do NOT use unary-comma return — that nests as [[img,img]] after @() wrap
      and Zod rejects with "images: expected object, received array".
      ArrayList only — List[hashtable].Add throws on PS 5.1 with some wrappers.
    #>
    param($Images)

    $out = New-Object System.Collections.ArrayList
    if ($null -eq $Images) { return @() }

    # Flatten one nesting level (PS often wraps arrays)
    $items = New-Object System.Collections.ArrayList
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
        $entry = @{}
        $entry['media_type'] = [string]$mediaType
        $entry['data_base64'] = [string]$data
        if ($name) { $entry['name'] = [string]$name }
        [void]$out.Add($entry)
        if ($out.Count -ge 6) { break }
    }
    # Flat array of hashtables (pipeline-unroll is OK — callers use @())
    return @($out.ToArray())
}

function Protect-PromptParleSecret {
    <#
    .SYNOPSIS
      Protect a secret for local disk storage (Windows DPAPI CurrentUser; else plain).
    #>
    param([Parameter(Mandatory)][string]$PlainText)
    if (-not $script:PromptParleIsWindows) { return $PlainText }
    try {
        Add-Type -AssemblyName System.Security -ErrorAction Stop
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($PlainText)
        $protected = [System.Security.Cryptography.ProtectedData]::Protect(
            $bytes,
            $null,
            [System.Security.Cryptography.DataProtectionScope]::CurrentUser
        )
        return 'dpapi:' + [Convert]::ToBase64String($protected)
    } catch {
        Write-Warning "DPAPI protect failed; storing key with file ACL only: $_"
        return $PlainText
    }
}

function Unprotect-PromptParleSecret {
    <#
    .SYNOPSIS
      Reverse Protect-PromptParleSecret. Plain values (legacy) pass through.
    #>
    param([Parameter(Mandatory)][string]$Stored)
    if (-not $Stored) { return $Stored }
    if (-not $Stored.StartsWith('dpapi:')) { return $Stored }
    if (-not $script:PromptParleIsWindows) {
        Write-Warning 'Encrypted API key found but DPAPI is Windows-only.'
        return $null
    }
    try {
        Add-Type -AssemblyName System.Security -ErrorAction Stop
        $b64 = $Stored.Substring(6)
        $protected = [Convert]::FromBase64String($b64)
        $bytes = [System.Security.Cryptography.ProtectedData]::Unprotect(
            $protected,
            $null,
            [System.Security.Cryptography.DataProtectionScope]::CurrentUser
        )
        return [System.Text.Encoding]::UTF8.GetString($bytes)
    } catch {
        Write-Warning "Could not decrypt API key (DPAPI). Re-run Set-PromptParleApiKey. $_"
        return $null
    }
}

# Local-first: provider keys + optimize + direct provider calls (portal = licensing only)
$script:PromptParleLocalFirstPath = Join-Path $PSScriptRoot 'LocalFirst.ps1'
if (Test-Path -LiteralPath $script:PromptParleLocalFirstPath) {
    . $script:PromptParleLocalFirstPath
} else {
    Write-Warning "LocalFirst.ps1 missing at $($script:PromptParleLocalFirstPath) — local provider path unavailable"
}

# Module dir (for spawning a detached child pwsh that re-imports the module).
$script:PromptParleModuleDir = $PSScriptRoot

# =============================================================================
# 0.30 Background jobs: long turns run in a DETACHED child pwsh process so the
# single-threaded local HTTP server never blocks. Job state is file-backed under
# the config dir (jobs/<id>.json); the child writes the final result there. The
# UI polls /api/chat/job. Result lands in the origin chat (client_session_id).
# =============================================================================

function Get-PromptParleJobsDir {
    $dir = Join-Path $script:PromptParleConfigDir 'jobs'
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    return $dir
}

function Get-PromptParleJobPath {
    param([Parameter(Mandatory)][string]$Id)
    $safe = ($Id -replace '[^A-Za-z0-9_-]', '')
    if (-not $safe) { throw 'bad job id' }
    return (Join-Path (Get-PromptParleJobsDir) ("$safe.json"))
}

function Read-PromptParleJob {
    param([Parameter(Mandatory)][string]$Id)
    $path = Get-PromptParleJobPath -Id $Id
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try {
        $raw = Get-Content -LiteralPath $path -Raw -ErrorAction Stop
        if (-not $raw) { return $null }
        return (ConvertFrom-PromptParleJson -Json $raw)
    } catch { return $null }
}

function Write-PromptParleJob {
    param([Parameter(Mandatory)]$Job)
    $id = [string](Get-PromptParleProp $Job 'id' '')
    if (-not $id) { throw 'job has no id' }
    $path = Get-PromptParleJobPath -Id $id
    $tmp = "$path.tmp"
    $json = ConvertTo-PromptParleJson -InputObject $Job -Depth 12
    # Atomic-ish write so a poller never reads a half-written file.
    Set-Content -LiteralPath $tmp -Value $json -Encoding UTF8
    try { Move-Item -LiteralPath $tmp -Destination $path -Force } catch { Set-Content -LiteralPath $path -Value $json -Encoding UTF8 }
}

function Start-PromptParleChatJob {
    <#
    .SYNOPSIS
      Spawn a detached child pwsh to run one chat turn in the background.
      Returns { job_id, status='running' } immediately. Child writes the final
      result (response + metadata) into jobs/<id>.json when done.
    #>
    param(
        [Parameter(Mandatory)][hashtable]$Payload,
        [string]$SessionId = '',
        [string]$Title = ''
    )
    # id: time-free (Date.now unavailable concerns don't apply here — module, not workflow)
    $id = 'job_' + ([guid]::NewGuid().ToString('N').Substring(0, 16))
    $now = (Get-Date).ToUniversalTime().ToString('o')
    $job = [pscustomobject]@{
        id                = $id
        status            = 'running'
        session_id        = [string]$SessionId
        title             = [string]$Title
        created_at        = $now
        updated_at        = $now
        prompt_preview    = ([string](Get-PromptParleProp $Payload 'message' '')).Substring(0, [Math]::Min(80, ([string](Get-PromptParleProp $Payload 'message' '')).Length))
        response          = $null
        metadata          = $null
        error             = $null
    }
    Write-PromptParleJob -Job $job

    # Hand the payload + job path to the child via a temp request file.
    $reqPath = (Get-PromptParleJobPath -Id $id) -replace '\.json$', '.req.json'
    Set-Content -LiteralPath $reqPath -Value (ConvertTo-PromptParleJson -InputObject $Payload -Depth 12) -Encoding UTF8

    $modDir = $script:PromptParleModuleDir
    $cfgDir = $script:PromptParleConfigDir
    $jobPath = Get-PromptParleJobPath -Id $id
    # Child script: import module, run the turn via the shared runner, write result.
    $childScript = @"
`$ErrorActionPreference = 'Stop'
`$env:PROMPTPARLE_CONFIG_DIR = '$($cfgDir -replace "'", "''")'
Import-Module '$($modDir -replace "'", "''")\PromptParle.psd1' -Force
try {
    Invoke-PromptParleRunChatJob -JobPath '$($jobPath -replace "'", "''")' -RequestPath '$($reqPath -replace "'", "''")'
} catch {
    try {
        `$j = Get-Content -LiteralPath '$($jobPath -replace "'", "''")' -Raw | ConvertFrom-Json
        `$j.status = 'error'; `$j.error = "`$_"
        `$j | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath '$($jobPath -replace "'", "''")' -Encoding UTF8
    } catch { }
}
"@
    $b64 = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($childScript))
    $pwshExe = (Get-Process -Id $PID).Path
    if (-not $pwshExe) { $pwshExe = if ($script:PromptParleIsWindows) { 'powershell.exe' } else { 'pwsh' } }
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $pwshExe
        $psi.Arguments = "-NoProfile -NonInteractive -EncodedCommand $b64"
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.WindowStyle = 'Hidden'
        [void][System.Diagnostics.Process]::Start($psi)
    } catch {
        # Could not spawn — mark failed so the UI stops polling.
        $job.status = 'error'; $job.error = "spawn failed: $($_.Exception.Message)"
        Write-PromptParleJob -Job $job
    }
    return [pscustomobject]@{ job_id = $id; status = $job.status }
}

function Invoke-PromptParleRunChatJob {
    <#
    .SYNOPSIS
      Child-process entry: read the request payload, run the turn synchronously
      via the shared runner, write the result into the job file. Runs in a fresh
      process so it never touches the parent's HTTP listener.
    #>
    param(
        [Parameter(Mandatory)][string]$JobPath,
        [Parameter(Mandatory)][string]$RequestPath
    )
    $job = Get-Content -LiteralPath $JobPath -Raw | ConvertFrom-Json
    $payload = Get-Content -LiteralPath $RequestPath -Raw | ConvertFrom-Json
    try {
        $res = Invoke-PromptParleChatTurnCore -Body $payload
        $job.status = 'done'
        $job.response = [string](Get-PromptParleProp $res 'response' '')
        $job.metadata = Get-PromptParleProp $res 'metadata' $null
        $job.error = $null
    } catch {
        $job.status = 'error'
        $job.error = "$_"
    }
    $job.updated_at = (Get-Date).ToUniversalTime().ToString('o')
    $json = $job | ConvertTo-Json -Depth 12
    Set-Content -LiteralPath $JobPath -Value $json -Encoding UTF8
    try { Remove-Item -LiteralPath $RequestPath -Force -ErrorAction SilentlyContinue } catch { }
}

function Get-PromptParleJobList {
    <# Pending/recent jobs for the UI badge. Prunes finished jobs older than 1h. #>
    $dir = Get-PromptParleJobsDir
    $out = New-Object System.Collections.ArrayList
    Get-ChildItem -LiteralPath $dir -Filter '*.json' -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notmatch '\.req\.json$' } |
        ForEach-Object {
            try {
                $j = ConvertFrom-PromptParleJson -Json (Get-Content -LiteralPath $_.FullName -Raw)
                [void]$out.Add([pscustomobject]@{
                    id         = [string](Get-PromptParleProp $j 'id' '')
                    status     = [string](Get-PromptParleProp $j 'status' 'running')
                    session_id = [string](Get-PromptParleProp $j 'session_id' '')
                    title      = [string](Get-PromptParleProp $j 'title' '')
                    updated_at = [string](Get-PromptParleProp $j 'updated_at' '')
                })
            } catch { }
        }
    return @($out.ToArray())
}

function Set-PromptParleConfigAcl {
    <#
      Restrict config/token file to current user on Windows.
      Best-effort only: some sessions lack SeSecurityPrivilege (Set-Acl noise).
      Never write console errors — profile NTFS defaults are acceptable fallback.
    #>
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    if ($script:PromptParleIsWindows) {
        try {
            $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
            $acl.SetAccessRuleProtection($true, $false)
            $rules = @($acl.Access)
            foreach ($r in $rules) {
                try { [void]$acl.RemoveAccessRule($r) } catch { }
            }
            $user = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
            $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
                $user, 'FullControl', 'Allow'
            )
            $acl.AddAccessRule($rule)
            # -ErrorAction Stop so PrivilegeNotHeld is caught (non-terminating by default)
            Set-Acl -LiteralPath $Path -AclObject $acl -ErrorAction Stop
        } catch {
            # Fallback: icacls (still best-effort; silence all output)
            try {
                $userName = $env:USERNAME
                if ($userName) {
                    $null = & icacls.exe $Path /inheritance:r /grant:r "${userName}:(F)" 2>&1
                }
            } catch { }
            Write-Verbose ("Set-PromptParleConfigAcl: best-effort ACL skipped for {0}: {1}" -f $Path, $_)
        }
    } else {
        try { chmod 600 $Path 2>$null } catch { }
    }
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
            if ($json.ApiKey) {
                $stored = [string]$json.ApiKey
                $config.ApiKey = Unprotect-PromptParleSecret -Stored $stored
                # Migrate legacy plaintext → DPAPI on next successful read (Windows)
                if (
                    $script:PromptParleIsWindows -and
                    $config.ApiKey -and
                    -not $stored.StartsWith('dpapi:')
                ) {
                    try {
                        $base = if ($json.BaseUrl) { [string]$json.BaseUrl } else { $script:DefaultBaseUrl }
                        $cid = [string](Get-PromptParleProp $json 'DesktopClientId' '')
                        Save-PromptParleConfigInternal -ApiKey $config.ApiKey -BaseUrl $base -DesktopClientId $cid
                    } catch { }
                }
            }
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

    return (ConvertTo-PromptParleCustomObject $config)
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

    # Preserve existing desktop client id + local provider keys (Local-first)
    $existingClientId = ''
    $existingProviders = $null
    $existingSecretPolicy = 'strict'
    if (Test-Path -LiteralPath $script:PromptParleConfigPath) {
        try {
            $prev = Get-Content -LiteralPath $script:PromptParleConfigPath -Raw | ConvertFrom-Json
            if (-not $DesktopClientId) {
                $existingClientId = [string](Get-PromptParleProp $prev 'DesktopClientId' '')
            }
            $existingProviders = Get-PromptParleProp $prev 'Providers' $null
            $sp = [string](Get-PromptParleProp $prev 'SecretPolicy' 'strict')
            if ($sp) { $existingSecretPolicy = $sp }
        } catch { }
    }
    $clientId = if ($DesktopClientId) { $DesktopClientId } else { $existingClientId }

    $protectedKey = Protect-PromptParleSecret -PlainText $ApiKey
    $obj = [ordered]@{
        ApiKey           = $protectedKey
        BaseUrl          = $BaseUrl.TrimEnd('/')
        DesktopClientId  = $clientId
        UpdatedAt        = (Get-Date).ToUniversalTime().ToString('o')
        KeyProtection    = $(if ($protectedKey.StartsWith('dpapi:')) { 'dpapi-currentuser' } else { 'file-acl' })
        SecretPolicy     = $existingSecretPolicy
        LocalFirst       = $true
    }
    if ($null -ne $existingProviders) {
        $obj['Providers'] = $existingProviders
    }

    $obj | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $script:PromptParleConfigPath -Encoding UTF8
    Set-PromptParleConfigAcl -Path $script:PromptParleConfigPath
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

    # Per-tool savings breakdown (0.28.0): honest counterfactual per local tool.
    # chars_saved is vendor-neutral; shown as ~tokens (chars/4). Safety tools (0) labeled.
    $tb = Get-PromptParleProp $Metadata 'tool_breakdown' $null
    if ($tb) {
        $parts = @()
        foreach ($t in @($tb)) {
            if ($null -eq $t) { continue }
            $tn = [string](Get-PromptParleProp $t 'tool' '')
            if (-not $tn) { continue }
            $kind = [string](Get-PromptParleProp $t 'kind' 'measured')
            $cs = [int](Get-PromptParleProp $t 'chars_saved' 0)
            if ($kind -eq 'none') {
                $parts += ("{0} (safety)" -f $tn)
            } elseif ($cs -gt 0) {
                $parts += ("{0} -{1}t" -f $tn, [Math]::Max(1, [int][Math]::Ceiling($cs / 4.0)))
            }
        }
        if ($parts.Count -gt 0) {
            Write-Host ("  By tool         : {0}" -f ($parts -join ', ')) -ForegroundColor DarkGreen
        }
    }
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
        Write-Host 'No AI provider keys on this PC yet.' -ForegroundColor Yellow
        Write-Host "Run: Set-PromptParleProviderKey -Provider openai -ApiKey 'sk-...'" -ForegroundColor Yellow
        Write-Host '(Keys stay local. Portal is licensing only.)' -ForegroundColor DarkGray
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

# --- 0.29 Tool-savings bridge: local rollup → periodic POST to portal ---
# Privacy: aggregate numbers/labels only (tool, provider, chars_saved, count).
# NEVER prompt/context bodies. Rolls up per day; flushed on heartbeat.
$script:PromptParleToolSavingsTools = @(
    'fleet', 'error_brief', 'code_brief', 'relevant_slice', 'git', 'ssh_read',
    'chat_memory', 'budget_cap', 'framing', 'web_page', 'quality_gate'
)

function Get-PromptParleToolSavingsPath {
    return (Join-Path $script:PromptParleConfigDir 'tool-savings.json')
}

function Add-PromptParleToolSavings {
    <#
    .SYNOPSIS
      Accumulate one turn's tool_breakdown into the local daily rollup.
      Keyed by day|tool|provider → { chars_saved, occurrences }. Numbers only.
    #>
    param(
        [object[]]$Breakdown = @(),
        [string]$Provider = 'unknown',
        [string]$Day = ''
    )
    if (-not $Breakdown -or $Breakdown.Count -eq 0) { return }
    $d = if ($Day) { $Day } else { (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd') }
    $prov = if ($Provider) { [string]$Provider } else { 'unknown' }
    # Load existing rows into a plain hashtable keyed "day|tool|provider".
    $rows = Get-PromptParleToolSavingsRows
    foreach ($b in $Breakdown) {
        if ($null -eq $b) { continue }
        $tool = [string](Get-PromptParleProp $b 'tool' '')
        if (-not $tool -or ($script:PromptParleToolSavingsTools -notcontains $tool)) { continue }
        $saved = [int](Get-PromptParleProp $b 'chars_saved' 0)
        if ($saved -le 0) { continue }   # only real savings roll up (safety tools = 0)
        $key = "$d|$tool|$prov"
        if (-not $rows.ContainsKey($key)) {
            $rows[$key] = @{ day = $d; tool = $tool; provider = $prov; chars_saved = 0; occurrences = 0 }
        }
        $rows[$key]['chars_saved'] = [int]$rows[$key]['chars_saved'] + $saved
        $rows[$key]['occurrences'] = [int]$rows[$key]['occurrences'] + 1
    }
    Save-PromptParleToolSavingsRows -Rows $rows
}

function Get-PromptParleToolSavingsRows {
    <# Load the rollup file into a plain hashtable keyed "day|tool|provider". #>
    $path = Get-PromptParleToolSavingsPath
    $rows = @{}
    if (-not (Test-Path -LiteralPath $path)) { return $rows }
    try {
        $raw = Get-Content -LiteralPath $path -Raw -ErrorAction Stop
        if (-not $raw) { return $rows }
        $parsed = ConvertFrom-PromptParleJson -Json $raw
        $arr = Get-PromptParleProp $parsed 'rows' @()
        foreach ($r in @($arr)) {
            if ($null -eq $r) { continue }
            $day = [string](Get-PromptParleProp $r 'day' '')
            $tool = [string](Get-PromptParleProp $r 'tool' '')
            $prov = [string](Get-PromptParleProp $r 'provider' 'unknown')
            if (-not $day -or -not $tool) { continue }
            $key = "$day|$tool|$prov"
            $rows[$key] = @{
                day         = $day
                tool        = $tool
                provider    = $prov
                chars_saved = [int](Get-PromptParleProp $r 'chars_saved' 0)
                occurrences = [int](Get-PromptParleProp $r 'occurrences' 0)
            }
        }
    } catch { return @{} }
    return $rows
}

function Save-PromptParleToolSavingsRows {
    <# Persist the rollup hashtable as { rows: [ {day,tool,provider,chars_saved,occurrences} ] }. #>
    param([hashtable]$Rows = @{})
    $path = Get-PromptParleToolSavingsPath
    $list = New-Object System.Collections.ArrayList
    foreach ($k in @($Rows.Keys)) {
        $r = $Rows[$k]
        [void]$list.Add([pscustomobject]@{
            day         = [string]$r['day']
            tool        = [string]$r['tool']
            provider    = [string]$r['provider']
            chars_saved = [int]$r['chars_saved']
            occurrences = [int]$r['occurrences']
        })
    }
    try {
        $obj = [pscustomobject]@{ rows = @($list.ToArray()) }
        $json = ConvertTo-PromptParleJson -InputObject $obj -Depth 6
        Set-Content -LiteralPath $path -Value $json -Encoding UTF8
    } catch { }
}

function Send-PromptParleToolSavings {
    <#
    .SYNOPSIS
      Flush unsent daily rollup rows to the portal (POST /api/v1/desktop/savings).
      On 200, clears the flushed rows. Best-effort; silent on failure (offline OK).
    #>
    param([int]$MinRows = 1)
    $path = Get-PromptParleToolSavingsPath
    if (-not (Test-Path -LiteralPath $path)) { return }
    $store = $null
    try {
        $raw = Get-Content -LiteralPath $path -Raw -ErrorAction Stop
        if ($raw) { $store = ConvertFrom-PromptParleJson -Json $raw -AsHashtable }
    } catch { return }
    if ($null -eq $store -or -not $store.ContainsKey('rows')) { return }
    $rows = $store['rows']
    $keys = @($rows.Keys)
    if ($keys.Count -lt $MinRows) { return }

    # Group by day → items[] for the endpoint (one POST per day present)
    $byDay = @{}
    foreach ($k in $keys) {
        $r = $rows[$k]
        $day = [string]$r['day']
        if (-not $byDay.ContainsKey($day)) { $byDay[$day] = New-Object System.Collections.ArrayList }
        [void]$byDay[$day].Add(@{
            tool        = [string]$r['tool']
            provider    = [string]$r['provider']
            chars_saved = [int]$r['chars_saved']
            occurrences = [int]$r['occurrences']
        })
    }
    $sentAny = $false
    foreach ($day in @($byDay.Keys)) {
        $items = @($byDay[$day].ToArray())
        if ($items.Count -eq 0) { continue }
        try {
            $body = @{ day = $day; items = $items }
            $null = Invoke-PromptParleApi -Method POST -Path '/api/v1/desktop/savings' -Body $body
            # On success, drop this day's rows from the store
            foreach ($k in @($rows.Keys)) {
                if ([string]$rows[$k]['day'] -eq $day) { [void]$rows.Remove($k) }
            }
            $sentAny = $true
        } catch {
            # Offline / older server without the endpoint: keep rows for next flush.
            Write-PromptParleDebugLog ("tool-savings flush skipped: " + $_.Exception.Message)
        }
    }
    if ($sentAny) {
        try {
            $store['rows'] = $rows
            $json = ($store | ConvertTo-PromptParleJson -Depth 6)
            Set-Content -LiteralPath $path -Value $json -Encoding UTF8
        } catch { }
    }
}

# --- 0.26 multi-connection + on-disk catalog (token-cheap) ---
$script:PromptParleMaxLocalConnections = 5
$script:PromptParleMaxKnowledgeConnections = 2
$script:PromptParleCatalogMaxFiles = 2000

function Get-PromptParleCatalogDir {
    $dir = Join-Path $script:PromptParleConfigDir 'catalog'
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    return $dir
}

function New-PromptParleConnectionId {
    param([string]$Prefix = 'c')
    $p = if ($Prefix) { $Prefix } else { 'c' }
    return ('{0}_{1}' -f $p, ([guid]::NewGuid().ToString('N').Substring(0, 10)))
}

function ConvertTo-PromptParleBool {
    param($Value, [bool]$Default = $false)
    if ($null -eq $Value) { return $Default }
    try {
        if ($Value -is [bool]) { return $Value }
        if ($Value -is [int] -or $Value -is [long]) { return ($Value -ne 0) }
        $s = [string]$Value
        if ([string]::IsNullOrWhiteSpace($s)) { return $Default }
        if ($s -eq '1' -or $s -eq 'true' -or $s -eq 'True' -or $s -eq 'TRUE' -or $s -eq 'yes') { return $true }
        if ($s -eq '0' -or $s -eq 'false' -or $s -eq 'False' -or $s -eq 'FALSE' -or $s -eq 'no') { return $false }
        return [System.Convert]::ToBoolean($Value)
    } catch {
        return $Default
    }
}

function ConvertTo-PromptParleConnectionObject {
    param($Item)
    if ($null -eq $Item) { return $null }
    try {
        $kind = [string](Get-PromptParleProp $Item 'kind' 'local')
        if ([string]::IsNullOrWhiteSpace($kind)) { $kind = 'local' }
        $kind = $kind.Trim().ToLowerInvariant()
        if ($kind -ne 'local' -and $kind -ne 'knowledge' -and $kind -ne 'ssh' -and $kind -ne 'git') { $kind = 'local' }
        $id = [string](Get-PromptParleProp $Item 'id' '')
        if ([string]::IsNullOrWhiteSpace($id)) {
            $pref = if ($kind -eq 'knowledge') { 'kn' } else { 'pc' }
            $id = New-PromptParleConnectionId -Prefix $pref
        }
        $label = [string](Get-PromptParleProp $Item 'label' '')
        $path = [string](Get-PromptParleProp $Item 'path' '')
        $source = [string](Get-PromptParleProp $Item 'source' 'local')
        if ([string]::IsNullOrWhiteSpace($source)) { $source = 'local' }
        $source = $source.Trim().ToLowerInvariant()
        if ($source -ne 'ssh') { $source = 'local' }
        $active = ConvertTo-PromptParleBool -Value (Get-PromptParleProp $Item 'active' $false) -Default $false
        $readonly = ($kind -eq 'knowledge')
        if ($null -ne (Get-PromptParleProp $Item 'readonly' $null)) {
            $readonly = ConvertTo-PromptParleBool -Value (Get-PromptParleProp $Item 'readonly' $readonly) -Default $readonly
        }
        if ($kind -eq 'knowledge') { $readonly = $true }
        # Inline port/count — do not call helpers that may not be defined yet / throw binder errors
        $portRaw = Get-PromptParleProp $Item 'ssh_port' 22
        $portN = 22
        try {
            if ($portRaw -is [int]) { $portN = $portRaw }
            elseif ($portRaw -is [long]) { $portN = [int]$portRaw }
            else {
                $ps = [string]$portRaw
                if (-not [string]::IsNullOrWhiteSpace($ps)) { $portN = [Convert]::ToInt32($ps.Trim(), 10) }
            }
            if ($portN -lt 1 -or $portN -gt 65535) { $portN = 22 }
        } catch { $portN = 22 }
        $fcN = 0
        try {
            $fcRaw = Get-PromptParleProp $Item 'file_count' 0
            if ($fcRaw -is [int]) { $fcN = $fcRaw }
            elseif ($fcRaw -is [long]) { $fcN = [int]$fcRaw }
            else {
                $fs = [string]$fcRaw
                if (-not [string]::IsNullOrWhiteSpace($fs)) { $fcN = [Convert]::ToInt32($fs.Trim(), 10) }
            }
        } catch { $fcN = 0 }
        $cat = [string](Get-PromptParleProp $Item 'catalog_id' $id)
        if ([string]::IsNullOrWhiteSpace($cat)) { $cat = $id }
        return [pscustomobject]@{
            id         = $id
            kind       = $kind
            label      = $label
            path       = $path
            active     = $active
            readonly   = $readonly
            source     = $source
            ssh_target = [string](Get-PromptParleProp $Item 'ssh_target' '')
            ssh_port   = $portN
            ssh_cwd    = [string](Get-PromptParleProp $Item 'ssh_cwd' '')
            ssh_name   = [string](Get-PromptParleProp $Item 'ssh_name' '')
            catalog_id = $cat
            indexed_at = [string](Get-PromptParleProp $Item 'indexed_at' '')
            file_count = $fcN
        }
    } catch {
        Write-PromptParleDebugLog ("ConvertTo-PromptParleConnectionObject FAIL: " + $_.Exception.ToString())
        return $null
    }
}

function ConvertTo-PromptParleConnectionList {
    param($InputObject)
    $acc = New-Object System.Collections.ArrayList
    if ($null -eq $InputObject) { return @() }
    try {
        foreach ($item in @($InputObject)) {
            if ($null -eq $item) { continue }
            # Skip scalar noise if JSON had a bad shape
            if ($item -is [string] -or $item -is [int] -or $item -is [long] -or $item -is [bool] -or $item -is [double]) { continue }
            $c = ConvertTo-PromptParleConnectionObject -Item $item
            if ($null -ne $c) { [void]$acc.Add($c) }
        }
    } catch {
        Write-PromptParleDebugLog ("ConvertTo-PromptParleConnectionList FAIL: " + $_.Exception.ToString())
    }
    return @($acc.ToArray())
}

function Ensure-PromptParleConnectionsMigrated {
    param($State)
    try {
        $list = @(ConvertTo-PromptParleConnectionList -InputObject (Get-PromptParleProp $State 'connections' @()))
        if ($list.Count -gt 0) {
            # Exactly one active local when any local exists
            $locals = @($list | Where-Object { $_.kind -eq 'local' })
            $actives = @($locals | Where-Object { $_.active -eq $true })
            if ($locals.Count -gt 0 -and $actives.Count -eq 0) {
                $locals[0].active = $true
            } elseif ($actives.Count -gt 1) {
                $first = $true
                foreach ($c in $list) {
                    if ($c.kind -ne 'local') { continue }
                    if ($first -and $c.active) { $first = $false; continue }
                    if ($c.active) { $c.active = $false }
                }
            }
            return @($list)
        }
        $path = [string](Get-PromptParleProp $State 'workspace_path' '')
        if ($path) {
            $kind = [string](Get-PromptParleProp $State 'workspace_kind' 'local')
            if ($kind -eq 'none' -or -not $kind) { $kind = 'local' }
            if ($kind -eq 'git') { $kind = 'local' }
            $leaf = ''
            try { $leaf = [string](Split-Path -Leaf $path) } catch { $leaf = '' }
            if (-not $leaf) { $leaf = 'This PC' }
            $newId = New-PromptParleConnectionId -Prefix 'pc'
            $row = [pscustomobject]@{
                id         = $newId
                kind       = 'local'
                label      = $leaf
                path       = $path
                active     = $true
                readonly   = $false
                source     = 'local'
                ssh_target = ''
                ssh_port   = 22
                ssh_cwd    = ''
                ssh_name   = ''
                catalog_id = $newId
                indexed_at = ''
                file_count = 0
            }
            return @($row)
        }
        return @()
    } catch {
        Write-PromptParleDebugLog ("Ensure-PromptParleConnectionsMigrated FAIL: " + $_.Exception.ToString())
        return @()
    }
}

function Sync-PromptParleLegacyWorkspaceFromConnections {
    param($State)
    $list = @(Ensure-PromptParleConnectionsMigrated -State $State)
    $active = $null
    foreach ($c in $list) {
        if ($c.kind -eq 'local' -and $c.active) { $active = $c; break }
    }
    if (-not $active) {
        foreach ($c in $list) {
            if ($c.kind -eq 'local') { $active = $c; $c.active = $true; break }
        }
    }
    $path = if ($active) { [string]$active.path } else { '' }
    $wkind = 'none'
    if ($path) {
        $wkind = if (Test-PromptParlePathIsGitRepo -Path $path) { 'git' } else { 'local' }
    }
    return [pscustomobject]@{
        connections    = @($list)
        workspace_path = $path
        workspace_kind = $wkind
    }
}

function Get-PromptParleConnections {
    try {
        $state = Get-PromptParleSessionState
        return @(Ensure-PromptParleConnectionsMigrated -State $state)
    } catch {
        Write-PromptParleDebugLog ("Get-PromptParleConnections FAIL: " + $_.Exception.ToString())
        return @()
    }
}

function Get-PromptParleActiveLocalConnection {
    foreach ($c in @(Get-PromptParleConnections)) {
        if ($c.kind -eq 'local' -and $c.active) { return $c }
    }
    foreach ($c in @(Get-PromptParleConnections)) {
        if ($c.kind -eq 'local') { return $c }
    }
    return $null
}

function Save-PromptParleConnectionsState {
    param(
        [Parameter(Mandatory)]$Connections,
        $WorkspaceRecent = $null
    )
    $list = @(ConvertTo-PromptParleConnectionList -InputObject $Connections)
    $synced = Sync-PromptParleLegacyWorkspaceFromConnections -State ([pscustomobject]@{
            connections    = $list
            workspace_path = ''
            workspace_kind = 'none'
        })
    $state = Get-PromptParleSessionState
    if ($null -ne $WorkspaceRecent) {
        $state = New-PromptParleSessionSnapshot -Base $state `
            -WorkspacePath $synced.workspace_path `
            -WorkspaceKind $synced.workspace_kind `
            -Connections $synced.connections `
            -WorkspaceRecent $WorkspaceRecent
    } else {
        $state = New-PromptParleSessionSnapshot -Base $state `
            -WorkspacePath $synced.workspace_path `
            -WorkspaceKind $synced.workspace_kind `
            -Connections $synced.connections
    }
    Save-PromptParleSessionState -State $state
    return $state
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
    # Build a plain Hashtable first — avoid OrderedDictionary → [pscustomobject] cast issues
    $state = @{
        active_agent               = 'none'
        provider                   = 'openai'
        profile                    = 'general'
        dial                       = 3
        model                      = $null
        optimize_only              = $false
        tools_enabled              = $true
        workspace_path             = ''
        workspace_kind             = 'none'
        workspace_recent           = @()
        ssh_target                 = ''
        ssh_port                   = 22
        ssh_cwd                    = ''
        ssh_name                   = ''
        product_root               = ''
        product_live               = ''
        open_obligation_kind       = ''
        open_obligation_artifact   = ''
        open_obligation_source     = ''
        open_obligation_source_ref = ''
        connections                = @()
    }
    if (Test-Path -LiteralPath $path) {
        try {
            $raw = Get-Content -LiteralPath $path -Raw -ErrorAction Stop
            if ($raw) {
                $s = $raw | ConvertFrom-Json
                foreach ($k in @('active_agent', 'provider', 'profile', 'model', 'workspace_path', 'workspace_kind', 'ssh_target', 'ssh_cwd', 'ssh_name', 'product_root', 'product_live', 'open_obligation_kind', 'open_obligation_artifact', 'open_obligation_source', 'open_obligation_source_ref')) {
                    $v = Get-PromptParleProp $s $k
                    if ($null -ne $v -and "$v" -ne '') { $state[$k] = [string]$v }
                }
                $d = Get-PromptParleProp $s 'dial'
                if ($null -ne $d) {
                    try { $state['dial'] = [Convert]::ToInt32([string]$d, 10) } catch { $state['dial'] = 3 }
                }
                $o = Get-PromptParleProp $s 'optimize_only'
                if ($null -ne $o) { $state['optimize_only'] = ConvertTo-PromptParleBool -Value $o -Default $false }
                $te = Get-PromptParleProp $s 'tools_enabled' $null
                if ($null -ne $te) { $state['tools_enabled'] = ConvertTo-PromptParleBool -Value $te -Default $true } else { $state['tools_enabled'] = $true }
                $sp = Get-PromptParleProp $s 'ssh_port'
                if ($null -ne $sp) {
                    try {
                        $pn = [Convert]::ToInt32([string]$sp, 10)
                        if ($pn -ge 1 -and $pn -le 65535) { $state['ssh_port'] = $pn }
                    } catch { }
                }
                $rec = Get-PromptParleProp $s 'workspace_recent'
                if ($null -ne $rec) {
                    $rlist = New-Object System.Collections.ArrayList
                    foreach ($item in @($rec)) {
                        $rs = [string](ConvertTo-PromptParleSingleString $item)
                        if (-not [string]::IsNullOrWhiteSpace($rs)) { [void]$rlist.Add($rs) }
                    }
                    $state['workspace_recent'] = @($rlist.ToArray())
                }
                $connRaw = Get-PromptParleProp $s 'connections'
                if ($null -ne $connRaw) {
                    $state['connections'] = @(ConvertTo-PromptParleConnectionList -InputObject $connRaw)
                }
            }
        } catch {
            Write-PromptParleDebugLog ("Get-PromptParleSessionState read FAIL: " + $_.Exception.ToString())
        }
    }
    # Migrate single workspace_path → connections[] when list empty (pass hashtable; Get-PromptParleProp supports IDictionary)
    try {
        $state['connections'] = @(Ensure-PromptParleConnectionsMigrated -State $state)
    } catch {
        Write-PromptParleDebugLog ("Get-PromptParleSessionState migrate FAIL: " + $_.Exception.ToString())
        if (-not $state['connections']) { $state['connections'] = @() }
    }
    if (-not $state['active_agent']) {
        $state['active_agent'] = 'none'
    }
    # Safe bag → PSCustomObject (never cast OrderedDictionary / raw IDictionary)
    try {
        return (ConvertTo-PromptParleCustomObject $state)
    } catch {
        Write-PromptParleDebugLog ("Get-PromptParleSessionState cast FAIL: " + $_.Exception.ToString())
        return [pscustomobject]@{
            active_agent     = 'none'
            provider         = 'openai'
            profile          = 'general'
            dial             = 3
            model            = $null
            optimize_only    = $false
            tools_enabled    = $true
            workspace_path   = ''
            workspace_kind   = 'none'
            workspace_recent = @()
            ssh_target       = ''
            ssh_port         = 22
            ssh_cwd          = ''
            ssh_name         = ''
            connections      = @()
        }
    }
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
        [string]$SshName,
        [string]$ProductRoot,
        [string]$ProductLive,
        [string]$OpenObligationKind,
        [string]$OpenObligationArtifact,
        [string]$OpenObligationSource,
        [string]$OpenObligationSourceRef,
        $Connections = $null
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
        $toolsEn = ConvertTo-PromptParleBool -Value $ToolsEnabled -Default $true
    } else {
        $baseTe = Get-PromptParleProp $Base 'tools_enabled' $null
        if ($null -ne $baseTe) { $toolsEn = ConvertTo-PromptParleBool -Value $baseTe -Default $true } else { $toolsEn = $true }
    }
    $connList = @()
    if ($PSBoundParameters.ContainsKey('Connections') -and $null -ne $Connections) {
        $connList = @(ConvertTo-PromptParleConnectionList -InputObject $Connections)
    } else {
        $connList = @(ConvertTo-PromptParleConnectionList -InputObject (Get-PromptParleProp $Base 'connections' @()))
    }
    $optOnly = $false
    if ($null -ne $OptimizeOnly) {
        $optOnly = ConvertTo-PromptParleBool -Value $OptimizeOnly -Default $false
    } else {
        $optOnly = ConvertTo-PromptParleBool -Value (Get-PromptParleProp $Base 'optimize_only' $false) -Default $false
    }
    # Plain Hashtable only — [pscustomobject]$ordered throws "Argument types do not match"
    $out = @{
        active_agent     = if ($PSBoundParameters.ContainsKey('ActiveAgent') -and $ActiveAgent) { $ActiveAgent } else { [string](Get-PromptParleProp $Base 'active_agent' 'default') }
        provider         = if ($PSBoundParameters.ContainsKey('Provider') -and $Provider) { $Provider } else { [string](Get-PromptParleProp $Base 'provider' 'openai') }
        profile          = if ($PSBoundParameters.ContainsKey('Profile') -and $Profile) { $Profile } else { [string](Get-PromptParleProp $Base 'profile' 'general') }
        dial             = if ($Dial -ge 1) { ConvertTo-PromptParleInt32 -Value $Dial -Default 3 } else { ConvertTo-PromptParleInt32 -Value (Get-PromptParleProp $Base 'dial' 3) -Default 3 }
        model            = if ($PSBoundParameters.ContainsKey('Model')) { $Model } else { Get-PromptParleProp $Base 'model' $null }
        optimize_only    = $optOnly
        tools_enabled    = $toolsEn
        workspace_path   = if ($PSBoundParameters.ContainsKey('WorkspacePath')) { [string]$WorkspacePath } else { [string](Get-PromptParleProp $Base 'workspace_path' '') }
        workspace_kind   = if ($PSBoundParameters.ContainsKey('WorkspaceKind')) { [string]$WorkspaceKind } else { [string](Get-PromptParleProp $Base 'workspace_kind' 'none') }
        workspace_recent = $recent
        ssh_target       = if ($PSBoundParameters.ContainsKey('SshTarget')) { [string]$SshTarget } else { [string](Get-PromptParleProp $Base 'ssh_target' '') }
        ssh_port         = if ($null -ne $SshPort) { ConvertTo-PromptParleSshPort -Value $SshPort } else { ConvertTo-PromptParleSshPort -Value (Get-PromptParleProp $Base 'ssh_port' 22) }
        ssh_cwd          = if ($PSBoundParameters.ContainsKey('SshCwd')) { [string]$SshCwd } else { [string](Get-PromptParleProp $Base 'ssh_cwd' '') }
        ssh_name         = if ($PSBoundParameters.ContainsKey('SshName')) { [string]$SshName } else { [string](Get-PromptParleProp $Base 'ssh_name' '') }
        product_root     = if ($PSBoundParameters.ContainsKey('ProductRoot')) { [string]$ProductRoot } else { [string](Get-PromptParleProp $Base 'product_root' '') }
        product_live     = if ($PSBoundParameters.ContainsKey('ProductLive')) { [string]$ProductLive } else { [string](Get-PromptParleProp $Base 'product_live' '') }
        open_obligation_kind       = if ($PSBoundParameters.ContainsKey('OpenObligationKind')) { [string]$OpenObligationKind } else { [string](Get-PromptParleProp $Base 'open_obligation_kind' '') }
        open_obligation_artifact   = if ($PSBoundParameters.ContainsKey('OpenObligationArtifact')) { [string]$OpenObligationArtifact } else { [string](Get-PromptParleProp $Base 'open_obligation_artifact' '') }
        open_obligation_source     = if ($PSBoundParameters.ContainsKey('OpenObligationSource')) { [string]$OpenObligationSource } else { [string](Get-PromptParleProp $Base 'open_obligation_source' '') }
        open_obligation_source_ref = if ($PSBoundParameters.ContainsKey('OpenObligationSourceRef')) { [string]$OpenObligationSourceRef } else { [string](Get-PromptParleProp $Base 'open_obligation_source_ref' '') }
        connections      = $connList
    }
    return (ConvertTo-PromptParleCustomObject $out)
}

function Save-PromptParleSessionState {
    param($State)
    $path = Get-PromptParleSessionStatePath
    $dir = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $recent = New-Object System.Collections.ArrayList
    $recRaw = Get-PromptParleProp $State 'workspace_recent'
    if ($null -ne $recRaw) {
        foreach ($item in @($recRaw)) {
            $s = [string](ConvertTo-PromptParleSingleString $item)
            if (-not [string]::IsNullOrWhiteSpace($s)) { [void]$recent.Add($s) }
        }
    }
    $toolsEnSave = Get-PromptParleProp $State 'tools_enabled' $null
    if ($null -eq $toolsEnSave) { $toolsEnSave = $true } else {
        try { $toolsEnSave = [System.Convert]::ToBoolean($toolsEnSave) } catch { $toolsEnSave = $true }
    }
    $optOnly = $false
    try { $optOnly = [System.Convert]::ToBoolean((Get-PromptParleProp $State 'optimize_only' $false)) } catch { $optOnly = $false }

    # Plain hashtables only — avoids PSCustomObject/ConvertTo-Json method-bind issues
    $connArr = New-Object System.Collections.ArrayList
    foreach ($c in @(ConvertTo-PromptParleConnectionList -InputObject (Get-PromptParleProp $State 'connections' @()))) {
        if (-not $c) { continue }
        $portN = ConvertTo-PromptParleInt32 -Value (Get-PromptParleProp $c 'ssh_port' 22) -Default 22
        if ($portN -lt 1 -or $portN -gt 65535) { $portN = 22 }
        $activeB = $false
        try { $activeB = [System.Convert]::ToBoolean((Get-PromptParleProp $c 'active' $false)) } catch { $activeB = $false }
        $roB = $false
        try { $roB = [System.Convert]::ToBoolean((Get-PromptParleProp $c 'readonly' $false)) } catch { $roB = $false }
        [void]$connArr.Add(@{
                id         = [string](Get-PromptParleProp $c 'id' '')
                kind       = [string](Get-PromptParleProp $c 'kind' 'local')
                label      = [string](Get-PromptParleProp $c 'label' '')
                path       = [string](Get-PromptParleProp $c 'path' '')
                active     = $activeB
                readonly   = $roB
                source     = [string](Get-PromptParleProp $c 'source' 'local')
                ssh_target = [string](Get-PromptParleProp $c 'ssh_target' '')
                ssh_port   = $portN
                ssh_cwd    = [string](Get-PromptParleProp $c 'ssh_cwd' '')
                ssh_name   = [string](Get-PromptParleProp $c 'ssh_name' '')
                catalog_id = [string](Get-PromptParleProp $c 'catalog_id' '')
                indexed_at = [string](Get-PromptParleProp $c 'indexed_at' '')
                file_count = ConvertTo-PromptParleInt32 -Value (Get-PromptParleProp $c 'file_count' 0) -Default 0
            })
    }

    $sshPortSave = ConvertTo-PromptParleInt32 -Value (Get-PromptParleProp $State 'ssh_port' 22) -Default 22
    if ($sshPortSave -lt 1 -or $sshPortSave -gt 65535) { $sshPortSave = 22 }
    $dialSave = ConvertTo-PromptParleInt32 -Value (Get-PromptParleProp $State 'dial' 3) -Default 3
    if ($dialSave -lt 1 -or $dialSave -gt 5) { $dialSave = 3 }

    $modelVal = Get-PromptParleProp $State 'model' $null
    if ($null -ne $modelVal) { $modelVal = [string]$modelVal }

    $out = @{
        active_agent               = [string](Get-PromptParleProp $State 'active_agent' 'default')
        provider                   = [string](Get-PromptParleProp $State 'provider' 'openai')
        profile                    = [string](Get-PromptParleProp $State 'profile' 'general')
        dial                       = $dialSave
        model                      = $modelVal
        optimize_only              = $optOnly
        tools_enabled              = $toolsEnSave
        workspace_path             = [string](Get-PromptParleProp $State 'workspace_path' '')
        workspace_kind             = [string](Get-PromptParleProp $State 'workspace_kind' 'none')
        workspace_recent           = @($recent.ToArray())
        ssh_target                 = [string](Get-PromptParleProp $State 'ssh_target' '')
        ssh_port                   = $sshPortSave
        ssh_cwd                    = [string](Get-PromptParleProp $State 'ssh_cwd' '')
        ssh_name                   = [string](Get-PromptParleProp $State 'ssh_name' '')
        product_root               = [string](Get-PromptParleProp $State 'product_root' '')
        product_live               = [string](Get-PromptParleProp $State 'product_live' '')
        open_obligation_kind       = [string](Get-PromptParleProp $State 'open_obligation_kind' '')
        open_obligation_artifact   = [string](Get-PromptParleProp $State 'open_obligation_artifact' '')
        open_obligation_source     = [string](Get-PromptParleProp $State 'open_obligation_source' '')
        open_obligation_source_ref = [string](Get-PromptParleProp $State 'open_obligation_source_ref' '')
        connections                = @($connArr.ToArray())
        updated_at                 = (Get-Date).ToString('o')
    }
    try {
        $json = ConvertTo-Json -InputObject $out -Depth 8 -Compress
        if (-not $json) { throw 'ConvertTo-Json returned empty' }
        [System.IO.File]::WriteAllText($path, $json, [System.Text.UTF8Encoding]::new($false))
    } catch {
        Write-PromptParleDebugLog ("Save-PromptParleSessionState FAIL: " + $_.Exception.ToString())
        throw "Save session state failed: $($_.Exception.GetType().FullName): $($_.Exception.Message)"
    }
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

function Get-PromptParleSelfCard {
    <#
    .SYNOPSIS
      Compact self-knowledge — product identity, hands, session storage truth, portal.
      Always-on so the model does not invent wrong hosts, paths, or session folders.
    #>
    $ver = '0.32.15'
    try {
        $v = Get-PromptParleClientVersion
        if ($v) { $ver = [string]$v }
    } catch {
        try {
            if ($MyInvocation.MyCommand.Module -and $MyInvocation.MyCommand.Module.Version) {
                $ver = [string]$MyInvocation.MyCommand.Module.Version
            }
        } catch { }
    }
    $os = if ($script:PromptParleIsWindows) { 'Windows' } else { 'Linux/macOS' }
    $cfgHint = if ($script:PromptParleIsWindows) { '%USERPROFILE%\.promptparle\' } else { '~/.promptparle/' }
    $lines = @(
        "[SELF] PromptParle desktop client v$ver on $os (this PC is the hands)",
        'Identity: multi-AI eng client — portal optimizes/routes; THIS machine runs tools and holds keys/paths.',
        'Local (this PC): local_list any path (C:\, /home, …), workspace attach, git, file_index, tree_pack, terminal. Paths never leave the PC for listing.',
        'Remote (only if SSH connected AND user means remote): ssh_list, ssh_read, ssh_run.',
        'Web: web_search, web_page. Docs: ```file name=…``` deliverables. Mutate: ```apply path=``` under bound source only.',
        'Chat history (sessions): lives in THIS desktop UI — sidebar Chat history (browser localStorage on this PC). Rolling densify store: ' + $cfgHint + 'chat-memory/<id>.json. NOT inside project trees. There is NO .parle/sessions/ folder in repos — never invent one.',
        'Catch-up: "latest session / get caught up" on THIS chat → answer from [MEM]/[KNOW]/history. Other chats → user opens them in the sidebar. Project catch-up (path/repo) → git status, HANDOFF/AGENTS/README, recent commits — not a fictional sessions dir.',
        'Portal: https://promptparle.com — Providers, API keys, Usage (before/after context), Settings, plan.',
        'Help: /help · /status · /workspace · /ssh · /search · /dial · UI Browse folders + Activity log.',
        'Routing: "on this PC" / drive letters (C:\) = LOCAL tools. Do not list a remote product root unless asked. Never invent directory listings — use [OBSERVE]/[MEM] results.'
    )
    return ($lines -join "`n")
}

function Get-PromptParleChatSystemPrompt {
    <#
    .SYNOPSIS
      0.22/0.22.4: multi-AI eng client — native tools; desktop is the hands.
      Pass-through first; optimization is deferred. Know yourself (see [SELF]).
    #>
    return @(
        'You are PromptParle — a conversational assistant in a continuous chat (same feel as Grok / Claude / ChatGPT). Talk like a helpful person: clear prose, short lists when useful, natural follow-ups. No modes for the user.',
        'BRAIN + HANDS: You are the brain (this API call). PromptParle desktop on the user''s PC executes tools: local filesystem, optional SSH, web fetch, apply/run, document deliver. The user never sees tool protocol.',
        'NATIVE TOOLS: web_search, web_page, local_list (THIS PC directories), ssh_list/ssh_read/ssh_run (remote only), workspace_find, relevant_slice, file_index, git_diff, git, connections, tree_pack. Prefer tools over guessing — then answer in plain language.',
        'HOST ROUTING: "on this PC" / Windows paths (C:\) / local folders → local_list or workspace tools. SSH/product host only when the user means remote or [CONN] shows an SSH target they asked about. Never substitute a hardcoded server path for a local request.',
        'FORBIDDEN in the user-visible answer: toolcall/tool_call/function_call XML, HTML tool tags, markdown hands fences, [HANDS] packs, hands# logs, "Client ran tools", or any method homework. Only a final conversational answer (or a real ```file deliverable when owed).',
        'When evidence is enough: answer the question. NEVER answer with the method (no run-ls homework). NEVER Generating-now without a file fence body for user documents.',
        'MUTATE: apply path=rel full files under source_root when a product bind exists (client writes, backups). Never invent a product root. run allowlisted pipeline only.',
        'DELIVER: when the user asks for a downloadable document (one-pager, executive summary, pdf/docx, "write me a report") OR asks you to create/build/make/generate an artifact ("create me a web form", "build a page/app/script/tool"), emit a ```file name=...``` with the FULL working body so the client produces a real download — do NOT paste the whole thing as an inline code block and stop. Chat reviews ("tell me about", "review site.com", "newest movies") are prose answers — do NOT invent a file obligation.',
        'RESEARCH HONESTY: [SESSION WEB] lists pages this client already fetched. If the user asks "did you research X?", answer from that list. Never claim "Not yet" when the domain is listed.',
        'SESSIONS: Chat history is the desktop sidebar (localStorage) + optional ~/.promptparle/chat-memory — never a project .parle/sessions folder. Catch-up this chat from [MEM]/[KNOW]; project catch-up from git/HANDOFF/README via tools — never invent session dirs.',
        'Trust [SELF][CONN][PROJECT][MEM][KNOW][OBSERVE][WEB][SESSION WEB][SSH] live evidence over invention. Opaque outcomes are bugs: tool result, apply/run/file, or one hard blocker.'
    ) -join ' '
}

function Test-PromptParleSessionCatchUpIntent {
    <#
    .SYNOPSIS
      True when user wants chat/work continuity ("get caught up", "latest session"),
      not a request to invent a sessions directory under a project path.
    #>
    param([string]$Prompt = '')
    $p = if ($null -eq $Prompt) { '' } else { $Prompt.Trim() }
    if (-not $p) { return $false }
    if ($p -match '(?i)\b(get caught up|catch me up|catch up|where we left off|what were we (doing|working)|pick up where|continue (from|where)|resume (the )?(chat|work|session))\b') {
        return $true
    }
    if ($p -match '(?i)\b(latest|last|prior|previous|this)\s+session\b') { return $true }
    if ($p -match '(?i)\bread (the )?(latest |last )?(session|chat|conversation)\b') { return $true }
    if ($p -match '(?i)\b(session history|chat history|prior (chat|work|turns))\b') { return $true }
    return $false
}

function Test-PromptParleProjectCatchUpIntent {
    <# True when catch-up is about repo/project state (path/git/handoff), not UI chat history alone. #>
    param([string]$Prompt = '')
    $p = if ($null -eq $Prompt) { '' } else { $Prompt.Trim() }
    if (-not $p) { return $false }
    if ($p -match '(?i)\b(project|repo|codebase|handoff|git (log|status|history)|what.?s (on|in) (disk|server|remote))\b') {
        return $true
    }
    if ($p -match '(?i)(?:^|[\s`"''(])(?:/home/|/var/www/|/etc/|[A-Za-z]:\\|\./)[\w./\\-]+') {
        # Path + catch-up language → project state
        if (Test-PromptParleSessionCatchUpIntent -Prompt $p) { return $true }
        if ($p -match '(?i)\b(status|state|what.?s going on|orient|overview)\b') { return $true }
    }
    return $false
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
      0.22.4: NEVER invent /home/ubuntu/... on machines where it does not exist.
    #>
    [CmdletBinding()]
    param()
    # Only use path defaults that exist on THIS host (dev box), never hardcode for end users
    $devRootCandidates = @(
        '/home/ubuntu/projects/promptparle',
        '/var/www/promptparle'
    )
    $defaultRoot = ''
    $defaultLive = ''
    foreach ($c in $devRootCandidates) {
        if ($c -match '/projects/promptparle' -and (Test-Path -LiteralPath $c -PathType Container -ErrorAction SilentlyContinue)) {
            $defaultRoot = $c
        }
        if ($c -match '/var/www/promptparle' -and (Test-Path -LiteralPath $c -PathType Container -ErrorAction SilentlyContinue)) {
            $defaultLive = $c
        }
    }
    $root = ''
    $live = ''
    $src = 'unbound'
    try {
        $st = Get-PromptParleSessionState
        $root = [string](Get-PromptParleProp $st 'product_root' '')
        $live = [string](Get-PromptParleProp $st 'product_live' '')
        if ($root) { $src = 'session' }
        $sshCwd = [string](Get-PromptParleProp $st 'ssh_cwd' '')
        $wsPath = [string](Get-PromptParleProp $st 'workspace_path' '')
        if (-not $root) {
            if ($sshCwd -match '(?i)/promptparle' -and $sshCwd.Trim()) {
                $root = $sshCwd.TrimEnd('/\')
                $src = 'ssh_cwd'
            } elseif ($wsPath -and (Test-Path -LiteralPath $wsPath -PathType Container -ErrorAction SilentlyContinue)) {
                # Workspace is a real local folder the user attached — not a fake server root
                if ($wsPath -match '(?i)promptparle') {
                    $root = $wsPath
                    $src = 'workspace'
                }
            } elseif ($defaultRoot) {
                # Dev host only (path exists here)
                $root = $defaultRoot
                $src = 'local_dev_default'
            }
        }
        if (-not $live) {
            if ($defaultLive -and ($root -eq $defaultRoot -or $root -match '(?i)/promptparle')) {
                $live = $defaultLive
            } elseif ($root -match '(?i)/promptparle' -and (Test-Path -LiteralPath '/var/www/promptparle' -ErrorAction SilentlyContinue)) {
                $live = '/var/www/promptparle'
            }
        }
    } catch {
        $root = $defaultRoot
        $live = $defaultLive
        $src = 'fallback'
    }
    # Do NOT invent roots — unbound is honest for desktop users
    if ($root -and -not (Test-Path -LiteralPath $root -ErrorAction SilentlyContinue)) {
        # Session remembered a foreign path (e.g. shipped hardcode) — drop it
        if ($root -match '(?i)/home/ubuntu/projects/promptparle' -and -not $defaultRoot) {
            $root = ''
            $src = 'cleared_foreign_default'
        }
    }
    # Persist only real binds
    if ($root) {
        try {
            $st2 = Get-PromptParleSessionState
            $needSave = $false
            if (-not [string](Get-PromptParleProp $st2 'product_root' '')) {
                $st2 = New-PromptParleSessionSnapshot -Base $st2 -ProductRoot $root -ProductLive $live
                $needSave = $true
            } elseif ($live -and -not [string](Get-PromptParleProp $st2 'product_live' '')) {
                $st2 = New-PromptParleSessionSnapshot -Base $st2 -ProductLive $live
                $needSave = $true
            }
            if ($needSave) { Save-PromptParleSessionState -State $st2 }
        } catch { }
    }
    $public = if ($live) { ($live.TrimEnd('/\') + '/public') } else { '' }
    return [pscustomobject]@{
        root   = $root
        live   = $live
        public = $public
        source = $src
        bound  = [bool]$root
    }
}

function Get-PromptParleProjectCard {
    <#
    .SYNOPSIS
      Always-on tiny project map. Unbound when no real product root on this PC.
    #>
    [CmdletBinding()]
    param(
        [string]$TurnKind = 'chat'
    )
    $b = Resolve-PromptParleProductBind
    if (-not $b.bound) {
        return @(
            '[PROJECT] no product source_root bound on this PC',
            'Desktop can still list local paths, use workspace/SSH/web tools.',
            'Bind: attach /workspace <repo> or /ssh user@host with product cwd when implementing a product tree.',
            "turn: $TurnKind · do not invent /home/ubuntu or /var/www paths"
        ) -join "`n"
    }
    $lines = @(
        '[PROJECT] product bind (handoff/docs map into these roots when present)',
        "source_root: $($b.root)",
        "live_app: $($b.live)",
        "live_public: $($b.public)",
        'layout: portal=src/app + prisma + src/lib · desktop=powershell/PromptParle (+ local-ui) · ship=public/ + live_public',
        "bind: $($b.source) · turn: $TurnKind",
        'rule: answer from [PROJECT]/evidence; implement under source_root; deploy to live_* only when that host is real'
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
            description = 'Skinny PC / KNOW / SSH map only (catalog on disk; not a file dump).'
            auto = $true
        },
        [pscustomobject]@{
            id = 'conn_index'; name = 'Connection index'
            category = 'project'; local = $true
            description = 'On-demand structure for one connection (top dirs, ext counts, samples).'
            auto = $false
        },
        [pscustomobject]@{
            id = 'know_search'; name = 'Knowledge search'
            category = 'project'; local = $true
            description = 'Search knowledge indexes (paths/titles only). Then know_read for text.'
            auto = $false
        },
        [pscustomobject]@{
            id = 'know_read'; name = 'Knowledge read'
            category = 'project'; local = $true
            description = 'Read one knowledge file (readonly). Never writes.'
            auto = $false
        },
        [pscustomobject]@{
            id = 'web_search'; name = 'Web search'
            category = 'research'; local = $true
            description = 'Brief web results (DDG IA + HTML + Wikipedia + domain page); cached, char-capped.'
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
            $rest = $p.Substring($home.Length).TrimStart([char]0x5C, [char]0x2F)
            if ($rest) { return "~/$rest".Replace('\', '/') }
            return '~'
        }
    } catch { }
    # Prefer leaf + parent for long paths
    try {
        if ($p.Length -gt 48) {
            $leaf = [IO.Path]::GetFileName($p.TrimEnd([char]0x5C, [char]0x2F))
            $parent = [IO.Path]::GetFileName([IO.Path]::GetDirectoryName($p.TrimEnd([char]0x5C, [char]0x2F)))
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
    $conns = @()
    try { $conns = @(Get-PromptParleConnections) } catch { $conns = @() }
    $keyParts = New-Object System.Collections.Generic.List[string]
    foreach ($c in $conns) {
        [void]$keyParts.Add(('{0}:{1}:{2}:{3}' -f $c.kind, $c.id, $c.active, $c.path))
    }
    if ($ws) {
        [void]$keyParts.Add(('{0}|{1}|{2}' -f $ws.ssh_target, $ws.ssh_cwd, $ws.ssh_port))
    }
    $key = if ($keyParts.Count) { ($keyParts -join ';') } else { 'none' }
    $now = [datetime]::UtcNow
    if (-not $Force -and $script:PromptParleConnBriefCache.key -eq $key -and `
        $script:PromptParleConnBriefCache.text -and `
        ($now - $script:PromptParleConnBriefCache.at).TotalSeconds -lt 20) {
        return [string]$script:PromptParleConnBriefCache.text
    }

    # Skinny map only — catalogs stay on disk; tools pull content on demand (no token dump)
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('[CONN] map (catalog on PC; use know_search/conn_index/relevant_slice for content)')

    $locals = @($conns | Where-Object { $_.kind -eq 'local' })
    if ($locals.Count -eq 0) {
        $lines.Add('PC: none — Project connections / /workspace add <path>')
    } else {
        foreach ($c in $locals) {
            $mark = if ($c.active) { 'PC[active]' } else { 'PC' }
            $lab = if ($c.label) { $c.label } else { 'folder' }
            $fc = if ($c.file_count -gt 0) { " · idx $($c.file_count)" } else { '' }
            $lines.Add("${mark}: $lab$fc")
        }
    }

    $knows = @($conns | Where-Object { $_.kind -eq 'knowledge' })
    if ($knows.Count -gt 0) {
        foreach ($c in $knows) {
            $lab = if ($c.label) { $c.label } else { 'docs' }
            $src = if ($c.source -eq 'ssh') { 'ssh' } else { 'local' }
            $fc = if ($c.file_count -gt 0) { " · idx $($c.file_count)" } else { '' }
            $lines.Add("KNOW: $lab ($src, readonly$fc)")
        }
    }

    $sshT = if ($ws) { [string](Get-PromptParleProp $ws 'ssh_target' '') } else { '' }
    if ($sshT) {
        $sshNm = if ($ws) { [string](Get-PromptParleProp $ws 'ssh_name' '') } else { '' }
        $cwd = if ($ws) { [string](Get-PromptParleProp $ws 'ssh_cwd' '') } else { '' }
        $lab = if ($sshNm) { $sshNm } else { 'SSH' }
        $bit = if ($cwd) { ' · remote dir set' } else { ' · login home' }
        $lines.Add("SSH: $lab$bit")
    } else {
        $lines.Add('SSH: none')
    }

    $gitOk = Test-PromptParleCommandAvailable -Name 'git'
    $lines.Add($(if ($gitOk) { 'Git: on PATH' } else { 'Git: not on PATH' }))
    $lines.Add('Doctrine: do not invent paths; knowledge is read-only; Term uses active PC / coding SSH.')

    $text = ($lines -join "`n")
    if ($MaxChars -lt 200) { $MaxChars = 200 }
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
    # "research the strengths of example.com" → domain + topic (page fetch uses domain; search uses this)
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
    <# 0.18/0.21/0.26.17: structural web observe — URLs/domains/research verbs + live/current-info asks.
       0.32.x: local-reference guard first — a question about a local file / this
       chat / a spreadsheet must NOT trigger a (slow, wrong) web search. #>
    param([string]$Prompt)
    if (-not $Prompt) { return $false }
    $b = $Prompt.ToLowerInvariant()
    # An explicit URL always means web.
    if ($b -match 'https?://') { return $true }
    # LOCAL-REFERENCE GUARD: if the ask is clearly about a local artifact — a
    # filename with a doc/data extension, a spreadsheet/workbook, "this chat",
    # "this PC", a downloads/desktop path — do NOT infer a web search. These are
    # local/SSH-tool targets. (Fixes "what's currently in ALL ISSUES.xlsx"
    # wrongly web-searching, and the ~2s+ it wasted.)
    $localRef = (
        ($b -match '(?i)\.(xlsx?|xls|csv|docx?|pdf|md|txt|json|log|pptx?|zip|ps1|psm1|py|ts|tsx|js)\b') -or
        ($b -match '(?i)\b(this chat|in chat|this conversation|this pc|my (pc|computer|machine|downloads|desktop|documents)|downloads folder|local (file|folder|drive)|workbook|spreadsheet|worksheet)\b')
    )
    # Only skip when there is ALSO no explicit web signal (URL handled above;
    # "search the web"/domain handled below force web even for a local-ish word).
    $explicitWeb = ($b -match '(?i)\b(search the web|web search|online|on the (web|internet)|from (the )?(web|internet)|google (it|for))\b') -or ($b -match '(?i)\b[\w.-]+\.(?:com|org|net|io|ai|dev|co)\b')
    if ($localRef -and -not $explicitWeb) { return $false }
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
    # Live / current-events style (no domain required) — "newest movies in theaters as of today"
    if ($b -match '(?i)\b(as of today|as of now|right now|currently|this (week|weekend|month)|in theaters?|now playing|box office|showtimes?)\b') { return $true }
    if ($b -match '(?i)\b(newest|latest|current)\s+(movies?|films?|releases?|news|scores?|prices?|weather|headlines?)\b') { return $true }
    if ($b -match '(?i)\bwhat (are|is) (the )?(newest|latest|current|playing|out now)\b') { return $true }
    if ($b -match '(?i)\b(movies?|films?)\b.{0,40}\b(theaters?|cinemas?|now playing|out now)\b') { return $true }
    return $false
}

function Invoke-PromptParleWebSearchLocal {
    <#
    .SYNOPSIS
      Brief multi-source web search on this PC (no AI tokens for the fetch).
      Sources: DDG Instant Answer → Wikipedia → HTML DDG → domain/page auto-fetch (0.22.1).
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
        $ddg = Invoke-RestMethod -Uri $ddgUrl -TimeoutSec 6 -Headers @{ 'User-Agent' = $ua } -ErrorAction Stop
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
            $os = Invoke-RestMethod -Uri $osUrl -TimeoutSec 6 -Headers @{ 'User-Agent' = $ua } -ErrorAction Stop
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
                        $sum = Invoke-RestMethod -Uri $sumUrl -TimeoutSec 6 -Headers @{ 'User-Agent' = $ua } -ErrorAction Stop
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

    # 3) HTML DuckDuckGo search — Instant Answer is often empty for niche products
    if ($hits.Count -lt 2) {
        try {
            $htmlHits = @(Invoke-PromptParleWebSearchHtml -Query $q -MaxResults $MaxResults)
            $added = 0
            foreach ($hh in $htmlHits) {
                if ($hits.Count -ge $MaxResults) { break }
                $dup = $false
                foreach ($h in $hits) {
                    if (($hh.url -and $h.url -eq $hh.url) -or ($h.title -eq $hh.title)) { $dup = $true; break }
                }
                if ($dup) { continue }
                $hits.Add($hh)
                $added++
            }
            if ($added -gt 0) { $notes.Add("ddg-html:$added") }
        } catch {
            $notes.Add('ddg-html-skip')
        }
    }

    # 4) Domain / brand in query → always fetch primary page (site is source of truth)
    $pageBlob = ''
    $domainHit = ''
    if ($q -match '(?i)\b((?:[a-z0-9-]+\.)+(?:com|org|net|io|ai|dev|co))\b') {
        $domainHit = $Matches[1].ToLowerInvariant()
    }
    # Brand-like token → try matching hit URL host (e.g. "acme strengths")
    if (-not $domainHit -and $hits.Count -gt 0) {
        $qTokens = @([regex]::Matches($q.ToLowerInvariant(), '[a-z0-9]{4,}') | ForEach-Object { $_.Value } |
            Where-Object { $_ -notmatch '^(https|http|www|com|org|net|news|latest|release|releases|strength|strengths|about|what|does|with|from|site|website|company|product|solution)$' })
        foreach ($h in $hits) {
            $hu = [string]$h.url
            if (-not $hu) { continue }
            if ($hu -match '(?i)https?://(?:www\.)?([a-z0-9-]+(?:\.[a-z0-9-]+)+)') {
                $hostCand = $Matches[1].ToLowerInvariant()
                if ($hostCand -match '(?i)(wikipedia|duckduckgo|reddit|youtube|twitter|linkedin|facebook|medium\.com|github\.com)') { continue }
                $hostCore = ($hostCand -split '\.')[0]
                foreach ($tok in $qTokens) {
                    if ($hostCore -eq $tok -or $hostCore.Contains($tok) -or $tok.Contains($hostCore)) {
                        $domainHit = $hostCand
                        break
                    }
                }
                if ($domainHit) { break }
            }
        }
    }
    if ($domainHit) {
        try {
            $pg = Invoke-PromptParleWebPageFetch -UrlOrDomain $domainHit -MaxChars ([Math]::Min(4500, [int]($MaxChars * 0.7)))
            if ($pg.ok -and $pg.text) {
                $pageBlob = $pg.text
                $notes.Add("page:$domainHit")
                # Ensure domain appears as hit #1 if missing
                $hasDom = $false
                foreach ($h in $hits) {
                    if ($h.url -and $h.url -match [regex]::Escape($domainHit)) { $hasDom = $true; break }
                }
                if (-not $hasDom) {
                    $titleLine = $domainHit
                    # Use the brand-ish token from the query (if any) to pull a title line
                    # from the fetched page — generic, no hardcoded brand.
                    $brandTok = ''
                    if ($q -match '(?i)\b([a-z][a-z0-9]{3,})\b') { $brandTok = $Matches[1] }
                    if ($brandTok -and $pageBlob -match ('(?i)\b' + [regex]::Escape($brandTok) + '[^\n.]{0,80}')) {
                        $titleLine = $Matches[0].Trim()
                    }
                    $snip = $pageBlob
                    if ($snip.Length -gt 200) { $snip = $snip.Substring(0, 197) + '…' }
                    $hits.Insert(0, [pscustomobject]@{
                        title = $titleLine
                        url   = "https://$domainHit/"
                        snip  = $snip
                    })
                }
                if (-not $abstract) {
                    $abstract = if ($pageBlob.Length -gt 500) { $pageBlob.Substring(0, 497) + '…' } else { $pageBlob }
                }
            } else {
                $notes.Add("page-fail:$domainHit")
            }
        } catch {
            $notes.Add('page-skip')
        }
    }

    # Build brief text
    $out = New-Object System.Collections.Generic.List[string]
    $out.Add("[WEB] q=$q")
    if ($abstract) {
        $a = $abstract.Trim()
        if ($a.Length -gt 900) { $a = $a.Substring(0, 897) + '…' }
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
    if ($pageBlob) {
        $room = $MaxChars - (($out -join "`n").Length) - 80
        if ($room -gt 400) {
            $pb = $pageBlob
            if ($pb.Length -gt $room) { $pb = $pb.Substring(0, $room) + '…[page]' }
            $out.Add("---")
            $out.Add("[OBSERVE] kind=web_page from web_search auto-fetch")
            $out.Add("url: https://$domainHit/")
            $out.Add($pb)
            try { Add-PromptParleWebEvidence -Url ("https://{0}/" -f $domainHit) -Kind 'web_search_page' } catch { }
        }
    }
    if ($n -eq 0 -and -not $abstract -and -not $pageBlob) {
        $out.Add('(no brief hits — client will still try web_page if a domain is known)')
        $notes.Add('empty')
    }
    $out.Add('Cite sources; prefer fetched page text over memory.')
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

    $ok = ($n -gt 0 -or [bool]$abstract -or [bool]$pageBlob)
    return [pscustomobject]@{
        ok      = $ok
        tool    = 'web_search'
        local   = $true
        text    = $text
        notes   = @($notes.ToArray())
        query   = $q
        cached  = $false
        hits    = $n
        domain  = $domainHit
    }
}

function Invoke-PromptParleWebSearchHtml {
    <#
    .SYNOPSIS
      0.22.1: HTML DuckDuckGo search fallback when Instant Answer API is empty.
      Parses result titles + destination URLs (uddg=).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Query,
        [int]$MaxResults = 5
    )
    $q = $Query.Trim()
    if (-not $q) { return @() }
    if ($MaxResults -lt 1) { $MaxResults = 1 }
    if ($MaxResults -gt 8) { $MaxResults = 8 }
    $ua = 'Mozilla/5.0 (compatible; PromptParle/0.22; +https://promptparle.com)'
    $enc = [uri]::EscapeDataString($q)
    $url = "https://html.duckduckgo.com/html/?q=$enc"
    $html = ''
    try {
        $resp = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 7 -Headers @{
            'User-Agent' = $ua
            'Accept'     = 'text/html,application/xhtml+xml'
        } -ErrorAction Stop
        $html = [string]$resp.Content
    } catch {
        return @()
    }
    if (-not $html -or $html.Length -lt 80) { return @() }

    $hits = New-Object System.Collections.Generic.List[object]
    $seen = @{}
    # result links: class="result__a" ... uddg=ENCODED
    foreach ($m in [regex]::Matches($html, '(?is)class="result__a"[^>]*href="([^"]+)"[^>]*>(.*?)</a>')) {
        if ($hits.Count -ge $MaxResults) { break }
        $href = [System.Net.WebUtility]::HtmlDecode($m.Groups[1].Value)
        $title = [System.Net.WebUtility]::HtmlDecode(($m.Groups[2].Value -replace '<[^>]+>', ' '))
        $title = [regex]::Replace($title, '\s+', ' ').Trim()
        $dest = $href
        if ($href -match 'uddg=([^&]+)') {
            try { $dest = [uri]::UnescapeDataString($Matches[1]) } catch { $dest = $Matches[1] }
        } elseif ($href -match '^//') {
            $dest = 'https:' + $href
        }
        if (-not $title -or $title.Length -lt 3) { continue }
        if ($dest -match 'duckduckgo\.com' -and $dest -notmatch 'uddg=') { continue }
        $k = ($dest + '|' + $title).ToLowerInvariant()
        if ($seen.ContainsKey($k)) { continue }
        $seen[$k] = $true
        # nearby snippet
        $snip = ''
        $idx = $m.Index + $m.Length
        $window = if ($idx -lt $html.Length) { $html.Substring($idx, [Math]::Min(600, $html.Length - $idx)) } else { '' }
        if ($window -match '(?is)class="result__snippet"[^>]*>(.*?)</a>|class="result__snippet"[^>]*>(.*?)</td>|class="result__snippet"[^>]*>(.*?)</') {
            $snip = [System.Net.WebUtility]::HtmlDecode(($Matches[1] + $Matches[2] + $Matches[3]) -replace '<[^>]+>', ' ')
            $snip = [regex]::Replace($snip, '\s+', ' ').Trim()
            if ($snip.Length -gt 180) { $snip = $snip.Substring(0, 177) + '…' }
        }
        $hits.Add([pscustomobject]@{ title = $title; url = $dest; snip = $snip })
    }
    return @($hits.ToArray())
}

function Invoke-PromptParleSecretScanLocal {
    param([string]$Text)
    if (-not $Text) {
        return [pscustomobject]@{ text = ''; masked = 0 }
    }
    $masked = 0
    $out = $Text
    # Order matters: more specific keys before generic sk-
    $patterns = @(
        @{ re = '(?i)(sk-ant-[A-Za-z0-9\-_]{16,})'; rep = 'sk-ant-***MASKED***' },
        @{ re = '(?i)\b(sk-(?!ant-)[A-Za-z0-9_-]{20,})\b'; rep = 'sk-***MASKED***' },
        @{ re = '(?i)\b(xai-[A-Za-z0-9]{20,})\b'; rep = 'xai-***MASKED***' },
        @{ re = '(?i)\b(AIza[0-9A-Za-z\-_]{20,})\b'; rep = 'AIza***MASKED***' },
        @{ re = '(?i)\b(AKIA[0-9A-Z]{16})\b'; rep = 'AKIA***MASKED***' },
        @{ re = '(?i)\b(ghp_[A-Za-z0-9]{20,})\b'; rep = 'ghp_***MASKED***' },
        @{ re = '(?i)\b(github_pat_[A-Za-z0-9_]{20,})\b'; rep = 'github_pat_***MASKED***' },
        @{ re = '(?i)\b(pp_live_[A-Za-z0-9]{16,})\b'; rep = 'pp_live_***MASKED***' },
        @{ re = '(?i)(Bearer\s+)[A-Za-z0-9\-._~+/]+=*'; rep = '${1}***MASKED***' },
        @{ re = '(?i)(-----BEGIN (?:RSA |OPENSSH |EC )?PRIVATE KEY-----[\s\S]*?-----END (?:RSA |OPENSSH |EC )?PRIVATE KEY-----)'; rep = '-----BEGIN PRIVATE KEY-----***MASKED***-----END PRIVATE KEY-----' },
        @{ re = '(?i)((?:api[_-]?key|secret|password|token|passwd|aws_secret_access_key)\s*[=:]\s*)(["'']?)([^\s"'';]{8,})\2'; rep = '${1}${2}***MASKED***${2}' }
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
      High-fidelity first: strip only NOISE (deliverable bodies, apply dumps, hands/tool theater).
      Real conversation prose is kept with generous caps — selection over destruction.
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
    # Hands / tool theater dumps only (noise) — keep query + hit titles as signal
    if ($t -match '(?i)\[HANDS\]\s*client results|Client ran tools|hands#\d|Raw toolcall') {
        $wq = ''
        if ($t -match '(?m)^\[WEB\]\s*q=(.+)$') { $wq = $Matches[1].Trim() }
        elseif ($t -match '(?m)^arg:\s*(.+)$') { $wq = $Matches[1].Trim() }
        $titles = New-Object System.Collections.Generic.List[string]
        foreach ($m in [regex]::Matches($t, '(?m)^\d+\.\s+(.+?)(?:\s+\|\s+https?://\S+)?\s*$')) {
            $tt = $m.Groups[1].Value.Trim()
            if ($tt.Length -gt 100) { $tt = $tt.Substring(0, 97) + '…' }
            [void]$titles.Add($tt)
            if ($titles.Count -ge 6) { break }
        }
        $bits = New-Object System.Collections.Generic.List[string]
        [void]$bits.Add('[prior web lookup]')
        if ($wq) { [void]$bits.Add("q=$wq") }
        if ($titles.Count -gt 0) { [void]$bits.Add(($titles -join '; ')) }
        $t = ($bits -join ' · ')
    } else {
        $t = [regex]::Replace($t, '(?ms)\[HANDS\][^\n]*\r?\n.*?(?=\r?\n\[(?:MEM|CONN|PROJECT|WEB|OBSERVE)\]|\z)', '[prior hands omitted]')
        $t = [regex]::Replace($t, '(?is)<\s*(tool_?call|toolcall|function_?call)\b[\s\S]*?</\s*\1\s*>', '[prior tool markup omitted]')
        $t = [regex]::Replace($t, '(?ms)```(?:hands|tool_code|tool)[^\n]*\r?\n.*?```', '[prior tool fence omitted]')
    }
    # Fat [WEB] blocks: keep query + titles + summary (signal), drop raw dump
    if ($t -match '(?m)^\[WEB\]' -and $t.Length -gt 900) {
        $wq2 = ''
        if ($t -match '(?m)^\[WEB\]\s*q=(.+)$') { $wq2 = $Matches[1].Trim() }
        $sum = ''
        if ($t -match '(?ms)^Summary:\s*(.+?)(?=\r?\n\d+\.|\r?\n---|$)') {
            $sum = $Matches[1].Trim()
            if ($sum.Length -gt 280) { $sum = $sum.Substring(0, 277) + '…' }
        }
        $titles2 = New-Object System.Collections.Generic.List[string]
        foreach ($m in [regex]::Matches($t, '(?m)^\d+\.\s+(.+?)(?:\s+\|\s+https?://\S+)?\s*$')) {
            $tt = $m.Groups[1].Value.Trim()
            if ($tt.Length -gt 90) { $tt = $tt.Substring(0, 87) + '…' }
            [void]$titles2.Add($tt)
            if ($titles2.Count -ge 6) { break }
        }
        $parts = New-Object System.Collections.Generic.List[string]
        [void]$parts.Add('[prior web]')
        if ($wq2) { [void]$parts.Add("q=$wq2") }
        if ($sum) { [void]$parts.Add($sum) }
        if ($titles2.Count -gt 0) { [void]$parts.Add(($titles2 -join '; ')) }
        $t = ($parts -join ' · ')
    }
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
            # Keep short lead-in prose if present (high-fid decisions near deliverable)
            $lead = [regex]::Replace($t, '(?ms)\[prior[^\]]*\]', '').Trim()
            if ($lead.Length -gt 200) { $lead = $lead.Substring(0, 197) + '…' }
            $t = "delivered: $names"
            if ($lead -and $lead.Length -gt 20) { $t = $t + "`n" + $lead }
            return $t.Trim()
        }
        # Structural: multi-fence + "run this" homework dumps (not phrase moles)
        $fenceN = ([regex]::Matches($t, '```')).Count
        if ($t.Length -gt 800 -and $fenceN -ge 4 -and $t -match '(?i)\b(run this|please run|npx |npm run |curl -X)\b') {
            return '[prior homework-style dump omitted — land with ```apply path=``` / ```run```]'
        }
        # High-fidelity: keep substantial prior answers; only soft-cap extremes
        if ($t.Length -gt 1400) {
            $t = Get-PromptParleFidelityTrim -Text $t -MaxChars 1200 -Marker '…[prior assistant soft-cap]'
        }
    } else {
        # User asks/paste: keep signal; only trim huge pastes
        if ($t.Length -gt 2200) {
            $t = Get-PromptParleFidelityTrim -Text $t -MaxChars 1800 -Marker '…'
        }
    }
    return $t.Trim()
}

function Get-PromptParleChatMemoryDir {
    $dir = Join-Path $script:PromptParleConfigDir 'chat-memory'
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    return $dir
}

function Get-PromptParleChatMemoryStorePath {
    param([string]$SessionId = '')
    $id = if ($SessionId) { $SessionId.Trim() } else { '' }
    if (-not $id) { $id = 'default' }
    # Safe filename
    $safe = [regex]::Replace($id, '[^A-Za-z0-9._-]', '_')
    if ($safe.Length -gt 80) { $safe = $safe.Substring(0, 80) }
    return (Join-Path (Get-PromptParleChatMemoryDir) ($safe + '.json'))
}

function Get-PromptParleChatMemoryStore {
    <# Load rolling durable memory for a chat/project session (local disk, 0 tokens). #>
    param([string]$SessionId = '')
    $empty = @{
        session_id       = $(if ($SessionId) { $SessionId } else { 'default' })
        turn_count       = 0
        updated_utc      = ''
        project_spine    = ''
        rolling_summary  = ''
        open_work        = ''
        last_compact_turn = 0
        chars_saved_est  = 0
        priority_knowledge = @()
    }
    $path = Get-PromptParleChatMemoryStorePath -SessionId $SessionId
    if (-not (Test-Path -LiteralPath $path)) { return $empty }
    try {
        $raw = Get-Content -LiteralPath $path -Raw -ErrorAction Stop
        if (-not $raw) { return $empty }
        $j = $raw | ConvertFrom-Json
        $out = @{}
        foreach ($k in @('session_id', 'project_spine', 'rolling_summary', 'open_work', 'updated_utc')) {
            $v = Get-PromptParleProp $j $k ''
            $out[$k] = if ($null -ne $v) { [string]$v } else { '' }
        }
        if (-not $out['session_id']) { $out['session_id'] = $empty.session_id }
        try { $out['turn_count'] = [int](Get-PromptParleProp $j 'turn_count' 0) } catch { $out['turn_count'] = 0 }
        try { $out['last_compact_turn'] = [int](Get-PromptParleProp $j 'last_compact_turn' 0) } catch { $out['last_compact_turn'] = 0 }
        try { $out['chars_saved_est'] = [int](Get-PromptParleProp $j 'chars_saved_est' 0) } catch { $out['chars_saved_est'] = 0 }
        $pk = New-Object System.Collections.ArrayList
        $pkRaw = Get-PromptParleProp $j 'priority_knowledge' $null
        if ($null -ne $pkRaw) {
            foreach ($item in @($pkRaw)) {
                if ($null -eq $item) { continue }
                $txt = [string](Get-PromptParleProp $item 'text' (Get-PromptParleProp $item 'Text' ''))
                if (-not $txt) { continue }
                $role = [string](Get-PromptParleProp $item 'role' (Get-PromptParleProp $item 'Role' 'assistant'))
                $kid = [string](Get-PromptParleProp $item 'id' (Get-PromptParleProp $item 'Id' ''))
                [void]$pk.Add(@{
                        id   = $kid
                        role = $role
                        text = $txt
                    })
            }
        }
        $out['priority_knowledge'] = @($pk.ToArray())
        return $out
    } catch {
        return $empty
    }
}

function Save-PromptParleChatMemoryStore {
    param(
        [hashtable]$Store,
        [string]$SessionId = ''
    )
    if (-not $Store) { return }
    $id = $SessionId
    if (-not $id) { $id = [string]$Store['session_id'] }
    if (-not $id) { $id = 'default' }
    $Store['session_id'] = $id
    $Store['updated_utc'] = [datetime]::UtcNow.ToString('o')
    $path = Get-PromptParleChatMemoryStorePath -SessionId $id
    try {
        $pkOut = New-Object System.Collections.ArrayList
        foreach ($item in @($Store['priority_knowledge'])) {
            if ($null -eq $item) { continue }
            $txt = [string](Get-PromptParleProp $item 'text' (Get-PromptParleProp $item 'Text' ''))
            if (-not $txt) { continue }
            if ($txt.Length -gt 4000) { $txt = $txt.Substring(0, 3997) + '…' }
            $role = [string](Get-PromptParleProp $item 'role' 'assistant')
            $kid = [string](Get-PromptParleProp $item 'id' '')
            [void]$pkOut.Add([ordered]@{
                    id   = $kid
                    role = $role
                    text = $txt
                })
            if ($pkOut.Count -ge 12) { break }
        }
        $payload = [ordered]@{
            session_id         = [string]$Store['session_id']
            turn_count         = [int]$Store['turn_count']
            updated_utc        = [string]$Store['updated_utc']
            project_spine      = [string]$Store['project_spine']
            rolling_summary    = [string]$Store['rolling_summary']
            open_work          = [string]$Store['open_work']
            last_compact_turn  = [int]$Store['last_compact_turn']
            chars_saved_est    = [int]$Store['chars_saved_est']
            priority_knowledge = @($pkOut.ToArray())
        }
        $json = $payload | ConvertTo-Json -Compress -Depth 6
        [System.IO.File]::WriteAllText($path, $json, [System.Text.UTF8Encoding]::new($false))
    } catch {
        Write-PromptParleDebugLog ("Save-PromptParleChatMemoryStore FAIL: " + $_.Exception.ToString())
    }
}

function Format-PromptParlePriorityKnowledgeBlock {
    <#
    .SYNOPSIS
      User-pinned session knowledge — highest priority in-session facts (never densify away).
    #>
    param(
        [object[]]$Items = @(),
        [int]$MaxChars = 4800,
        [int]$MaxItems = 8
    )
    if (-not $Items -or $Items.Count -eq 0) { return '' }
    if ($MaxItems -lt 1) { $MaxItems = 8 }
    if ($MaxChars -lt 400) { $MaxChars = 400 }
    $lines = New-Object System.Collections.ArrayList
    [void]$lines.Add('[KNOW] user-pinned session knowledge (priority — treat as session truth; prefer over older [MEM] when they conflict)')
    $n = 0
    $used = ($lines[0]).Length
    foreach ($item in @($Items)) {
        if ($null -eq $item) { continue }
        if ($n -ge $MaxItems) { break }
        $txt = [string](Get-PromptParleProp $item 'text' (Get-PromptParleProp $item 'Text' ''))
        if (-not $txt) { continue }
        $txt = $txt.Trim()
        if (-not $txt) { continue }
        $role = [string](Get-PromptParleProp $item 'role' (Get-PromptParleProp $item 'Role' 'assistant'))
        $role = $role.ToLowerInvariant()
        if ($role -match 'bot|ai|model') { $role = 'assistant' }
        elseif ($role -notmatch 'user|assistant') { $role = 'assistant' }
        # Per-pin soft cap — keep signal, avoid dumping whole essays into every turn
        $pinCap = 1400
        if ($txt.Length -gt $pinCap) {
            $txt = Get-PromptParleFidelityTrim -Text $txt -MaxChars $pinCap -Marker '…[know cap]…'
        }
        $n++
        $block = ("{0}. ({1}) {2}" -f $n, $role, $txt)
        if (($used + $block.Length + 2) -gt $MaxChars -and $n -gt 1) { break }
        if (($used + $block.Length + 2) -gt $MaxChars) {
            $room = $MaxChars - $used - 40
            if ($room -lt 80) { break }
            $block = ("{0}. ({1}) {2}" -f $n, $role, (Get-PromptParleFidelityTrim -Text $txt -MaxChars $room -Marker '…'))
        }
        [void]$lines.Add($block)
        $used += $block.Length + 1
    }
    if ($n -eq 0) { return '' }
    return (($lines.ToArray()) -join "`n")
}

function Merge-PromptParlePriorityKnowledge {
    <# Merge UI pins + disk store; UI order wins; dedupe by id then text prefix. #>
    param(
        [object[]]$FromUi = @(),
        [object[]]$FromStore = @(),
        [int]$MaxItems = 12
    )
    $out = New-Object System.Collections.ArrayList
    $seenId = @{}
    $seenText = @{}
    foreach ($src in @(@($FromUi), @($FromStore))) {
        foreach ($item in @($src)) {
            if ($null -eq $item) { continue }
            $txt = [string](Get-PromptParleProp $item 'text' '')
            if (-not $txt) { continue }
            $kid = [string](Get-PromptParleProp $item 'id' '')
            if ($kid -and $seenId.ContainsKey($kid)) { continue }
            $tk = $txt.Trim().ToLowerInvariant()
            if ($tk.Length -gt 120) { $tk = $tk.Substring(0, 120) }
            if ($seenText.ContainsKey($tk)) { continue }
            if ($kid) { $seenId[$kid] = $true }
            $seenText[$tk] = $true
            $role = [string](Get-PromptParleProp $item 'role' 'assistant')
            [void]$out.Add(@{
                    id   = $kid
                    role = $role
                    text = $txt.Trim()
                })
            if ($out.Count -ge $MaxItems) { break }
        }
        if ($out.Count -ge $MaxItems) { break }
    }
    return @($out.ToArray())
}

function Update-PromptParleChatMemoryStore {
    <#
    .SYNOPSIS
      Rolling project memory — fold ONLY older turns into durable spine/summary.
      High fidelity is paramount: densify noise and age, never gut recent signal.
      Extractive only (0 model tokens for compaction).
    #>
    param(
        [hashtable]$Store,
        [object[]]$Turns = @(),
        [int]$Dial = 3
    )
    if (-not $Store) { $Store = @{} }
    $list = @($Turns)
    if ($list.Count -eq 0) { return $Store }

    $prevTurns = 0
    try { $prevTurns = [int]$Store['turn_count'] } catch { $prevTurns = 0 }
    $Store['turn_count'] = $list.Count

    # Spine: merge window extract with prior store (UI only sends last N turns —
    # must not wipe durable project facts from earlier in the session)
    $spineMax = if ($Dial -ge 4) { 520 } elseif ($Dial -le 2) { 900 } else { 720 }
    $spineNew = Get-PromptParleMemorySpine -Turns $list -MaxLen $spineMax
    $spinePrev = [string]$Store['project_spine']
    if ($spineNew -and $spinePrev) {
        $bits = New-Object System.Collections.Generic.List[string]
        $seenS = @{}
        foreach ($part in @(($spinePrev + ' · ' + $spineNew) -split '\s*·\s*')) {
            $p = $part.Trim()
            if (-not $p) { continue }
            $k = $p.ToLowerInvariant()
            if ($seenS.ContainsKey($k)) { continue }
            $seenS[$k] = $true
            [void]$bits.Add($p)
            if ($bits.Count -ge 22) { break }
        }
        $merged = ($bits -join ' · ')
        if ($merged.Length -gt $spineMax) { $merged = $merged.Substring(0, $spineMax - 1) + '…' }
        $Store['project_spine'] = $merged
    } elseif ($spineNew) {
        $Store['project_spine'] = $spineNew
    }

    # Open-work lines (more slots = higher fidelity on project continuity)
    $openBits = New-Object System.Collections.Generic.List[string]
    foreach ($t in $list) {
        $text = [string]$t.text
        foreach ($line in ($text -split "`n")) {
            $ln = $line.Trim()
            if ($ln -match '(?i)\b(todo|open|blocker|next|still need|in progress|must|fix|ship|decided|use |don''t )\b' -and $ln.Length -ge 12 -and $ln.Length -le 180) {
                $s = if ($ln.Length -gt 140) { $ln.Substring(0, 137) + '…' } else { $ln }
                if (-not ($openBits -contains $s)) { [void]$openBits.Add($s) }
                if ($openBits.Count -ge 8) { break }
            }
        }
        if ($openBits.Count -ge 8) { break }
    }
    if ($openBits.Count -gt 0) {
        $ow = ($openBits -join ' · ')
        if ($ow.Length -gt 480) { $ow = $ow.Substring(0, 477) + '…' }
        $Store['open_work'] = $ow
    }

    # Deep compact cadence: slower (every 8–10 turns) so mid-session fidelity stays high
    $lastCompact = 0
    try { $lastCompact = [int]$Store['last_compact_turn'] } catch { $lastCompact = 0 }
    $cadence = if ($Dial -ge 4) { 8 } elseif ($Dial -le 2) { 10 } else { 8 }
    $needDeep = ($list.Count -ge $cadence) -and (
        ($list.Count - $lastCompact) -ge $cadence -or
        ($list.Count -gt $prevTurns -and ($list.Count % $cadence) -eq 0)
    )

    # Keep a larger live window before folding into summary
    $keepRecent = if ($Dial -le 2) { 6 } elseif ($Dial -eq 3) { 5 } else { 4 }
    $cut = [Math]::Max(0, $list.Count - $keepRecent)
    if ($cut -gt 0 -and ($needDeep -or (-not $Store['rolling_summary'] -and $list.Count -ge 8))) {
        $sumBits = New-Object System.Collections.Generic.List[string]
        $existing = [string]$Store['rolling_summary']
        if ($existing) {
            # Keep prior summary lead (already compacted) — generous for fidelity
            $lead = $existing
            if ($lead.Length -gt 700) { $lead = $lead.Substring(0, 697) + '…' }
            [void]$sumBits.Add($lead)
        }
        $start = [Math]::Max(0, $cut - 14)
        for ($i = $start; $i -lt $cut; $i++) {
            $t = $list[$i]
            # Longer extracts = higher fidelity on decisions/errors/paths
            $ex = Get-PromptParleMemoryExtract -Text $t.text -MaxLen $(if ($Dial -ge 4) { 140 } elseif ($Dial -le 2) { 220 } else { 180 })
            if (-not $ex) { continue }
            $tag = if ($t.role -eq 'assistant') { 'A' } else { 'U' }
            [void]$sumBits.Add("${tag}: $ex")
            if ($sumBits.Count -ge 18) { break }
        }
        $joined = ($sumBits -join ' · ')
        $sumCap = if ($Dial -ge 4) { 1000 } elseif ($Dial -le 2) { 1600 } else { 1300 }
        if ($joined.Length -gt $sumCap) {
            $joined = Get-PromptParleFidelityTrim -Text $joined -MaxChars $sumCap -Marker '…'
        }
        $Store['rolling_summary'] = $joined
        $Store['last_compact_turn'] = $list.Count

        $rawOlder = 0
        for ($i = 0; $i -lt $cut; $i++) { $rawOlder += ([string]$list[$i].text).Length }
        $saved = [Math]::Max(0, $rawOlder - $joined.Length)
        try { $Store['chars_saved_est'] = [int]$Store['chars_saved_est'] + $saved } catch { $Store['chars_saved_est'] = $saved }
    }

    return $Store
}

function Invoke-PromptParleChatMemoryBrief {
    <#
    .SYNOPSIS
      Continuous session memory — high fidelity first, then densify age/noise.
      Doctrine: selection over destruction.
        - Spine + open work: durable project facts (paths, versions, decisions)
        - Rolling summary: older turns folded extractively (not gutted)
        - Mid: rich extracts bridging summary → recent
        - Recent: near-full bodies (dial-capped, generous)
      Extractive compact = 0 model tokens. Never trade correctness for token theater.
    #>
    param(
        [object[]]$History,
        [string]$HistoryText = '',
        [int]$MaxChars = 3200,
        [int]$Dial = 3,
        [string]$ClientSessionId = ''
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
                $tt = Reduce-PromptParleTurnTextForMemory -Text $Matches[2].Trim() -Role $r
                if ($tt) { $turns.Add([pscustomobject]@{ role = $r; text = $tt }) }
            }
        }
    }

    # Load + update rolling store (project continuity across long sessions)
    $store = $null
    $sid = if ($ClientSessionId) { $ClientSessionId.Trim() } else { '' }
    if ($sid) {
        try {
            $store = Get-PromptParleChatMemoryStore -SessionId $sid
            if ($turns.Count -gt 0) {
                $store = Update-PromptParleChatMemoryStore -Store $store -Turns @($turns.ToArray()) -Dial $Dial
                Save-PromptParleChatMemoryStore -Store $store -SessionId $sid
            }
        } catch {
            $store = $null
            Write-PromptParleDebugLog ("chat-memory store: " + $_.Exception.ToString())
        }
    }

    if ($turns.Count -eq 0 -and (-not $store -or (-not $store['project_spine'] -and -not $store['rolling_summary']))) {
        return [pscustomobject]@{ text = ''; notes = @('memory: none'); chars_in = 0; chars_out = 0 }
    }

    $charsIn = 0
    foreach ($t in $turns) { $charsIn += $t.text.Length }
    # Count prior store as "would have been replayed" for savings narrative
    if ($store -and $store['chars_saved_est']) {
        try { $charsIn += [int]$store['chars_saved_est'] } catch { }
    }

    # High-fidelity tiers by dial — recent near-full; mid rich; older in summary
    $recentN = if ($Dial -le 2) { 5 } elseif ($Dial -eq 3) { 4 } else { 3 }
    $midN = if ($Dial -le 2) { 6 } elseif ($Dial -eq 3) { 5 } else { 3 }
    $hasRolling = [bool]($store -and $store['rolling_summary'])
    # With rolling summary, still keep a solid mid bridge (do not collapse to amnesia)
    if ($hasRolling) { $midN = [Math]::Max(2, [Math]::Min($midN, 4)) }

    $startRecent = [Math]::Max(0, $turns.Count - $recentN)
    $startMid = [Math]::Max(0, $startRecent - $midN)

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('[MEM] high-fidelity session (noise stripped; older folded; recent near-full — treat as known context)')

    # Spine: prefer store (durable), else compute — generous caps
    $spine = ''
    if ($store -and $store['project_spine']) { $spine = [string]$store['project_spine'] }
    if (-not $spine -and $turns.Count -gt 0) {
        $spine = Get-PromptParleMemorySpine -Turns @($turns.ToArray()) -MaxLen $(if ($Dial -ge 4) { 520 } elseif ($Dial -le 2) { 820 } else { 680 })
    }
    if ($spine) {
        $lines.Add('Spine:')
        $lines.Add($spine)
    }
    if ($store -and $store['open_work']) {
        $lines.Add('Open: ' + [string]$store['open_work'])
    }

    # Rolling summary for deep past only — never a substitute for mid/recent
    if ($hasRolling) {
        $lines.Add('Summary (older, compacted):')
        $lines.Add([string]$store['rolling_summary'])
    } elseif ($startMid -gt 0) {
        $lines.Add('Earlier:')
        for ($i = 0; $i -lt $startMid; $i++) {
            $t = $turns[$i]
            $extract = Get-PromptParleMemoryExtract -Text $t.text -MaxLen $(if ($Dial -ge 4) { 120 } else { 160 })
            if ($extract) {
                $tag = if ($t.role -eq 'assistant') { 'A' } else { 'U' }
                $lines.Add("· ${tag}: $extract")
            }
        }
    }

    # Mid band — rich extracts (high-fid bridge into recent)
    if ($startMid -lt $startRecent) {
        $lines.Add('Mid:')
        for ($i = $startMid; $i -lt $startRecent; $i++) {
            $t = $turns[$i]
            $extract = Get-PromptParleMemoryExtract -Text $t.text -MaxLen $(if ($Dial -ge 4) { 180 } elseif ($Dial -le 2) { 280 } else { 220 })
            if ($extract) {
                $tag = if ($t.role -eq 'assistant') { 'A' } else { 'U' }
                $lines.Add("· ${tag}: $extract")
            }
        }
    }

    # Recent: near-full densified body (conversational live window — fidelity first)
    if ($turns.Count -gt 0) {
        $lines.Add('Recent:')
        for ($i = $startRecent; $i -lt $turns.Count; $i++) {
            $t = $turns[$i]
            $tag = if ($t.role -eq 'assistant') { 'assistant' } else { 'user' }
            $body = $t.text
            $cap = if ($Dial -le 2) { 1400 } elseif ($Dial -eq 3) { 1000 } elseif ($Dial -eq 4) { 700 } else { 480 }
            if ($body.Length -gt $cap) {
                $body = Get-PromptParleFidelityTrim -Text $body -MaxChars $cap -Marker '…'
            }
            $body = $body.Trim()
            if ($body) { $lines.Add("${tag}: $body") }
        }
    }

    $out = ($lines -join "`n")
    if ($out.Length -gt $MaxChars) {
        $out = Get-PromptParleFidelityTrim -Text $out -MaxChars $MaxChars -Marker '…[mem budget]…'
    }
    $pct = if ($charsIn -gt 0) { [int][Math]::Round(100.0 * (1.0 - ($out.Length / [double]$charsIn))) } else { 0 }
    if ($pct -lt 0) { $pct = 0 }
    $notes = New-Object System.Collections.Generic.List[string]
    [void]$notes.Add("memory −${pct}% ($charsIn→$($out.Length))")
    [void]$notes.Add("turns $($turns.Count)")
    [void]$notes.Add('rolling-compact')
    if ($hasRolling) { [void]$notes.Add('session-summary') }
    if ($store -and $store['last_compact_turn']) { [void]$notes.Add(('compact@' + $store['last_compact_turn'])) }

    return [pscustomobject]@{
        text      = $out
        notes     = @($notes.ToArray())
        chars_in  = $charsIn
        chars_out = $out.Length
        turns     = $turns.Count
        rolling   = [bool]$hasRolling
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
            $rel = $_.FullName.Substring($root.Length).TrimStart([char]0x5C, [char]0x2F)
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
            $rel = $_.FullName.Substring($root.Length).TrimStart([char]0x5C, [char]0x2F)
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
    # Counterfactual baseline: full chars of the files we sliced from (what a
    # no-tool client would have had to paste/ingest to reach the same answer).
    $rawChars = 0
    foreach ($f in $top) {
        $fileN++
        $lineArr = @($f.lines)
        try { $rawChars += (($lineArr -join "`n").Length) } catch { }
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
        # avoided-ingest counterfactual: full sliced-file chars vs the slice emitted
        chars_without = $rawChars
        chars_with    = $text.Length
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
            foreach ($n in @($r.notes)) { if ($n) { [void]$notes.Add([string]$n) } }
            return [pscustomobject]@{ text = $r.text; notes = @($notes); chars_in = $charsIn; chars_out = $r.text.Length }
        }
        $r2 = Invoke-PromptParleCodeBriefLocal -Text $Text -MaxChars $MaxChars -Dial $Dial -Prompt $Prompt
        foreach ($n in @($r2.notes)) { if ($n) { [void]$notes.Add([string]$n) } }
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
            $rel = $_.FullName.Substring($root.Length).TrimStart([char]0x5C, [char]0x2F)
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
                $rel = $_.FullName.Substring($root.Length).TrimStart([char]0x5C, [char]0x2F)
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
                $rel = $_.FullName.Substring($root.Length).TrimStart([char]0x5C, [char]0x2F)
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
                $rel = $_.FullName.Substring($root.Length).TrimStart([char]0x5C, [char]0x2F)
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
    # avoided-ingest side channel: raw git output the model could not have produced
    # itself (git ran on this PC for 0 model tokens). prep reads this right after.
    $script:PromptParleLastGitRawChars = $text.Length
    if ($text.Length -gt $MaxChars) {
        $text = $text.Substring(0, $MaxChars) + "`n…[diff]"
    }
    $script:PromptParleLastGitWithChars = $text.Length
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
            return [pscustomobject]@{ ok = $true; tool = $id; local = $true; text = $t; notes = @('connections: skinny map') }
        }
        'conn_index' {
            $argS = if ($Arg) { [string]$Arg } else { '' }
            $t = Get-PromptParleConnectionIndexText -IdOrLabel $argS
            return [pscustomobject]@{ ok = $true; tool = $id; local = $true; text = $t; notes = @('conn_index: on-disk catalog') }
        }
        'know_search' {
            $q = if ($Arg) { [string]$Arg } elseif ($Text) { [string]$Text } else { '' }
            $t = Search-PromptParleKnowledgeCatalog -Query $q
            return [pscustomobject]@{ ok = $true; tool = $id; local = $true; text = $t; notes = @('know_search: index only') }
        }
        'know_read' {
            $p = if ($Arg) { [string]$Arg } else { '' }
            $t = Read-PromptParleKnowledgeFile -PathOrRel $p
            return [pscustomobject]@{ ok = $true; tool = $id; local = $true; text = $t; notes = @('know_read: readonly') }
        }
        { $_ -in @('web_search', 'web', 'search') } {
            $q = if ($Arg) { $Arg } elseif ($Text) { $Text } else { '' }
            return Invoke-PromptParleWebSearchLocal -Query $q
        }
        { $_ -in @('local_list', 'dir_list', 'listdir', 'local_dir') } {
            $path = if ($Arg) { $Arg } elseif ($Text) { $Text } else { '' }
            $listing = Invoke-PromptParleLocalDirListing -LocalPath $path -MaxChars 7000
            return [pscustomobject]@{
                ok    = [bool]$listing.ok
                tool  = 'local_list'
                local = $true
                text  = if ($listing.text) { $listing.text } else { "Could not list local path: $path" }
                notes = @($listing.notes)
                path  = $listing.path
            }
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
        { $_ -in @('list', 'ls', 'dir') } {
            # Smart route: Windows / no SSH → local; else SSH
            $path = if ($Arg) { $Arg } else { '' }
            $useLocal = $true
            if ($path -match '^[A-Za-z]:') { $useLocal = $true }
            elseif ($path -match '(?i)^(/home|/var|/opt|/usr|/tmp|/etc|~)') {
                $hasSsh = $false
                try {
                    $st = Get-PromptParleSessionState
                    $hasSsh = [bool][string](Get-PromptParleProp $st 'ssh_target' '')
                } catch { }
                $useLocal = -not $hasSsh
            }
            if ($useLocal) {
                $r = Invoke-PromptParleLocalDirListing -LocalPath $path -MaxChars 6000
                return [pscustomobject]@{
                    ok = [bool]$r.ok; tool = 'local_list'; local = $true
                    text = $(if ($r.text) { $r.text } else { "local_list failed: $($r.notes -join ', ')" })
                    notes = @($r.notes); path = $r.path
                }
            }
            $r = Invoke-PromptParleSshDirListing -RemotePath $path -MaxChars 6000
            return [pscustomobject]@{
                ok = [bool]$r.ok; tool = 'ssh_list'; local = $true
                text = $(if ($r.text) { $r.text } else { "ssh_list failed: $($r.notes -join ', ')" })
                notes = @($r.notes); path = $r.path
            }
        }
        'ssh_list' {
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
                    $rel = $_.FullName.Substring($root.Length).TrimStart([char]0x5C, [char]0x2F)
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
        '[HANDS] client tools (0 AI tokens). Request tools as tool: arg lines — either fenced ```hands ... ``` or a bare block:',
        '[HANDS]',
        'web_page: url-or-domain',
        'web_search: q | web_page: url|domain | local_list: C:\path | ssh_list: path | ssh_read: path | ssh_run: allowlisted-cmd',
        'workspace_find: *.md,*.pdf | query | relevant_slice: q | file_index | git_diff | git | connections | tree_pack: depth',
        'After client returns [HANDS] results: answer or apply/run/file. Never teach the user the method. Never leave a bare tool request as the final answer.'
    ) -join "`n"
}

function Test-PromptParleHasBareHandsRequest {
    <# True when model used bare [HANDS] + tool:arg (not ```hands fence, not client result packs). #>
    param([string]$Text = '')
    if (-not $Text) { return $false }
    # Whole-line [HANDS] header (request form)
    if ($Text -match '(?im)^\s*\[HANDS\]\s*$') { return $true }
    # Inline: [HANDS] web_page: domain  — exclude our own "client results/tools" pack headers
    if ($Text -match '(?im)^\s*\[HANDS\]\s+(?!client\s+(?:results|tools)\b)([a-z_][a-z0-9_]*)\s*[:|]\s*\S') { return $true }
    return $false
}

function ConvertFrom-PromptParleBareHandsBlocks {
    <#
    .SYNOPSIS
      Parse bare [HANDS] requests models emit when they echo the catalog header
      instead of a ```hands fence. Example:
        [HANDS]
        web_page: example.com
      Or inline:
        [HANDS] web_page: example.com
    #>
    param([string]$Text = '')
    $reqs = New-Object System.Collections.Generic.List[object]
    if (-not $Text) { return @() }

    $parseToolLine = {
        param([string]$Ln, [int]$Index)
        if (-not $Ln) { return $null }
        $tool = ''
        $arg = ''
        if ($Ln -match '^(?i)([a-z_][a-z0-9_]*)\s*:\s*(.*)$') {
            $tool = $Matches[1].Trim()
            $arg = $Matches[2].Trim()
        } elseif ($Ln -match '^(?i)([a-z_][a-z0-9_]*)\s*\|\s*(.*)$') {
            $tool = $Matches[1].Trim()
            $arg = $Matches[2].Trim()
        } elseif ($Ln -match '^(?i)([a-z_][a-z0-9_]*)\s+(.+)$') {
            $tool = $Matches[1].Trim()
            $arg = $Matches[2].Trim()
        } elseif ($Ln -match '^(?i)([a-z_][a-z0-9_]*)$') {
            $tool = $Matches[1].Trim()
        } else {
            return $null
        }
        $tool = $tool.ToLowerInvariant()
        # Never treat pack headers / markdown noise as tools
        if ($tool -in @('client', 'http', 'https', 'after', 'never', 'request', 'answer')) { return $null }
        return [pscustomobject]@{ tool = $tool; arg = $arg; index = $Index; bare = $true }
    }

    # Inline form: [HANDS] web_page: domain
    foreach ($m in [regex]::Matches($Text, '(?im)^\s*\[HANDS\]\s+(.+?)\s*$')) {
        $rest = $m.Groups[1].Value.Trim()
        if ($rest -match '^(?i)client\s+(?:results|tools)\b') { continue }
        $obj = & $parseToolLine $rest $m.Index
        if ($obj) { [void]$reqs.Add($obj) }
    }

    # Block form: [HANDS]\n tool: arg lines (stop at first non-tool non-empty line after tools start)
    foreach ($m in [regex]::Matches($Text, '(?im)^\s*\[HANDS\]\s*$')) {
        $start = $m.Index + $m.Length
        if ($start -ge $Text.Length) { continue }
        $rest = $Text.Substring($start)
        $got = 0
        $offset = $start
        foreach ($line in ($rest -split '\r?\n', -1)) {
            # account for leading newline after header match
            if ($line.Length -eq 0 -and $offset -eq $start) {
                $offset += 1
                continue
            }
            $ln = $line.Trim()
            $lineIndex = $offset
            $offset += $line.Length + 1
            if (-not $ln) {
                if ($got -gt 0) { break }
                continue
            }
            if ($ln -match '^(?i)\[HANDS\]') { break }
            if ($ln.StartsWith('#')) { continue }
            $obj = & $parseToolLine $ln $lineIndex
            if ($obj) {
                [void]$reqs.Add($obj)
                $got++
                if ($got -ge 8) { break }
                continue
            }
            # prose / non-tool → end of bare block
            break
        }
    }

    return @($reqs.ToArray())
}

function Test-PromptParleForeignToolTheater {
    <# True when model dumped foreign tool XML / toolcall markup instead of answering or using ```hands. #>
    param([string]$Text = '')
    if (-not $Text) { return $false }
    if ($Text -match '(?is)<\s*(tool_?call|toolcall|function_?call|invoke|tool_request|xai:tool)\b') { return $true }
    if ($Text -match '(?is)</\s*(tool_?call|toolcall|function_?call)\s*>') { return $true }
    if ($Text -match '(?im)^\s*(tool_?call|function_?call|invoke_tool|tool_code)\s*$') { return $true }
    if ($Text -match '(?is)```(?:html|xml|tool|tool_code|json)?\s*\r?\n\s*<\s*(tool_?call|toolcall|function_?call)\b') { return $true }
    if ($Text -match '(?is)```(?:tool_code|toolcall|tool)\b') { return $true }
    # Gemini / Google-style pseudo tools
    if ($Text -match '(?i)\bgoogle_?search\s*\(') { return $true }
    if ($Text -match '(?im)^\s*(google_?search|default_api\.\w+)\s*$') { return $true }
    if ($Text -match '(?i)\bdefault_api\.(google_?search|web_?search|web_?page)\s*\(') { return $true }
    return $false
}

function ConvertFrom-PromptParleForeignToolCalls {
    <#
    .SYNOPSIS
      0.21/0.26.17: parse foreign model tool protocols into hands tool/arg requests.
      Handles toolcall XML, Gemini google_search / tool_code, and "tool\nq is …" bodies.
    #>
    param([string]$Text = '')
    $reqs = New-Object System.Collections.Generic.List[object]
    if (-not $Text) { return @() }

    $normalizeTool = {
        param([string]$Tool)
        if (-not $Tool) { return '' }
        $t = $Tool.ToLowerInvariant().Trim()
        $t = $t -replace '^(tool_|function_|invoke_|default_api\.)', ''
        switch ($t) {
            'search' { return 'web_search' }
            'websearch' { return 'web_search' }
            'web-search' { return 'web_search' }
            'web_search' { return 'web_search' }
            'search_web' { return 'web_search' }
            'google' { return 'web_search' }
            'google_search' { return 'web_search' }
            'googlesearch' { return 'web_search' }
            'google-search' { return 'web_search' }
            'bing_search' { return 'web_search' }
            'duckduckgo' { return 'web_search' }
            'ddg_search' { return 'web_search' }
            'browse' { return 'web_page' }
            'open_url' { return 'web_page' }
            'fetch_url' { return 'web_page' }
            'fetch' { return 'web_page' }
            'page' { return 'web_page' }
            'read_url' { return 'web_page' }
            'web_page' { return 'web_page' }
            'open_page' { return 'web_page' }
            'get_page' { return 'web_page' }
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
    $addReq = {
        param([string]$Tool, [string]$Arg, [int]$Index)
        $tool = & $normalizeTool $Tool
        $arg = & $normalizeArg $Arg $tool
        if (-not $tool) { return }
        foreach ($existing in $reqs) {
            if ($existing.tool -eq $tool -and $existing.arg -eq $arg) { return }
        }
        [void]$reqs.Add([pscustomobject]@{ tool = $tool; arg = $arg; index = $Index; foreign = $true })
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
        if (-not $tool -and $body -match '(?i)\b(web_search|web_page|google_search|ssh_list|ssh_read|ssh_run|workspace_find|relevant_slice)\b') {
            $tool = $Matches[1]
            if (-not $arg) { $arg = $body }
        }
        & $addReq $tool $arg $m.Index
    }

    # Bare / unclosed toolcall bodies (incl. Gemini: tool_call + google_search + query line)
    if ($reqs.Count -eq 0 -and $Text -match '(?is)(?:tool_?call|toolcall|function_?call|tool_code)') {
        $tool = ''
        $arg = ''
        if ($Text -match '(?im)\b(web_search|web_page|websearch|search_web|browse|google_search|googlesearch|google-search|google_search|search)\b') {
            $tool = $Matches[1]
        }
        if ($Text -match '(?is)(?:q|query|search)\s*(?:is|=|:)\s*([^\r\n<]+)') { $arg = $Matches[1].Trim() }
        elseif ($Text -match '(?is)(?:url|page|domain)\s*(?:is|=|:)\s*([^\r\n<]+)') {
            $arg = $Matches[1].Trim()
            if (-not $tool) { $tool = 'web_page' }
        }
        # tool_call\ngoogle_search\nnewest movies...
        if (-not $arg -and $Text -match '(?is)(?:tool_?call|toolcall|function_?call|tool_code)\s*\r?\n\s*(?:[a-z_][a-z0-9_]*)\s*\r?\n\s*([^\r\n<]{3,200})') {
            $arg = $Matches[1].Trim()
            if (-not $tool) { $tool = 'web_search' }
        }
        if (-not $tool -and $arg) { $tool = 'web_search' }
        if ($tool) { & $addReq $tool $arg 0 }
    }

    # Function-call style: google_search(query="...") / default_api.web_search(q='...')
    foreach ($m in [regex]::Matches($Text, '(?is)\b(?:default_api\.)?(google_?search|web_?search|web_?page|search_web|browse)\s*\(\s*(?:(?:q|query|url|input)\s*=\s*)?["'']([^"'']+)["'']')) {
        & $addReq $m.Groups[1].Value $m.Groups[2].Value $m.Index
    }
    # print(google_search(...)) residual without named kw
    foreach ($m in [regex]::Matches($Text, '(?is)\b(?:print\s*\(\s*)?(?:default_api\.)?(google_?search|web_?search)\s*\(\s*["'']([^"'']+)["'']\s*\)')) {
        & $addReq $m.Groups[1].Value $m.Groups[2].Value $m.Index
    }

    # fenced tool_code / json / xml tool payloads
    foreach ($m in [regex]::Matches($Text, '(?ms)```(?:tool|tool_code|toolcall|json|xml|html)?[^\n]*\r?\n(.*?)```')) {
        $body = $m.Groups[1].Value
        if ($body -match '(?i)"(?:name|tool)"\s*:\s*"(web_search|web_page|google_search|ssh_list|ssh_read|workspace_find)"') {
            $tool = $Matches[1]
            $arg = ''
            if ($body -match '(?i)"(?:q|query|input|url|arguments?)"\s*:\s*"([^"]+)"') { $arg = $Matches[1] }
            & $addReq $tool $arg $m.Index
        }
        if ($body -match '(?is)\b(?:default_api\.)?(google_?search|web_?search|web_?page)\s*\(') {
            foreach ($fm in [regex]::Matches($body, '(?is)\b(?:default_api\.)?(google_?search|web_?search|web_?page)\s*\(\s*(?:(?:q|query|url|input)\s*=\s*)?["'']([^"'']+)["'']')) {
                & $addReq $fm.Groups[1].Value $fm.Groups[2].Value ($m.Index + $fm.Index)
            }
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
    # Bare [HANDS] + tool:arg (Gemini and others echo catalog header instead of ```hands fence)
    foreach ($br in @(ConvertFrom-PromptParleBareHandsBlocks -Text $Text)) {
        if (-not $br.tool) { continue }
        $dup = $false
        foreach ($existing in $reqs) {
            if ($existing.tool -eq $br.tool -and $existing.arg -eq $br.arg) { $dup = $true; break }
        }
        if (-not $dup) { [void]$reqs.Add($br) }
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
    $id = $id -replace '^(default_api\.)', ''
    switch ($id) {
        'ls' { $id = 'list' }       # smart local/ssh router in LocalTool
        'dir' { $id = 'list' }
        'local_list' { $id = 'local_list' }
        'search' { $id = 'web_search' }
        'web' { $id = 'web_search' }
        'websearch' { $id = 'web_search' }
        'web-search' { $id = 'web_search' }
        'search_web' { $id = 'web_search' }
        'google' { $id = 'web_search' }
        'google_search' { $id = 'web_search' }
        'googlesearch' { $id = 'web_search' }
        'google-search' { $id = 'web_search' }
        'bing_search' { $id = 'web_search' }
        'duckduckgo' { $id = 'web_search' }
        'fetch' { $id = 'web_page' }
        'page' { $id = 'web_page' }
        'browse' { $id = 'web_page' }
        'open_url' { $id = 'web_page' }
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
    <# Internal pack for model context only — never show raw to the user. #>
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

function Format-PromptParleUserFacingEvidence {
    <#
    .SYNOPSIS
      0.26.18: conversational brief from hands/web results for the user.
      Never includes [HANDS], hands#, tool theater, or "ask for a prose summary".
    #>
    param(
        [object[]]$Results,
        [string]$Prompt = '',
        [int]$MaxChars = 4500
    )
    $lines = New-Object System.Collections.Generic.List[string]
    $q = ''
    if ($Prompt) { $q = $Prompt.Trim() }
    if ($q.Length -gt 120) { $q = $q.Substring(0, 117) + '…' }

    $linkLines = New-Object System.Collections.Generic.List[string]
    $extra = New-Object System.Collections.Generic.List[string]
    $anyOk = $false

    foreach ($r in @($Results)) {
        if (-not $r) { continue }
        $ok = $true
        try { $ok = [bool]$r.ok } catch { }
        if ($ok) { $anyOk = $true }
        $blob = [string]$r.text
        if (-not $blob) { continue }

        # Prefer structured [WEB] hits
        if ($blob -match '(?m)^\[WEB\]') {
            if ($blob -match '(?m)^\[WEB\]\s*q=(.+)$') {
                $wq = $Matches[1].Trim()
                if (-not $q) { $q = $wq }
            }
            if ($blob -match '(?ms)^Summary:\s*(.+?)(?=\r?\n\d+\.|\r?\n---|$)') {
                $sum = $Matches[1].Trim()
                if ($sum -and $sum.Length -gt 20) { [void]$extra.Add($sum) }
            }
            foreach ($m in [regex]::Matches($blob, '(?m)^(\d+)\.\s+(.+?)(?:\s+\|\s+(https?://\S+))?\s*$')) {
                $title = $m.Groups[2].Value.Trim()
                $url = $m.Groups[3].Value.Trim()
                if ($url) {
                    [void]$linkLines.Add(('- **{0}** — {1}' -f $title, $url))
                } else {
                    [void]$linkLines.Add(('- **{0}**' -f $title))
                }
            }
            # Optional page body after OBSERVE
            if ($blob -match '(?ms)\[OBSERVE\][^\n]*\r?\n(?:url:\s*\S+\r?\n)?([\s\S]{80,2400})') {
                $body = $Matches[1].Trim()
                $body = [regex]::Replace($body, '\s+', ' ')
                if ($body.Length -gt 500) { $body = $body.Substring(0, 497) + '…' }
                [void]$extra.Add($body)
            }
            continue
        }

        # web_page / plain text
        $clean = [regex]::Replace($blob, '(?m)^\[(HANDS|WEB|OBSERVE|CLIENT)\][^\n]*\r?\n?', '')
        $clean = [regex]::Replace($clean, '\s+', ' ').Trim()
        if ($clean.Length -gt 40) {
            if ($clean.Length -gt 600) { $clean = $clean.Substring(0, 597) + '…' }
            [void]$extra.Add($clean)
        }
    }

    if ($q) {
        [void]$lines.Add(('Here''s what I found for **{0}**:' -f $q))
    } else {
        [void]$lines.Add('Here''s what I found:')
    }
    [void]$lines.Add('')

    if ($extra.Count -gt 0) {
        foreach ($e in $extra) {
            if ($e) { [void]$lines.Add($e); [void]$lines.Add('') }
        }
    }

    if ($linkLines.Count -gt 0) {
        [void]$lines.Add('**Sources**')
        foreach ($ll in $linkLines) { [void]$lines.Add($ll) }
        [void]$lines.Add('')
        # Honest when we only have listing hubs (common for "newest movies")
        $hubby = ($linkLines -join ' ') -match '(?i)fandango|amc|cinemark|rottentomatoes|showtimes|movies.in.theaters|new movies'
        if ($hubby -and $extra.Count -eq 0) {
            [void]$lines.Add('Those are live theater listing pages. Open a source above for the full current title list (listings change daily by market).')
        }
    } elseif (-not $anyOk) {
        [void]$lines.Add('I couldn''t pull solid web results just now. Try again, or name a site (e.g. fandango.com).')
    } elseif ($extra.Count -eq 0) {
        [void]$lines.Add('Search ran, but the brief came back thin. Try a more specific ask (city, theater chain, or a title).')
    }

    $text = ($lines -join "`n").Trim()
    if ($text.Length -gt $MaxChars) {
        $text = $text.Substring(0, $MaxChars).Trim() + '…'
    }
    return $text
}

function Expand-PromptParleHandsWithListingPages {
    <#
    .SYNOPSIS
      0.26.18: when web_search only returned theater/listing hub links, fetch 1–2 pages
      so synthesis can name actual movies when the HTML has them.
    #>
    param(
        [object[]]$Results,
        [string]$Prompt = '',
        [int]$MaxPages = 2,
        [int]$MaxChars = 3500
    )
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($r in @($Results)) { if ($r) { [void]$out.Add($r) } }
    $blob = ($out | ForEach-Object { [string]$_.text }) -join "`n"
    $q = ($Prompt + ' ' + $blob).ToLowerInvariant()
    $wantsMovies = [bool]($q -match '(?i)\b(movie|movies|film|films|theater|theatre|cinema|showtimes?|box office|now playing)\b')
    if (-not $wantsMovies) { return @($out.ToArray()) }

    $urls = New-Object System.Collections.Generic.List[string]
    foreach ($m in [regex]::Matches($blob, 'https?://[^\s<>"'']+')) {
        $u = $m.Value.TrimEnd('.,);')
        if ($u -match '(?i)(fandango\.com/movies|rottentomatoes\.com/browse/movies|amctheatres\.com/movies|cinemark\.com/movies|rottentomatoes\.com/guide/popular)') {
            if (-not ($urls -contains $u)) { [void]$urls.Add($u) }
        }
    }
    # Prefer known listing roots if only generic hosts appeared
    if ($urls.Count -eq 0) {
        if ($blob -match '(?i)fandango\.com') { [void]$urls.Add('https://www.fandango.com/movies-in-theaters') }
        if ($blob -match '(?i)rottentomatoes\.com') { [void]$urls.Add('https://www.rottentomatoes.com/browse/movies_in_theaters/sort:newest') }
    }
    $n = 0
    foreach ($u in $urls) {
        if ($n -ge $MaxPages) { break }
        try {
            $pg = Invoke-PromptParleWebPageFetch -UrlOrDomain $u -MaxChars $MaxChars
            if ($pg.ok -and $pg.text) {
                [void]$out.Add([pscustomobject]@{
                    ok = $true
                    tool = 'web_page'
                    arg = $u
                    text = [string]$pg.text
                    notes = @('listing-page-expand')
                })
                $n++
                Write-Host ("  hands(expand): web_page {0} ({1}c)" -f $u, ([string]$pg.text).Length) -ForegroundColor Cyan
            }
        } catch { }
    }
    return @($out.ToArray())
}

function Invoke-PromptParleConversationalSynthesis {
    <#
    .SYNOPSIS
      0.26.18: force a user-facing prose answer from evidence. Falls back to local brief.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [object[]]$HandsResults = @(),
        [string]$PrepEvidence = '',
        [string]$System = '',
        [string]$Runtime = '',
        [string]$Provider = 'openai',
        [string]$Profile = 'general',
        [int]$CompressionLevel = 3,
        [string]$Model = ''
    )
    $hands = @($HandsResults)
    if ($hands.Count -gt 0) {
        try { $hands = @(Expand-PromptParleHandsWithListingPages -Results $hands -Prompt $Prompt) } catch { }
    }
    $pack = if ($hands.Count -gt 0) { Format-PromptParleHandsPack -Results $hands -MaxChars 9000 } else { '' }
    $userBrief = if ($hands.Count -gt 0) { Format-PromptParleUserFacingEvidence -Results $hands -Prompt $Prompt -MaxChars 4500 } else { '' }

    $ctxParts = New-Object System.Collections.ArrayList
    if ($PrepEvidence) { [void]$ctxParts.Add([string]$PrepEvidence) }
    if ($pack) { [void]$ctxParts.Add([string]$pack) }
    $ctx = ([string[]]@($ctxParts.ToArray())) -join "`n`n"

    $sys = if ($System) { $System.Trim() } else { '' }
    if ($sys) {
        $sys = $sys + "`n`nYou are in a normal chat with a person. Be warm, direct, and conversational."
    } else {
        $sys = 'You are PromptParle in a normal chat. Be warm, direct, and conversational.'
    }

    $promptSyn = @(
        $Prompt.Trim()
        ''
        '[CLIENT DIRECTIVE — conversational answer · 0.26.18]'
        'The client ALREADY ran tools. Evidence is in context ([HANDS]/[WEB]/[OBSERVE]).'
        'Write the FINAL answer as natural chat prose a human would want to read.'
        'Rules:'
        '- Answer the user question directly. Use bullet lists for movies/titles when useful.'
        '- Cite source names/URLs briefly when you use them.'
        '- If evidence only has listing-site links (Fandango/AMC/RT) without individual titles, say that clearly and list the best sources — still sound like a helpful person, not a tool log.'
        '- NEVER output: [HANDS], hands#, toolcall, function_call, tool_code, ```hands, "Client ran tools", or "ask for a prose summary".'
        '- NEVER request more tools. This is the last step.'
    ) -join "`n"

    $rt = 'FINAL conversational answer only. No tools. No markup. No method dump.'
    if ($Runtime) { $rt = ($Runtime.Trim() + ' ' + $rt).Trim() }

    try {
        Write-Host '  agent: conversational synthesis' -ForegroundColor DarkYellow
        $params = @{
            Prompt           = $promptSyn
            Context          = $ctx
            System           = $sys
            Runtime          = $rt
            Provider         = $Provider
            Profile          = $Profile
            CompressionLevel = $CompressionLevel
            Quiet            = $true
            Raw              = $true
        }
        if ($Model) { $params.Model = $Model }
        $result = Invoke-PromptParle @params
        $syn = [string](Get-PromptParleProp $result 'response' (Get-PromptParleProp $result 'Response' ''))
        $syn = Remove-PromptParleHandsBlocks -Text $syn
        $bad = (-not $syn) -or ($syn.Trim().Length -lt 24) `
            -or (Test-PromptParleResponseIsToolTheaterOnly -Text $syn) `
            -or (Test-PromptParleForeignToolTheater -Text $syn) `
            -or ($syn -match '(?i)\[HANDS\]\s*client results|Client ran tools|ask a follow-up for a prose summary|hands#\d')
        if (-not $bad) {
            return [pscustomobject]@{
                ok       = $true
                text     = $syn.Trim()
                result   = $result
                hands    = $hands
                source   = 'model'
            }
        }
        Write-Host '  agent: synthesis still tool-theater — using local conversational brief' -ForegroundColor DarkYellow
    } catch {
        Write-Host ("  agent: synthesis failed: {0}" -f $_) -ForegroundColor DarkYellow
    }

    $fallback = if ($userBrief) { $userBrief } else {
        "I looked that up, but couldn't form a clean answer from the results. Try asking again a bit more specifically."
    }
    return [pscustomobject]@{
        ok     = $true
        text   = $fallback
        result = $null
        hands  = $hands
        source = 'local-brief'
    }
}

function Test-PromptParleResponseNeedsHands {
    param([string]$Text = '')
    if (-not $Text) { return $false }
    if ($Text -match '(?ms)```hands') { return $true }
    if ($Text -match '(?i)<<hands\s+') { return $true }
    if (Test-PromptParleHasBareHandsRequest -Text $Text) { return $true }
    if (Test-PromptParleForeignToolTheater -Text $Text) { return $true }
    return $false
}

function Remove-PromptParleHandsBlocks {
    param([string]$Text = '')
    if (-not $Text) { return '' }
    $t = [regex]::Replace($Text, '(?ms)```hands[^\n]*\r?\n.*?```', '')
    $t = [regex]::Replace($t, '(?i)<<hands\s+[^>]+>>', '')
    # Bare [HANDS] block: header + following tool:arg lines
    $t = [regex]::Replace($t, '(?ims)^\s*\[HANDS\]\s*\r?\n(?:[ \t]*(?:[a-z_][a-z0-9_]*\s*[:|].*|[a-z_][a-z0-9_]*\s+\S.*)[ \t]*\r?\n?)+', '')
    # Inline [HANDS] tool: arg (not client results/tools pack headers)
    $t = [regex]::Replace($t, '(?im)^\s*\[HANDS\]\s+(?!client\s+(?:results|tools)\b).+$', '')
    # Orphan bare [HANDS] header left alone
    $t = [regex]::Replace($t, '(?im)^\s*\[HANDS\]\s*$', '')
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
    # Bare residual tool lines without fence
    if ($t -match '(?i)^(web_search|web_page|ssh_list|ssh_read|workspace_find)\s*[:|]' -and $t.Length -lt 160) { return $true }
    return $false
}

function Get-PromptParleNativeToolDefinitions {
    <# OpenAI-style tool schemas for multi-provider agent pass-through (0.22). #>
    $propsQ = @{
        type = 'object'
        properties = @{
            query = @{ type = 'string'; description = 'Search query or free text' }
            q     = @{ type = 'string'; description = 'Alias for query' }
            path  = @{ type = 'string'; description = 'File or directory path' }
            url   = @{ type = 'string'; description = 'URL or domain' }
            command = @{ type = 'string'; description = 'Allowlisted remote command' }
            arg   = @{ type = 'string'; description = 'Generic argument' }
        }
    }
    $mk = {
        param([string]$Name, [string]$Desc)
        return [ordered]@{
            type = 'function'
            function = [ordered]@{
                name        = $Name
                description = $Desc
                parameters  = $propsQ
            }
        }
    }
    return @(
        (& $mk 'web_search' 'Search the web for public information. Returns brief results.')
        (& $mk 'web_page' 'Fetch a URL or domain homepage as plain text.')
        (& $mk 'local_list' 'List a directory on THIS PC (Windows C:\ or local paths). Use for "on this PC" requests — not SSH.')
        (& $mk 'ssh_list' 'List a directory on the connected SSH/product host (remote only).')
        (& $mk 'ssh_read' 'Read a file on the connected SSH host.')
        (& $mk 'ssh_run' 'Run an allowlisted pipeline command on SSH (build/test/git status-class).')
        (& $mk 'workspace_find' 'Find files in the local workspace by glob/query.')
        (& $mk 'relevant_slice' 'Load ranked relevant code slices for a query.')
        (& $mk 'file_index' 'Brief local workspace file index.')
        (& $mk 'git_diff' 'Git status/diff pack for the local workspace.')
        (& $mk 'git' 'Git status summary for the local workspace.')
        (& $mk 'connections' 'Show connected local folder / SSH targets.')
        (& $mk 'tree_pack' 'Directory tree pack for workspace or path.')
    )
}

function Get-PromptParleCaptureDir {
    $root = Join-Path $HOME '.promptparle'
    $dir = Join-Path $root 'captures'
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    return $dir
}

function Write-PromptParleAgentCapture {
    param(
        [string]$TurnId,
        [int]$Round,
        [object]$Request,
        [object]$Response,
        [string]$Note = ''
    )
    try {
        $dir = Get-PromptParleCaptureDir
        $safe = if ($TurnId) { $TurnId } else { [guid]::NewGuid().ToString('N').Substring(0, 12) }
        $name = ('{0:yyyyMMdd-HHmmss}-r{1}-{2}.json' -f (Get-Date), $Round, $safe)
        $path = Join-Path $dir $name
        $obj = [ordered]@{
            at       = (Get-Date).ToUniversalTime().ToString('o')
            turn_id  = $safe
            round    = $Round
            note     = $Note
            request  = $Request
            response = $Response
        }
        $json = ConvertTo-PromptParleJson -InputObject $obj -Depth 20
        [System.IO.File]::WriteAllText($path, $json)
        # prune old captures keep last ~80
        $files = @(Get-ChildItem -LiteralPath $dir -Filter '*.json' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
        if ($files.Count -gt 80) {
            $files | Select-Object -Skip 80 | Remove-Item -Force -ErrorAction SilentlyContinue
        }
        return $path
    } catch {
        return $null
    }
}

function ConvertTo-PromptParleHandsArgFromToolArgs {
    param(
        [string]$ToolName = '',
        [string]$ArgumentsJson = ''
    )
    $raw = if ($null -eq $ArgumentsJson) { '' } else { $ArgumentsJson.Trim() }
    if (-not $raw) { return '' }
    try {
        $o = $raw | ConvertFrom-Json
        foreach ($k in @('query', 'q', 'url', 'path', 'command', 'arg', 'input', 'text', 'domain')) {
            $v = Get-PromptParleProp $o $k $null
            if ($null -ne $v -and "$v".Trim()) { return [string]$v }
        }
        # single property object
        $props = @($o.PSObject.Properties)
        if ($props.Count -eq 1) { return [string]$props[0].Value }
        return $raw
    } catch {
        return $raw
    }
}

function Invoke-PromptParleNativeAgentTurn {
    <#
    .SYNOPSIS
      0.22 multi-AI native tool agent loop (pass-through).
      Portal /api/v1/agent = one model step with tools; desktop runs tools and continues.
      Captures each request/response under ~/.promptparle/captures for later optimization.
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
        [int]$MaxRounds = 8,
        [switch]$OptimizeOnly
    )
    if ($OptimizeOnly) {
        $p = @{
            Prompt = $Prompt; Context = $Context; System = $System; Runtime = $Runtime
            Provider = $Provider; Profile = $Profile; CompressionLevel = $CompressionLevel
            Quiet = $true; Raw = $true; OptimizeOnly = $true
        }
        if ($Model) { $p.Model = $Model }
        return Invoke-PromptParle @p
    }

    if ($MaxRounds -le 0) { $MaxRounds = 8 }
    $turnId = [guid]::NewGuid().ToString('N').Substring(0, 12)
    $tools = @(Get-PromptParleNativeToolDefinitions)
    $sys = if ($System) { $System.Trim() } else { Get-PromptParleChatSystemPrompt }
    if ($Runtime) { $sys = ($sys + "`n`n" + $Runtime.Trim()).Trim() }
    $sys = ($sys + "`n`nAGENT 0.22 pass-through: use native tools when you need evidence; then answer in prose. Never dump tool XML.").Trim()

    $userContent = $Prompt.Trim()
    if ($Context) {
        $userContent = $userContent + "`n`n--- connection / session context ---`n" + $Context.Trim()
    }

    $messages = New-Object System.Collections.Generic.List[object]
    [void]$messages.Add([ordered]@{ role = 'system'; content = $sys })
    [void]$messages.Add([ordered]@{ role = 'user'; content = $userContent })

    $allHands = New-Object System.Collections.Generic.List[object]
    $sumIn = 0
    $sumOut = 0
    $roundsUsed = 0
    $lastContent = ''
    $capturePaths = New-Object System.Collections.Generic.List[string]
    $modelOut = $Model

    for ($round = 1; $round -le $MaxRounds; $round++) {
        $roundsUsed = $round
        Write-Host ("  agent-native: round {0}/{1} provider={2}" -f $round, $MaxRounds, $Provider) -ForegroundColor DarkCyan

        $body = [ordered]@{
            provider     = [string]$Provider
            messages     = @($messages.ToArray())
            tools        = @($tools)
            tool_choice  = 'auto'
            include_raw  = $true
            max_tokens   = 4096
            temperature  = 0.2
        }
        if ($Model) { $body.model = [string]$Model }

        # 0.25 Local-first: agent loop stays on PC (text-hands → Invoke-PromptParle local).
        # Portal /api/v1/agent is no longer on the desktop path (no key custody / no prompt hop).
        Write-Host '  agent-native: local-first text-hands (no portal agent hop)' -ForegroundColor DarkCyan
        $fb = @{
            Prompt = $Prompt; Context = $Context; System = $System; Runtime = $Runtime
            Provider = $Provider; Profile = $Profile; CompressionLevel = $CompressionLevel
            MaxRounds = $MaxRounds
        }
        if ($Model) { $fb.Model = $Model }
        if ($Images) { $fb.Images = $Images }
        return Invoke-PromptParleLegacyTextHandsTurn @fb

        # Unreachable legacy portal agent (kept for reference / future opt-in)
        $resp = $null
        try {
            $resp = Invoke-PromptParleApi -Method POST -Path '/api/v1/agent' -Body $body
        } catch {
            if ("$_" -match '404|Not Found|/api/v1/agent|Unknown path') {
                Write-Host '  agent-native: /api/v1/agent unavailable — falling back to text-hands loop' -ForegroundColor Yellow
                return Invoke-PromptParleLegacyTextHandsTurn @fb
            }
            throw
        }

        $cap = Write-PromptParleAgentCapture -TurnId $turnId -Round $round -Request $body -Response $resp -Note 'native-step'
        if ($cap) { [void]$capturePaths.Add($cap) }

        if (-not $resp) { throw 'Empty agent response' }
        $err = Get-PromptParleProp $resp 'error' $null
        if ($err) { throw "Agent API: $err" }

        $msg = Get-PromptParleProp $resp 'message' $null
        if (-not $msg) { throw 'Agent response missing message' }
        if (Get-PromptParleProp $resp 'model' $null) { $modelOut = [string](Get-PromptParleProp $resp 'model' $modelOut) }

        $usage = Get-PromptParleProp $resp 'usage' $null
        if ($usage) {
            try { $sumIn += [int](Get-PromptParleProp $usage 'input_tokens' 0) } catch { }
            try { $sumOut += [int](Get-PromptParleProp $usage 'output_tokens' 0) } catch { }
        }

        $content = Get-PromptParleProp $msg 'content' $null
        if ($null -ne $content) { $lastContent = [string]$content }
        $toolCalls = @()
        $tcRaw = Get-PromptParleProp $msg 'tool_calls' $null
        if ($null -ne $tcRaw) { $toolCalls = @($tcRaw) }

        # Append assistant message (with tool_calls if any)
        $asst = [ordered]@{ role = 'assistant'; content = $(if ($null -eq $content) { $null } else { [string]$content }) }
        if ($toolCalls.Count -gt 0) {
            $normCalls = New-Object System.Collections.Generic.List[object]
            foreach ($tc in $toolCalls) {
                $fn = Get-PromptParleProp $tc 'function' $null
                $name = [string](Get-PromptParleProp $fn 'name' '')
                $args = [string](Get-PromptParleProp $fn 'arguments' '{}')
                $id = [string](Get-PromptParleProp $tc 'id' ("call_" + [guid]::NewGuid().ToString('N').Substring(0, 8)))
                [void]$normCalls.Add([ordered]@{
                    id       = $id
                    type     = 'function'
                    function = [ordered]@{ name = $name; arguments = $args }
                })
            }
            $asst.tool_calls = @($normCalls.ToArray())
        }
        [void]$messages.Add($asst)

        if ($toolCalls.Count -eq 0) {
            break
        }

        # Execute tools on this PC
        foreach ($tc in $toolCalls) {
            $fn = Get-PromptParleProp $tc 'function' $null
            $name = [string](Get-PromptParleProp $fn 'name' '')
            $argsJson = [string](Get-PromptParleProp $fn 'arguments' '{}')
            $id = [string](Get-PromptParleProp $tc 'id' '')
            $arg = ConvertTo-PromptParleHandsArgFromToolArgs -ToolName $name -ArgumentsJson $argsJson
            Write-Host ("  tool: {0} ({1})" -f $name, $(if ($arg.Length -gt 60) { $arg.Substring(0, 57) + '...' } else { $arg })) -ForegroundColor Cyan
            $hr = Invoke-PromptParleHandsRequest -Tool $name -Arg $arg -MaxChars 6000
            [void]$allHands.Add($hr)
            $toolText = if ($hr.text) { [string]$hr.text } else { '' }
            if (-not $hr.ok) { $toolText = "ERROR: $toolText" }
            [void]$messages.Add([ordered]@{
                role         = 'tool'
                tool_call_id = $id
                name         = $name
                content      = $toolText
            })
        }
    }

    if ((-not $lastContent -or (Test-PromptParleResponseIsToolTheaterOnly -Text $lastContent) -or (Test-PromptParleForeignToolTheater -Text $lastContent)) -and $allHands.Count -gt 0) {
        $synN = Invoke-PromptParleConversationalSynthesis `
            -Prompt $Prompt `
            -HandsResults @($allHands.ToArray()) `
            -PrepEvidence $Context `
            -System $System `
            -Runtime $Runtime `
            -Provider $Provider `
            -Profile $Profile `
            -CompressionLevel $CompressionLevel `
            -Model $Model
        if ($synN.hands) { $allHands = New-Object System.Collections.Generic.List[object]; foreach ($h in @($synN.hands)) { [void]$allHands.Add($h) } }
        if ($synN.text) { $lastContent = [string]$synN.text }
    }

    # Strip any accidental tool theater from final text
    if ((Test-PromptParleForeignToolTheater -Text $lastContent) -or ($lastContent -match '(?i)\[HANDS\]\s*client results|hands#\d')) {
        $lastContent = Remove-PromptParleHandsBlocks -Text $lastContent
        if (-not $lastContent -or $lastContent.Length -lt 24) {
            if ($allHands.Count -gt 0) {
                $lastContent = Format-PromptParleUserFacingEvidence -Results @($allHands.ToArray()) -Prompt $Prompt -MaxChars 4500
            }
        }
    }

    $evidenceContext = $Context
    if ($allHands.Count -gt 0) {
        try {
            $hp = Format-PromptParleHandsPack -Results @($allHands.ToArray()) -MaxChars 12000
            if ($evidenceContext) { $evidenceContext = $evidenceContext + "`n`n" + $hp }
            else { $evidenceContext = $hp }
        } catch { }
    }

    $agentMeta = [ordered]@{
        agent_rounds         = $roundsUsed
        hands_count          = $allHands.Count
        hands_tools          = @($allHands | ForEach-Object { $_.tool } | Select-Object -Unique)
        tokens_sum_original  = $sumIn
        tokens_sum_optimized = $sumIn
        tokens_sum_output    = $sumOut
        token_first          = $false
        pass_through         = $true
        architecture         = '0.22-native-agent'
        capture_dir          = (Get-PromptParleCaptureDir)
        capture_files        = @($capturePaths)
        turn_id              = $turnId
    }

    # Dial is still the session aggressiveness knob (local prep budgets, round depth).
    # Native agent is pass-through for the *portal optimize* step — do not hardcode dial 1
    # or the chat UI reports "dial 1/5" while the sidebar is set to 3.
    $dialReport = 3
    try {
        $dialReport = [int]$CompressionLevel
        if ($dialReport -lt 1) { $dialReport = 1 }
        if ($dialReport -gt 5) { $dialReport = 5 }
    } catch { $dialReport = 3 }

    $metaOut = [ordered]@{
        original_tokens         = $sumIn
        optimized_tokens        = $sumIn
        token_reduction_percent = 0
        tokens_saved            = 0
        expanded                = $false
        provider                = [string]$Provider
        model                   = [string]$modelOut
        optimization_profile    = 'agent-pass-through'
        compression_level       = $dialReport
        strategy                = 'native-agent-0.22'
        secrets_masked          = $false
        notes                   = @(
            'pass-through'
            'portal-optimize-skipped'
            ('local-prep-dial:' + $dialReport)
            ('rounds:' + $roundsUsed)
            ('tools:' + $allHands.Count)
        )
        signals                 = @{}
        image_count             = 0
    }

    return [pscustomobject]@{
        response         = $lastContent
        metadata         = (ConvertTo-PromptParleCustomObject $metaOut)
        agent            = (ConvertTo-PromptParleCustomObject $agentMeta)
        evidence_context = $evidenceContext
        optimized_prompt = $null
    }
}

function Invoke-PromptParleLegacyTextHandsTurn {
    <# Internal fallback when /api/v1/agent is unavailable. #>
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
        # Soft wall-clock budget for the whole turn. When the next round would
        # exceed it, do ONE final synthesis call and return the best answer so
        # far — never loop until the client aborts. 0 = derive from rounds.
        [int]$DeadlineSeconds = 0,
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

    $handsCatalog = Get-PromptParleHandsCatalogBrief
    $baseRuntime = if ($Runtime) { $Runtime.Trim() } else { '' }
    $runtime = ($baseRuntime + ' AGENT legacy text-hands: use hands fence (tool: arg) when you need client evidence.').Trim()

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

    # Soft deadline: keep the total turn under a wall-clock budget so the client
    # never has to hard-abort (which would discard partial work + uncaptured
    # tokens). One provider call can take ~180s; leave room for a final synthesis.
    if ($DeadlineSeconds -le 0) {
        $DeadlineSeconds = [Math]::Min(540, 150 * [Math]::Max(1, $MaxRounds))
    }
    $deadlineHit = $false
    $turnStopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    for ($round = 1; $round -le $MaxRounds; $round++) {
        $roundsUsed = $round
        # Before starting a fresh round (past the first), check the budget. If we
        # are close, stop looping and force a final answer-now synthesis instead.
        if ($round -gt 1 -and $turnStopwatch.Elapsed.TotalSeconds -ge $DeadlineSeconds) {
            Write-Host ("  agent: soft deadline {0}s reached at round {1} — final synthesis, returning best-so-far" -f $DeadlineSeconds, $round) -ForegroundColor Yellow
            $deadlineHit = $true
            break
        }
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

    # Soft-deadline break: one final answer-now synthesis using the evidence we
    # already gathered, so the user gets a real answer (not a silent client abort).
    if ($deadlineHit -and (Test-PromptParleResponseNeedsHands -Text ([string]$lastResp))) {
        Write-Host '  agent: deadline final synthesis (answer now from gathered evidence)' -ForegroundColor Yellow
        $packD = if ($allHands.Count -gt 0) { Format-PromptParleHandsPack -Results @($allHands.ToArray()) -MaxChars 9000 } else { '' }
        $ctxD = @($handsCatalog, $evidenceSpine, $packD | Where-Object { $_ }) -join "`n`n"
        $paramsD = @{
            Prompt           = ($Prompt.Trim() + "`n`n[CLIENT DIRECTIVE — time budget reached] Answer NOW from the evidence already gathered. No more tool requests. If a document was asked for, emit it. Be complete but do not stall.")
            Context          = $ctxD
            System           = $System
            Runtime          = ($runtime + ' DEADLINE: final answer, no hands.')
            Provider         = $Provider
            Profile          = $Profile
            CompressionLevel = $CompressionLevel
            Quiet            = $true
            Raw              = $true
        }
        if ($Model) { $paramsD.Model = $Model }
        try {
            $resultD = Invoke-PromptParle @paramsD
            $lastResult = $resultD
            $metaD = Get-PromptParleProp $resultD 'metadata'
            if ($metaD) {
                try { $sumOrig += [int](Get-PromptParleProp $metaD 'original_tokens' 0) } catch { }
                try { $sumOpt += [int](Get-PromptParleProp $metaD 'optimized_tokens' 0) } catch { }
            }
            $rd = [string](Get-PromptParleProp $resultD 'response' (Get-PromptParleProp $resultD 'Response' ''))
            if ($rd) { $lastResp = $rd }
        } catch {
            Write-Host ("  agent: deadline synthesis failed ({0}) — returning best-so-far" -f $_.Exception.Message) -ForegroundColor DarkYellow
        }
    }

    # Never show raw hands fences / foreign toolcall / internal [HANDS] packs to the user
    $rawFinal = [string]$lastResp
    $hadToolMarkup = (Test-PromptParleResponseNeedsHands -Text $rawFinal) -or (Test-PromptParleForeignToolTheater -Text $rawFinal) -or (Test-PromptParleResponseIsToolTheaterOnly -Text $rawFinal)
    $looksLikeHandsDump = [bool]($rawFinal -match '(?i)\[HANDS\]\s*client results|Client ran tools|hands#\d|ask a follow-up for a prose summary')

    # Emergency: foreign toolcall never entered the hands loop (parse miss) → run tools now
    if ($hadToolMarkup -and $allHands.Count -eq 0) {
        $emergency = @(ConvertFrom-PromptParleForeignToolCalls -Text $rawFinal)
        if ($emergency.Count -eq 0) { $emergency = @(Parse-PromptParleHandsBlocks -Text $rawFinal) }
        # Still unmapped → web_search the user question (never dead-end on tool theater)
        if ($emergency.Count -eq 0) {
            $fallbackQ = ''
            if ($rawFinal -match '(?is)(?:query|q|search)\s*(?:=|:|is)\s*["'']?([^"''<\r\n]{3,200})') {
                $fallbackQ = $Matches[1].Trim().TrimEnd('.,;:)')
            }
            if (-not $fallbackQ -and $Prompt) {
                try { $fallbackQ = Get-PromptParleWebSearchQuery -Prompt $Prompt } catch { $fallbackQ = '' }
            }
            if (-not $fallbackQ) { $fallbackQ = [string]$Prompt }
            $shouldSearch = [bool]$fallbackQ -and (
                (Test-PromptParleForeignToolTheater -Text $rawFinal) -or
                (Test-PromptParleHasBareHandsRequest -Text $rawFinal) -or
                (Test-PromptParleWebSearchIntent -Prompt $Prompt) -or
                ($rawFinal -match '(?i)google_?search|web_?search|tool_?call|function_?call|tool_code')
            )
            if ($shouldSearch -and $fallbackQ) {
                $emergency = @([pscustomobject]@{ tool = 'web_search'; arg = $fallbackQ; index = 0; foreign = $true; emergency_fallback = $true })
                Write-Host ("  hands(emergency-fallback): web_search ← {0}" -f $(if ($fallbackQ.Length -gt 60) { $fallbackQ.Substring(0, 57) + '...' } else { $fallbackQ })) -ForegroundColor Magenta
            }
        }
        foreach ($req in $emergency) {
            if ($allHands.Count -ge 4) { break }
            if (-not $req.tool) { continue }
            $hr = Invoke-PromptParleHandsRequest -Tool $req.tool -Arg $req.arg -MaxChars 4500
            [void]$allHands.Add($hr)
            Write-Host ("  hands(emergency): {0} ({1})" -f $hr.tool, $(if ($hr.ok) { 'ok' } else { 'FAIL' })) -ForegroundColor Magenta
        }
    }

    # 0.26.18: if we have tool evidence but no real prose (or dumped hands pack), force conversational answer
    $needsConvo = $false
    if ($allHands.Count -gt 0) {
        $strippedProbe = Remove-PromptParleHandsBlocks -Text $rawFinal
        if ($hadToolMarkup -or $looksLikeHandsDump -or (Test-PromptParleResponseIsToolTheaterOnly -Text $rawFinal) `
            -or (-not $strippedProbe) -or $strippedProbe.Length -lt 40) {
            $needsConvo = $true
        }
    } elseif ($hadToolMarkup -and (Test-PromptParleResponseIsToolTheaterOnly -Text $rawFinal)) {
        $needsConvo = $true
    }

    if ($needsConvo) {
        $synOut = Invoke-PromptParleConversationalSynthesis `
            -Prompt $Prompt `
            -HandsResults @($allHands.ToArray()) `
            -PrepEvidence $prepEvidence `
            -System $System `
            -Runtime $runtime `
            -Provider $Provider `
            -Profile $Profile `
            -CompressionLevel $CompressionLevel `
            -Model $Model
        if ($synOut.hands -and @($synOut.hands).Count -gt $allHands.Count) {
            $allHands.Clear()
            foreach ($h in @($synOut.hands)) { [void]$allHands.Add($h) }
        }
        if ($synOut.text) {
            $lastResp = [string]$synOut.text
            $rawFinal = $lastResp
            $roundsUsed++
        }
        if ($synOut.result) {
            $lastResult = $synOut.result
            $metaEm = Get-PromptParleProp $synOut.result 'metadata'
            if ($null -eq $metaEm) { $metaEm = Get-PromptParleProp $synOut.result 'Metadata' }
            if ($metaEm) {
                try { $sumOrig += [int](Get-PromptParleProp $metaEm 'original_tokens' 0) } catch { }
                try { $sumOpt += [int](Get-PromptParleProp $metaEm 'optimized_tokens' 0) } catch { }
            }
        }
        $hadToolMarkup = (Test-PromptParleResponseNeedsHands -Text $rawFinal) -or (Test-PromptParleForeignToolTheater -Text $rawFinal) -or (Test-PromptParleResponseIsToolTheaterOnly -Text $rawFinal)
        $looksLikeHandsDump = [bool]($rawFinal -match '(?i)\[HANDS\]\s*client results|Client ran tools|hands#\d')
    }

    if ($hadToolMarkup -or $looksLikeHandsDump) {
        $stripped = Remove-PromptParleHandsBlocks -Text $rawFinal
        if ($looksLikeHandsDump -or (Test-PromptParleResponseIsToolTheaterOnly -Text $rawFinal) -or (-not $stripped) -or $stripped.Length -lt 24) {
            if ($allHands.Count -gt 0) {
                # Last resort: local conversational brief — never dump internal hands packs
                $lastResp = Format-PromptParleUserFacingEvidence -Results @($allHands.ToArray()) -Prompt $Prompt -MaxChars 4500
            } else {
                $lastResp = "I couldn't finish that lookup cleanly. Try once more, or name a site (e.g. fandango.com)."
            }
        } else {
            $lastResp = $stripped
        }
    }

    # Final safety: never leave internal hands protocol in the chat bubble
    if ($lastResp -match '(?i)\[HANDS\]\s*client results|Client ran tools|hands#\d|ask a follow-up for a prose summary') {
        if ($allHands.Count -gt 0) {
            $lastResp = Format-PromptParleUserFacingEvidence -Results @($allHands.ToArray()) -Prompt $Prompt -MaxChars 4500
        } else {
            $lastResp = Remove-PromptParleHandsBlocks -Text $lastResp
            if (-not $lastResp -or $lastResp.Length -lt 12) {
                $lastResp = "I hit a snag turning tool results into a chat answer. Please try that question again."
            }
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
            $lastResult | Add-Member -NotePropertyName agent -NotePropertyValue (ConvertTo-PromptParleCustomObject $agentMeta) -Force
            $lastResult | Add-Member -NotePropertyName evidence_context -NotePropertyValue $evidenceContext -Force
            return $lastResult
        } catch {
            return [pscustomobject]@{
                response          = $lastResp
                metadata          = $metaOut
                agent             = (ConvertTo-PromptParleCustomObject $agentMeta)
                evidence_context  = $evidenceContext
                optimized_prompt  = Get-PromptParleProp $lastResult 'optimized_prompt' $null
            }
        }
    }
    return [pscustomobject]@{
        response         = $lastResp
        metadata         = $metaOut
        agent            = (ConvertTo-PromptParleCustomObject $agentMeta)
        evidence_context = $evidenceContext
    }
}

function Invoke-PromptParleAgentTurn {
    <#
    .SYNOPSIS
      0.22 entry: multi-AI native tool agent (pass-through). Falls back to text-hands if portal agent API missing.
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
        [switch]$OptimizeOnly,
        [switch]$LegacyTextHands,
        # Accepted from local-ui chat splat (tools-on path). Forwarded when falling through to Invoke-PromptParle.
        [string]$SessionTitle = '',
        [string]$ClientSessionId = '',
        # UI may also splat these; accept so @params never throws "parameter cannot be found"
        [switch]$Quiet,
        [switch]$Raw
    )
    if ($OptimizeOnly) {
        $p = @{
            Prompt = $Prompt; Context = $Context; System = $System; Runtime = $Runtime
            Provider = $Provider; Profile = $Profile; CompressionLevel = $CompressionLevel
            Quiet = $true; Raw = $true; OptimizeOnly = $true
        }
        if ($Model) { $p.Model = $Model }
        if ($Images) { $p.Images = $Images }
        if ($SessionTitle) { $p.SessionTitle = $SessionTitle }
        if ($ClientSessionId) { $p.ClientSessionId = $ClientSessionId }
        return Invoke-PromptParle @p
    }
    if ($LegacyTextHands) {
        $lp = @{
            Prompt = $Prompt; Context = $Context; System = $System; Runtime = $Runtime
            Provider = $Provider; Profile = $Profile; CompressionLevel = $CompressionLevel
            MaxRounds = $MaxRounds
        }
        if ($Model) { $lp.Model = $Model }
        if ($Images) { $lp.Images = $Images }
        return Invoke-PromptParleLegacyTextHandsTurn @lp
    }
    $np = @{
        Prompt = $Prompt; Context = $Context; System = $System; Runtime = $Runtime
        Provider = $Provider; Profile = $Profile; CompressionLevel = $CompressionLevel
        MaxRounds = $(if ($MaxRounds -gt 0) { $MaxRounds } else { 8 })
    }
    if ($Model) { $np.Model = $Model }
    if ($Images) { $np.Images = $Images }
    return Invoke-PromptParleNativeAgentTurn @np
}

function Get-PromptParleSshPathCandidatesFromPrompt {
    <#
    .SYNOPSIS
      Extract file/path tokens from user text for SSH auto-fetch against ssh_cwd.
    #>
    [CmdletBinding()]
    param([string]$Prompt = '')
    $out = New-Object System.Collections.ArrayList
    $seen = @{}
    $add = {
        param([string]$Raw)
        if (-not $Raw) { return }
        $t = ([string]$Raw).Trim().Trim('"').Trim("'").Trim([char]0x60)
        $t = $t.TrimEnd([char[]]@('.', ',', ')', ';', ':', ']'))
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
        [void]$out.Add([string]$t)
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
    <#
    .SYNOPSIS
      True when live product-bind pack is needed (SSH status under product_root).
      Not "almost always" — only implement/mutate or structural product/workspace work.
      Session evidence_mode never reaches this (prep early-returns first).
    #>
    param(
        [string]$Prompt = '',
        [string]$TurnKind = 'chat',
        [object]$Obligation = $null
    )
    $p = if ($null -eq $Prompt) { '' } else { $Prompt.Trim() }
    if (-not $p) { return $false }

    $kind = if ($TurnKind) { $TurnKind } else { 'chat' }
    if ($kind -eq 'implement') { return $true }

    $oblMode = ''
    try { $oblMode = [string](Get-PromptParleProp $Obligation 'mode' '') } catch { $oblMode = '' }
    if ($oblMode -eq 'mutate') { return $true }

    # Structural product / workspace work (paths, tools, land-code) — not small-talk or pure research
    if ($p -match '(?i)\b(ssh_|```apply|```run|product_?root|source_?root|live_?path)\b') { return $true }
    if ($p -match '(?i)\b(implement|apply (the )?|migrate|deploy|refactor|patch|land (it|the)|wire (up|the))\b') { return $true }
    if ($p -match '(?i)\b(where is|show (me )?(the )?(code|file|tree)|list (the )?(dir|directory|folder)|on (the )?(server|remote|disk))\b') { return $true }
    if ($p -match '(?i)(?:^|[\s`"''(])(?:/home/|/var/www/|/etc/|[A-Za-z]:\\|\./)[\w./\\-]+') { return $true }
    if ($p -match '(?i)\b[\w.-]+\.(?:psm1|psd1|php|ts|tsx|js|sql|prisma)\b' -and $p -match '(?i)\b(read|open|show|edit|fix|where|status|build)\b') {
        return $true
    }
    return $false
}

function Resolve-PromptParleEvidenceMode {
    <#
    .SYNOPSIS
      Product turn evidence mode — single decision for prep depth + chat dispatch.
      session | live | refresh

      session  — answer from [MEM]/[KNOW]/bind only; no live fleet; no hands agent
      live     — may pull SSH/observe/fleet; hands agent allowed when tools on
      refresh  — user forced live re-pull (same pipeline as live)

      Doctrine: if the client already holds the fact in session evidence, do not re-fetch.
      Not keyword theater: structural signals (session store, history, obligation, paths).
    #>
    [CmdletBinding()]
    param(
        [string]$Prompt = '',
        [object[]]$History = @(),
        [string]$MemText = '',
        [object[]]$PriorityKnowledge = @(),
        [string]$TurnKind = 'chat',
        [object]$Obligation = $null
    )
    $p = if ($null -eq $Prompt) { '' } else { $Prompt.Trim() }
    $kind = if ($TurnKind) { $TurnKind } else { 'chat' }

    # Session evidence present? (computed early — catch-up + session mode both need it)
    $memLen = if ($MemText) { $MemText.Length } else { 0 }
    $knowN = 0
    if ($PriorityKnowledge) { $knowN = @($PriorityKnowledge).Count }
    $recentAsstLen = 0
    if ($History -and $History.Count -gt 0) {
        for ($i = $History.Count - 1; $i -ge 0; $i--) {
            $hr = [string](Get-PromptParleProp $History[$i] 'role' 'user')
            $ht = [string](Get-PromptParleProp $History[$i] 'text' (Get-PromptParleProp $History[$i] 'content' ''))
            if (-not $ht) { continue }
            if ($hr -match '(?i)assistant|bot|ai') {
                if ($ht.Length -ge 200 -and $ht -notmatch '(?i)^\[prior ') {
                    $recentAsstLen = $ht.Length
                    break
                }
            }
        }
    }
    $hasSession = ($memLen -ge 400) -or ($knowN -gt 0) -or ($recentAsstLen -ge 280)

    # Explicit live re-pull (user agency)
    if ($p -match '(?i)\b(refresh|re-?check|re-?fetch|re-?scan|pull again|look again)\b') {
        return [pscustomobject]@{ mode = 'refresh'; hands_allowed = $true; reason = 'user-refresh' }
    }
    if ($p -match '(?i)\b(from (the )?(server|ssh|remote|disk)|live (status|state|git|on (server|remote))|current on (disk|server|remote))\b') {
        return [pscustomobject]@{ mode = 'refresh'; hands_allowed = $true; reason = 'user-live-scope' }
    }

    # Catch-up: chat continuity vs project state (never invent .parle/sessions)
    $catchUp = $false
    $projectCatch = $false
    try { $catchUp = [bool](Test-PromptParleSessionCatchUpIntent -Prompt $p) } catch { $catchUp = $false }
    try { $projectCatch = [bool](Test-PromptParleProjectCatchUpIntent -Prompt $p) } catch { $projectCatch = $false }
    if ($catchUp -and $hasSession -and -not $projectCatch) {
        return [pscustomobject]@{ mode = 'session'; hands_allowed = $false; reason = 'catchup-session' }
    }
    if ($catchUp -and $projectCatch) {
        # Project path / repo state — live for git/HANDOFF; not a sessions-dir hunt
        return [pscustomobject]@{ mode = 'live'; hands_allowed = $true; reason = 'catchup-project' }
    }
    if ($catchUp -and -not $hasSession) {
        # No MEM in this chat — still answer from [SELF] honesty; optional light live only if path given
        if ($p -match '(?i)(?:^|[\s`"''(])(?:/home/|/var/www/|/etc/|[A-Za-z]:\\|\./)[\w./\\-]+') {
            return [pscustomobject]@{ mode = 'live'; hands_allowed = $true; reason = 'catchup-project-no-mem' }
        }
        return [pscustomobject]@{ mode = 'session'; hands_allowed = $false; reason = 'catchup-self-only' }
    }

    # Work that cannot be satisfied from memory alone
    if ($kind -eq 'implement') {
        return [pscustomobject]@{ mode = 'live'; hands_allowed = $true; reason = 'implement' }
    }
    $oblMode = ''
    try { $oblMode = [string](Get-PromptParleProp $Obligation 'mode' '') } catch { $oblMode = '' }
    if ($oblMode -eq 'mutate') {
        return [pscustomobject]@{ mode = 'live'; hands_allowed = $true; reason = 'mutate' }
    }
    if ($oblMode -eq 'observe' -or $oblMode -eq 'deliver') {
        # Observe/deliver may need fresh web/files — live unless pure meta on existing ledger
        if (-not (Test-PromptParleResearchMetaIntent -Prompt $p)) {
            return [pscustomobject]@{ mode = 'live'; hands_allowed = $true; reason = ('obligation:' + $oblMode) }
        }
    }

    # Structural need for new external evidence (paths, tools, web) — not product-name moles
    $needsLive = $false
    if ($p -match '(?i)\b(ssh_|web_search|web_page|```hands|```apply|```run)\b') { $needsLive = $true }
    if ($p -match '(?i)\b(list (the )?(dir|directory|folder|tree)|read (the )?file|open (the )?file|cat |show (me )?(the )?code|on (the )?remote)\b') { $needsLive = $true }
    # Bare path: live only when user wants file/tree/code — not when they named a project as chat topic alone
    if ($p -match '(?i)(?:^|[\s`"''(])(?:/home/|/var/www/|/etc/|[A-Za-z]:\\|\./|\.\./)[\w./\\-]+') {
        if ($p -match '(?i)\b(read|open|show|list|cat|edit|fix|where|contents|tree|ls |status|git |file|folder|dir)\b') {
            $needsLive = $true
        }
    }
    if ($p -match '(?i)\b[\w.-]+\.(?:md|php|psm1|psd1|ts|tsx|js|json|yml|yaml|sql)\b' -and $p -match '(?i)\b(read|open|show|edit|fix|where is|contents of)\b') {
        $needsLive = $true
    }
    try {
        if (Test-PromptParleWebSearchIntent -Prompt $p) { $needsLive = $true }
    } catch { }
    if ($needsLive) {
        return [pscustomobject]@{ mode = 'live'; hands_allowed = $true; reason = 'needs-live-evidence' }
    }

    if (-not $hasSession) {
        return [pscustomobject]@{ mode = 'live'; hands_allowed = $true; reason = 'no-session-evidence' }
    }

    # Session can answer — hands off
    $why = 'session-evidence'
    if ($knowN -gt 0) { $why = 'know' }
    elseif ($memLen -ge 400) { $why = 'mem' }
    elseif ($recentAsstLen -ge 280) { $why = 'recent-assistant' }
    return [pscustomobject]@{ mode = 'session'; hands_allowed = $false; reason = $why }
}

function Get-PromptParleProtectedSessionContext {
    <#
    .SYNOPSIS
      Keep only bind + session truth tags for evidence_mode=session (no bulk re-fleet residue).
    #>
    param([string]$Context = '')
    if (-not $Context) { return '' }
    $blocks = New-Object System.Collections.ArrayList
    $rx = '(?ms)(\[(?:SELF|CONN|PROJECT|KNOW|MEM)\][^\n]*(?:\n(?!\[)[^\n]*)*)'
    foreach ($m in [regex]::Matches($Context, $rx)) {
        $b = $m.Groups[1].Value.Trim()
        if ($b) { [void]$blocks.Add($b) }
    }
    if ($blocks.Count -eq 0) { return $Context.Trim() }
    return (($blocks.ToArray()) -join "`n`n")
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
    $sshRawTotal = 0
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
        # Counterfactual: full remote file chars (the model cannot ssh; this ran on PC).
        $sshRawTotal += $content.Length

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
        # avoided-ingest: full remote file chars vs the packed evidence emitted
        chars_without = $sshRawTotal
        chars_with    = $textOut.Length
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
    <# Absolute or project-looking paths for observe list/read (Windows + Unix). #>
    param([string]$Text = '')
    $out = New-Object System.Collections.Generic.List[string]
    $seen = @{}
    if (-not $Text) { return @() }
    $add = {
        param([string]$p)
        if (-not $p) { return }
        $p = $p.Trim().TrimEnd('.,);:''"')
        if (-not $p) { return }
        $k = $p.ToLowerInvariant()
        if (-not $seen.ContainsKey($k)) { $seen[$k] = $true; [void]$out.Add($p) }
    }
    # Windows drive paths: C:\  C:\Users\me  C:/Windows
    foreach ($m in [regex]::Matches($Text, '(?i)(?<![A-Za-z0-9])([A-Za-z]:\\[^\s"''<>|?]{0,220}|[A-Za-z]:/[^\s"''<>|?]{0,220}|[A-Za-z]:\\|[A-Za-z]:/)')) {
        & $add $m.Groups[1].Value
    }
    # Bare drive mention: "of C:" / "drive C"
    foreach ($m in [regex]::Matches($Text, '(?i)\b(?:of|on|drive|path)\s+([A-Za-z]):(?:\b|\\|/|\s|$)')) {
        & $add ($m.Groups[1].Value.ToUpperInvariant() + ':\')
    }
    # Unix absolute
    foreach ($m in [regex]::Matches($Text, '(?i)(?<![A-Za-z0-9_])((?:/home|/var|/opt|/usr|/tmp|/etc|~)[A-Za-z0-9_./+\-]{0,220})')) {
        & $add $m.Groups[1].Value
    }
    foreach ($m in [regex]::Matches($Text, '(?i)(?<![A-Za-z0-9_])((?:\./|\.\./)[A-Za-z0-9_./+\-]{1,200})')) {
        & $add $m.Groups[1].Value
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

    # Local vs SSH list routing (0.22.4) — never send "on this PC / C:\" to product SSH root
    $wantLocalList = $false
    $wantSshList = $false
    $thisPc = [bool]($p -match '(?i)\b(on this (pc|computer|machine|box)|this (pc|computer|machine)|local(ly)?\b|my (pc|computer|machine)|windows (pc|machine|drive))\b')
    $remoteLang = [bool]($p -match '(?i)\b(remote|over ssh|via ssh|on the (server|host|box|node|unit|appliance)|product (root|host)|ssh (host|target))\b')
    $winPaths = @($paths | Where-Object { $_ -match '^[A-Za-z]:' })
    $unixPaths = @($paths | Where-Object { $_ -match '^(?:/|~)' })
    $hasSsh = $false
    try {
        $st0 = Get-PromptParleSessionState
        $hasSsh = [bool][string](Get-PromptParleProp $st0 'ssh_target' '')
    } catch { }
    if ($wantList) {
        if ($thisPc -or $winPaths.Count -gt 0) {
            $wantLocalList = $true
        } elseif ($remoteLang -or ($hasSsh -and $unixPaths.Count -gt 0 -and -not $thisPc)) {
            $wantSshList = $true
        } else {
            # Default desktop: local listing (not a foreign product root)
            $wantLocalList = $true
        }
    }
    # Keep want_list as any list for mode=observe
    if ($wantLocalList -or $wantSshList) { $wantList = $true }

    # Explicit document deliver only — "review X.com" / "tell me about" are chat answers, not downloads.
    $wantDeliver = [bool]($p -match '(?i)\b(one[\s-]?page|one[\s-]?pager|executive summary|write me (a |an )?(article|summary|brief|report|pdf|docx|document)|deliverable|download(able)?|as (a )?(pdf|docx|markdown|md)\b)')
    # Artifact ask: "create/build/make/generate/write me a <form|app|page|script|
    # component|website|tool|file|html|template>" → the user wants a usable file,
    # not code pasted in chat. Default to a downloadable deliverable (0.30.1).
    if (-not $wantDeliver -and
        $p -match '(?i)\b(create|build|make|generate|write|scaffold|give me)\b' -and
        $p -match '(?i)\b(web\s?form|form|web\s?page|webpage|page|app|application|script|component|website|site|landing\s?page|tool|utility|file|html|template|dashboard|widget|snippet|program|calculator|spreadsheet)\b') {
        $wantDeliver = $true
    }
    # Sticky document continues ONLY with clear regenerate language (not bare "now" / incidental web).
    if ($open.kind -eq 'document' -and -not $wantDeliver) {
        if ($p -match '(?i)\b(from the website|from (their|the) site|generate (the )?(doc|document|summary|report|one[\s-]?pager)|do (the )?(doc|document|summary)|again (as |with )?(a )?(pdf|docx|md|file)|updated (summary|report|one[\s-]?pager|document)|strictly from)\b') {
            $wantDeliver = $true
        }
    }
    # Topic pivot: new research/Q&A without deliver language clears sticky document so FAIL-CLOSED does not fire.
    if ($open.kind -eq 'document' -and -not $wantDeliver) {
        $pivotAway = [bool](
            $wantWeb `
            -or $p -match '(?i)\b(tell me|what is|who is|about|review|research|did you|you researched|insider|overview|capabilit)\b'
        )
        if ($pivotAway) {
            try { Set-PromptParleOpenObligation -Clear } catch { }
            $open = Get-PromptParleOpenObligation
        }
    }

    $wantMutate = $false
    try {
        $tk = Get-PromptParleTurnKind -Prompt $p -History $History
        if ($tk -eq 'implement') { $wantMutate = $true }
    } catch { }
    if ($p -match '(?i)\b(implement|apply path|ship it|get it done|fix the|add the|wire up)\b') { $wantMutate = $true }

    # Mutate needs somewhere to write. With NO bound workspace/source, an
    # artifact ask ("create me a web form") can't mutate a project — it should
    # produce a downloadable file instead. Gate mutate on a real bind so these
    # turns become deliver, not code-pasted-in-chat. (0.30.1)
    $hasBoundSource = $false
    try { $wsB = Get-PromptParleWorkspace; $hasBoundSource = [bool]($wsB -and $wsB.exists) } catch { $hasBoundSource = $false }
    if ($wantMutate -and -not $hasBoundSource -and $wantDeliver) {
        $wantMutate = $false
    }

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
    if ($wantLocalList) { [void]$observe.Add('local_list') }
    if ($wantSshList) { [void]$observe.Add('ssh_list') }
    if ($wantRead) { [void]$observe.Add('ssh_read') }

    return [pscustomobject]@{
        mode       = $mode
        observe    = @($observe.ToArray())
        want_web   = $wantWeb
        want_list  = $wantList
        want_local_list = $wantLocalList
        want_ssh_list   = $wantSshList
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

function Get-PromptParleWebEvidencePath {
    return (Join-Path $script:PromptParleConfigDir 'web-evidence.json')
}

function Add-PromptParleWebEvidence {
    <#
    .SYNOPSIS
      Session ledger of URLs the client actually fetched (authoritative for "did you research?").
    #>
    param(
        [string]$Url = '',
        [string]$Kind = 'web_page'
    )
    $u = if ($null -eq $Url) { '' } else { $Url.Trim() }
    if (-not $u) { return }
    try {
        $path = Get-PromptParleWebEvidencePath
        $dir = Split-Path -Parent $path
        if (-not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        $items = New-Object System.Collections.ArrayList
        if (Test-Path -LiteralPath $path) {
            try {
                $raw = Get-Content -LiteralPath $path -Raw -ErrorAction Stop
                if ($raw) {
                    $parsed = $raw | ConvertFrom-Json
                    foreach ($it in @($parsed)) {
                        if (-not $it) { continue }
                        $iu = [string](Get-PromptParleProp $it 'url' '')
                        if ($iu) { [void]$items.Add(@{ url = $iu; kind = [string](Get-PromptParleProp $it 'kind' 'web_page'); at = [string](Get-PromptParleProp $it 'at' '') }) }
                    }
                }
            } catch { }
        }
        # Dedupe by host+path (case-insensitive), newest first
        $key = $u.ToLowerInvariant()
        $next = New-Object System.Collections.ArrayList
        [void]$next.Add(@{ url = $u; kind = $Kind; at = (Get-Date).ToUniversalTime().ToString('o') })
        foreach ($it in $items) {
            $iu = [string]$it.url
            if (-not $iu) { continue }
            if ($iu.ToLowerInvariant() -eq $key) { continue }
            [void]$next.Add($it)
            if ($next.Count -ge 20) { break }
        }
        $json = ConvertTo-Json -InputObject @($next.ToArray()) -Depth 4 -Compress
        [System.IO.File]::WriteAllText($path, $json, [System.Text.UTF8Encoding]::new($false))
    } catch { }
}

function Get-PromptParleWebEvidenceBrief {
    <# Compact [SESSION WEB] block for prep — so follow-ups cannot deny completed research. #>
    param([int]$Max = 12)
    try {
        $path = Get-PromptParleWebEvidencePath
        if (-not (Test-Path -LiteralPath $path)) { return '' }
        $raw = Get-Content -LiteralPath $path -Raw -ErrorAction Stop
        if (-not $raw) { return '' }
        $parsed = $raw | ConvertFrom-Json
        $lines = New-Object System.Collections.Generic.List[string]
        $lines.Add('[SESSION WEB] pages this client actually fetched (authoritative — not model memory)')
        $n = 0
        foreach ($it in @($parsed)) {
            if ($n -ge $Max) { break }
            $u = [string](Get-PromptParleProp $it 'url' '')
            if (-not $u) { continue }
            $n++
            $lines.Add(('- {0}' -f $u))
        }
        if ($n -eq 0) { return '' }
        $lines.Add('rule: If the user asks whether you researched/fetched/read a site, answer YES when the domain or URL appears above. Never say "Not yet" / "Share the URL" when it is already on this list.')
        return ($lines -join "`n")
    } catch {
        return ''
    }
}

function Test-PromptParleResearchMetaIntent {
    <# "did you research / you researched the website?" — answer from session ledger, not amnesia. #>
    param([string]$Prompt = '')
    $p = if ($null -eq $Prompt) { '' } else { $Prompt.Trim() }
    if (-not $p) { return $false }
    return [bool]($p -match '(?i)\b(did you (actually )?(research|fetch|read|browse|open|visit|pull|look( at)?)|you researched|researched the (actual )?(website|site|page|url)|did (the )?client (fetch|research)|from the (actual )?website\??)\b')
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
    $ua = 'PromptParle/0.26 (desktop observe; +https://promptparle.com)'
    try {
        $resp = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 7 -Headers @{ 'User-Agent' = $ua } -ErrorAction Stop
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
        try { Add-PromptParleWebEvidence -Url $url -Kind 'web_page' } catch { }
        return [pscustomobject]@{ ok = $true; text = $t; url = $url; notes = @('page-fetch'); bytes = $t.Length }
    } catch {
        return [pscustomobject]@{ ok = $false; text = ''; url = $url; notes = @("page-fail: $_") }
    }
}

function Invoke-PromptParleLocalDirListing {
    <#
    .SYNOPSIS
      0.22.4: list a directory on THIS PC (not SSH). Used for "on this PC" / C:\ / local paths.
    #>
    [CmdletBinding()]
    param(
        [string]$LocalPath = '',
        [int]$MaxChars = 7000
    )
    $target = if ($null -eq $LocalPath) { '' } else { $LocalPath.Trim() }
    # Normalize bare drive "C:" → "C:\"
    if ($target -match '^[A-Za-z]:$') { $target = $target + '\' }
    if ($target -match '^[A-Za-z]:/$') { $target = $target.Substring(0, 2) + '\' }

    if (-not $target) {
        $ws = $null
        try { $ws = Get-PromptParleWorkspace } catch { }
        if ($ws -and $ws.exists -and $ws.path) { $target = [string]$ws.path }
        else {
            try { $target = [string](Get-PromptParleHomePath) } catch { $target = '' }
        }
    }
    if (-not $target) {
        return [pscustomobject]@{
            ok = $false; text = ''; path = ''; notes = @('local-list: no path')
        }
    }

    try {
        if (-not (Test-Path -LiteralPath $target)) {
            return [pscustomobject]@{
                ok = $false; text = "Path not found on this PC: $target"; path = $target
                notes = @('local-list: missing')
            }
        }
        $item = Get-Item -LiteralPath $target -Force -ErrorAction Stop
        if (-not $item.PSIsContainer) {
            return [pscustomobject]@{
                ok = $false; text = "Not a directory: $target"; path = $target
                notes = @('local-list: not-dir')
            }
        }
        $full = $item.FullName
        $list = Get-PromptParleFsList -Path $full -Max 200
        $lines = New-Object System.Collections.Generic.List[string]
        [void]$lines.Add("PATH $full")
        [void]$lines.Add('TYPE directory')
        [void]$lines.Add('HOST This PC (local)')
        foreach ($e in @($list.entries)) {
            if ($e.is_dir) {
                $mark = if ($e.is_git) { ' [git]' } else { '' }
                [void]$lines.Add(("d  {0}/{1}" -f $e.name, $mark))
            } else {
                $sz = if ($null -ne $e.size) { [string]$e.size } else { '' }
                [void]$lines.Add(("f  {0}  {1}" -f $e.name, $sz))
            }
        }
        if (-not $list.entries -or $list.entries.Count -eq 0) { [void]$lines.Add('(empty)') }
        [void]$lines.Add('EXIT 0')
        $text = ($lines -join "`n")
        if ($text.Length -gt $MaxChars) { $text = $text.Substring(0, $MaxChars) + "`n…[list budget]" }
        return [pscustomobject]@{
            ok = $true; text = $text; path = $full; notes = @('local-list')
        }
    } catch {
        return [pscustomobject]@{
            ok = $false; text = "$_"; path = $target; notes = @("local-list-fail: $_")
        }
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

    # --- Local directory listing (this PC) ---
    $doLocalList = $false
    try { $doLocalList = [bool]$Obligation.want_local_list } catch { }
    if (-not $doLocalList) {
        # Back-compat: want_list without ssh flag → local on desktop
        try {
            if ($Obligation.want_list -and -not $Obligation.want_ssh_list) { $doLocalList = $true }
        } catch {
            if ($Obligation.want_list) { $doLocalList = $true }
        }
    }
    if ($doLocalList) {
        $listPaths = New-Object System.Collections.Generic.List[string]
        foreach ($p in @($Obligation.paths)) {
            if ($p -match '\.[A-Za-z0-9]{1,8}$' -and $p -notmatch '[/\\]$' -and $p -notmatch '^[A-Za-z]:\\?$') { continue }
            # Prefer Windows / local-looking paths for local list
            if ($p -match '^[A-Za-z]:' -or $p -match '^(?:/|~|\./)') { [void]$listPaths.Add($p) }
            elseif ($p) { [void]$listPaths.Add($p) }
        }
        if ($listPaths.Count -eq 0) { [void]$listPaths.Add('') }  # workspace or home — NOT product SSH root

        $anyList = $false
        foreach ($lp in @($listPaths | Select-Object -First 2)) {
            $listing = Invoke-PromptParleLocalDirListing -LocalPath $lp -MaxChars $listBudget
            if ($listing.ok -and $listing.text) {
                $blocks.Add("[OBSERVE] kind=local_list client-first (0.22.4)`npath: $($listing.path)`nhost: This PC`nrule: Present this listing as the answer for the LOCAL path the user asked about. NEVER substitute a remote/product path. NEVER reply with homework commands.`n---`n$($listing.text)")
                [void]$fulfilled.Add("local_list:$($listing.path)")
                [void]$notes.Add('observe-local-list')
                [void]$tools.Add('local_list')
                $anyList = $true
            } else {
                foreach ($n in @($listing.notes)) { if ($n) { [void]$notes.Add([string]$n) } }
                [void]$failed.Add("local_list:$($listing.path)")
            }
        }
        if (-not $anyList) {
            $blocks.Add("[OBSERVE] kind=local_list_failed client-first (0.22.4)`nrule: Client could not list the local path on this PC. State the hard blocker (path missing / access). Do not invent a directory listing or show a remote product tree.")
            [void]$notes.Add('observe-local-list-empty')
        }
    }

    # --- SSH directory listing (remote only) ---
    $doSshList = $false
    try { $doSshList = [bool]$Obligation.want_ssh_list } catch { }
    if ($doSshList) {
        $listPaths = New-Object System.Collections.Generic.List[string]
        foreach ($p in @($Obligation.paths)) {
            # Prefer directories over file-looking paths for list
            if ($p -match '\.[A-Za-z0-9]{1,8}$' -and $p -notmatch '/$') { continue }
            if ($p -match '^[A-Za-z]:') { continue }  # Windows paths are local
            [void]$listPaths.Add($p)
        }
        if ($listPaths.Count -eq 0) { [void]$listPaths.Add('') }  # ssh_cwd / product root when remote intended

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
      Conservative: flag high-severity invention keywords / phrases missing from evidence.
      0.22.3: near-quote token coverage + known acronym expansions are NOT flagged.
    #>
    param(
        [string]$Response = '',
        [string]$Evidence = '',
        [int]$MaxFlags = 8
    )
    $flags = New-Object System.Collections.Generic.List[string]
    if (-not $Response -or -not $Evidence) { return @() }
    $ev = $Evidence.ToLowerInvariant()
    $evNorm = [regex]::Replace($ev, '[^a-z0-9\s]+', ' ')
    $evNorm = [regex]::Replace($evNorm, '\s+', ' ')
    $stop = @{
        'the'=$true;'and'=$true;'for'=$true;'with'=$true;'that'=$true;'this'=$true;'from'=$true
        'your'=$true;'their'=$true;'have'=$true;'has'=$true;'are'=$true;'was'=$true;'were'=$true
        'will'=$true;'can'=$true;'into'=$true;'onto'=$true;'about'=$true;'using'=$true;'used'=$true
        'also'=$true;'than'=$true;'then'=$true;'when'=$true;'which'=$true;'while'=$true;'over'=$true
        'such'=$true;'more'=$true;'most'=$true;'other'=$true;'only'=$true;'just'=$true;'been'=$true
        'based'=$true;'provides'=$true;'provide'=$true;'platform'=$true;'solution'=$true;'security'=$true
        'network'=$true;'networks'=$true;'system'=$true;'systems'=$true;'real'=$true;'time'=$true;'designed'=$true
        'these'=$true;'those'=$true;'them'=$true;'they'=$true;'what'=$true;'make'=$true;'makes'=$true
        'delivering'=$true;'delivers'=$true;'together'=$true;'across'=$true;'before'=$true;'after'=$true
        'emphasizes'=$true;'emphasize'=$true;'capabilities'=$true;'capability'=$true
    }
    # Known expansions of terms present as acronyms/tokens in evidence (not inventions)
    $knownExpansions = @(
        @{ phrase = 'active moving target defense'; need = 'amtd' },
        @{ phrase = 'moving target defense'; need = 'amtd' },
        @{ phrase = 'automated moving target defense'; need = 'amtd' }
    )
    foreach ($kx in $knownExpansions) {
        if ($ev.Contains($kx.need) -and $Response.ToLowerInvariant().Contains($kx.phrase)) {
            # mark expansion as "present" so substring matcher won't flag pieces of it alone as invention
            $ev = $ev + ' ' + $kx.phrase
            $evNorm = $evNorm + ' ' + $kx.phrase
        }
    }

    # Candidate: 2-5 word runs of letters
    foreach ($m in [regex]::Matches($Response, '(?i)\b[a-z][a-z0-9]+(?:\s+[a-z][a-z0-9]+){1,4}\b')) {
        if ($flags.Count -ge $MaxFlags) { break }
        $ph = $m.Value.Trim()
        if ($ph.Length -lt 8 -or $ph.Length -gt 80) { continue }
        $low = $ph.ToLowerInvariant()
        if ($ev.Contains($low) -or $evNorm.Contains($low)) { continue }
        $toks = @($low -split '\s+')
        $subToks = @()
        foreach ($t in $toks) {
            if ($t.Length -ge 4 -and -not $stop.ContainsKey($t)) { $subToks += $t }
        }
        if ($subToks.Count -lt 2) { continue }

        # Near-quote: if most distinctive tokens appear in evidence, do not flag
        $hit = 0
        $missing = New-Object System.Collections.Generic.List[string]
        foreach ($t in $subToks) {
            if ($ev.Contains($t) -or $evNorm.Contains($t)) { $hit++ }
            else { [void]$missing.Add($t) }
        }
        $ratio = $hit / [double]$subToks.Count
        if ($ratio -ge 0.6) { continue }  # paraphrase / near-quote of on-page wording
        if ($missing.Count -eq 0) { continue }

        # high-value product claim patterns always flag if distinctive tokens missing
        $priority = $low -match '(?i)honeypot|decoy|zero.?day|patent|certified|guaranteed|distributed\s+honeypot|ransomware'
        if (-not $priority) {
            # 0.22.3: only flag non-priority when 3+ distinctive tokens AND majority missing
            if ($subToks.Count -lt 3) { continue }
            if ($ratio -ge 0.4) { continue }
            # skip soft marketing glue that is not a concrete invention
            if ($low -match '(?i)^(is |are |the platform|and |that |these |those )') { continue }
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
      0.20/0.22.3: optional high-severity grounding audit.
      Prefer quality gate (0.21+). This path only flags hard inventions (honeypot/etc.),
      not near-quotes — and callers should not run it after a clean quality-gate pass.
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
    # 0.22.3: only high-severity invention patterns (not n-gram near-quote spam)
    $flags = @(Get-PromptParleUnverifiedPhrases -Response $text -Evidence $ev -MaxFlags 8)
    $flags = @($flags | Where-Object {
        $_ -match '(?i)honeypot|decoy|zero-?day|patent|certified|guaranteed|ransomware|distributed\s+honeypot'
    })
    if ($flags.Count -eq 0) {
        return [pscustomobject]@{ text = $text; flagged = @(); applied = $false }
    }
    $banner = New-Object System.Collections.Generic.List[string]
    $banner.Add('')
    $banner.Add('---')
    $banner.Add('## Grounding (client 0.22.3) — high-severity audit')
    $banner.Add('_These high-severity product phrases were **not** found in fetched [OBSERVE]/[WEB]/[HANDS] evidence:_')
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

function Test-PromptParleGroundingTheaterClaim {
    <#
    .SYNOPSIS
      0.22.2: true for self-referential grounding lines (not product facts).
      e.g. "All statements above are taken strictly from [OBSERVE]/[WEB]…"
    #>
    param([string]$Text = '')
    if (-not $Text) { return $false }
    $s = $Text.ToLowerInvariant()
    if ($s -match '\[observe\]|\[web\]|\[hands\]|\[evidence') { return $true }
    if ($s -match '\b(taken strictly from|from the provided|directly from (the )?(site|page|evidence|search)|statements above|no additional (capabilities|details|facts)|not invent|did not invent|haven''t invent|additional resources are available at|all statements above)\b') { return $true }
    if ($s -match '\b(quality gate|evidence-backed|unverified rows|client self-check)\b') { return $true }
    return $false
}

function Get-PromptParleCheckableClaims {
    <#
    .SYNOPSIS
      Extract 3–8 factual claims from a model reply for evidence matching.
      Prefers product/site assertions; skips meta/chat/filler/grounding theater.
      0.22.2: do not skip markdown-bold bullets (was dropping real product claims).
    #>
    param(
        [string]$Response = '',
        [int]$MaxClaims = 8
    )
    $candidates = New-Object System.Collections.Generic.List[object]
    $seen = @{}
    if (-not $Response) { return @() }
    $body = Remove-PromptParleClientAuditSections -Text $Response
    # Drop fenced code (apply/file/run/hands) — not product claims
    $body = [regex]::Replace($body, '(?ms)```[\s\S]*?```', ' ')
    $body = [regex]::Replace($body, '(?m)^\s{0,3}#{1,6}\s+.*$', ' ')
    # Strip list markers and markdown emphasis (keep text) — was wrongly skipping **bold** lines
    $body = [regex]::Replace($body, '(?m)^\s*[-*+]\s+', '')
    $body = [regex]::Replace($body, '\*\*([^*]+)\*\*', '$1')
    $body = [regex]::Replace($body, '(?<!\*)\*([^*]+)\*(?!\*)', '$1')
    $body = [regex]::Replace($body, '__([^_]+)__', '$1')
    $body = [regex]::Replace($body, '`([^`]+)`', '$1')

    $priorityRx = '(?i)\b(honeypot|decoy|zero-?day|patent|certified|certification|guaranteed|distributed|firewall|ransomware|ai-powered|machine learning|compliance|nist|fips|ot\b|ics|scada|modbus|federation|amtd|vpatch|sensor|sensors|deception|deceptive|capability|capabilities|feature|features|offers|provides|includes|supports|enables|integrates|platform|solution|enforcement|inline|wire.?speed|unmappable|alertbox|threat reach|secure control)\b'
    $metaRx = '(?i)^(i (can|will|would|think|believe|am|have)|here''s|heres|let me|sure[,.]|of course|based on (the )?(above|context)|as an ai|hope (this|that)|feel free|please (let|note)|note that|importantly)\b'
    # 0.22.1/0.22.2: denial + grounding theater are not product claims
    $denialRx = '(?i)\b(no web results|no (brief )?hits|no product facts|no (local )?(workspace|ssh) evidence|not present in (the )?(session|evidence|results|provided)|cannot be cited|requested research data is not present|all statements are therefore limited|quality gate \(client|evidence-backed \(|unverified rows|do not treat unverified|ask "where does it say)\b'

    # Sentence-ish + line splits (bullets often lack terminal periods)
    $parts = [regex]::Split($body, '(?<=[.!?])\s+|\r?\n+')
    foreach ($raw in $parts) {
        $s = [regex]::Replace(([string]$raw).Trim(), '\s+', ' ')
        # "Label: claim body" → keep full line (product bullets)
        if ($s.Length -lt 18 -or $s.Length -gt 280) { continue }
        if ($s -match $metaRx) { continue }
        if ($s -match $denialRx) { continue }
        if (Test-PromptParleGroundingTheaterClaim -Text $s) { continue }
        if ($s -match '(?i)^(what changed|applied|download|hands ran|client |additional resources|key strengths|latest news)\b') { continue }
        # Action menus / offers — not product claims (quality gate must not score these)
        if ($s -match '(?i)^(explore|look at|check for|check the|would you like|let me know|how you.d like|how would you like)\b') { continue }
        if ($s -match '(?i)\b(would you like me to|let me know how|how you.?d like to proceed)\b') { continue }
        if ($s -match '^\s*https?://') { continue }
        # Must look like a factual assertion or labeled product capability
        $isPriority = [bool]($s -match $priorityRx)
        $isLabeled = [bool]($s -match '^[A-Za-z][^:]{2,60}:\s+\S')
        $isAssert = [bool]($s -match '(?i)\b(is|are|was|were|has|have|offers|provides|includes|supports|enables|uses|used|features|allows|can|will|delivers|protects|detects|blocks|prevents|enforces|enforce|makes|make|rotating|stops|cuts|surfaces|combines|positions|centered|emphasizes|reduces|stops)\b')
        $hasNum = [bool]($s -match '\d')
        if (-not ($isPriority -or $isLabeled -or ($isAssert -and ($hasNum -or $s.Length -ge 40)))) { continue }
        $k = $s.ToLowerInvariant()
        if ($seen.ContainsKey($k)) { continue }
        $seen[$k] = $true
        # Score for ranking: product-labeled / priority first; deprioritize vague platform lines
        $rank = 0
        if ($isLabeled -and $isPriority) { $rank = 100 }
        elseif ($isPriority) { $rank = 80 }
        elseif ($isLabeled) { $rank = 60 }
        elseif ($isAssert) { $rank = 40 }
        if ($s -match '(?i)\b(single (integrated )?stack|point solutions|work together)\b') { $rank = [Math]::Max(20, $rank - 30) }
        [void]$candidates.Add([pscustomobject]@{ text = $s; rank = $rank })
    }

    # Fallback: high-value n-grams if few sentences
    if ($candidates.Count -lt 2) {
        foreach ($m in [regex]::Matches($body, '(?i)\b[a-z][a-z0-9]+(?:\s+[a-z][a-z0-9]+){1,5}\b')) {
            $ph = $m.Value.Trim()
            if ($ph.Length -lt 10 -or $ph.Length -gt 80) { continue }
            if ($ph -notmatch $priorityRx) { continue }
            if (Test-PromptParleGroundingTheaterClaim -Text $ph) { continue }
            $k = $ph.ToLowerInvariant()
            if ($seen.ContainsKey($k)) { continue }
            $seen[$k] = $true
            [void]$candidates.Add([pscustomobject]@{ text = $ph; rank = 70 })
        }
    }

    $sorted = @($candidates | Sort-Object -Property @{ Expression = 'rank'; Descending = $true }, @{ Expression = { $_.text.Length }; Descending = $false })
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($c in $sorted) {
        if ($out.Count -ge $MaxClaims) { break }
        [void]$out.Add([string]$c.text)
    }
    return @($out.ToArray())
}

function Get-PromptParleClaimMatchStatus {
    <#
    .SYNOPSIS
      Match one claim against evidence corpus.
      Returns: supported | partial | unsupported | skip
      0.22.2: multi-word phrase hits + product-token support; skip grounding theater.
    #>
    param(
        [string]$Claim = '',
        [string]$Evidence = ''
    )
    if (-not $Claim) { return 'skip' }
    if (Test-PromptParleGroundingTheaterClaim -Text $Claim) { return 'skip' }
    if (-not $Evidence -or $Evidence.Length -lt 20) { return 'skip' }
    $c = $Claim.ToLowerInvariant()
    $ev = $Evidence.ToLowerInvariant()
    # Normalize light punctuation for contains checks
    $cNorm = [regex]::Replace($c, '[\u2013\u2014\-_/]+', ' ')
    $cNorm = [regex]::Replace($cNorm, '[^a-z0-9\s]+', ' ')
    $cNorm = [regex]::Replace($cNorm, '\s+', ' ').Trim()
    $evNorm = [regex]::Replace($ev, '[\u2013\u2014\-_/]+', ' ')
    $evNorm = [regex]::Replace($evNorm, '[^a-z0-9\s]+', ' ')
    $evNorm = [regex]::Replace($evNorm, '\s+', ' ')
    # Acronym expansions present on-page as AMTD/etc. are not inventions
    if ($evNorm -match '\bamtd\b') {
        $evNorm += ' active moving target defense automated moving target defense moving target defense'
        $ev += ' active moving target defense'
    }

    if ($ev.Contains($c) -or ($cNorm.Length -ge 20 -and $evNorm.Contains($cNorm))) { return 'supported' }

    # Multi-word phrase hits (product labels often exact on page)
    $phraseHits = 0
    foreach ($m in [regex]::Matches($c, '(?i)\b[a-z][a-z0-9]+(?:\s+[a-z][a-z0-9]+){1,4}\b')) {
        $ph = $m.Value.ToLowerInvariant()
        if ($ph.Length -lt 8 -or $ph.Length -gt 60) { continue }
        if ($ph -match '^(the |and |for |with |that |this |from )') { continue }
        if ($ev.Contains($ph) -or $evNorm.Contains($ph)) { $phraseHits++ }
    }
    if ($phraseHits -ge 2) { return 'supported' }
    if ($phraseHits -eq 1 -and $c.Length -lt 120) {
        # One strong product phrase + any second distinctive token
    }

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
        'website'=$true;'page'=$true;'site'=$true;'http'=$true;'https'=$true
        'environments'=$true;'environment'=$true;'organizations'=$true;'rather'=$true;'these'=$true
        'capabilities'=$true;'capability'=$true;'features'=$true;'feature'=$true;'above'=$true
        'additional'=$true;'details'=$true;'claimed'=$true;'statements'=$true;'taken'=$true
        'strictly'=$true;'provided'=$true;'evidence'=$true;'emphasizes'=$true;'combines'=$true
    }
    $toks = @([regex]::Matches($cNorm, '[a-z0-9]{3,}') | ForEach-Object { $_.Value } | Where-Object { -not $stop.ContainsKey($_) })
    if ($toks.Count -eq 0) { return 'skip' }
    $hit = 0
    $productHit = 0
    $productRx = '^(amtd|deception|deceptive|sensor|sensors|federation|alertbox|modbus|scada|ntcip|honeypot|decoy|vpatch|unmappable|ot|ics|ipv6|omb|wire|enforcement|inline|rotating|responders|siem)$'
    foreach ($t in $toks) {
        if ($evNorm.Contains($t) -or $ev.Contains($t)) {
            $hit++
            if ($t -match $productRx -or $t.Length -ge 6) { $productHit++ }
        }
    }
    $ratio = $hit / [double]$toks.Count
    # Strong: most distinctive tokens present OR multi-word phrase + product tokens
    if ($phraseHits -ge 1 -and $productHit -ge 2) { return 'supported' }
    if ($ratio -ge 0.75 -and $hit -ge 3) { return 'supported' }
    if ($ratio -ge 0.85 -and $hit -eq $toks.Count) { return 'supported' }
    if ($ratio -ge 0.55 -and $hit -ge 2) { return 'partial' }
    if ($phraseHits -ge 1 -and $hit -ge 2) { return 'partial' }
    # priority invention keywords missing from evidence → hard unsupported
    $priorityMissing = $false
    foreach ($t in $toks) {
        if ($t -match '^(honeypot|honeypots|decoy|decoys|zero.?day|ransomware|certified|patent|fips|nist)$') {
            if (-not $ev.Contains($t) -and -not $evNorm.Contains($t)) { $priorityMissing = $true; break }
        }
    }
    if ($priorityMissing) { return 'unsupported' }
    if ($ratio -lt 0.35 -or $hit -eq 0) { return 'unsupported' }
    return 'partial'
}

function Test-PromptParleNoEvidenceMetaReply {
    <#
    .SYNOPSIS
      0.22.1: true when the reply is about missing evidence (not product claims).
      Quality gate must not score these as 0% unverified product facts.
    #>
    param([string]$Text = '')
    if (-not $Text -or $Text.Length -lt 20) { return $false }
    $t = $Text.ToLowerInvariant()
    $hits = 0
    if ($t -match 'no web results') { $hits++ }
    if ($t -match 'no product facts|no (local )?(workspace|ssh) evidence') { $hits++ }
    if ($t -match 'not present in (the )?(session|evidence|results|provided)') { $hits++ }
    if ($t -match 'requested research data is not present|cannot be cited') { $hits++ }
    if ($t -match 'all statements are therefore limited') { $hits++ }
    if ($t -match 'no brief hits|client could not fetch') { $hits++ }
    # Strong single signals
    if ($t -match 'no web results available' -or $t -match 'requested research data is not present') { return $true }
    return ($hits -ge 2)
}

function Test-PromptParleEvidenceHasSubstance {
    <#
    .SYNOPSIS
      0.22.1: evidence corpus has real page/search content (not empty-shell tags).
    #>
    param([string]$Evidence = '')
    if (-not $Evidence -or $Evidence.Length -lt 60) { return $false }
    $e = $Evidence
    # Strip observe/web scaffolding and failure notices
    $e = [regex]::Replace($e, '(?im)^(kind|url|path|rule|q)=.*$', ' ')
    $e = [regex]::Replace($e, '(?is)\[OBSERVE\][^\n]*|\[WEB\][^\n]*|client-first|from web_search auto-fetch', ' ')
    $e = [regex]::Replace($e, '(?is)\(no brief hits[^)]*\)|kind=web_failed|kind=ssh_list_failed|client could not fetch[^\n]*|Cite sources[^\n]*', ' ')
    $e = [regex]::Replace($e, '\s+', ' ').Trim()
    if ($e.Length -lt 80) { return $false }
    # Need some alphanumeric substance beyond scaffolding
    $alnum = ([regex]::Matches($e, '[A-Za-z0-9]{4,}')).Count
    return ($alnum -ge 12)
}

function Invoke-PromptParleQualityGate {
    <#
    .SYNOPSIS
      0.21/0.22.1 quality gate — under-the-hood BS detector + corrector (0 AI tokens).
      Extract checkable claims, match against [OBSERVE]/[WEB]/[HANDS] evidence,
      quantify support, flag unverified, soft-correct high-severity inventions.
      0.22.1: skip no-evidence meta replies and empty-shell evidence (no 0% spam).
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

    # Strip audit tails early so meta-detection sees model prose only
    $bodyEarly = Remove-PromptParleClientAuditSections -Text $raw
    if (Test-PromptParleNoEvidenceMetaReply -Text $bodyEarly) {
        return [pscustomobject]@{
            text = $raw; applied = $false; reason = 'no-evidence-meta'
            claims = @(); supported = 0; partial = 0; unsupported = 0; score_pct = $null; corrected = $false
        }
    }

    # Procedural / menu replies are not product-claim audits
    if (-not $Force -and $bodyEarly -match '(?i)\bwould you like me to\b' -and $bodyEarly -notmatch '(?i)\b(honeypot|decoy|amtd|federation|vpatch|modbus|scada)\b') {
        return [pscustomobject]@{
            text = $raw; applied = $false; reason = 'procedural-menu'
            claims = @(); supported = 0; partial = 0; unsupported = 0; score_pct = $null; corrected = $false
        }
    }

    $hasWebObs = ($Context -match '(?m)\[OBSERVE\]') -or ($Context -match '(?m)\[WEB\]') -or ($Context -match '(?m)\[GROUNDING\]') -or ($Context -match '(?m)\[EVIDENCE_SPINE\]') -or ($Context -match '(?m)\[ATTACH\]') -or ($Context -match '===== FILE:')
    $hasHandsOnly = ($Context -match '(?m)\[HANDS\]') -and -not $hasWebObs
    $hasSource = $Force -or $hasWebObs -or ($Context -match '(?m)\[HANDS\]')
    if (-not $hasSource) {
        return [pscustomobject]@{
            text = $raw; applied = $false; reason = 'no-evidence'
            claims = @(); supported = 0; partial = 0; unsupported = 0; score_pct = $null; corrected = $false
        }
    }
    # HANDS-only dir listings are not product research evidence — do not 0% spam conversational replies
    if (-not $Force -and $hasHandsOnly -and $bodyEarly -notmatch '(?i)\b(honeypot|decoy|amtd|federation|vpatch|modbus|scada|zero-?day|patent|certified)\b') {
        return [pscustomobject]@{
            text = $raw; applied = $false; reason = 'hands-only-nonproduct'
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
    # Empty-shell [WEB]/(no brief hits) is not scorable product evidence
    if (-not $Force -and -not (Test-PromptParleEvidenceHasSubstance -Evidence $ev)) {
        return [pscustomobject]@{
            text = $raw; applied = $false; reason = 'thin-evidence'
            claims = @(); supported = 0; partial = 0; unsupported = 0; score_pct = $null; corrected = $false
        }
    }

    $body = $bodyEarly
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

    # 0.22.2/0.22.3: only surface the gate when there is real risk.
    # Soft marketing intros without invention keywords do not spam the user.
    $severityRxShow = '(?i)\b(distributed\s+honeypots?|honeypots?|zero-?days?|guaranteed|patent(?:ed)?|certified\s+for|ransomware)\b'
    $hardUnsup = 0
    foreach ($r in $results) {
        if ($r.status -ne 'unsupported') { continue }
        if ([string]$r.claim -match $severityRxShow) { $hardUnsup++ }
    }
    $show = $AlwaysShowScore -or $corrected -or ($hardUnsup -gt 0)
    if (-not $show -and $nUnsup -gt 0 -and $score -lt 50 -and $checked -ge 2) { $show = $true }
    # Soft-only unverified + decent score → silent (still recorded in metadata)
    if ($nUnsup -gt 0 -and $hardUnsup -eq 0 -and $score -ge 60 -and -not $corrected -and -not $AlwaysShowScore) {
        $show = $false
    }
    if ($nUnsup -eq 0 -and $score -ge 70 -and -not $corrected -and -not $AlwaysShowScore) {
        $show = $false
    }

    # Build plain claim rows (avoid List[pscustomobject] → pscustomobject cast errors on PS 5.1/7)
    $claimArrSilent = @()
    foreach ($r in $results) {
        $claimArrSilent += [pscustomobject]@{
            claim  = [string]$r.claim
            status = [string]$r.status
        }
    }

    if (-not $show) {
        $silent = New-Object psobject
        $silent | Add-Member -NotePropertyName text -NotePropertyValue $raw
        $silent | Add-Member -NotePropertyName applied -NotePropertyValue $false
        $silentReason = if ($hardUnsup -eq 0 -and $nUnsup -gt 0 -and $score -ge 60) { 'soft-unverified-silent' }
            elseif ($score -ge 70) { 'clean-silent' }
            else { 'partial-silent' }
        $silent | Add-Member -NotePropertyName reason -NotePropertyValue $silentReason
        $silent | Add-Member -NotePropertyName claims -NotePropertyValue $claimArrSilent
        $silent | Add-Member -NotePropertyName supported -NotePropertyValue ([int]$nSup)
        $silent | Add-Member -NotePropertyName partial -NotePropertyValue ([int]$nPart)
        $silent | Add-Member -NotePropertyName unsupported -NotePropertyValue ([int]$nUnsup)
        $silent | Add-Member -NotePropertyName score_pct -NotePropertyValue ([int]$score)
        $silent | Add-Member -NotePropertyName corrected -NotePropertyValue $false
        $silent | Add-Member -NotePropertyName checked -NotePropertyValue ([int]$checked)
        return $silent
    }

    $lines = New-Object System.Collections.Generic.List[string]
    [void]$lines.Add('')
    [void]$lines.Add('---')
    [void]$lines.Add(('## Quality gate (client 0.22.2) — {0}% evidence-backed ({1}/{2} claims)' -f $score, $nSup, $checked))
    [void]$lines.Add(('_Client self-check vs fetched [OBSERVE]/[WEB]/[HANDS] evidence — 0 AI tokens. supported={0} partial={1} unverified={2}_' -f $nSup, $nPart, $nUnsup))
    # Table: unverified product claims only (partials alone do not spam the user)
    if ($nUnsup -gt 0) {
        [void]$lines.Add('')
        [void]$lines.Add('| Claim | Status |')
        [void]$lines.Add('| --- | --- |')
        foreach ($r in $results) {
            if ($r.status -ne 'unsupported') { continue }
            $short = [string]$r.claim
            if ($short.Length -gt 90) { $short = $short.Substring(0, 87) + '...' }
            $short = $short.Replace('|', '/')
            [void]$lines.Add(('| {0} | **unverified** |' -f $short))
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
    # Only when this turn explicitly owes a downloadable file — NOT sticky-doc + incidental web research.
    if ($Obligation.mode -eq 'deliver' -or $Obligation.want_deliver) { return $true }
    # Theater promised a deliverable in the model text
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
        [string]$HistoryText = '',
        [string]$ClientSessionId = '',
        # User-pinned session knowledge (UI ★ marks) — highest in-session priority
        [object[]]$PriorityKnowledge = @(),
        # When true, UI list replaces disk pins (empty array clears). When false, merge UI + disk.
        [bool]$PriorityKnowledgeReplace = $false
    )
    # ArrayList — List[string].Add throws "Argument types do not match" with PS string wrappers
    $notes = New-Object System.Collections.ArrayList
    $ctx = if ($null -eq $Context) { '' } else { [string]$Context }
    $pr = if ($null -eq $Prompt) { '' } else { [string]$Prompt }
    # Wire baseline ONLY (prompt + attach context + history as received) — never inflate with fleet/KNOW
    $charsIn = $ctx.Length + $pr.Length
    $histChars = 0
    if ($HistoryText) {
        $histChars = $HistoryText.Length
        $charsIn += $histChars
    } elseif ($History) {
        foreach ($h in $History) {
            $ht = [string](Get-PromptParleProp $h 'text' (Get-PromptParleProp $h 'content' ''))
            $histChars += $ht.Length
        }
        $charsIn += $histChars
    }
    $charsWire = $charsIn
    # Honest baseline: chars of client framing (SELF / CONN / PROJECT / MEM) that ANY
    # chat client would send for the same fidelity. Counted into "before" so identical
    # framing nets to 0% (not a false expansion) and real compression shows as savings.
    # Does NOT change what the model sees — accounting only. (0.27.2)
    $framingInjected = 0
    # Rolling disk densify credit (beyond this-turn history wire) — lifts "before" baseline
    $memRollingCredit = 0
    # Per-tool savings ledger (0.28.0): honest counterfactual — tokens the model would
    # have used WITHOUT the tool vs WITH it. Vendor-neutral chars; display converts per
    # selected model. kind: measured | avoided-ingest | none (safety, 0 savings).
    # Each helper already returns chars_in/chars_out; we stop discarding it.
    $toolBreakdown = New-Object System.Collections.ArrayList
    $recordToolSaving = {
        param([string]$Tool, [int]$Without, [int]$With, [string]$Kind = 'measured')
        $w0 = [Math]::Max(0, [int]$Without); $w1 = [Math]::Max(0, [int]$With)
        $saved = if ($Kind -eq 'none') { 0 } else { [Math]::Max(0, $w0 - $w1) }
        [void]$toolBreakdown.Add([pscustomobject]@{
            tool          = [string]$Tool
            kind          = [string]$Kind
            chars_without = $w0
            chars_with    = $w1
            chars_saved   = $saved
        })
    }
    $tools = New-Object System.Collections.ArrayList
    # Resolved later (after MEM) so [KNOW] sits above densified history as session truth
    $knowItems = @()
    $PriorityKnowledge = @($PriorityKnowledge)
    $evidenceMode = 'live'
    $handsAllowed = $true
    $evidenceReason = 'default'
    $memTextForGate = ''

    # Prep depth only — model already understands natural language; we must not underrun evidence
    $turnKind = 'chat'
    try { $turnKind = Get-PromptParleTurnKind -Prompt $pr -History $History } catch { $turnKind = 'chat' }
    [void]$notes.Add([string]("turn:$turnKind"))

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
            [void]$notes.Add('implement-directive')
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
                $framingInjected += $connBrief.Length
            } elseif (-not $ctx) {
                $ctx = $connBrief
                $framingInjected += $connBrief.Length
            }
            [void]$notes.Add('conn')
            [void]$tools.Add('connections')
        }
    } catch {
        [void]$notes.Add('conn-skip')
    }

    # 0a) [SELF] — identity, capabilities, portal, help. Memoized (0.30.1): full
    # card only on turn 1 of a session; on later turns the model already has it in
    # history, so send a 1-line pointer. Saves ~1.4k chars/turn on continued chats
    # and stops tiny prompts from reading as "expanded". Counterfactual: without
    # memoization we would re-send the full card, so credit the difference as saved.
    try {
        $selfCardFull = Get-PromptParleSelfCard
        if ($selfCardFull -and $ctx -notmatch '(?m)^\[SELF\]') {
            $priorTurns = ($histChars -gt 0)
            if ($priorTurns) {
                $selfCard = '[SELF] PromptParle desktop client (identity/tools/paths already established earlier this chat — unchanged).'
                # Savings: full card would have been re-sent; only the pointer goes out.
                if ($selfCardFull.Length -gt $selfCard.Length) {
                    & $recordToolSaving 'framing' $selfCardFull.Length $selfCard.Length 'measured'
                }
                [void]$notes.Add('self-card:memoized')
            } else {
                $selfCard = $selfCardFull
                [void]$notes.Add('self-card')
            }
            if ($ctx) { $ctx = $selfCard + "`n`n" + $ctx } else { $ctx = $selfCard }
            $framingInjected += $selfCard.Length
        }
    } catch {
        [void]$notes.Add('self-card-skip')
    }

    # 0a2) Always-on [PROJECT] bind card — only when a real bind exists (or unbound notice)
    try {
        $projCard = Get-PromptParleProjectCard -TurnKind $turnKind
        if ($projCard -and $ctx -notmatch '(?m)^\[PROJECT\]') {
            if ($ctx -match '(?s)^(\[SELF\][\s\S]*?)(\n\n|$)(.*)$') {
                $ctx = $Matches[1] + "`n`n" + $projCard + $(if ($Matches[3]) { "`n`n" + $Matches[3] } else { '' })
            } elseif ($ctx -match '(?s)^(\[CONN\][^\n]*(?:\n(?!\[)[^\n]*)*)\n\n?(.*)$') {
                $ctx = $Matches[1] + "`n`n" + $projCard + "`n`n" + $Matches[2]
            } elseif ($ctx) {
                $ctx = $projCard + "`n`n" + $ctx
            } else {
                $ctx = $projCard
            }
            $framingInjected += $projCard.Length
            [void]$notes.Add('project-card')
            [void]$tools.Add('project_bind')
        }
    } catch {
        [void]$notes.Add('project-card-skip')
    }

    # 0b) Continuous chat memory — high-fidelity first; densify only age + noise
    $mem = $null
    try {
        # Budgets favor fidelity (dial still owns aggressiveness)
        $memMax = 3200
        if ($Dial -le 2) { $memMax = 4800 }
        if ($Dial -eq 3) { $memMax = 3600 }
        if ($Dial -ge 4) { $memMax = 2400 }
        if ($Dial -ge 5) { $memMax = 1800 }
        $histForMem = $History
        $histTextForMem = $HistoryText
        # Structural densify only (Reduce-*) — no phrase-list content moles
        try {
            if ($History -and $History.Count -gt 0) {
                $filtered = New-Object System.Collections.Generic.List[object]
                foreach ($h in @($History)) {
                    $hr = [string](Get-PromptParleProp $h 'role' 'user')
                    $ht = [string](Get-PromptParleProp $h 'text' (Get-PromptParleProp $h 'content' ''))
                    $roleForReduce = if ($hr -match '(?i)assistant|bot|ai') { 'assistant' } else { 'user' }
                    $ht = Reduce-PromptParleTurnTextForMemory -Text $ht -Role $roleForReduce
                    if ($ht) { $filtered.Add([pscustomobject]@{ role = $hr; text = $ht }) }
                }
                $histForMem = @($filtered.ToArray())
            }
        } catch { }
        $memParams = @{ MaxChars = $memMax; Dial = $Dial }
        if ($ClientSessionId) { $memParams.ClientSessionId = $ClientSessionId }
        if ($histForMem -and $histForMem.Count -gt 0) {
            $mem = Invoke-PromptParleChatMemoryBrief -History $histForMem @memParams
        } elseif ($histTextForMem -and $histTextForMem.Trim().Length -gt 20) {
            $mem = Invoke-PromptParleChatMemoryBrief -HistoryText $histTextForMem @memParams
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
                [void]$notes.Add('mem-attach-priority')
            }
            if ($ctx -notmatch '(?m)^\[MEM\]') {
                # Place memory after CONN/PROJECT, before bulky attaches
                if ($ctx -match '(?s)^((?:\[(?:CONN|PROJECT)\][^\n]*(?:\n(?!\[)[^\n]*)*\n\n?)+)(.*)$') {
                    $ctx = $Matches[1] + $mem.text + "`n`n" + $Matches[2]
                } else {
                    $ctx = $mem.text + "`n`n" + $ctx
                }
            }
            foreach ($n in @($mem.notes)) { if ($n) { [void]$notes.Add([string]$n) } }
            [void]$tools.Add('chat_memory')
            # Credit rolling densify: mem.chars_in includes prior session fold savings
            try {
                $mci = [int](Get-PromptParleProp $mem 'chars_in' 0)
                $mco = [int](Get-PromptParleProp $mem 'chars_out' ($mem.text.Length))
                if ($mci -gt $histChars) {
                    $memRollingCredit = $mci - $histChars
                    [void]$notes.Add(("mem-credit:{0}c" -f $memRollingCredit))
                }
                # Savings: prior turns densified to the brief actually sent.
                if ($mci -gt $mco) { & $recordToolSaving 'chat_memory' $mci $mco 'measured' }
            } catch { }
        }
    } catch {
        [void]$notes.Add('mem-skip')
    }

    # 0c) User-pinned session Knowledge (★ in UI) — after MEM, protected from budget densify
    try {
        $storeKnow = @()
        if ($ClientSessionId) {
            try {
                $stK = Get-PromptParleChatMemoryStore -SessionId $ClientSessionId.Trim()
                if ($stK -and $stK['priority_knowledge']) { $storeKnow = @($stK['priority_knowledge']) }
            } catch { }
        }
        if ($PriorityKnowledgeReplace) {
            # Chat UI is authoritative (unpin clears disk too)
            $knowItems = @(Merge-PromptParlePriorityKnowledge -FromUi $PriorityKnowledge -FromStore @() -MaxItems 12)
        } else {
            $knowItems = @(Merge-PromptParlePriorityKnowledge -FromUi $PriorityKnowledge -FromStore $storeKnow -MaxItems 12)
        }
        if ($ClientSessionId -and ($PriorityKnowledgeReplace -or $knowItems.Count -gt 0)) {
            try {
                $stSave = Get-PromptParleChatMemoryStore -SessionId $ClientSessionId.Trim()
                $stSave['priority_knowledge'] = $knowItems
                Save-PromptParleChatMemoryStore -Store $stSave -SessionId $ClientSessionId.Trim()
            } catch { }
        }
        $knowMax = 4800
        if ($Dial -ge 4) { $knowMax = 3600 }
        if ($Dial -le 2) { $knowMax = 6000 }
        $knowBlock = Format-PromptParlePriorityKnowledgeBlock -Items $knowItems -MaxChars $knowMax -MaxItems 8
        if ($knowBlock) {
            # Drop any prior [KNOW] then place after SELF/CONN/PROJECT (before MEM/bulk)
            $ctx = [regex]::Replace($ctx, '(?ms)\[KNOW\][^\n]*(?:\n(?!\[)[^\n]*)*\n*', '')
            if ($ctx -match '(?s)^((?:\[(?:SELF|CONN|PROJECT)\][^\n]*(?:\n(?!\[)[^\n]*)*\n\n?)+)(.*)$') {
                $ctx = $Matches[1] + $knowBlock + "`n`n" + $Matches[2]
            } elseif ($ctx) {
                $ctx = $knowBlock + "`n`n" + $ctx
            } else {
                $ctx = $knowBlock
            }
            [void]$notes.Add(('know:' + $knowItems.Count))
            [void]$tools.Add('priority_knowledge')
            # Do NOT add pin sizes to charsWire/charsIn — pins are selected signal, not "before" bloat
        }
    } catch {
        [void]$notes.Add('know-skip')
    }

    # Evidence mode (product core) — decides prep depth + whether hands agent may run
    $oblEarly = $null
    try { $oblEarly = Resolve-PromptParleTurnObligation -Prompt $pr -History $History } catch { $oblEarly = $null }
    try {
        if ($mem -and $mem.text) { $memTextForGate = [string]$mem.text }
        $em = Resolve-PromptParleEvidenceMode `
            -Prompt $pr `
            -History $History `
            -MemText $memTextForGate `
            -PriorityKnowledge $knowItems `
            -TurnKind $turnKind `
            -Obligation $oblEarly
        $evidenceMode = [string]$em.mode
        $handsAllowed = [bool]$em.hands_allowed
        $evidenceReason = [string]$em.reason
    } catch {
        $evidenceMode = 'live'
        $handsAllowed = $true
        $evidenceReason = 'resolve-fallback'
    }
    [void]$notes.Add(('evidence:' + $evidenceMode + '/' + $evidenceReason))
    [void]$tools.Add(('evidence_' + $evidenceMode))

    if (-not $ToolsEnabled) {
        [void]$notes.Add('tools off')
        $charsOutOff = $ctx.Length + $pr.Length
        $charsBeforeOff = $charsWire + [Math]::Max(0, [int]$memRollingCredit) + [Math]::Max(0, [int]$framingInjected)
        $tokInOff = if ($charsBeforeOff -le 0) { 0 } else { [Math]::Max(1, [int][Math]::Ceiling($charsBeforeOff / 4.0)) }
        $tokOutOff = if ($charsOutOff -le 0) { 0 } else { [Math]::Max(1, [int][Math]::Ceiling($charsOutOff / 4.0)) }
        return ,([pscustomobject]@{
            prompt           = $pr
            context          = $ctx
            notes            = @($notes.ToArray())
            tools            = @($tools)
            tool_breakdown   = @($toolBreakdown.ToArray())
            agent            = 'none'
            tools_enabled    = $false
            chars_in         = $charsBeforeOff
            chars_out        = $charsOutOff
            tokens_before    = $tokInOff
            tokens_after     = $tokOutOff
            evidence_mode    = $evidenceMode
            hands_allowed    = $false
            evidence_reason  = $evidenceReason
        })
    }

    if ($Dial -lt 1) { $Dial = 1 }
    if ($Dial -gt 5) { $Dial = 5 }
    $prof = if ($Profile) { $Profile } else { 'general' }
    $budget = Get-PromptParleLocalContextBudget -Dial $Dial
    [void]$tools.Add('secret_scan')
    [void]$tools.Add('code_brief')

    # 1) Mask secrets (always when tools on)
    $r1 = Invoke-PromptParleSecretScanLocal -Text $pr
    $r2 = Invoke-PromptParleSecretScanLocal -Text $ctx
    $pr = $r1.text
    $ctx = $r2.text
    if (($r1.masked + $r2.masked) -gt 0) { [void]$notes.Add("mask $($r1.masked + $r2.masked)") }

    # --- evidence_mode=session: bind + MEM/KNOW only; no live fleet; return early ---
    if ($evidenceMode -eq 'session') {
        $ctx = Get-PromptParleProtectedSessionContext -Context $ctx
        $sessDir = @(
            '[CLIENT DIRECTIVE — evidence_mode=session]',
            'Answer from [MEM]/[KNOW]/[PROJECT]/[CONN] only — session already holds the evidence.',
            'Write a normal conversational answer. NEVER emit hands, toolcall, ssh_list/ssh_read, or re-discovery.',
            'If a fact is missing, say so briefly and invite the user to say refresh for a live pull.'
        ) -join ' '
        if ($pr -notmatch '\[CLIENT DIRECTIVE — evidence_mode=session') {
            $pr = $pr + "`n`n" + $sessDir
        }
        $charsOutS = $ctx.Length + $pr.Length
        $charsInS = $charsWire + [Math]::Max(0, [int]$memRollingCredit) + [Math]::Max(0, [int]$framingInjected)
        $tokBeforeS = if ($charsInS -le 0) { 0 } else { [Math]::Max(1, [int][Math]::Ceiling($charsInS / 4.0)) }
        $tokAfterS = if ($charsOutS -le 0) { 0 } else { [Math]::Max(1, [int][Math]::Ceiling($charsOutS / 4.0)) }
        $savedS = [Math]::Max(0, $charsInS - $charsOutS)
        if ($savedS -gt 0 -and $charsInS -gt 0) {
            $pctS = [int][Math]::Round(100.0 * $savedS / $charsInS)
            [void]$notes.Add("local −${pctS}%")
        }
        [void]$notes.Add(("prep-tokens:{0}->{1}" -f $tokBeforeS, $tokAfterS))
        return ,([pscustomobject]@{
            prompt           = $pr
            context          = $ctx
            notes            = @($notes.ToArray())
            tools            = @($tools | Select-Object -Unique)
            tool_breakdown   = @($toolBreakdown.ToArray())
            agent            = 'none'
            tools_enabled    = $true
            dial             = $Dial
            budget           = $budget
            chars_in         = $charsInS
            chars_out        = $charsOutS
            tokens_before    = $tokBeforeS
            tokens_after     = $tokAfterS
            evidence_mode    = 'session'
            hands_allowed    = $false
            evidence_reason  = $evidenceReason
            obligation       = $oblEarly
            turn_kind        = $turnKind
        })
    }

    # --- evidence_mode=live|refresh: full prep (SSH / observe / fleet) ---
    # Catch-up on project path: steer to real project spine, never invent .parle/sessions
    try {
        if ($evidenceReason -match '^catchup-' -or (Test-PromptParleSessionCatchUpIntent -Prompt $pr)) {
            $cuDir = @(
                '[CLIENT DIRECTIVE — project catch-up]',
                'User wants orientation on recent work. Chat history is NOT under the project tree (no .parle/sessions/).',
                'Use [MEM]/[KNOW] if present. For a project path: prefer git status/log, HANDOFF.md, AGENTS.md, README, recent diffs — never invent a sessions folder.',
                'Answer with a real catch-up brief (what changed, open work, next step). Do not offer a menu of "would you like me to explore" without first using tools.'
            ) -join ' '
            if ($pr -notmatch '\[CLIENT DIRECTIVE — project catch-up') {
                $pr = $pr + "`n`n" + $cuDir
                [void]$notes.Add('catchup-directive')
            }
        }
    } catch { }

    # 2) Fidelity fleet — protect [CONN]/[MEM]; shrink rest with prompt-aware tools
    if ($ctx.Length -gt 200) {
        $headKeep = ''
        $restCtx = $ctx
        # Peel each framing card as ONE paragraph block: header + its own non-blank
        # continuation lines, stopping at the blank line before the next block.
        # (0.28.0) Prior pattern was greedy — a card's continuation `(?!\[)` swallowed
        # every following non-bracket line, i.e. the entire document, so the fleet
        # never saw real content and chat turns showed ~0% savings. Stop at blank line.
        while ($restCtx -match '(?s)^(\[(?:CONN|PROJECT|MEM|KNOW|SELF)\][^\n]*(?:\n(?![\[\r\n])[^\n]+)*)\n\n+(.*)$') {
            if ($headKeep) { $headKeep = $headKeep + "`n`n" + $Matches[1] }
            else { $headKeep = $Matches[1] }
            $restCtx = $Matches[2]
        }
        if ($restCtx.Length -gt 200) {
            $room = [Math]::Max(800, $budget - $headKeep.Length - 80)
            $fleet = Invoke-PromptParleFidelityContextLocal -Text $restCtx -Prompt $pr -MaxChars $room -Dial $Dial
            $restCtx = $fleet.text
            foreach ($n in @($fleet.notes)) { if ($n) { [void]$notes.Add([string]$n) } }
            $fleetTool = 'fleet'
            foreach ($fn in @($fleet.notes)) {
                if ($fn -match 'error_brief') { [void]$tools.Add('error_brief'); $fleetTool = 'error_brief'; break }
            }
            try {
                $fci = [int](Get-PromptParleProp $fleet 'chars_in' ($restCtx.Length))
                $fco = [int](Get-PromptParleProp $fleet 'chars_out' ($fleet.text.Length))
                if ($fci -gt $fco) { & $recordToolSaving $fleetTool $fci $fco 'measured' }
            } catch { }
        }
        if ($headKeep) { $ctx = $headKeep + "`n`n" + $restCtx } else { $ctx = $restCtx }
    }

    # 2.5) SSH cwd auto-evidence — named files in prompt
    try {
        $sshMax = [Math]::Min(14000, [int]($budget * 0.48))
        if ($Dial -le 2) { $sshMax = [Math]::Min(20000, [int]($budget * 0.55)) }
        if ($Dial -ge 4) { $sshMax = [Math]::Min(10000, $sshMax) }
        $sshFiles = if ($Dial -le 2) { 6 } else { 4 }
        $sshEv = Get-PromptParleSshPromptEvidence -Prompt $pr -Profile $prof -MaxFiles $sshFiles -MaxChars $sshMax
        if ($sshEv -and $sshEv.text) {
            if ($ctx) { $ctx = $ctx + "`n`n" + $sshEv.text } else { $ctx = [string]$sshEv.text }
            [void]$notes.Add(("ssh-fetch {0}" -f $sshEv.files))
            foreach ($sn in @($sshEv.notes)) {
                if ($sn -and $sn -match '^ssh-ok:') { [void]$notes.Add([string]$sn) }
            }
            [void]$tools.Add('ssh')
            try {
                $sw = [int](Get-PromptParleProp $sshEv 'chars_without' 0)
                $swWith = [int](Get-PromptParleProp $sshEv 'chars_with' ($sshEv.text.Length))
                if ($sw -gt $swWith) { & $recordToolSaving 'ssh_read' $sw $swWith 'avoided-ingest' }
            } catch { }
        } elseif ($sshEv -and $sshEv.notes) {
            $miss = @($sshEv.notes | Where-Object { $_ -match '^ssh-miss:' } | Select-Object -First 4)
            if ($miss.Count -gt 0) {
                $missNames = @($miss | ForEach-Object { $_ -replace '^ssh-miss:', '' })
                $missBlock = "[SSH] Fetch attempted (not found on remote under session cwd):`n- " + ($missNames -join "`n- ")
                if ($ctx) { $ctx = $ctx + "`n`n" + $missBlock } else { $ctx = $missBlock }
                [void]$notes.Add('ssh-miss')
                [void]$tools.Add('ssh')
            }
        }
    } catch {
        [void]$notes.Add('ssh-fetch-skip')
    }

    # 2.6) Product bind live evidence — only when turn needs product workspace pack
    try {
        $wantProduct = Test-PromptParleProductWorkIntent -Prompt $pr -TurnKind $turnKind -Obligation $oblEarly
        if ($wantProduct) {
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
                foreach ($pn in @($prod.notes)) { if ($pn) { [void]$notes.Add([string]$pn) } }
                [void]$tools.Add('ssh')
                [void]$tools.Add('product_bind')
            }
        }
    } catch {
        [void]$notes.Add('ssh-product-skip')
    }

    # 2b) Session web ledger — compact (max 6) so long research sessions don't accumulate URL noise
    try {
        $webMax = 6
        if ($Dial -le 2) { $webMax = 8 }
        if ($Dial -ge 4) { $webMax = 4 }
        # Research-meta asks need the full list to answer "did you research X?"
        if (Test-PromptParleResearchMetaIntent -Prompt $pr) { $webMax = 12 }
        $webEv = Get-PromptParleWebEvidenceBrief -Max $webMax
        if ($webEv) {
            if ($ctx) { $ctx = $ctx + "`n`n" + $webEv } else { $ctx = $webEv }
            [void]$notes.Add('session-web')
        }
    } catch { [void]$notes.Add('session-web-skip') }

    # 2c) Research-meta: "did you research the site?" → ledger is the answer, not amnesia
    try {
        if (Test-PromptParleResearchMetaIntent -Prompt $pr) {
            $metaDir = @(
                '[CLIENT DIRECTIVE — research meta · 0.26.17]',
                'User is asking whether you already researched/fetched a website.',
                'Answer from [SESSION WEB] and any [OBSERVE]/[WEB]/[WEB_PAGE] in context THIS turn.',
                'If the domain or URL is listed, answer YES and cite those URLs. Do NOT say "Not yet" or ask them to share the URL when evidence is already present.',
                'If the ledger is empty, say you have no client-fetched pages yet — then offer to fetch now.'
            ) -join ' '
            if ($pr -notmatch '\[CLIENT DIRECTIVE — research meta') {
                $pr = $pr + "`n`n" + $metaDir
                [void]$notes.Add('research-meta-directive')
            }
        }
    } catch { }

    # 3) 0.18 obligation resolve + client-first OBSERVE (before model tokens)
    $blob = ("{0} {1}" -f $pr, $prof).ToLowerInvariant()
    $obligation = $null
    try {
        $obligation = Resolve-PromptParleTurnObligation -Prompt $pr -History $History
        [void]$notes.Add(('obligation:' + $obligation.mode))
        if ($obligation.observe -and $obligation.observe.Count -gt 0) {
            [void]$notes.Add(('observe:' + ($obligation.observe -join '+')))
        }
    } catch {
        [void]$notes.Add('obligation-skip')
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
            foreach ($n in @($obs.notes)) { if ($n) { [void]$notes.Add([string]$n) } }
            foreach ($t in @($obs.tools)) { if ($t) { [void]$tools.Add([string]$t) } }
            if ($obs.fulfilled -and $obs.fulfilled.Count -gt 0) {
                [void]$notes.Add(('observe-ok:' + $obs.fulfilled.Count))
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
                    [void]$notes.Add('observe-directive')
                }
            } elseif ($obligation.want_web -or $obligation.want_list) {
                $failDir = @(
                    '[CLIENT DIRECTIVE — observe failed · capability=obligation 0.18]',
                    'Client could not fill required observe evidence. State the single hard blocker.',
                    'Do NOT invent website or directory content from [MEM]. Do NOT dump commands as the answer.'
                ) -join ' '
                if ($pr -notmatch '\[CLIENT DIRECTIVE — observe') {
                    $pr = $pr + "`n`n" + $failDir
                    [void]$notes.Add('observe-fail-directive')
                }
            }
        } catch {
            [void]$notes.Add('observe-prep-skip')
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
                    [void]$notes.Add($(if ($web.cached) { 'web-cache' } else { 'web' }))
                    [void]$tools.Add('web_search')
                }
            }
        } catch {
            [void]$notes.Add('web-skip')
        }
    }

    # 3b) 0.20 GROUNDING pack when web observe present
    try {
        $gb = Get-PromptParleGroundingBlock -Context $ctx
        if ($gb) {
            if ($ctx) { $ctx = $ctx + "`n`n" + $gb } else { $ctx = $gb }
            [void]$notes.Add('grounding-block')
        }
    } catch { [void]$notes.Add('grounding-skip') }

    # 3c) 0.20 PROVENANCE when user audits a claim (where does it say / where did you get)
    try {
        if (Test-PromptParleProvenanceIntent -Prompt $pr) {
            # Ensure web observe if domain/site mentioned and not already fetched
            if ($pr -match '(?i)website|https?://' -or $pr -match '(?i)\b(site|page)\b') {
                if ($ctx -notmatch '(?m)\[OBSERVE\] kind=web') {
                    try {
                        $dom = ''
                        if ($pr -match '(?i)([a-z0-9.-]+\.(?:com|org|net|io|ai))') { $dom = $Matches[1] }
                        if ($dom) {
                            $pg = Invoke-PromptParleWebPageFetch -UrlOrDomain $dom -MaxChars 6000
                            if ($pg.ok -and $pg.text) {
                                $blk = "[OBSERVE] kind=web_page client-first (0.20 provenance)`nurl: $($pg.url)`nrule: Use for claim audit only.`n---`n$($pg.text)"
                                if ($ctx) { $ctx = $ctx + "`n`n" + $blk } else { $ctx = $blk }
                                [void]$notes.Add('provenance-refetch')
                            }
                        }
                    } catch { }
                }
            }
            $prov = Invoke-PromptParleProvenancePrep -Prompt $pr -Context $ctx -History $History
            if ($prov.text) {
                if ($ctx) { $ctx = $ctx + "`n`n" + $prov.text } else { $ctx = $prov.text }
                foreach ($n in @($prov.notes)) { if ($n) { [void]$notes.Add([string]$n) } }
                $pdir = @(
                    '[CLIENT DIRECTIVE — provenance owed · 0.20]',
                    'Client already audited challenged claims in [PROVENANCE].',
                    'Your answer MUST include: (1) on-source yes/no (2) if prior assistant invented it, say that explicitly (3) closest on-page wording only from [OBSERVE].',
                    'Do not stop at "nowhere" without provenance of where the phrase entered this chat.'
                ) -join ' '
                if ($pr -notmatch '\[CLIENT DIRECTIVE — provenance') {
                    $pr = $pr + "`n`n" + $pdir
                    [void]$notes.Add('provenance-directive')
                }
            }
        }
    } catch {
        [void]$notes.Add('provenance-skip')
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
            [void]$notes.Add('deliver-directive')
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
                if ($extra) {
                    [void]$notes.Add('diff'); [void]$tools.Add('git_diff')
                    $gw = [int]$script:PromptParleLastGitRawChars; $gwWith = [int]$script:PromptParleLastGitWithChars
                    if ($gw -gt $gwWith) { & $recordToolSaving 'git' $gw $gwWith 'avoided-ingest' }
                }
            } elseif ($wantDeps) {
                $extra = Get-PromptParleWorkspaceDepsMap -MaxChars 2800
                if ($extra) { [void]$notes.Add('deps'); [void]$tools.Add('deps') }
            } elseif ($wantSlice -or ($bodyLen -lt 80 -and -not $wantMap)) {
                # Prefer high-fidelity relevant slices over bare index when we have query tokens
                $sliceBudget = [Math]::Min(14000, [int]($budget * 0.45))
                if ($Dial -le 2) { $sliceBudget = [Math]::Min(20000, [int]($budget * 0.55)) }
                $sl = Get-PromptParleRelevantSlice -Prompt $pr -MaxFiles $(if ($Dial -le 2) { 5 } else { 4 }) -MaxChars $sliceBudget
                if ($sl.text) {
                    $extra = $sl.text
                    foreach ($n in @($sl.notes)) { if ($n) { [void]$notes.Add([string]$n) } }
                    [void]$tools.Add('relevant_slice')
                    try {
                        $slw = [int](Get-PromptParleProp $sl 'chars_without' 0)
                        $slWith = [int](Get-PromptParleProp $sl 'chars_with' ($sl.text.Length))
                        if ($slw -gt $slWith) { & $recordToolSaving 'relevant_slice' $slw $slWith 'avoided-ingest' }
                    } catch { }
                } elseif ($wantMap -or $bodyLen -lt 40) {
                    $extra = Get-PromptParleWorkspaceFileIndex -MaxChars 1800
                    if ($extra) { [void]$notes.Add('idx'); [void]$tools.Add('file_index') }
                }
            } elseif ($wantMap -or $bodyLen -lt 40) {
                $extra = Get-PromptParleWorkspaceFileIndex -MaxChars 1800
                if ($extra) { [void]$notes.Add('idx'); [void]$tools.Add('file_index') }
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
                foreach ($n in @($sl.notes)) { if ($n) { [void]$notes.Add([string]$n) } }
                [void]$notes.Add('slice>bulk')
                [void]$tools.Add('relevant_slice')
                try {
                    $slw2 = [int](Get-PromptParleProp $sl 'chars_without' 0)
                    $slWith2 = [int](Get-PromptParleProp $sl 'chars_with' ($sl.text.Length))
                    if ($slw2 -gt $slWith2) { & $recordToolSaving 'relevant_slice' $slw2 $slWith2 'avoided-ingest' }
                } catch { }
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
                    [void]$notes.Add('diff>files')
                    [void]$tools.Add('git_diff')
                    $gw2 = [int]$script:PromptParleLastGitRawChars; $gwWith2 = [int]$script:PromptParleLastGitWithChars
                    if ($gw2 -gt $gwWith2) { & $recordToolSaving 'git' $gw2 $gwWith2 'avoided-ingest' }
                }
            } catch { }
        }
    }

    # 5) Hard local budget — head+tail fidelity trim; never drop CONN/MEM/KNOW; protect PROVENANCE/GROUNDING
    if ($ctx.Length -gt $budget) {
        $budgetCapBefore = $ctx.Length
        $protected = New-Object System.Collections.Generic.List[string]
        $work = $ctx
        foreach ($tag in @('PROVENANCE', 'GROUNDING', 'KNOW')) {
            $rx = '(?ms)(\[' + $tag + '\][^\n]*(?:\n(?!\[)[^\n]*)*)'
            foreach ($m in [regex]::Matches($work, $rx)) {
                [void]$protected.Add($m.Groups[1].Value.Trim())
            }
            $work = [regex]::Replace($work, $rx, '')
        }
        $headKeep = ''
        $rest = $work
        # Per-block peel (stop at blank line) so the document stays in $rest and gets
        # trimmed to budget, instead of riding into $headKeep untouched. See 0.28.0 note above.
        while ($rest -match '(?s)^(\[(?:SELF|CONN|PROJECT|MEM)\][^\n]*(?:\n(?![\[\r\n])[^\n]+)*)\n\n+(.*)$') {
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
        [void]$notes.Add("cap $budget")
        # Savings: over-budget context head+tail trimmed to the dial budget.
        if ($budgetCapBefore -gt $ctx.Length) { & $recordToolSaving 'budget_cap' $budgetCapBefore $ctx.Length 'measured' }
    }

    $charsOut = $ctx.Length + $pr.Length
    # Honest meter: wire in (+ rolling densify credit + always-on client framing) → prep out.
    # framingInjected = SELF/CONN/PROJECT scaffolding any chat client would send anyway.
    # No synthetic fleet credits.
    $charsInEffective = $charsWire + [Math]::Max(0, [int]$memRollingCredit) + [Math]::Max(0, [int]$framingInjected)
    $tokBefore = if ($charsInEffective -le 0) { 0 } else { [Math]::Max(1, [int][Math]::Ceiling($charsInEffective / 4.0)) }
    $tokAfter = if ($charsOut -le 0) { 0 } else { [Math]::Max(1, [int][Math]::Ceiling($charsOut / 4.0)) }
    $saved = [Math]::Max(0, $charsInEffective - $charsOut)
    if ($saved -gt 0) {
        $pct = if ($charsInEffective -gt 0) { [int][Math]::Round(100.0 * $saved / $charsInEffective) } else { 0 }
        [void]$notes.Add("local −${pct}%")
        [void]$notes.Add(("prep-tokens:{0}->{1}" -f $tokBefore, $tokAfter))
    } elseif ($tokAfter -gt $tokBefore -and $tokBefore -gt 0) {
        [void]$notes.Add(("prep-expanded:{0}->{1}" -f $tokBefore, $tokAfter))
    } elseif ($notes.Count -eq 0) {
        [void]$notes.Add('fidelity ok')
    }

    # Framing memoization (0.30.1): the [SELF] card saving is recorded inline at
    # injection time (turn 2+ sends a pointer, not the full card) — see section 0a.

    return ,([pscustomobject]@{
        prompt           = $pr
        context          = $ctx
        notes            = @($notes.ToArray())
        tools            = @($tools | Select-Object -Unique)
        tool_breakdown   = @($toolBreakdown.ToArray())
        agent            = 'none'
        tools_enabled    = $true
        dial             = $Dial
        budget           = $budget
        chars_in         = $charsInEffective
        chars_out        = $charsOut
        tokens_before    = $tokBefore
        tokens_after     = $tokAfter
        evidence_mode    = $evidenceMode
        hands_allowed    = [bool]$handsAllowed
        evidence_reason  = $evidenceReason
        obligation       = $obligation
        turn_kind        = $turnKind
    })
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
    if ($blob -match 'search|web|research|look up|news|docs|documentation|internet|theaters?|movies?|showtimes?|box office|as of today|right now') {
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
    <#
    .SYNOPSIS
      Strip trailing \ or / without calling String.TrimEnd (PS method-bind footgun).
    #>
    param($Path)
    $p = [string](ConvertTo-PromptParleSingleString $Path)
    if ([string]::IsNullOrEmpty($p)) { return '' }
    while ($p.Length -gt 0) {
        $last = $p[$p.Length - 1]
        if ($last -eq [char]0x5C -or $last -eq [char]0x2F) {
            $p = $p.Substring(0, $p.Length - 1)
        } else {
            break
        }
    }
    return $p
}

function Get-PromptParleTrimPathStart {
    param($Path)
    $p = [string](ConvertTo-PromptParleSingleString $Path)
    if ([string]::IsNullOrEmpty($p)) { return '' }
    $i = 0
    while ($i -lt $p.Length) {
        $ch = $p[$i]
        if ($ch -eq [char]0x5C -or $ch -eq [char]0x2F) { $i++ } else { break }
    }
    if ($i -le 0) { return $p }
    return $p.Substring($i)
}

function ConvertTo-PromptParleInt32 {
    <# Internal: coerce numbers without [ref]/TryParse or ambiguous casts. #>
    param($Value, [int]$Default = 0)
    if ($null -eq $Value) { return $Default }
    try {
        if ($Value -is [int]) { return $Value }
        if ($Value -is [long]) {
            if ($Value -gt [int]::MaxValue -or $Value -lt [int]::MinValue) { return $Default }
            return [int]$Value
        }
        if ($Value -is [double] -or $Value -is [float] -or $Value -is [decimal]) {
            return [int][math]::Truncate([double]$Value)
        }
        $s = [string](ConvertTo-PromptParleSingleString $Value)
        if ([string]::IsNullOrWhiteSpace($s)) { return $Default }
        return [Convert]::ToInt32($s.Trim(), 10)
    } catch {
        return $Default
    }
}

function Write-PromptParleDebugLog {
    param([string]$Message)
    try {
        $log = Join-Path ([System.IO.Path]::GetTempPath()) 'promptparle-debug.log'
        $line = '{0} {1}' -f (Get-Date).ToString('o'), $Message
        [System.IO.File]::AppendAllText($log, $line + [Environment]::NewLine)
    } catch { }
}

function Test-PromptParlePathEqual {
    param($A, $B)
    # Normalize trailing slashes via Get-PromptParleTrimPath (PS 5.1-safe)
    $a = Get-PromptParleTrimPath -Path $A
    $b = Get-PromptParleTrimPath -Path $B
    if ($null -eq $a) { $a = '' }
    if ($null -eq $b) { $b = '' }
    return [string]::Equals([string]$a, [string]$b, [StringComparison]::OrdinalIgnoreCase)
}

function Test-PromptParlePathStartsWith {
    param($Path, $Prefix)
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
        [Parameter(Mandatory)]$Path,
        [switch]$DirectoryOnly
    )
    $raw = (ConvertTo-PromptParleSingleString $Path).Trim().Trim([char]0x22).Trim([char]0x27)
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
        $Path,
        [int]$Max = 12
    )
    $pathStr = ConvertTo-PromptParleSingleString $Path
    if (-not $pathStr) { return ,([string[]]@()) }

    # Avoid List[string].Add — on PS 5.1 odd string wrappers throw "Argument types do not match"
    $acc = New-Object System.Collections.ArrayList
    [void]$acc.Add([string]$pathStr)

    $state = Get-PromptParleSessionState
    $existing = Get-PromptParleProp $state 'workspace_recent'
    if ($null -ne $existing) {
        foreach ($item in @($existing)) {
            $s = ConvertTo-PromptParleSingleString $item
            if (-not $s) { continue }
            if (Test-PromptParlePathEqual -A $s -B $pathStr) { continue }
            if (Test-Path -LiteralPath $s -PathType Container) {
                [void]$acc.Add([string]$s)
            }
        }
    }
    while ($acc.Count -gt $Max) { $acc.RemoveAt($acc.Count - 1) }
    # Force array (never unwrap single element to bare string)
    return ,([string[]]@($acc.ToArray()))
}

function Set-PromptParleWorkspace {
    <#
    .SYNOPSIS
      Attach a local folder as a coding workspace connection.
      Mode add (default): append up to max locals. Mode replace: single active local only.
      Path stays on this PC; never uploaded to PromptParle cloud.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Path,
        [ValidateSet('add', 'replace')]
        [string]$Mode = 'add',
        [string]$Label = '',
        [string]$Id = ''
    )
    $stage = 'init'
    $pathIn = ConvertTo-PromptParleSingleString $Path
    try {
        $stage = 'resolve'
        $resolved = Resolve-PromptParleExistingPath -Path $pathIn -DirectoryOnly
        $resolved = ConvertTo-PromptParleSingleString $resolved
        if (-not $resolved) { throw 'Resolved path is empty' }

        $stage = 'git-check'
        $wkind = if (Test-PromptParlePathIsGitRepo -Path $resolved) { 'git' } else { 'local' }

        $stage = 'recent'
        $recent = @()
        try {
            $recent = @([string[]]@(Add-PromptParleWorkspaceRecent -Path $resolved))
        } catch {
            $recent = @([string]$resolved)
        }

        $stage = 'connections-load'
        $list = @()
        try {
            $list = @(Get-PromptParleConnections)
        } catch {
            Write-PromptParleDebugLog ("Set-PromptParleWorkspace connections-load: " + $_.Exception.ToString())
            $list = @()
        }

        $stage = 'normalize'
        $norm = Get-PromptParleTrimPath -Path $resolved

        if ($Mode -eq 'replace') {
            $list = @($list | Where-Object { $_.kind -ne 'local' })
        } else {
            # Dedupe same path
            foreach ($c in $list) {
                if ($c.kind -eq 'local' -and $c.path -and (Test-PromptParlePathEqual -A $c.path -B $norm)) {
                    $c.active = $true
                    foreach ($o in $list) {
                        if ($o.kind -eq 'local' -and $o.id -ne $c.id) { $o.active = $false }
                    }
                    if ($Label) { $c.label = (ConvertTo-PromptParleSingleString $Label).Trim() }
                    $stage = 'save-existing'
                    $null = Save-PromptParleConnectionsState -Connections $list -WorkspaceRecent $recent
                    try { Update-PromptParleConnectionCatalog -Connection $c | Out-Null } catch { }
                    return [pscustomobject]@{
                        path        = $resolved
                        kind        = $wkind
                        is_git      = [bool]($wkind -eq 'git')
                        recent      = $recent
                        id          = $c.id
                        label       = $c.label
                        connections = @(Get-PromptParleConnections)
                        mode        = 'existing'
                    }
                }
            }
            $localCount = @($list | Where-Object { $_.kind -eq 'local' }).Count
            if ($localCount -ge $script:PromptParleMaxLocalConnections) {
                throw "Local folder limit is $($script:PromptParleMaxLocalConnections). Detach one before adding another."
            }
        }

        $stage = 'new-row'
        $labIn = (ConvertTo-PromptParleSingleString $Label).Trim()
        $leaf = if ($labIn) { $labIn } else { Split-Path -Leaf $resolved }
        if (-not $leaf) { $leaf = 'This PC' }
        $newId = if ($Id) { ConvertTo-PromptParleSingleString $Id } else { New-PromptParleConnectionId -Prefix 'pc' }
        # New local becomes active
        foreach ($c in $list) {
            if ($c.kind -eq 'local') { $c.active = $false }
        }
        $row = [pscustomobject]@{
            id         = $newId
            kind       = 'local'
            label      = $leaf
            path       = $resolved
            active     = $true
            readonly   = $false
            source     = 'local'
            ssh_target = ''
            ssh_port   = 22
            ssh_cwd    = ''
            ssh_name   = ''
            catalog_id = $newId
            indexed_at = ''
            file_count = 0
        }
        $list = @($list) + @($row)

        $stage = 'save-new'
        $null = Save-PromptParleConnectionsState -Connections $list -WorkspaceRecent $recent

        $stage = 'catalog'
        $idx = $null
        try { $idx = Update-PromptParleConnectionCatalog -Connection $row } catch { $idx = $null }
        if ($idx) {
            $row.indexed_at = [string](Get-PromptParleProp $idx 'indexed_at' '')
            $row.file_count = ConvertTo-PromptParleInt32 -Value (Get-PromptParleProp $idx 'file_count' 0) -Default 0
            $list2 = @(Get-PromptParleConnections)
            foreach ($c in $list2) {
                if ($c.id -eq $row.id) {
                    $c.indexed_at = $row.indexed_at
                    $c.file_count = $row.file_count
                }
            }
            $stage = 'save-indexed'
            $null = Save-PromptParleConnectionsState -Connections $list2 -WorkspaceRecent $recent
        }
        return [pscustomobject]@{
            path        = $resolved
            kind        = $wkind
            is_git      = [bool]($wkind -eq 'git')
            recent      = $recent
            id          = $newId
            label       = $leaf
            connections = @(Get-PromptParleConnections)
            mode        = $Mode
            file_count  = if ($idx) { ConvertTo-PromptParleInt32 -Value (Get-PromptParleProp $idx 'file_count' 0) -Default 0 } else { 0 }
        }
    } catch {
        $ver = 'unknown'
        try { $ver = Get-PromptParleClientVersion } catch { }
        $msg = $_.Exception.Message
        if (-not $msg) { $msg = "$_" }
        $etype = $_.Exception.GetType().FullName
        Write-PromptParleDebugLog ("Set-PromptParleWorkspace FAIL v$ver stage=$stage path=$pathIn type=$etype msg=$msg stack=$($_.ScriptStackTrace)")
        throw ("Attach folder failed [v{0}] ({1}) at {2}: {3}: {4}" -f $ver, $pathIn, $stage, $etype, $msg)
    }
}

function Clear-PromptParleWorkspace {
    param(
        [string]$Id = '',
        [switch]$All
    )
    $list = @(Get-PromptParleConnections)
    if ($Id) {
        $list = @($list | Where-Object { $_.id -ne $Id })
    } elseif ($All -or -not $Id) {
        # Default: clear all locals (legacy clear)
        $list = @($list | Where-Object { $_.kind -ne 'local' })
    }
    # Ensure one active local if any remain
    $locals = @($list | Where-Object { $_.kind -eq 'local' })
    if ($locals.Count -gt 0 -and -not ($locals | Where-Object { $_.active })) {
        $locals[0].active = $true
    }
    $null = Save-PromptParleConnectionsState -Connections $list
}

function Set-PromptParleActiveLocalConnection {
    param([Parameter(Mandatory)][string]$IdOrLabel)
    $key = $IdOrLabel.Trim()
    $list = @(Get-PromptParleConnections)
    $hit = $null
    foreach ($c in $list) {
        if ($c.kind -ne 'local') { continue }
        if ($c.id -eq $key -or ($c.label -and $c.label.Equals($key, [StringComparison]::OrdinalIgnoreCase))) {
            $hit = $c; break
        }
    }
    if (-not $hit) { throw "Local connection not found: $IdOrLabel" }
    foreach ($c in $list) {
        if ($c.kind -eq 'local') { $c.active = ($c.id -eq $hit.id) }
    }
    $null = Save-PromptParleConnectionsState -Connections $list
    return $hit
}

function Add-PromptParleKnowledgeConnection {
    <#
    .SYNOPSIS
      Attach a read-only knowledge root (local folder or SSH docs cwd). Indexes on disk; not dumped into prompts.
    #>
    [CmdletBinding()]
    param(
        [string]$Path = '',
        [string]$Label = '',
        [ValidateSet('local', 'ssh')]
        [string]$Source = 'local',
        [string]$SshTarget = '',
        [int]$SshPort = 22,
        [string]$SshCwd = '',
        [string]$SshName = ''
    )
    $list = @(Get-PromptParleConnections)
    $kCount = @($list | Where-Object { $_.kind -eq 'knowledge' }).Count
    if ($kCount -ge $script:PromptParleMaxKnowledgeConnections) {
        throw "Knowledge repo limit is $($script:PromptParleMaxKnowledgeConnections). Detach one first."
    }
    $resolved = ''
    if ($Source -eq 'local') {
        if (-not $Path) { throw 'Knowledge local path required.' }
        $resolved = Resolve-PromptParleExistingPath -Path (ConvertTo-PromptParleSingleString $Path) -DirectoryOnly
        $norm = Get-PromptParleTrimPath -Path $resolved
        foreach ($c in $list) {
            if ($c.kind -eq 'knowledge' -and $c.source -eq 'local' -and $c.path -and (Test-PromptParlePathEqual -A $c.path -B $norm)) {
                throw "Knowledge folder already attached: $($c.label)"
            }
        }
    } else {
        if (-not $SshTarget) { throw 'SSH knowledge requires host (user@host).' }
        $SshTarget = $SshTarget.Trim()
    }
    $leaf = if ($Label -and $Label.Trim()) { $Label.Trim() } elseif ($resolved) { Split-Path -Leaf $resolved } elseif ($SshName) { $SshName } else { 'Knowledge' }
    $newId = New-PromptParleConnectionId -Prefix 'kn'
    $row = [pscustomobject]@{
        id         = $newId
        kind       = 'knowledge'
        label      = $leaf
        path       = $resolved
        active     = $false
        readonly   = $true
        source     = $Source
        ssh_target = if ($Source -eq 'ssh') { $SshTarget } else { '' }
        ssh_port   = if ($Source -eq 'ssh') { $SshPort } else { 22 }
        ssh_cwd    = if ($Source -eq 'ssh') { $SshCwd } else { '' }
        ssh_name   = if ($Source -eq 'ssh') { $SshName } else { '' }
        catalog_id = $newId
        indexed_at = ''
        file_count = 0
    }
    $list = @($list) + @($row)
    $null = Save-PromptParleConnectionsState -Connections $list
    $idx = $null
    try { $idx = Update-PromptParleConnectionCatalog -Connection $row } catch { $idx = $null }
    if ($idx) {
        $list2 = @(Get-PromptParleConnections)
        foreach ($c in $list2) {
            if ($c.id -eq $newId) {
                $c.indexed_at = [string]$idx.indexed_at
                $c.file_count = [int]$idx.file_count
            }
        }
        $null = Save-PromptParleConnectionsState -Connections $list2
    }
    return [pscustomobject]@{
        id         = $newId
        label      = $leaf
        path       = $resolved
        source     = $Source
        file_count = if ($idx) { [int]$idx.file_count } else { 0 }
        connections = @(Get-PromptParleConnections)
    }
}

function Remove-PromptParleConnection {
    param([Parameter(Mandatory)][string]$Id)
    $list = @(Get-PromptParleConnections)
    $before = $list.Count
    $list = @($list | Where-Object { $_.id -ne $Id })
    if ($list.Count -eq $before) { throw "Connection not found: $Id" }
    $locals = @($list | Where-Object { $_.kind -eq 'local' })
    if ($locals.Count -gt 0 -and -not ($locals | Where-Object { $_.active })) {
        $locals[0].active = $true
    }
    $null = Save-PromptParleConnectionsState -Connections $list
    try {
        $cat = Get-PromptParleCatalogDir
        $meta = Join-Path $cat ("conn_{0}.json" -f $Id)
        $idx = Join-Path $cat ("conn_{0}.idx.jsonl" -f $Id)
        if (Test-Path -LiteralPath $meta) { Remove-Item -LiteralPath $meta -Force -ErrorAction SilentlyContinue }
        if (Test-Path -LiteralPath $idx) { Remove-Item -LiteralPath $idx -Force -ErrorAction SilentlyContinue }
    } catch { }
    return @(Get-PromptParleConnections)
}

function Update-PromptParleConnectionCatalog {
    <#
    .SYNOPSIS
      Build on-disk structure index for a connection (no model, no prompt tokens).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Connection,
        [int]$MaxFiles = 0
    )
    if ($MaxFiles -le 0) { $MaxFiles = $script:PromptParleCatalogMaxFiles }
    $c = ConvertTo-PromptParleConnectionObject -Item $Connection
    if (-not $c) { throw 'Invalid connection' }
    $catDir = Get-PromptParleCatalogDir
    $cid = if ($c.catalog_id) { $c.catalog_id } else { $c.id }
    $metaPath = Join-Path $catDir ("conn_{0}.json" -f $cid)
    $idxPath = Join-Path $catDir ("conn_{0}.idx.jsonl" -f $cid)
    $skip = @($script:PromptParleSkipDirNames)
    # ArrayList — avoid List[string].Add type mismatches on Windows PS 5.1
    $entries = New-Object System.Collections.ArrayList
    $extCount = @{}
    $topDirs = @{}
    $fileCount = 0
    $sample = New-Object System.Collections.ArrayList

    if ($c.kind -eq 'knowledge' -and $c.source -eq 'ssh') {
        # Lightweight remote listing under ssh cwd (names only)
        try {
            $remote = if ($c.ssh_cwd) { $c.ssh_cwd } else { '.' }
            $cmd = "find $(if ($c.ssh_cwd) { [string][char]39 + $c.ssh_cwd.Replace([string][char]39, '') + [string][char]39 } else { '.' }) -maxdepth 3 -type f 2>/dev/null | head -n $MaxFiles"
            $r = Invoke-PromptParleSsh -RemoteCommand $cmd -Target $c.ssh_target -Port $c.ssh_port -SkipSessionCwd
            $lines = @([string]$r.text -split "`n")
            foreach ($ln in $lines) {
                $rel = $ln.Trim()
                if (-not $rel) { continue }
                $fileCount++
                $ext = [IO.Path]::GetExtension($rel).ToLowerInvariant()
                if (-not $ext) { $ext = '(none)' }
                if (-not $extCount.ContainsKey($ext)) { $extCount[$ext] = 0 }
                $extCount[$ext]++
                $name = Split-Path -Leaf $rel
                [void]$entries.Add([string](@{ p = $rel; e = $ext; n = $name } | ConvertTo-Json -Compress))
                if ($sample.Count -lt 12) { [void]$sample.Add([string]$rel) }
            }
        } catch {
            # leave empty index
        }
    } elseif ($c.path -and (Test-Path -LiteralPath $c.path -PathType Container)) {
        $root = $c.path
        $rootLen = $root.Length
        Get-ChildItem -LiteralPath $root -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object {
                $rel = $_.FullName.Substring($rootLen).TrimStart([char]0x5C, [char]0x2F)
                $skipHit = $false
                foreach ($d in $skip) {
                    if ($rel -match [regex]::Escape($d + [IO.Path]::DirectorySeparatorChar) -or
                        $rel -match ('(?i)(^|[/\\])' + [regex]::Escape($d) + '([/\\]|$)')) {
                        $skipHit = $true; break
                    }
                }
                -not $skipHit
            } |
            Select-Object -First $MaxFiles |
            ForEach-Object {
                $fileCount++
                $rel = $_.FullName.Substring($rootLen).TrimStart([char]0x5C, [char]0x2F).Replace('\', '/')
                $ext = if ($_.Extension) { $_.Extension.ToLowerInvariant() } else { '(none)' }
                if (-not $extCount.ContainsKey($ext)) { $extCount[$ext] = 0 }
                $extCount[$ext]++
                $parts = $rel -split '/'
                if ($parts.Count -gt 1) {
                    $td = $parts[0]
                    if (-not $topDirs.ContainsKey($td)) { $topDirs[$td] = 0 }
                    $topDirs[$td]++
                }
                $title = ''
                # Cheap title for knowledge markdown
                if ($c.kind -eq 'knowledge' -and $ext -in @('.md', '.txt', '.rst')) {
                    try {
                        $head = Get-Content -LiteralPath $_.FullName -TotalCount 8 -ErrorAction SilentlyContinue
                        foreach ($h in @($head)) {
                            if ($h -match '^\s*#\s+(.+)$') { $title = $Matches[1].Trim(); break }
                            if ($h -and $h.Trim() -and $h.Length -lt 120) { $title = $h.Trim(); break }
                        }
                    } catch { }
                }
                $obj = [ordered]@{
                    p = $rel
                    e = $ext
                    b = [long]$_.Length
                    n = $_.Name
                }
                if ($title) { $obj.t = $title }
                [void]$entries.Add([string]($obj | ConvertTo-Json -Compress))
                if ($sample.Count -lt 12) { [void]$sample.Add([string]$rel) }
            }
    }

    $extParts = @()
    foreach ($k in ($extCount.Keys | Sort-Object { -$extCount[$_] } | Select-Object -First 12)) {
        $extParts += ('{0}:{1}' -f $k, $extCount[$k])
    }
    $topList = @($topDirs.Keys | Sort-Object { -$topDirs[$_] } | Select-Object -First 10)
    $now = (Get-Date).ToString('o')
    $meta = [ordered]@{
        id         = $c.id
        catalog_id = $cid
        kind       = $c.kind
        label      = $c.label
        path       = $c.path
        source     = $c.source
        file_count = $fileCount
        top_dirs   = $topList
        ext_counts = ($extParts -join ' ')
        samples    = @($sample)
        indexed_at = $now
    }
    ($meta | ConvertTo-Json -Depth 4) | Set-Content -LiteralPath $metaPath -Encoding UTF8
    if ($entries.Count -gt 0) {
        ($entries -join "`n") | Set-Content -LiteralPath $idxPath -Encoding UTF8
    } else {
        '' | Set-Content -LiteralPath $idxPath -Encoding UTF8
    }
    return [pscustomobject]@{
        catalog_id = $cid
        file_count = $fileCount
        indexed_at = $now
        meta_path  = $metaPath
    }
}

function Get-PromptParleConnectionCatalogMeta {
    param([Parameter(Mandatory)][string]$Id)
    $path = Join-Path (Get-PromptParleCatalogDir) ("conn_{0}.json" -f $Id)
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try {
        return (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json)
    } catch { return $null }
}

function Search-PromptParleKnowledgeCatalog {
    <#
    .SYNOPSIS
      Keyword search over knowledge indexes only (paths/titles). Bodies loaded only via Read.
    #>
    param(
        [Parameter(Mandatory)][string]$Query,
        [int]$MaxHits = 12,
        [int]$MaxChars = 1800
    )
    $q = $Query.Trim()
    if (-not $q) { return 'know_search: empty query' }
    $tokens = @($q.ToLowerInvariant() -split '\s+' | Where-Object { $_.Length -gt 1 } | Select-Object -First 8)
    if ($tokens.Count -eq 0) { $tokens = @($q.ToLowerInvariant()) }
    $hits = New-Object System.Collections.Generic.List[string]
    $used = 0
    foreach ($c in @(Get-PromptParleConnections | Where-Object { $_.kind -eq 'knowledge' })) {
        $cid = if ($c.catalog_id) { $c.catalog_id } else { $c.id }
        $idxPath = Join-Path (Get-PromptParleCatalogDir) ("conn_{0}.idx.jsonl" -f $cid)
        if (-not (Test-Path -LiteralPath $idxPath)) {
            try { Update-PromptParleConnectionCatalog -Connection $c | Out-Null } catch { }
        }
        if (-not (Test-Path -LiteralPath $idxPath)) { continue }
        $lines = Get-Content -LiteralPath $idxPath -ErrorAction SilentlyContinue
        foreach ($ln in @($lines)) {
            if (-not $ln) { continue }
            $low = $ln.ToLowerInvariant()
            $score = 0
            foreach ($t in $tokens) {
                if ($low.Contains($t)) { $score++ }
            }
            if ($score -le 0) { continue }
            try {
                $obj = $ln | ConvertFrom-Json
                $p = [string](Get-PromptParleProp $obj 'p' '')
                $title = [string](Get-PromptParleProp $obj 't' '')
                $line = "KNOW[$($c.label)] $p"
                if ($title) { $line += " — $title" }
                $line += " (score $score)"
                if (($used + $line.Length) -gt $MaxChars -and $hits.Count -gt 0) { break }
                [void]$hits.Add($line)
                $used += $line.Length + 1
                if ($hits.Count -ge $MaxHits) { break }
            } catch { }
        }
        if ($hits.Count -ge $MaxHits) { break }
    }
    if ($hits.Count -eq 0) {
        return "know_search: no hits for '$q' (knowledge indexes only; use know_read path after a hit)."
    }
    return "know_search '$q' (paths only — call know_read for text):`n" + ($hits -join "`n")
}

function Read-PromptParleKnowledgeFile {
    param(
        [Parameter(Mandatory)][string]$PathOrRel,
        [string]$ConnectionId = '',
        [int]$MaxChars = 8000
    )
    $want = $PathOrRel.Trim().Trim('"').Trim("'")
    $targets = @(Get-PromptParleConnections | Where-Object { $_.kind -eq 'knowledge' })
    if ($ConnectionId) {
        $targets = @($targets | Where-Object { $_.id -eq $ConnectionId -or $_.label -eq $ConnectionId })
    }
    foreach ($c in $targets) {
        if ($c.source -eq 'ssh') {
            try {
                $r = Invoke-PromptParleSsh -RemoteCommand ("head -c $MaxChars -- " + $want.Replace("'", '')) -Target $c.ssh_target -Port $c.ssh_port -WorkingDirectory $c.ssh_cwd
                if ($r.exit_code -eq 0 -and $r.text) {
                    $body = [string]$r.text
                    if ($body.Length -gt $MaxChars) { $body = $body.Substring(0, $MaxChars) + "`n…[know]" }
                    return "[KNOW $($c.label)] $want`n$body"
                }
            } catch { }
            continue
        }
        if (-not $c.path) { continue }
        $full = $want
        if (-not [IO.Path]::IsPathRooted($want)) {
            $full = Join-Path $c.path ($want -replace '/', [IO.Path]::DirectorySeparatorChar)
        }
        # Stay under knowledge root
        try {
            $fullRes = (Resolve-Path -LiteralPath $full -ErrorAction Stop).Path
            $rootRes = (Resolve-Path -LiteralPath $c.path -ErrorAction Stop).Path
            if (-not $fullRes.StartsWith($rootRes, [StringComparison]::OrdinalIgnoreCase)) { continue }
            if (-not (Test-Path -LiteralPath $fullRes -PathType Leaf)) { continue }
            $raw = Get-Content -LiteralPath $fullRes -Raw -ErrorAction Stop
            if ($raw.Length -gt $MaxChars) { $raw = $raw.Substring(0, $MaxChars) + "`n…[know]" }
            $rel = $fullRes.Substring($rootRes.Length).TrimStart([char]0x5C, [char]0x2F)
            return "[KNOW $($c.label)] $rel`n$raw"
        } catch { }
    }
    return "know_read: not found under knowledge roots: $want"
}

function Get-PromptParleConnectionIndexText {
    param([string]$IdOrLabel = '')
    $list = @(Get-PromptParleConnections)
    $c = $null
    if ($IdOrLabel) {
        foreach ($x in $list) {
            if ($x.id -eq $IdOrLabel -or ($x.label -and $x.label.Equals($IdOrLabel, [StringComparison]::OrdinalIgnoreCase))) {
                $c = $x; break
            }
        }
    } else {
        $c = Get-PromptParleActiveLocalConnection
    }
    if (-not $c) { return 'conn_index: no connection matched.' }
    $cid = if ($c.catalog_id) { $c.catalog_id } else { $c.id }
    $meta = Get-PromptParleConnectionCatalogMeta -Id $cid
    if (-not $meta) {
        try { Update-PromptParleConnectionCatalog -Connection $c | Out-Null } catch { }
        $meta = Get-PromptParleConnectionCatalogMeta -Id $cid
    }
    if (-not $meta) { return "conn_index: $($c.label) — no catalog yet." }
    $lines = @(
        "conn_index: $($c.label) [$($c.kind)]",
        "files: $($meta.file_count)",
        "top: $([string]($meta.top_dirs -join ', '))",
        "ext: $([string]$meta.ext_counts)",
        "sample: $((@($meta.samples) | Select-Object -First 8) -join ' · ')"
    )
    return ($lines -join "`n")
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
    $conns = @()
    try { $conns = @(Ensure-PromptParleConnectionsMigrated -State $state) } catch { $conns = @() }
    return [pscustomobject]@{
        path        = $path
        kind        = $kind
        exists      = $exists
        is_git      = $isGit
        branch      = $branch
        remote      = $remote
        recent      = $recent
        ssh_target  = [string](Get-PromptParleProp $state 'ssh_target' '')
        ssh_port    = ConvertTo-PromptParleSshPort -Value (Get-PromptParleProp $state 'ssh_port' 22)
        ssh_cwd     = [string](Get-PromptParleProp $state 'ssh_cwd' '')
        ssh_name    = [string](Get-PromptParleProp $state 'ssh_name' '')
        connections = $conns
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
    $rel = (ConvertTo-PromptParleSingleString $RelativePath).Trim().TrimStart([char]0x2F, [char]0x5C)
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
        $rel = $_.FullName.Substring($wsPath.Length).TrimStart([char]0x5C, [char]0x2F)
        foreach ($s in $skip) {
            if ($rel -like "$s\*" -or $rel -like "$s/*" -or $rel -eq $s) { return $false }
        }
        if ($_.Name -eq '.env' -or $_.Name -like '.env.*') { return $false }
        return ($_.Name -like $Pattern -or $rel -like $Pattern)
    } | Select-Object -First $Max
    $wsRoot = Get-PromptParleTrimPath $wsPath
    $lines = @("Matches for '$Pattern' (max $Max):")
    foreach ($f in $files) {
        $rel = $f.FullName.Substring($wsRoot.Length).TrimStart([char]0x5C, [char]0x2F)
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
        $rel = $_.FullName.Substring($wsPath.Length).TrimStart([char]0x5C, [char]0x2F)
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
            $rel = $f.FullName.Substring($wsRoot.Length).TrimStart([char]0x5C, [char]0x2F)
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

function Get-PromptParleSshHistoryPath {
    return (Join-Path $script:PromptParleConfigDir 'ssh-history.json')
}

function ConvertTo-PromptParleSshPort {
    <# Internal: coerce port to 1–65535, default 22. Avoids try/catch inside hashtables (PS parse break). #>
    param($Value, [int]$Default = 22)
    $n = ConvertTo-PromptParleInt32 -Value $Value -Default $Default
    if ($n -lt 1 -or $n -gt 65535) { return $Default }
    return $n
}

function ConvertTo-PromptParleSshLastUsedSortKey {
    <# Internal: sortable DateTime for history last_used strings. #>
    param([string]$Value)
    if (-not $Value) { return [datetime]::MinValue }
    $dt = [datetime]::MinValue
    if ([datetime]::TryParse($Value, [ref]$dt)) { return $dt }
    return [datetime]::MinValue
}

function Get-PromptParleSshHistory {
    <#
    .SYNOPSIS
      Local SSH connection history (friendly name + target + port + cwd). Never stores passwords.
      Sorted by last_used descending (most recent first).
    #>
    [CmdletBinding()]
    param([int]$Max = 30)
    $path = Get-PromptParleSshHistoryPath
    $list = New-Object System.Collections.Generic.List[object]
    if (Test-Path -LiteralPath $path) {
        try {
            $raw = Get-Content -LiteralPath $path -Raw -ErrorAction Stop
            $arr = $raw | ConvertFrom-Json
            foreach ($item in @($arr)) {
                if (-not $item) { continue }
                $tgt = [string](Get-PromptParleProp $item 'target' '')
                if (-not $tgt) { continue }
                # Never accept password-like fields even if older files had them.
                # Build properties with plain assignments (no try/catch inside @{ } — PS 5.1 parse error).
                $portN = ConvertTo-PromptParleSshPort -Value (Get-PromptParleProp $item 'port' 22)
                $row = [pscustomobject]@{
                    name      = [string](Get-PromptParleProp $item 'name' '')
                    target    = $tgt
                    port      = $portN
                    cwd       = [string](Get-PromptParleProp $item 'cwd' '')
                    last_used = [string](Get-PromptParleProp $item 'last_used' '')
                }
                [void]$list.Add($row)
            }
        } catch { }
    }
    $sorted = @(
        $list | Sort-Object { ConvertTo-PromptParleSshLastUsedSortKey -Value $_.last_used } -Descending
    )
    if ($Max -gt 0 -and $sorted.Count -gt $Max) {
        $sorted = $sorted | Select-Object -First $Max
    }
    return @($sorted)
}

function Save-PromptParleSshHistoryEntry {
    <#
    .SYNOPSIS
      Upsert a history entry (no passwords). Keyed by target+port.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Target,
        [int]$Port = 22,
        [string]$WorkingDirectory = '',
        [string]$Name = ''
    )
    $t = $Target.Trim()
    if (-not $t) { return }
    if ($Port -le 0) { $Port = 22 }
    $cwd = if ($null -eq $WorkingDirectory) { '' } else { $WorkingDirectory.Trim() }
    $nm = if ($null -eq $Name) { '' } else { $Name.Trim() }
    $now = (Get-Date).ToString('o')
    $existing = @(Get-PromptParleSshHistory -Max 100)
    $out = New-Object System.Collections.Generic.List[object]
    $found = $false
    foreach ($e in $existing) {
        $ep = ConvertTo-PromptParleSshPort -Value $e.port
        if ([string]$e.target -eq $t -and $ep -eq $Port) {
            $found = $true
            $keepName = if ($nm) { $nm } else { [string]$e.name }
            $row = [pscustomobject]@{
                name      = $keepName
                target    = $t
                port      = $Port
                cwd       = $cwd
                last_used = $now
            }
            [void]$out.Add($row)
        } else {
            # Drop any accidental secret-like keys by re-projecting
            $row = [pscustomobject]@{
                name      = [string]$e.name
                target    = [string]$e.target
                port      = $ep
                cwd       = [string]$e.cwd
                last_used = [string]$e.last_used
            }
            [void]$out.Add($row)
        }
    }
    if (-not $found) {
        $rowNew = [pscustomobject]@{
            name      = $nm
            target    = $t
            port      = $Port
            cwd       = $cwd
            last_used = $now
        }
        $out.Insert(0, $rowNew)
    }
    # Cap + re-sort by last_used
    $sorted = @(
        $out | Sort-Object { ConvertTo-PromptParleSshLastUsedSortKey -Value $_.last_used } -Descending |
            Select-Object -First 30
    )
    $path = Get-PromptParleSshHistoryPath
    $dir = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    # Explicit shape only — never password/key fields
    $clean = @()
    foreach ($e in $sorted) {
        $clean += [ordered]@{
            name      = [string]$e.name
            target    = [string]$e.target
            port      = [int](ConvertTo-PromptParleSshPort -Value $e.port)
            cwd       = [string]$e.cwd
            last_used = [string]$e.last_used
        }
    }
    ($clean | ConvertTo-Json -Depth 4) | Set-Content -LiteralPath $path -Encoding UTF8
}

function Set-PromptParleSshTarget {
    param(
        [Parameter(Mandatory)]$Target,
        $Port = 22,
        $WorkingDirectory = '',
        # Friendly display name (shown in sidebar; host stays hidden)
        $Name = '',
        # Validate remote cwd exists (default true when path provided)
        [bool]$ValidateCwd = $true,
        # When false, do not touch ssh_name (e.g. cwd-only edit)
        [bool]$UpdateName = $true
    )
    $stage = 'coerce'
    try {
    # Coerce all inputs — history / JSON / UI can hand non-string types (PS 5.1 "Argument types do not match")
    $t = (ConvertTo-PromptParleSingleString $Target).Trim()
    if ($t -match '^ssh\s+(.+)$') { $t = $Matches[1].Trim() }
    # user@host[:port]
    $port = ConvertTo-PromptParleSshPort -Value $Port
    if ($t -match '^(.+):(\d+)$') {
        $t = $Matches[1]
        $port = ConvertTo-PromptParleSshPort -Value $Matches[2]
    }
    if ($t -notmatch '@' -and $t -notmatch '^[A-Za-z0-9._-]+$') {
        throw 'SSH target should look like user@host (or host).'
    }
    $cwd = (ConvertTo-PromptParleSingleString $WorkingDirectory).Trim()
    if ($cwd -and $ValidateCwd) {
        $stage = 'validate-cwd'
        $check = Test-PromptParleSshWorkingDirectory -Path $cwd -Target $t -Port $port
        if (-not $check.ok) {
            throw (ConvertTo-PromptParleSingleString $check.error)
        }
        if ($check.resolved) { $cwd = (ConvertTo-PromptParleSingleString $check.resolved).Trim() }
    }
    $stage = 'session-load'
    $state = Get-PromptParleSessionState
    $nm = (ConvertTo-PromptParleSingleString $Name).Trim()
    # Reject path/host-shaped "names" so the sidebar never regains directory leaks
    # Also reject quote-glued garbage from the old /ssh name parse bug (SSH connection"ubuntu@…)
    $isBadSshName = {
        param([string]$Label, [string]$TargetHost)
        if (-not $Label) { return $true }
        $s = $Label.Trim()
        if (-not $s) { return $true }
        if ($TargetHost -and $s.Equals($TargetHost, [StringComparison]::OrdinalIgnoreCase)) { return $true }
        if ($s -match '["'']') { return $true }
        if ($s -match '[@/\\]' -or $s -match '^[~\/]' -or $s -match '^[A-Za-z]:[\\/]') { return $true }
        if ($s -match ':\d{2,5}\b' -or $s -match '\s·\s') { return $true }
        if ($s -match '(?i)\.compute\.|amazonaws\.com|ec2-') { return $true }
        return $false
    }
    if ($UpdateName) {
        # Keep prior/history name only for the same host (never invent a host leak as the label)
        if (-not $nm -or (& $isBadSshName $nm $t)) {
            $nm = ''
            $prevT = [string](Get-PromptParleProp $state 'ssh_target' '')
            $prevP = ConvertTo-PromptParleSshPort -Value (Get-PromptParleProp $state 'ssh_port' 22)
            if ($prevT -eq $t -and $prevP -eq $port) {
                $cand = [string](Get-PromptParleProp $state 'ssh_name' '')
                if ($cand -and -not (& $isBadSshName $cand $t)) { $nm = $cand }
            }
            if (-not $nm) {
                try {
                    foreach ($h in @(Get-PromptParleSshHistory -Max 30)) {
                        $hp = ConvertTo-PromptParleSshPort -Value $h.port
                        $hn = [string]$h.name
                        if ([string]$h.target -eq $t -and $hp -eq $port -and $hn -and -not (& $isBadSshName $hn $t)) {
                            $nm = $hn
                            break
                        }
                    }
                } catch { }
            }
        }
        if ($nm.Length -gt 64) { $nm = $nm.Substring(0, 64) }
        $stage = 'snapshot-name'
        $state = New-PromptParleSessionSnapshot -Base $state -SshTarget $t -SshPort $port -SshCwd $cwd -SshName $nm
    } else {
        $nm = [string](Get-PromptParleProp $state 'ssh_name' '')
        if (& $isBadSshName $nm $t) { $nm = '' }
        $stage = 'snapshot-cwd'
        $state = New-PromptParleSessionSnapshot -Base $state -SshTarget $t -SshPort $port -SshCwd $cwd -SshName $nm
    }
    $stage = 'save-session'
    Save-PromptParleSessionState -State $state
    try {
        $stage = 'save-history'
        Save-PromptParleSshHistoryEntry -Target $t -Port $port -WorkingDirectory $cwd -Name $nm
    } catch { }
    return [pscustomobject]@{ target = $t; port = $port; cwd = $cwd; name = $nm }
    } catch {
        $ver = 'unknown'
        try { $ver = Get-PromptParleClientVersion } catch { }
        $msg = $_.Exception.Message
        if (-not $msg) { $msg = "$_" }
        $etype = $_.Exception.GetType().FullName
        Write-PromptParleDebugLog ("Set-PromptParleSshTarget FAIL v$ver stage=$stage type=$etype msg=$msg stack=$($_.ScriptStackTrace)")
        throw ("SSH set target failed [v{0}] at {1}: {2}: {3}" -f $ver, $stage, $etype, $msg)
    }
}

function Clear-PromptParleSshTarget {
    $state = Get-PromptParleSessionState
    $state = New-PromptParleSessionSnapshot -Base $state -SshTarget '' -SshPort 22 -SshCwd '' -SshName ''
    Save-PromptParleSessionState -State $state
}

function Invoke-PromptParleSsh {
    param(
        [Parameter(Mandatory)]$RemoteCommand,
        $Target,
        $Port = 0,
        $WorkingDirectory = '',
        [int]$TimeoutSec = 45,
        # When false, do not prepend session ssh_cwd (used for path checks themselves)
        [switch]$SkipSessionCwd
    )
    if (-not (Test-PromptParleCommandAvailable -Name 'ssh')) {
        throw 'ssh not found. On Windows install OpenSSH Client (Optional Features) or Git for Windows.'
    }
    $RemoteCommand = ConvertTo-PromptParleSingleString $RemoteCommand
    $Target = ConvertTo-PromptParleSingleString $Target
    $Port = ConvertTo-PromptParleInt32 -Value $Port -Default 0
    $cwd = ConvertTo-PromptParleSingleString $WorkingDirectory
    if (-not $Target) {
        $ws = Get-PromptParleWorkspace
        $Target = ConvertTo-PromptParleSingleString $ws.ssh_target
        if ($Port -le 0) { $Port = ConvertTo-PromptParleSshPort -Value $ws.ssh_port }
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

    # Nothing landed AND nothing to report → leave the text untouched.
    if ($delivered.Count -eq 0 -and $errors.Count -eq 0) {
        return [pscustomobject]@{ text = $text; exports = @(); count = 0; errors = @() }
    }

    $hdr = New-Object System.Collections.Generic.List[string]
    # ONLY claim "Downloads ready" + emit download links when a file was actually
    # written. If delivery failed (empty/unsupported/oversized block), a header +
    # "click to download" would point at a token that was never registered → the
    # browser gets a 404 "file wasn't available on site" and the user is told a
    # file exists that does not. Surface the failure instead.
    if ($delivered.Count -gt 0) {
        $hdr.Add('## Downloads ready')
        $hdr.Add('_Client built real files from ```file name=…``` blocks — click to download._')
        $hdr.Add('')
        foreach ($d in $delivered) {
            $kb = [Math]::Max(1, [int][Math]::Ceiling($d.bytes / 1024.0))
            $hdr.Add(("- **[{0}]({1})** · {2} KB · ``{3}``" -f $d.name, $d.download_url, $kb, $d.content_type))
        }
        if ($errors.Count -gt 0) {
            $hdr.Add('')
            $hdr.Add('**Some deliverables failed:**')
            foreach ($e in $errors) { $hdr.Add("- $e") }
        }
    } else {
        # No file was created — do NOT show a download link. Report why.
        $hdr.Add('## Deliverable not created')
        $hdr.Add('_No file was written (the ```file``` block was empty, unsupported, or too large). Nothing to download._')
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
  /model [id]           Preferred model for current provider (UI)
  /mode terminal|chat   Terminal AI layout vs bubble chat (local UI)
  /optimize             Toggle optimize-only (no model call — debug shrink)
  /usage                Cloud token savings summary
  /clear                Clear chat (UI) / screen (CLI)
  /quit                 Stop (CLI)

  Tip: In the local UI, type / to open the command list (works in bubble + terminal chat).

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
                $sn = [string](Get-PromptParleProp $ws 'ssh_name' '')
                $sc = [string](Get-PromptParleProp $ws 'ssh_cwd' '')
                # Privacy: status shows friendly name only (not host/cwd)
                $s = if ($sn) { "'$sn'" } else { 'connected' }
                if ($sc) { $s = "$s · remote dir set" } else { $s = "$s · login home" }
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
                } elseif ($arg -match '^(clear|none|off|detach|clearall)$') {
                    Clear-PromptParleWorkspace -All
                    $state = Get-PromptParleSessionState
                    $message = 'All local folders detached.'
                } elseif ($arg -match '^(?i)(list|ls-conn)$') {
                    $rows = @('Local connections:')
                    foreach ($c in @(Get-PromptParleConnections | Where-Object { $_.kind -eq 'local' })) {
                        $mark = if ($c.active) { '*' } else { ' ' }
                        $rows += ("  {0} [{1}] {2}  {3}" -f $mark, $c.id, $c.label, $c.path)
                    }
                    if ($rows.Count -eq 1) { $rows += '  (none)' }
                    $message = $rows -join "`n"
                } elseif ($arg -match '^(?i)active\s+(.+)$') {
                    $hit = Set-PromptParleActiveLocalConnection -IdOrLabel $Matches[1].Trim().Trim('"').Trim("'")
                    $state = Get-PromptParleSessionState
                    $message = "Active local: $($hit.label) ($($hit.path))"
                } elseif ($arg -match '^(?i)(rm|remove)\s+(.+)$') {
                    $key = $Matches[2].Trim().Trim('"').Trim("'")
                    $rid = $null
                    foreach ($c in @(Get-PromptParleConnections | Where-Object { $_.kind -eq 'local' })) {
                        if ($c.id -eq $key -or ($c.label -and $c.label.Equals($key, [StringComparison]::OrdinalIgnoreCase))) {
                            $rid = $c.id; break
                        }
                    }
                    if (-not $rid) { throw "Local connection not found: $key" }
                    $null = Remove-PromptParleConnection -Id $rid
                    $state = Get-PromptParleSessionState
                    $message = "Detached local $key"
                } elseif ($arg -match '^(?i)add\s+(.+)$') {
                    $pathArg = $Matches[1].Trim().Trim('"').Trim("'")
                    $wsSet = Set-PromptParleWorkspace -Path $pathArg -Mode add
                    $state = Get-PromptParleSessionState
                    $message = "Added local $($wsSet.label): $($wsSet.path) (idx $($wsSet.file_count) files on disk, not in chat)"
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
                            $relName = $fp.Substring($wsP.Length).TrimStart([char]0x5C, [char]0x2F).Replace([char]0x5C, [char]0x2F)
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
                    # Treat arg as path to attach (add to multi-local list)
                    $pathArg = $arg.Trim().Trim('"').Trim("'")
                    $wsSet = Set-PromptParleWorkspace -Path $pathArg -Mode add
                    $state = Get-PromptParleSessionState
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
        '^/(know|knowledge)$' {
            try {
                if (-not $arg -or $arg -match '^(?i)list$') {
                    $rows = @('Knowledge repos (indexed on PC; not dumped into chat):')
                    foreach ($c in @(Get-PromptParleConnections | Where-Object { $_.kind -eq 'knowledge' })) {
                        $src = if ($c.source -eq 'ssh') { 'ssh' } else { 'local' }
                        $loc = if ($c.path) { $c.path } elseif ($c.ssh_name) { $c.ssh_name } else { $c.ssh_target }
                        $rows += ("  [{0}] {1} ({2}) idx={3}  {4}" -f $c.id, $c.label, $src, $c.file_count, $loc)
                    }
                    if ($rows.Count -eq 1) { $rows += '  (none — /know add C:\docs or /know ssh name "Docs" user@host /path)' }
                    $rows += '  Search: tools know_search / know_read (on demand)'
                    $message = $rows -join "`n"
                } elseif ($arg -match '^(?i)(rm|remove|detach)\s+(.+)$') {
                    $key = $Matches[2].Trim().Trim('"').Trim("'")
                    $rid = $null
                    foreach ($c in @(Get-PromptParleConnections | Where-Object { $_.kind -eq 'knowledge' })) {
                        if ($c.id -eq $key -or ($c.label -and $c.label.Equals($key, [StringComparison]::OrdinalIgnoreCase))) {
                            $rid = $c.id; break
                        }
                    }
                    if (-not $rid) { throw "Knowledge connection not found: $key" }
                    $null = Remove-PromptParleConnection -Id $rid
                    $state = Get-PromptParleSessionState
                    $message = "Knowledge detached: $key"
                } elseif ($arg -match '^(?i)reindex(?:\s+(.+))?$') {
                    $key = if ($Matches[1]) { $Matches[1].Trim().Trim('"').Trim("'") } else { '' }
                    $cHit = $null
                    foreach ($c in @(Get-PromptParleConnections | Where-Object { $_.kind -eq 'knowledge' })) {
                        if (-not $key -or $c.id -eq $key -or ($c.label -and $c.label.Equals($key, [StringComparison]::OrdinalIgnoreCase))) {
                            $cHit = $c; break
                        }
                    }
                    if (-not $cHit) { throw 'No knowledge connection to reindex' }
                    $idx = Update-PromptParleConnectionCatalog -Connection $cHit
                    $list = @(Get-PromptParleConnections)
                    foreach ($c in $list) {
                        if ($c.id -eq $cHit.id) {
                            $c.indexed_at = [string]$idx.indexed_at
                            $c.file_count = [int]$idx.file_count
                        }
                    }
                    $null = Save-PromptParleConnectionsState -Connections $list
                    $state = Get-PromptParleSessionState
                    $message = "Reindexed $($cHit.label): $($idx.file_count) files on disk"
                } elseif ($arg -match '^(?i)ssh\s+(.+)$') {
                    $rest = $Matches[1].Trim()
                    $nameArg = ''
                    if ($rest -match '^(?i)name\s+(?:"([^"]+)"|''([^'']+)''|(\S+))\s+(.+)$') {
                        $nameArg = if ($Matches[1]) { $Matches[1] } elseif ($Matches[2]) { $Matches[2] } else { $Matches[3] }
                        $rest = $Matches[4].Trim()
                    }
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
                    $added = Add-PromptParleKnowledgeConnection -Source ssh -SshTarget $targetArg -SshPort $port -SshCwd $cwdArg -SshName $nameArg -Label $nameArg
                    $state = Get-PromptParleSessionState
                    $message = "Knowledge SSH '$($added.label)' attached (idx $($added.file_count); content on demand only)"
                } elseif ($arg -match '^(?i)add\s+(.+)$') {
                    $pathArg = $Matches[1].Trim().Trim('"').Trim("'")
                    $added = Add-PromptParleKnowledgeConnection -Path $pathArg -Source local
                    $state = Get-PromptParleSessionState
                    $message = "Knowledge '$($added.label)' → $($added.path) (idx $($added.file_count) on disk; use know_search, not prompt dump)"
                } else {
                    $pathArg = $arg.Trim().Trim('"').Trim("'")
                    $added = Add-PromptParleKnowledgeConnection -Path $pathArg -Source local
                    $state = Get-PromptParleSessionState
                    $message = "Knowledge '$($added.label)' → $($added.path) (idx $($added.file_count) on disk)"
                }
            } catch {
                $message = "Knowledge error: $_"
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
                    try { $null = Set-PromptParleWorkspace -Path $cloned.path -Mode add } catch { }
                    $state = Get-PromptParleSessionState
                    $message = "Cloned $repo → $($cloned.path)`nAttached as local connection ($($cloned.kind)).`n$($cloned.log)"
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
                        $dispNm = [string](Get-PromptParleProp $ws 'ssh_name' '')
                        if (-not $dispNm) { $dispNm = 'SSH connection' }
                        $hasCwd = [bool]([string](Get-PromptParleProp $ws 'ssh_cwd' ''))
                        $cwdNote = if ($hasCwd) { 'remote directory set (hidden in sidebar)' } else { 'login home (set with /ssh cwd)' }
                        $message = @"
SSH connected as '$dispNm' · $cwdNote
Host and path stay out of the sidebar (open Connect / Dir to edit).

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
                    $state = New-PromptParleSessionSnapshot -Base $state -SshTarget '' -SshPort 22 -SshCwd '' -SshName ''
                    $message = 'SSH target cleared.'
                } elseif ($arg -match '^(?i)rename\s+(.+)$') {
                    # Rename only (not connect). UI connect uses: /ssh name "Lab" user@host [/cwd]
                    $ws = Get-PromptParleWorkspace
                    if (-not $ws.ssh_target) { throw 'No SSH target. Connect first, then /ssh rename <friendly-name>.' }
                    $newName = $Matches[1].Trim().Trim('"').Trim("'")
                    if (-not $newName) { throw 'Usage: /ssh rename <friendly-name>' }
                    if ($newName.Length -gt 64) { $newName = $newName.Substring(0, 64) }
                    $set = Set-PromptParleSshTarget -Target $ws.ssh_target -Port ([int]$ws.ssh_port) -WorkingDirectory ([string]$ws.ssh_cwd) -Name $newName -ValidateCwd $false -UpdateName $true
                    $state = New-PromptParleSessionSnapshot -Base $state -SshTarget $set.target -SshPort $set.port -SshCwd $set.cwd -SshName $set.name
                    $message = "SSH display name set to '$($set.name)' (host details stay hidden in the sidebar)."
                } elseif ($arg -match '^(?i)name\s+(?:"([^"]+)"|''([^'']+)''|(\S+))\s*$') {
                    # /ssh name "Lab box"  (no host after — rename alias)
                    $ws = Get-PromptParleWorkspace
                    if (-not $ws.ssh_target) { throw 'No SSH target. Connect first, then /ssh name <friendly-name>.' }
                    $newName = if ($Matches[1]) { [string]$Matches[1] } elseif ($Matches[2]) { [string]$Matches[2] } else { [string]$Matches[3] }
                    $newName = $newName.Trim()
                    if (-not $newName) { throw 'Usage: /ssh name <friendly-name>' }
                    if ($newName.Length -gt 64) { $newName = $newName.Substring(0, 64) }
                    $set = Set-PromptParleSshTarget -Target $ws.ssh_target -Port ([int]$ws.ssh_port) -WorkingDirectory ([string]$ws.ssh_cwd) -Name $newName -ValidateCwd $false -UpdateName $true
                    $state = New-PromptParleSessionSnapshot -Base $state -SshTarget $set.target -SshPort $set.port -SshCwd $set.cwd -SshName $set.name
                    $message = "SSH display name set to '$($set.name)' (host details stay hidden in the sidebar)."
                } elseif ($arg -match '^(cwd|cd|dir)(?:\s+(.*))?$') {
                    $ws = Get-PromptParleWorkspace
                    if (-not $ws.ssh_target) { throw 'No SSH target. /ssh user@host first.' }
                    $cwdIn = if ($null -ne $Matches[2]) { $Matches[2].Trim().Trim('"').Trim("'") } else { '' }
                    if ($cwdIn -match '^(clear|none|off)$') { $cwdIn = '' }
                    if ($cwdIn -and $cwdIn -match '[;|&`$]') { throw 'Invalid remote path' }
                    # Validates remote dir exists; stores resolved absolute path (keep friendly name)
                    $set = Set-PromptParleSshTarget -Target $ws.ssh_target -Port ([int]$ws.ssh_port) -WorkingDirectory $cwdIn -ValidateCwd $true -UpdateName $false
                    $state = New-PromptParleSessionSnapshot -Base $state -SshTarget $set.target -SshPort $set.port -SshCwd $set.cwd
                    $disp = if ($set.name) { $set.name } else { 'SSH' }
                    if ($set.cwd) {
                        $message = "SSH working directory OK for $disp."
                    } else {
                        $message = "SSH working directory cleared for $disp (login home)."
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
                    # [name <friendly>] user@host[:port] [optional remote working directory]
                    # UI sends: /ssh name "Lab box" user@host /var/www
                    $rest = $arg.Trim()
                    $nameArg = ''
                    if ($rest -match '^(?i)name\s+(?:"([^"]+)"|''([^'']+)''|(\S+))\s+(.+)$') {
                        $nameArg = if ($Matches[1]) { $Matches[1] } elseif ($Matches[2]) { $Matches[2] } else { $Matches[3] }
                        $rest = $Matches[4].Trim()
                    }
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
                    if ($nameArg -and $nameArg.Length -gt 64) { $nameArg = $nameArg.Substring(0, 64) }
                    # Save host first. If history/UI cwd is stale, still connect host and report cwd separately.
                    $targetArg = ConvertTo-PromptParleSingleString $targetArg
                    $nameArg = ConvertTo-PromptParleSingleString $nameArg
                    $cwdArg = ConvertTo-PromptParleSingleString $cwdArg
                    $port = ConvertTo-PromptParleSshPort -Value $port
                    $cwdNote = ''
                    $cwdToSave = $cwdArg
                    if ($cwdArg) {
                        try {
                            $cwdCheck = Test-PromptParleSshWorkingDirectory -Path $cwdArg -Target $targetArg -Port $port
                            if ($cwdCheck.ok) {
                                if ($cwdCheck.resolved) { $cwdToSave = (ConvertTo-PromptParleSingleString $cwdCheck.resolved).Trim() }
                            } else {
                                $cwdNote = " Working directory not applied: $(ConvertTo-PromptParleSingleString $cwdCheck.error). Use Dir to set a valid remote folder."
                                $cwdToSave = ''
                            }
                        } catch {
                            $cwdNote = " Working directory not applied: $_. Use Dir to set a valid remote folder."
                            $cwdToSave = ''
                        }
                    }
                    $set = Set-PromptParleSshTarget -Target $targetArg -Port $port -WorkingDirectory $cwdToSave -Name $nameArg -ValidateCwd $false -UpdateName $true
                    $state = New-PromptParleSessionSnapshot -Base $state -SshTarget $set.target -SshPort $set.port -SshCwd $set.cwd -SshName $set.name
                    $r = Test-PromptParleSsh -Target $set.target -Port $set.port
                    $disp = if ($set.name) { $set.name } else { 'SSH' }
                    if ($r.exit_code -eq 0) {
                        $message = "SSH connected as '$disp' (details hidden in sidebar). OK$cwdNote"
                    } else {
                        $message = @"
SSH saved as '$disp' but connectivity test failed (exit $($r.exit_code)).
Check: ssh-agent loaded? key in ~/.ssh? host allows key auth?
$cwdNote
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
    $freshPort = ConvertTo-PromptParleSshPort -Value (Get-PromptParleProp $fresh 'ssh_port' 22)
    $state = New-PromptParleSessionSnapshot -Base $state `
        -WorkspacePath ([string](Get-PromptParleProp $fresh 'workspace_path' '')) `
        -WorkspaceKind ([string](Get-PromptParleProp $fresh 'workspace_kind' 'none')) `
        -SshTarget ([string](Get-PromptParleProp $fresh 'ssh_target' '')) `
        -SshPort $freshPort `
        -SshCwd ([string](Get-PromptParleProp $fresh 'ssh_cwd' '')) `
        -SshName ([string](Get-PromptParleProp $fresh 'ssh_name' ''))

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
        ssh_port         = ConvertTo-PromptParleSshPort -Value $wsOut.ssh_port
        ssh_cwd          = [string]$wsOut.ssh_cwd
        ssh_name         = [string]$wsOut.ssh_name
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
        session = (ConvertTo-PromptParleCustomObject $sessionOut)
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

function Sync-PromptParlePortalSettings {
    <#
    .SYNOPSIS
      Pull preferred provider/model/dial/tools from the portal into local session.
      Called after install / Set-PromptParleApiKey so desktop matches portal Settings.
    #>
    [CmdletBinding()]
    param(
        [switch]$Quiet
    )
    try {
        $remote = Invoke-PromptParleApi -Method GET -Path '/api/v1/settings'
    } catch {
        if (-not $Quiet) {
            Write-Host ("Could not pull portal settings: {0}" -f $_) -ForegroundColor Yellow
        }
        return $null
    }

    $prefProvider = [string](Get-PromptParleProp $remote 'preferred_provider' '')
    $prefModels = Get-PromptParleProp $remote 'preferred_models' $null
    $dial = Get-PromptParleProp $remote 'default_dial' 3
    $tools = Get-PromptParleProp $remote 'default_tools_enabled' $true
    try { $dial = [int]$dial } catch { $dial = 3 }
    if ($dial -lt 1) { $dial = 1 }
    if ($dial -gt 5) { $dial = 5 }
    $toolsEn = $true
    if ($null -ne $tools) { $toolsEn = [bool]$tools }

    $model = $null
    if ($prefProvider -and $prefModels) {
        $model = Get-PromptParleProp $prefModels $prefProvider $null
        if (-not $model -and ($prefModels -is [hashtable] -or $prefModels -is [System.Collections.IDictionary])) {
            if ($prefModels.ContainsKey($prefProvider)) { $model = [string]$prefModels[$prefProvider] }
        } elseif (-not $model) {
            try { $model = [string]$prefModels.$prefProvider } catch { }
        }
    }

    try {
        $base = Get-PromptParleSessionState
        $snapParams = @{
            Base         = $base
            Dial         = $dial
            ToolsEnabled = $toolsEn
        }
        if ($prefProvider) { $snapParams.Provider = $prefProvider }
        if ($model) { $snapParams.Model = [string]$model }
        $next = New-PromptParleSessionSnapshot @snapParams
        Save-PromptParleSessionState -State $next
    } catch {
        if (-not $Quiet) {
            Write-Host ("Could not apply portal settings locally: {0}" -f $_) -ForegroundColor Yellow
        }
    }

    if (-not $Quiet) {
        Write-Host ("Portal settings synced · provider={0} model={1} dial={2} tools={3}" -f `
            $(if ($prefProvider) { $prefProvider } else { '(auto)' }), `
            $(if ($model) { $model } else { '(default)' }), `
            $dial, `
            $(if ($toolsEn) { 'on' } else { 'off' })) -ForegroundColor Green
    }
    return $remote
}

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

    # Auto-install: pull portal chat defaults (provider/model/dial/tools) into local session
    try {
        $null = Sync-PromptParlePortalSettings
    } catch {
        Write-Host ("Note: portal settings sync skipped ({0})" -f $_) -ForegroundColor DarkYellow
    }

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

    $localMap = @{}
    try { $localMap = Get-PromptParleLocalProviderMap } catch { $localMap = @{} }
    $localSummary = @()
    foreach ($k in @($localMap.Keys)) {
        $localSummary += ("{0}=…{1}" -f $k, $localMap[$k].LastFour)
    }

    [pscustomobject]@{
        BaseUrl         = $c.BaseUrl
        ApiKey          = $masked
        ConfigPath      = $script:PromptParleConfigPath
        HasApiKey       = [bool]$c.ApiKey
        LocalFirst      = $true
        SecretPolicy    = $(try { Get-PromptParleSecretPolicy } catch { 'strict' })
        LocalProviders  = if ($localSummary.Count) { ($localSummary -join ', ') } else { '(none — Set-PromptParleProviderKey)' }
    }
}

function Get-PromptParleProvider {
    <#
    .SYNOPSIS
      List AI providers and which keys are configured on this PC (local-first).

    .EXAMPLE
      Get-PromptParleProvider
    #>
    [CmdletBinding()]
    param()

    $result = Get-PromptParleLocalProvidersPublic
    $list = @($result.providers)
    foreach ($p in $list) {
        [pscustomobject]@{
            Id           = $p.id
            Name         = $p.name
            Routing      = [bool]$p.routing
            DefaultModel = $p.default_model
            Configured   = [bool]$p.configured
            KeySource    = [string](Get-PromptParleProp $p 'key_source' 'none')
            LastFour     = Get-PromptParleProp $p 'last_four' $null
            LocalFirst   = $true
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
        [string]$SessionTitle = '',
        [string]$ClientSessionId = '',

        [switch]$Quiet,

        [switch]$Raw
    )

    begin {
        # ArrayList not List[string] — PS 5.1 "Argument types do not match" on .Add with string wrappers
        $contextChunks = New-Object System.Collections.ArrayList
    }

    process {
        if ($null -eq $InputObject) { return }
        if ($InputObject -is [System.IO.FileInfo]) {
            $leaf = [string]$InputObject.Name
            $raw = Get-Content -LiteralPath $InputObject.FullName -Raw -ErrorAction Stop
            [void]$contextChunks.Add([string]("===== FILE: $leaf =====`n$raw"))
        } elseif ($InputObject -is [string]) {
            [void]$contextChunks.Add([string]$InputObject)
        } else {
            [void]$contextChunks.Add([string]$InputObject)
        }
    }

    end {
        # Named -Context is one blob (do not treat as char array)
        if ($PSBoundParameters.ContainsKey('Context') -and -not [string]::IsNullOrEmpty($Context)) {
            [void]$contextChunks.Add([string]$Context)
        }

        if ($Path) {
            if (-not (Test-Path -LiteralPath $Path)) {
                throw "Context file not found: $Path"
            }
            $leaf = Split-Path -Leaf $Path
            $raw = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
            [void]$contextChunks.Add([string]("===== FILE: $leaf =====`n$raw"))
        }

        $contextText = $null
        if ($contextChunks.Count -gt 0) {
            $contextText = ([string[]]@($contextChunks.ToArray())) -join "`n"
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
        if ($SessionTitle) { $body.session_title = [string]$SessionTitle }
        if ($ClientSessionId) { $body.client_session_id = [string]$ClientSessionId }

        $imageList = @(ConvertTo-PromptParleImageList -Images $Images)

        # ---- Local-first (0.25+): keys + optimize + model call on this PC ----
        # Portal is licensing only (pp_live_ / entitlements). No prompt bodies to cloud.
        $lfParams = @{
            Prompt            = $promptText
            Context           = $(if ($contextText) { [string]$contextText } else { '' })
            Provider          = $Provider
            Profile           = $Profile
            CompressionLevel  = $CompressionLevel
        }
        if ($Model) { $lfParams.Model = [string]$Model }
        if ($PSBoundParameters.ContainsKey('System') -and -not [string]::IsNullOrWhiteSpace($System)) {
            $lfParams.System = [string]$System
        }
        if ($PSBoundParameters.ContainsKey('Runtime') -and -not [string]::IsNullOrWhiteSpace($Runtime)) {
            $lfParams.Runtime = [string]$Runtime
        }
        if ($OptimizeOnly) { $lfParams.OptimizeOnly = $true }
        if ($imageList.Count -gt 0 -and -not $OptimizeOnly) { $lfParams.Images = $imageList }
        if ($Quiet) { $lfParams.Quiet = $true }

        $result = Invoke-PromptParleLocalFirst @lfParams

        if ($Raw) {
            return $result
        }

        $meta = Get-PromptParleProp $result 'metadata'
        if ($null -eq $meta) { $meta = Get-PromptParleProp $result 'Metadata' }
        if (-not $Quiet) {
            Write-PromptParleMetadata -Metadata $meta
        }

        if ($OptimizeOnly) {
            if (-not $Quiet) {
                Write-Host 'Optimized prompt (local-first):' -ForegroundColor Cyan
            }
            return [pscustomobject]@{
                OptimizedPrompt = Get-PromptParleProp $result 'optimized_prompt' (Get-PromptParleProp $result 'OptimizedPrompt')
                Metadata        = $meta
                Provider        = $Provider
                Profile         = $Profile
                OptimizeOnly    = $true
                LocalFirst      = $true
            }
        }

        if (-not $Quiet) {
            Write-Host 'AI Response (local-first · provider direct):' -ForegroundColor Cyan
        }

        $responseText = [string](Get-PromptParleProp $result 'response' (Get-PromptParleProp $result 'Response' ''))
        [pscustomobject]@{
            Response     = $responseText
            Metadata     = $meta
            Provider     = if (Get-PromptParleProp $meta 'provider') { Get-PromptParleProp $meta 'provider' } else { $Provider }
            Model        = if (Get-PromptParleProp $meta 'model') { Get-PromptParleProp $meta 'model' } else { $Model }
            Profile      = if (Get-PromptParleProp $meta 'optimization_profile') { Get-PromptParleProp $meta 'optimization_profile' } else { $Profile }
            OptimizeOnly = $false
            LocalFirst   = $true
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

    # Local UI script hygiene (0.25.2 shipped a syntax error → nothing clickable)
    try {
        $uiRaw = Get-Content -LiteralPath $ui -Raw -ErrorAction Stop
        if ($uiRaw -notmatch '__PP_UI_READY__') {
            return [pscustomobject]@{
                ok      = $false
                message = 'local-ui/index.html missing __PP_UI_READY__ ready marker'
                version = $ver
            }
        }
        # Known broken pattern: unquoted "(treat as relevant..." after string concat
        if ($uiRaw -match "(?s)\+\s*\r?\n\s*\(treat as relevant") {
            return [pscustomobject]@{
                ok      = $false
                message = 'local-ui/index.html has broken attach-prompt string (JS would not parse)'
                version = $ver
            }
        }
    } catch {
        return [pscustomobject]@{
            ok      = $false
            message = "Could not read local-ui/index.html: $_"
            version = $ver
        }
    }

    # Parse psm1 + optional LocalFirst.ps1 (dot-sourced at import; must be PS 5.1 clean)
    $filesToParse = @($psm1)
    $lf = Join-Path $ModuleDir 'LocalFirst.ps1'
    if (Test-Path -LiteralPath $lf) { $filesToParse += $lf }

    try {
        foreach ($parsePath in $filesToParse) {
            $parseErrs = $null
            $parseTok = $null
            $null = [System.Management.Automation.Language.Parser]::ParseFile(
                $parsePath,
                [ref]$parseTok,
                [ref]$parseErrs
            )
            if ($parseErrs -and $parseErrs.Count -gt 0) {
                $first = $parseErrs[0]
                $leaf = Split-Path -Leaf $parsePath
                $where = if ($first.Extent) {
                    "${leaf} line $($first.Extent.StartLineNumber): $($first.Message)"
                } else { "$leaf : $([string]$first.Message)" }
                return [pscustomobject]@{
                    ok      = $false
                    message = "Module parse failed ($where)"
                    version = $ver
                }
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

    $sourceRoot = (Resolve-Path -LiteralPath $SourceDir).Path.TrimEnd([char]0x5C, [char]0x2F)
    $destRoot = (Resolve-Path -LiteralPath $DestDir).Path.TrimEnd([char]0x5C, [char]0x2F)
    $wanted = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)

    Get-ChildItem -LiteralPath $SourceDir -Recurse -File -Force -ErrorAction Stop | ForEach-Object {
        $full = $_.FullName
        $rel = $full.Substring($sourceRoot.Length).TrimStart([char]0x5C, [char]0x2F)
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
        $rel = $full.Substring($destRoot.Length).TrimStart([char]0x5C, [char]0x2F)
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
        # Open cloud portal (dashboard) instead of local UI
        [switch]$Cloud,
        [string]$Path = '/app'
    )

    if ($Cloud) {
        $config = Get-PromptParleConfigInternal
        $base = if ($config.BaseUrl) { $config.BaseUrl.TrimEnd('/') } else { $script:DefaultBaseUrl }
        if (-not $Path.StartsWith('/')) { $Path = "/$Path" }
        $url = "$base$Path"
        Write-Host "Opening cloud portal: $url" -ForegroundColor Yellow
        Write-Host '(Chat is local: Open-PromptParleBrowser  or  pp)' -ForegroundColor DarkGray
        Open-PromptParleUrl -Url $url
        return
    }

    Start-PromptParleLocalServer
}

function Test-PromptParleLocalUiRequest {
    <#
    .SYNOPSIS
      Auth + origin gate for the local HttpListener (desktop Achilles heel).
      Requires X-PromptParle-Local matching the per-run token.
      Rejects non-loopback Host and cross-origin browser calls.
    #>
    param(
        [Parameter(Mandatory)]$Request,
        [Parameter(Mandatory)][string]$ExpectedToken,
        [Parameter(Mandatory)][int]$Port
    )

    if (-not $ExpectedToken) { return $false }

    # Token header (primary). Query fallback only for rare form GETs — still same machine.
    $got = $null
    try { $got = [string]$Request.Headers['X-PromptParle-Local'] } catch { $got = $null }
    if (-not $got) {
        try { $got = [string]$Request.QueryString['pp_local'] } catch { $got = $null }
    }
    if (-not $got -or $got -ne $ExpectedToken) { return $false }

    # Host must be loopback
    $hostHdr = ''
    try { $hostHdr = [string]$Request.UserHostName } catch { }
    if (-not $hostHdr) {
        try { $hostHdr = [string]$Request.Headers['Host'] } catch { }
    }
    if ($hostHdr) {
        $h = $hostHdr.ToLowerInvariant()
        $okHost = (
            $h -eq "127.0.0.1:$Port" -or
            $h -eq "localhost:$Port" -or
            $h -eq '[::1]:' + $Port -or
            $h -eq '127.0.0.1' -or
            $h -eq 'localhost'
        )
        if (-not $okHost) { return $false }
    }

    # If browser sent Origin, it must be this local UI
    $origin = ''
    try { $origin = [string]$Request.Headers['Origin'] } catch { }
    if ($origin) {
        $o = $origin.TrimEnd('/').ToLowerInvariant()
        $allowed = @(
            "http://127.0.0.1:$Port",
            "http://localhost:$Port",
            "http://[::1]:$Port"
        )
        if ($allowed -notcontains $o) { return $false }
    }

    # Referer: if present, must point at this local origin
    $referer = ''
    try { $referer = [string]$Request.Headers['Referer'] } catch { }
    if ($referer) {
        $okRef = $false
        foreach ($prefix in @(
            "http://127.0.0.1:$Port/",
            "http://localhost:$Port/",
            "http://[::1]:$Port/",
            "http://127.0.0.1:$Port",
            "http://localhost:$Port"
        )) {
            if ($referer.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
                $okRef = $true
                break
            }
        }
        if (-not $okRef) { return $false }
    }

    return $true
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
    # Local UI requires X-PromptParle-Local (per-run token written to local-ui.token).
    $stopUrl = "http://127.0.0.1:$Port/api/stop"
    $localTok = ''
    try {
        $tokPath = Join-Path $script:PromptParleConfigDir 'local-ui.token'
        if (Test-Path -LiteralPath $tokPath) {
            $localTok = (Get-Content -LiteralPath $tokPath -Raw -ErrorAction Stop).Trim()
        }
    } catch { $localTok = '' }
    try {
        $headers = @{}
        if ($localTok) { $headers['X-PromptParle-Local'] = $localTok }
        if ($PSVersionTable.PSVersion.Major -le 5) {
            Invoke-WebRequest -Uri $stopUrl -Method POST -Headers $headers -UseBasicParsing -TimeoutSec 1 | Out-Null
        } else {
            Invoke-WebRequest -Uri $stopUrl -Method POST -Headers $headers -TimeoutSec 1 | Out-Null
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

function Test-PromptParleConsoleInteractive {
    <# True when this host can poll console keys (not redirected / headless). #>
    try {
        if ([Console]::IsInputRedirected) { return $false }
        # KeyAvailable throws when there is no console attached
        $null = [Console]::KeyAvailable
        return $true
    } catch {
        return $false
    }
}

function Write-PromptParleConsoleHotkeyHelp {
    param([string]$Url = '')
    Write-Host '  Console keys (focus this window):' -ForegroundColor Yellow
    Write-Host '    [U] Update client      [Shift+U] Force reinstall' -ForegroundColor White
    Write-Host '    [R] Restart server     [O] Open browser UI' -ForegroundColor White
    Write-Host '    [Q] Quit / stop        [H] or [?] Help' -ForegroundColor White
    Write-Host '    Ctrl+C also stops' -ForegroundColor DarkGray
    if ($Url) {
        Write-Host ("  UI: {0}" -f $Url) -ForegroundColor DarkGray
    }
}

function Read-PromptParleConsoleHotkey {
    <#
      Non-blocking: return action name or $null.
      Actions: update | force-update | restart | quit | open | help
    #>
    try {
        if (-not [Console]::KeyAvailable) { return $null }
        $k = [Console]::ReadKey($true)
    } catch {
        return $null
    }
    $key = $k.Key
    $ch = $k.KeyChar
    $shift = $false
    try {
        $shift = ($k.Modifiers -band [System.ConsoleModifiers]::Shift) -ne 0
    } catch { $shift = $false }

    # Letter keys (Key enum) — prefer Key over KeyChar for layout independence
    if ($key -eq [System.ConsoleKey]::U) {
        if ($shift -or $ch -ceq 'U') { return 'force-update' }
        return 'update'
    }
    if ($key -eq [System.ConsoleKey]::R) { return 'restart' }
    if ($key -eq [System.ConsoleKey]::Q -or $key -eq [System.ConsoleKey]::S) { return 'quit' }
    if ($key -eq [System.ConsoleKey]::O) { return 'open' }
    if ($key -eq [System.ConsoleKey]::H -or $key -eq [System.ConsoleKey]::F1) { return 'help' }
    if ($key -eq [System.ConsoleKey]::Escape) { return 'quit' }
    if ($ch -eq '?' -or $ch -eq '/') { return 'help' }
    if ($ch -eq 'u') { return 'update' }
    if ($ch -eq 'U') { return 'force-update' }
    if ($ch -eq 'r' -or $ch -eq 'R') { return 'restart' }
    if ($ch -eq 'q' -or $ch -eq 'Q' -or $ch -eq 's' -or $ch -eq 'S') { return 'quit' }
    if ($ch -eq 'o' -or $ch -eq 'O') { return 'open' }
    if ($ch -eq 'h' -or $ch -eq 'H') { return 'help' }
    return $null
}

function Invoke-PromptParleConsoleHotkey {
    <#
      Handle one console hotkey while the local server is idle (between HTTP requests).
      Returns $true if the main wait loop should break (quit/restart/update-handoff).
    #>
    param(
        [Parameter(Mandatory)][string]$Action,
        [Parameter(Mandatory)][int]$Port,
        [Parameter(Mandatory)][string]$Url,
        $Listener
    )

    if ($script:PromptParleConsoleBusy) {
        Write-Host '  (console busy — try again in a moment)' -ForegroundColor DarkGray
        return $false
    }

    switch ($Action) {
        'help' {
            Write-Host ''
            Write-PromptParleConsoleHotkeyHelp -Url $Url
            Write-Host ''
            return $false
        }
        'open' {
            Write-Host ("  Opening {0}" -f $Url) -ForegroundColor Cyan
            try { Open-PromptParleUrl -Url $Url } catch {
                Write-Host ("  Could not open browser: {0}" -f $_) -ForegroundColor Yellow
            }
            return $false
        }
        'quit' {
            Write-Host ''
            Write-Host 'Q — stopping local PromptParle...' -ForegroundColor Yellow
            $script:PromptParleShouldStop = $true
            $script:PromptParleStopAnnounced = $true
            $script:PromptParleConsoleRestart = $false
            try {
                if ($Listener -and $Listener.IsListening) { $Listener.Stop() }
            } catch { }
            return $true
        }
        'restart' {
            Write-Host ''
            Write-Host 'R — restarting local server (same port)...' -ForegroundColor Cyan
            $script:PromptParleConsoleRestart = $true
            $script:PromptParleShouldStop = $true
            $script:PromptParleStopAnnounced = $true
            $script:PromptParleExitProcessAfterStop = $false
            try {
                if ($Listener -and $Listener.IsListening) { $Listener.Stop() }
            } catch { }
            return $true
        }
        { $_ -eq 'update' -or $_ -eq 'force-update' } {
            $force = ($Action -eq 'force-update')
            Write-Host ''
            if ($force) {
                Write-Host 'Shift+U — force reinstall from portal...' -ForegroundColor Yellow
            } else {
                Write-Host 'U — checking portal for client update...' -ForegroundColor Cyan
            }
            $script:PromptParleConsoleBusy = $true
            try {
                if ($force) {
                    $result = Update-PromptParleClient -Force -RestartPort $Port
                } else {
                    $result = Update-PromptParleClient -RestartPort $Port
                }
            } catch {
                Write-Host ("  update error: {0}" -f $_) -ForegroundColor Red
                Write-Host '  Server still running. Press H for keys.' -ForegroundColor DarkGray
                $script:PromptParleConsoleBusy = $false
                return $false
            }
            $script:PromptParleConsoleBusy = $false

            $ok = $true
            try { $ok = [bool](Get-PromptParleProp $result 'ok' $true) } catch { $ok = $true }
            $updated = $false
            try { $updated = [bool](Get-PromptParleProp $result 'updated' $false) } catch { $updated = $false }
            $restartReq = $false
            try { $restartReq = [bool](Get-PromptParleProp $result 'restart_required' $false) } catch { $restartReq = $false }
            $msg = [string](Get-PromptParleProp $result 'message' '')

            if (-not $ok) {
                Write-Host ("  update failed: {0}" -f $(if ($msg) { $msg } else { 'unknown error' })) -ForegroundColor Red
                Write-Host '  Previous version kept; server still running.' -ForegroundColor DarkGray
                return $false
            }
            if (-not $updated) {
                Write-Host ("  {0}" -f $(if ($msg) { $msg } else { 'Already up to date.' })) -ForegroundColor Green
                Write-Host '  Server still running. Press H for keys.' -ForegroundColor DarkGray
                return $false
            }
            if ($restartReq) {
                Write-Host ("  {0}" -f $(if ($msg) { $msg } else { 'Updated' })) -ForegroundColor Green
                Write-Host '  New window starting; this window will close.' -ForegroundColor DarkGray
                $script:PromptParleExitProcessAfterStop = $true
                $script:PromptParleConsoleRestart = $false
                $script:PromptParleShouldStop = $true
                $script:PromptParleStopAnnounced = $true
                try {
                    if ($Listener -and $Listener.IsListening) { $Listener.Stop() }
                } catch { }
                return $true
            }
            Write-Host ("  {0}" -f $(if ($msg) { $msg } else { 'Updated' })) -ForegroundColor Green
            Write-Host '  No auto-restart; press R to restart or run  pp  in a new window.' -ForegroundColor Yellow
            return $false
        }
        default {
            return $false
        }
    }
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

function Invoke-PromptParleChatTurnCore {
    <#
    .SYNOPSIS
      Shared chat-turn runner. Takes a parsed request body and returns the
      response payload (@{ response; optimized_prompt; metadata }) or
      @{ error = <string> } on failure. Extracted verbatim from the /api/chat
      handler so a background-job child process can run the same turn logic
      without touching the HTTP listener. Must NOT reference $ctx/$req or write
      HTTP responses — the caller serializes/delivers the returned object.
    #>
    param(
        [Parameter(Mandatory)]$Body
    )
    $chatStage = 'init'
    try {
        $chatStage = 'parse-body'
        $body = $Body
        if ($null -eq $body) { throw 'Empty request body' }
        # StrictMode: never touch $body.foo if foo may be absent
        $prompt = [string](Get-PromptParleProp $body 'prompt' '')
        if (-not $prompt) { throw 'Missing prompt (type in the bottom box)' }
        $provider = [string](Get-PromptParleProp $body 'provider' 'openai')
        if (-not $provider) { $provider = 'openai' }
        # Explicit model from UI selector (0.23.4+) — body wins, then session sticky.
        # Mid-chat model switches must not fall back to a stale portal preferred.
        $modelChat = [string](Get-PromptParleProp $body 'model' '')
        $modelFromBody = -not [string]::IsNullOrWhiteSpace($modelChat)
        if (-not $modelFromBody) {
            try {
                $stM = Get-PromptParleSessionState
                $modelChat = [string](Get-PromptParleProp $stM 'model' '')
            } catch { $modelChat = '' }
        }
        $modelChat = $modelChat.Trim()
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

        $sessionTitleChat = [string](Get-PromptParleProp $body 'session_title' (Get-PromptParleProp $body 'sessionTitle' ''))
        $clientSessionIdChat = [string](Get-PromptParleProp $body 'client_session_id' (Get-PromptParleProp $body 'clientSessionId' ''))


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
            $toolsEnChat = ConvertTo-PromptParleBool -Value $teBody -Default $true
        } else {
            try {
                $stChat = Get-PromptParleSessionState
                if ($null -ne (Get-PromptParleProp $stChat 'tools_enabled' $null)) {
                    $toolsEnChat = ConvertTo-PromptParleBool -Value (Get-PromptParleProp $stChat 'tools_enabled' $true) -Default $true
                }
            } catch { $toolsEnChat = $true }
        }
        # Persist provider/model/tools/dial from UI each chat (model always when known)
        try {
            $stSave = Get-PromptParleSessionState
            $snapChat = @{
                Base         = $stSave
                ToolsEnabled = $toolsEnChat
                Dial         = $dial
                Profile      = $profile
                Provider     = $provider
                OptimizeOnly = $optOnly
            }
            # Force Model key so a UI switch replaces prior session model
            if ($modelFromBody -or $modelChat) {
                $snapChat.Model = $modelChat
            }
            $stSave = New-PromptParleSessionSnapshot @snapChat
            Save-PromptParleSessionState -State $stSave
        } catch { }

        # You → local prep → local-first optimize + provider (dial). Portal = license only.
        $prep = $null
        $toolBreakdownOut = @()
        $prepTokensBefore = 0
        $prepTokensAfter = 0
        $groundingContext = if ($context) { [string]$context } else { '' }
        $chatStage = 'local-prep'
        try {
            $prepParams = @{
                Prompt       = $prompt
                Context      = $(if ($context) { [string]$context } else { '' })
                ToolsEnabled = $toolsEnChat
                Dial         = $dial
                Profile      = $profile
            }
            if ($histArr.Count -gt 0) { $prepParams.History = $histArr }
            elseif ($histText) { $prepParams.HistoryText = $histText }
            if ($clientSessionIdChat) { $prepParams.ClientSessionId = $clientSessionIdChat.Trim() }
            # User-pinned session Knowledge (★) from local UI — key present = UI is source of truth (empty clears)
            $pkArr = @()
            $pkRaw = $null
            $pkKeyPresent = $false
            try {
                if ($body.PSObject.Properties['priority_knowledge'] -or $body.PSObject.Properties['priorityKnowledge']) {
                    $pkKeyPresent = $true
                    $pkRaw = Get-PromptParleProp $body 'priority_knowledge' $null
                    if ($null -eq $pkRaw) { $pkRaw = Get-PromptParleProp $body 'priorityKnowledge' $null }
                }
            } catch {
                $pkRaw = Get-PromptParleProp $body 'priority_knowledge' $null
                if ($null -eq $pkRaw) { $pkRaw = Get-PromptParleProp $body 'priorityKnowledge' $null }
                if ($null -ne $pkRaw) { $pkKeyPresent = $true }
            }
            if ($null -ne $pkRaw) {
                foreach ($pk in @($pkRaw)) {
                    if ($null -eq $pk) { continue }
                    $pkt = [string](Get-PromptParleProp $pk 'text' (Get-PromptParleProp $pk 'Text' ''))
                    if (-not $pkt) { continue }
                    $pkr = [string](Get-PromptParleProp $pk 'role' (Get-PromptParleProp $pk 'Role' 'assistant'))
                    $pki = [string](Get-PromptParleProp $pk 'id' (Get-PromptParleProp $pk 'Id' ''))
                    $pkArr += [pscustomobject]@{ id = $pki; role = $pkr; text = $pkt }
                    if ($pkArr.Count -ge 12) { break }
                }
            }
            if ($pkKeyPresent) {
                $prepParams.PriorityKnowledge = $pkArr
                $prepParams.PriorityKnowledgeReplace = $true
            }
            $prepRaw = Invoke-PromptParleAgentLocalPrep @prepParams
            # PS 5.1: pipeline pollution can wrap prep as Object[]; take last real object
            $prep = $null
            if ($null -ne $prepRaw) {
                if ($prepRaw -is [System.Array]) {
                    for ($pi = $prepRaw.Length - 1; $pi -ge 0; $pi--) {
                        $cand = $prepRaw[$pi]
                        if ($null -eq $cand) { continue }
                        if ($cand -is [int] -or $cand -is [long]) { continue }
                        $probe = Get-PromptParleProp $cand 'prompt' $null
                        if ($null -eq $probe) { $probe = Get-PromptParleProp $cand 'context' $null }
                        if ($null -ne $probe -or (Get-PromptParleProp $cand 'tokens_before' $null) -ne $null) {
                            $prep = $cand
                            break
                        }
                    }
                    if ($null -eq $prep -and $prepRaw.Length -gt 0) { $prep = $prepRaw[-1] }
                } else {
                    $prep = $prepRaw
                }
            }
            if ($null -eq $prep) { throw 'local prep returned empty result' }
            $prepPrompt = Get-PromptParleProp $prep 'prompt' $null
            if ($null -ne $prepPrompt -and [string]$prepPrompt) { $prompt = [string]$prepPrompt }
            $prepCtx = Get-PromptParleProp $prep 'context' $null
            if ($null -ne $prepCtx) { $context = [string]$prepCtx }
            $prepNotes = Get-PromptParleProp $prep 'notes' $null
            if ($prepNotes) { $localNotes = @($localNotes) + @($prepNotes) }
            # Per-tool savings ledger from prep (0.28.0) — carried to metaOut for display.
            $toolBreakdownOut = @()
            try {
                $tbRaw = Get-PromptParleProp $prep 'tool_breakdown' $null
                if ($tbRaw) { $toolBreakdownOut = @($tbRaw) }
            } catch { }
            # Turn baseline: raw prompt+history+attach before MEM/fleet densify
            try {
                $ptb = Get-PromptParleProp $prep 'tokens_before' $null
                $pta = Get-PromptParleProp $prep 'tokens_after' $null
                if ($null -eq $ptb) {
                    $ci = Get-PromptParleProp $prep 'chars_in' 0
                    if ($ci -gt 0) { $ptb = [Math]::Max(1, [int][Math]::Ceiling([int]$ci / 4.0)) }
                }
                if ($null -eq $pta) {
                    $co = Get-PromptParleProp $prep 'chars_out' 0
                    if ($co -gt 0) { $pta = [Math]::Max(1, [int][Math]::Ceiling([int]$co / 4.0)) }
                }
                if ($null -ne $ptb) { $prepTokensBefore = [int]$ptb }
                if ($null -ne $pta) { $prepTokensAfter = [int]$pta }
            } catch { }
        } catch {
            Write-Host ("  chat: local prep warning - {0}" -f $_) -ForegroundColor DarkYellow
            Write-PromptParleDebugLog ("chat local-prep: " + $_.Exception.ToString())
            $prep = $null
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
        # Prep owns evidence_mode + hands_allowed (product dispatch, not chat special cases)
        $evidenceMode = 'live'
        $handsAllowed = [bool]$toolsEnChat
        $evidenceReason = ''
        try {
            if ($prep) {
                $em0 = Get-PromptParleProp $prep 'evidence_mode' $null
                if ($em0) { $evidenceMode = [string]$em0 }
                $ha0 = Get-PromptParleProp $prep 'hands_allowed' $null
                if ($null -ne $ha0) { $handsAllowed = [bool]$ha0 -and $toolsEnChat }
                $evidenceReason = [string](Get-PromptParleProp $prep 'evidence_reason' '')
            }
        } catch { }
        if (-not $toolsEnChat) { $handsAllowed = $false }

        $rtNote = 'Prep ran. Tags may include [PROJECT][CONN][SSH][MEM][KNOW][ATTACH][WEB][OBSERVE][GROUNDING][PROVENANCE]. [KNOW]=user-pinned session truth. Doctrine: if client can obtain the fact, do not answer with the method; if document owed, emit ```file``` this turn; never invent product facts not in evidence.'
        if ($oblForRt -and $oblForRt.mode -eq 'mutate') {
            $rtNote = 'MUTATE TURN · capability=obligation. Emit full-file ```apply path=...```; ```run``` only for pipeline cmds client executes. NEVER dump homework. No Ready/Name-it theater.'
            $turnForRt = 'implement'
        } elseif ($oblForRt -and $oblForRt.mode -eq 'deliver') {
            $rtNote = 'DELIVER TURN · document owed. Emit ```file name=…``` with FULL body NOW. Use [WEB]/[OBSERVE]/[ATTACH] as source — never [MEM] invention when observe evidence exists. Never "Generating now" without the file fence.'
        } elseif ($oblForRt -and $oblForRt.mode -eq 'observe') {
            $rtNote = 'OBSERVE TURN · client already filled [OBSERVE]/[WEB] when possible. Present results only; invent nothing beyond evidence. NEVER ```run ls``` or search-homework as the answer.'
        } elseif ($turnForRt -eq 'implement') {
            $rtNote = 'IMPLEMENT TURN · capability=obligation. Emit full-file ```apply path=...```; ```run``` for migrate/build client executes. NEVER tell the user to run npx. No theater.'
        } elseif ($turnForRt -eq 'question') {
            $rtNote = 'QUESTION TURN. Answer from [PROJECT]/[OBSERVE]/[WEB]/[PROVENANCE]/[MEM][KNOW] evidence first. Never invent capabilities.'
        }
        if ($evidenceMode -eq 'session') {
            $rtNote = $rtNote + ' EVIDENCE_MODE=session: answer from [MEM]/[KNOW]/[PROJECT]/[CONN] only. No hands. No re-discovery. Offer refresh if incomplete.'
        } elseif ($evidenceMode -eq 'refresh') {
            $rtNote = $rtNote + ' EVIDENCE_MODE=refresh: user forced live re-pull; prefer [SSH]/[OBSERVE] this turn.'
        }
        if ($groundingContext -match '(?m)\[PROVENANCE\]') {
            $rtNote = $rtNote + ' PROVENANCE OWED: report client YES/NO on-source and prior-assistant origin. Never only "nowhere".'
        }
        try {
            $ctxHasAttach = $context -and ($context -match '(?m)^\[ATTACH\]' -or $context -match '===== FILE:')
            $prHasAttach = $prompt -match '\[ATTACHED THIS TURN'
            if ($ctxHasAttach -or $prHasAttach) {
                $rtNote = $rtNote + ' ATTACH PRIMARY: summarize/create deliverables from THIS turn FILE only. Do not reuse prior [MEM] document topic when a new file is attached.'
            }
        } catch { }
        if ($localNotes -and $localNotes.Count -gt 0) {
            $rtNote = $rtNote + ' Notes: ' + (($localNotes | Select-Object -First 8) -join ',') + '.'
        }
        $frame = Get-PromptParleChatFraming -Prompt $prompt -RuntimeNote $rtNote

        $ctxLen = if ($context) { $context.Length } else { 0 }
        Write-Host ("  chat: provider={0} model={1} profile={2} dial={3} tools={4} optimize_only={5} prompt={6}c system={7}c context={8}c images={9} local_notes={10} evidence={11} hands={12}" -f `
            $provider, $(if ($modelChat) { $modelChat } else { '(default)' }), $profile, $dial, $toolsEnChat, $optOnly, $frame.Prompt.Length, $frame.System.Length, $ctxLen, $images.Count, $localNotes.Count, $evidenceMode, $handsAllowed) -ForegroundColor DarkGray

        $params = @{
            Prompt            = [string]$frame.Prompt
            System            = [string]$frame.System
            Runtime           = [string]$frame.Runtime
            Provider          = $provider
            Profile           = $profile
            CompressionLevel  = $dial
        }
        if ($modelChat) {
            $params.Model = [string]$modelChat
            Write-Host ("  chat: forcing model={0}" -f $modelChat) -ForegroundColor DarkCyan
        } else {
            Write-Host '  chat: no model in body/session — local default model will apply' -ForegroundColor DarkYellow
        }
        if ($context) { $params.Context = [string]$context }
        if ($optOnly) { $params.OptimizeOnly = $true }
        if ($images.Count -gt 0) { $params.Images = $images }
        if ($sessionTitleChat) { $params.SessionTitle = $sessionTitleChat.Trim() }
        if ($clientSessionIdChat) { $params.ClientSessionId = $clientSessionIdChat.Trim() }

        # Dispatch from prep.hands_allowed only (no MaxRounds/session special cases)
        $chatStage = 'model-call'
        if (-not $handsAllowed -or -not $toolsEnChat -or $optOnly) {
            $params.Quiet = $true
            $params.Raw = $true
            foreach ($dropK in @('MaxRounds', 'ClientSessionId', 'SessionTitle')) {
                if ($params.ContainsKey($dropK)) { $params.Remove($dropK) | Out-Null }
            }
            Write-Host ("  chat: single completion (evidence={0} hands={1})" -f $evidenceMode, $handsAllowed) -ForegroundColor Green
            $result = Invoke-PromptParle @params
        } else {
            try {
                $result = Invoke-PromptParleAgentTurn @params
            } catch {
                $msg = "$_"
                if ($msg -match 'parameter name') {
                    Write-Host ("  chat: agent turn param retry after: {0}" -f $msg) -ForegroundColor DarkYellow
                    $params.Remove('ClientSessionId') | Out-Null
                    $params.Remove('SessionTitle') | Out-Null
                    $params.Remove('Quiet') | Out-Null
                    $params.Remove('Raw') | Out-Null
                    $result = Invoke-PromptParleAgentTurn @params
                } else {
                    throw
                }
            }
        }
        # Normalize metadata keys for the browser UI (always snake_case numbers)
        $chatStage = 'meta-normalize'
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
            # Prefer the dial the UI actually sent this turn (authoritative).
            # Older native-agent builds hardcoded compression_level=1; never let that win.
            $dialForMeta = $dial
            if ($null -ne $dialT) {
                $dialMetaN = ConvertTo-PromptParleInt32 -Value $dialT -Default $dial
                if ($dialMetaN -ge 1 -and $dialMetaN -le 5) {
                    if ($dial -lt 1 -or $dialMetaN -eq $dial) { $dialForMeta = $dialMetaN }
                    else { $dialForMeta = $dial }
                }
            }
            # Plain hashtable only — never [ordered] + cast / ConvertTo-Json footguns
            $metaOut = @{
                original_tokens         = (ConvertTo-PromptParleInt32 -Value $origT -Default 0)
                optimized_tokens        = (ConvertTo-PromptParleInt32 -Value $optT -Default 0)
                token_reduction_percent = (ConvertTo-PromptParleInt32 -Value $pctT -Default 0)
                tokens_saved            = 0
                expanded                = $false
                provider                = [string](Get-PromptParleProp $metaIn 'provider' '')
                model                   = [string](Get-PromptParleProp $metaIn 'model' '')
                optimization_profile    = [string](Get-PromptParleProp $metaIn 'optimization_profile' (Get-PromptParleProp $metaIn 'optimizationProfile' ''))
                compression_level       = (ConvertTo-PromptParleInt32 -Value $dialForMeta -Default 3)
                strategy                = [string](Get-PromptParleProp $metaIn 'strategy' '')
                secrets_masked          = (ConvertTo-PromptParleBool -Value (Get-PromptParleProp $metaIn 'secrets_masked' $false) -Default $false)
                notes                   = @()
                signals                 = @{}
                image_count             = 0
                local_tools             = @($localNotes)
                tool_breakdown          = @($toolBreakdownOut)
            }
            # Roll up this turn's per-tool savings for the portal bridge
            # (aggregate numbers only; flushed on heartbeat). Best-effort.
            try {
                if ($toolBreakdownOut -and @($toolBreakdownOut).Count -gt 0) {
                    Add-PromptParleToolSavings -Breakdown @($toolBreakdownOut) -Provider ([string]$metaOut.provider)
                }
            } catch { }
            $notesRaw = Get-PromptParleProp $metaIn 'notes' @()
            if ($null -ne $notesRaw) {
                $nAcc = New-Object System.Collections.ArrayList
                foreach ($n in @($notesRaw)) {
                    if ($null -eq $n) { continue }
                    [void]$nAcc.Add([string]$n)
                }
                $metaOut.notes = @($nAcc.ToArray())
            }
            $sigRaw = Get-PromptParleProp $metaIn 'signals' $null
            if ($null -ne $sigRaw -and $sigRaw -is [System.Collections.IDictionary]) {
                $metaOut.signals = @{}
                foreach ($sk in @($sigRaw.Keys)) {
                    $metaOut.signals[[string]$sk] = $sigRaw[$sk]
                }
            }
            $imgC = Get-PromptParleProp $metaIn 'image_count'
            if ($null -eq $imgC) { $imgC = Get-PromptParleProp $metaIn 'imageCount' }
            if ($null -ne $imgC) { $metaOut.image_count = ConvertTo-PromptParleInt32 -Value $imgC -Default 0 }
            $expF = Get-PromptParleProp $metaIn 'expanded'
            if ($null -ne $expF) { $metaOut.expanded = ConvertTo-PromptParleBool -Value $expF -Default $false }
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
                }
            } catch { }
            # Turn meter. Two honest cases (guardian Rule 6):
            #  - SINGLE-SHOT turn: one prompt in, one payload out. before→after = the prep
            #    wire baseline → tokens actually sent. A real savings %.
            #  - AGENT turn (>=1 round): the model consumes the SUM of all rounds, which is a
            #    genuine multi-round COST, not a compression "expansion". There is no honest
            #    single before/after, so we DON'T overwrite the pair with the 1-prompt prep
            #    baseline. Instead: savings basis stays the per-round sums (sum_original →
            #    sum_optimized, real compression the fleet did across rounds), and we publish a
            #    cost readout (agent_cost_tokens) the UI shows instead of a saved-% verdict.
            $isAgentTurn = ([int](Get-PromptParleProp $metaOut 'agent_rounds' 0) -gt 0)
            if ($isAgentTurn) {
                # Cost readout: what this multi-round build actually cost the model.
                $agentCost = [int]$metaOut.optimized_tokens   # = tokens_sum_optimized
                if ($agentCost -le 0) { $agentCost = [int]$metaOut.tokens_sum_optimized }
                $metaOut.is_agent_turn   = $true
                $metaOut.agent_cost_tokens = $agentCost
                if ($prepTokensBefore -gt 0) {
                    $metaOut.prep_tokens_before = [int]$prepTokensBefore
                    $metaOut.prep_tokens_after  = [int]$prepTokensAfter
                }
                # original/optimized stay the per-round sums → tokens_saved below is the
                # honest cross-round compression (>=0), never a 1-prompt-vs-total artifact.
            }
            elseif ($prepTokensBefore -gt 0) {
                $metaOut.is_agent_turn = $false
                $metaOut.prep_tokens_before = [int]$prepTokensBefore
                $metaOut.prep_tokens_after = [int]$prepTokensAfter
                $sendAfter = [int]$metaOut.optimized_tokens
                if ($sendAfter -le 0 -and $prepTokensAfter -gt 0) { $sendAfter = [int]$prepTokensAfter }
                if ($sendAfter -le 0) { $sendAfter = [int]$metaOut.original_tokens }
                $metaOut.original_tokens = [int]$prepTokensBefore
                $metaOut.optimized_tokens = [int]$sendAfter
            }
            try {
                $metaOut.evidence_mode = $evidenceMode
                $metaOut.hands_allowed = [bool]$handsAllowed
                if ($evidenceReason) { $metaOut.evidence_reason = $evidenceReason }
            } catch { }
            if ($metaOut.optimized_tokens -gt $metaOut.original_tokens -and $metaOut.original_tokens -gt 0) {
                $metaOut.expanded = $true
                $metaOut.tokens_saved = 0
                $metaOut.token_reduction_percent = 0
            } else {
                $metaOut.expanded = $false
                $metaOut.tokens_saved = [Math]::Max(0, [int]$metaOut.original_tokens - [int]$metaOut.optimized_tokens)
                if ($metaOut.original_tokens -gt 0) {
                    $metaOut.token_reduction_percent = [int][Math]::Round(100.0 * $metaOut.tokens_saved / $metaOut.original_tokens)
                } else {
                    $metaOut.token_reduction_percent = 0
                }
            }
            if ([int]$metaOut.optimized_tokens -eq [int]$metaOut.original_tokens) {
                $metaOut.expanded = $false
                $metaOut.tokens_saved = 0
                $metaOut.token_reduction_percent = 0
            }
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
            # Quality gate: product-claim auditor vs fetched evidence — not session/menu turns
            $qg = $null
            if ($evidenceMode -eq 'session') {
                $qg = [pscustomobject]@{
                    text = $respText; applied = $false; reason = 'session-mode'
                    claims = @(); supported = 0; partial = 0; unsupported = 0; score_pct = $null; corrected = $false
                }
            } else {
                $qg = Invoke-PromptParleQualityGate -ResponseText $respText -Context $gctx
            }
            if ($qg.applied) {
                $respText = [string]$qg.text
                Write-Host ("  chat: quality gate {0}% ({1} supported, {2} unverified, corrected={3})" -f `
                    $qg.score_pct, $qg.supported, $qg.unsupported, $qg.corrected) -ForegroundColor Yellow
            } elseif ($qg.reason -match 'clean-silent|partial-silent') {
                Write-Host ("  chat: quality gate silent ({0} score={1}%)" -f $qg.reason, $qg.score_pct) -ForegroundColor DarkGray
            }
            if ($metaOut) {
                $metaOut.quality_reason = [string]$qg.reason
                if ($null -ne $qg.score_pct) { $metaOut.quality_score_pct = [int]$qg.score_pct }
                # Meter truth (0.31): the quality gate self-checks the answer LOCALLY at
                # 0 AI tokens. Without PP, verifying that output means another model round
                # (~ re-ingesting the response). Credit that avoided round as local-work
                # savings so generation turns don't read as pure "expansion".
                try {
                    if ($qg.applied -or ($null -ne $qg.score_pct)) {
                        $qgChars = [Math]::Min(20000, ([string]$respText).Length)
                        if ($qgChars -gt 0) {
                            $qgEntry = [pscustomobject]@{ tool = 'quality_gate'; kind = 'avoided-ingest'; chars_without = [int]$qgChars; chars_with = 0; chars_saved = [int]$qgChars }
                            $metaOut.tool_breakdown = @($metaOut.tool_breakdown) + @($qgEntry)
                            # Also roll up to the portal savings bridge (numbers only).
                            try { Add-PromptParleToolSavings -Breakdown @($qgEntry) -Provider ([string]$metaOut.provider) } catch { }
                        }
                    }
                } catch { }
                try {
                    $metaOut.quality_supported = [int]$qg.supported
                    $metaOut.quality_partial = [int]$qg.partial
                    $metaOut.quality_unsupported = [int]$qg.unsupported
                    $metaOut.quality_corrected = [bool]$qg.corrected
                } catch { }
                if ($qg.applied) { $metaOut.quality_gate = $true }
                try {
                    if ($qg.claims) {
                        $metaOut.quality_claims = @($qg.claims | ForEach-Object {
                            [ordered]@{ claim = [string]$_.claim; status = [string]$_.status }
                        })
                    }
                } catch { }
            }
            # Last-resort high-severity only if gate never evaluated claims at all
            $gateEvaluated = $qg.applied -or ($null -ne $qg.score_pct) -or (
                [string]$qg.reason -match 'clean-silent|partial-silent|scored|unverified|corrected|no-claims|no-scored|no-evidence-meta|thin-evidence|empty-evidence|no-evidence|too-short|session-mode|procedural-menu|hands-only-nonproduct'
            )
            if (-not $gateEvaluated) {
                $gp = Invoke-PromptParleGroundingPostPass -ResponseText $respText -Context $gctx
                if ($gp.applied) {
                    $respText = [string]$gp.text
                    Write-Host ("  chat: grounding flagged {0} high-severity phrase(s)" -f $gp.flagged.Count) -ForegroundColor Yellow
                    if ($metaOut) {
                        $metaOut.grounding_flagged = @($gp.flagged)
                        $metaOut.grounding_audit = $true
                    }
                }
            }
        } catch {
            Write-Host ("  chat: quality/provenance post-pass warning: {0}" -f $_) -ForegroundColor DarkYellow
        }
        $chatStage = 'serialize'
        $payload = @{
            response         = [string]$respText
            optimized_prompt = Get-PromptParleProp $result 'optimized_prompt' (Get-PromptParleProp $result 'OptimizedPrompt' $null)
            metadata         = $metaOut
        }
        # Keep error field if present
        $errField = Get-PromptParleProp $result 'error'
        if ($errField) { $payload.error = [string]$errField }
        if ($metaOut) {
            Write-Host ("  chat: ok  {0} → {1} tokens (−{2}%) dial={3} strat={4}" -f `
                $metaOut.original_tokens, $metaOut.optimized_tokens, $metaOut.token_reduction_percent, `
                $metaOut.compression_level, $metaOut.strategy) -ForegroundColor DarkGreen
        } else {
            Write-Host '  chat: ok (no metadata)' -ForegroundColor DarkGreen
        }
        return $payload
    } catch {
        $verChat = 'unknown'
        try { $verChat = Get-PromptParleClientVersion } catch { }
        $etype = ''
        try { $etype = $_.Exception.GetType().FullName } catch { $etype = 'Exception' }
        $emsg = $_.Exception.Message
        if (-not $emsg) { $emsg = "$_" }
        $full = ("Chat failed [v{0}] at {1}: {2}: {3}" -f $verChat, $chatStage, $etype, $emsg)
        Write-Host ("  chat: error - {0}" -f $full) -ForegroundColor Red
        Write-PromptParleDebugLog ("chat FAIL " + $full + " stack=" + $_.ScriptStackTrace)
        return @{ error = $full }
    }
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

      Stop / control options (this PowerShell window):
        - [U] Update  [Shift+U] Force  [R] Restart  [Q] Quit  [O] Open UI  [H] Help
        - Ctrl+C
        - Browser: Stop server / Update
        - Other window: Stop-PromptParleLocalServer
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

    # Per-run local API token — blocks malicious pages from calling 127.0.0.1 tools/FS/SSH.
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $tokBytes = New-Object byte[] 32
    $rng.GetBytes($tokBytes)
    $rng.Dispose()
    $localUiToken = -join ($tokBytes | ForEach-Object { $_.ToString('x2') })
    $script:PromptParleLocalUiToken = $localUiToken
    $tokenFile = Join-Path $script:PromptParleConfigDir 'local-ui.token'
    try {
        if (-not (Test-Path -LiteralPath $script:PromptParleConfigDir)) {
            New-Item -ItemType Directory -Path $script:PromptParleConfigDir -Force | Out-Null
        }
        Set-Content -LiteralPath $tokenFile -Value $localUiToken -Encoding ASCII -NoNewline
        Set-PromptParleConfigAcl -Path $tokenFile
    } catch {
        Write-Warning "Could not write local UI token file: $_"
    }
    # Inject token + fetch wrapper into the HTML served to the browser only
    $inject = @"
<script>
window.__PP_LOCAL_TOKEN__ = '$localUiToken';
(function () {
  var _fetch = window.fetch.bind(window);
  window.fetch = function (input, init) {
    init = init || {};
    var url = typeof input === 'string' ? input : (input && input.url) || '';
    var isLocalApi = false;
    if (url.indexOf('/api/') === 0) isLocalApi = true;
    else if (url.indexOf('http://127.0.0.1') === 0 && url.indexOf('/api/') !== -1) isLocalApi = true;
    else if (url.indexOf('http://localhost') === 0 && url.indexOf('/api/') !== -1) isLocalApi = true;
    if (isLocalApi) {
      var h = new Headers(init.headers || {});
      if (!h.has('X-PromptParle-Local')) {
        h.set('X-PromptParle-Local', window.__PP_LOCAL_TOKEN__ || '');
      }
      init.headers = h;
    }
    return _fetch(input, init);
  };
})();
</script>
"@
    if ($html -match '(?i)<head[^>]*>') {
        $html = [regex]::Replace($html, '(?i)<head[^>]*>', { param($m) $m.Value + $inject }, 1)
    } else {
        $html = $inject + $html
    }

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
    $script:PromptParleConsoleRestart = $false
    $script:PromptParleConsoleBusy = $false
    # Shared ref so cancel handler and main loop can both print progress
    $script:PromptParleListener = $listener
    $consoleKeys = Test-PromptParleConsoleInteractive

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
    if ($consoleKeys) {
        Write-PromptParleConsoleHotkeyHelp -Url $url
        Write-Host ''
        Write-Host '  Also: browser Stop/Update · other window: Stop-PromptParleLocalServer' -ForegroundColor DarkGray
    } else {
        Write-Host '  Stop any of these ways:' -ForegroundColor Yellow
        Write-Host '    - Ctrl+C in this window' -ForegroundColor White
        Write-Host '    - Browser button: Stop server' -ForegroundColor White
        Write-Host '    - Close this window with the X' -ForegroundColor White
        Write-Host '    - Other window: Stop-PromptParleLocalServer' -ForegroundColor White
    }
    Write-Host ''

    Open-PromptParleUrl -Url $url

    try {
        while ($listener.IsListening -and -not $script:PromptParleShouldStop) {
            # Polling GetContext so Ctrl+C / Stop / console keys can interrupt
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
                # Console hotkeys only while idle (waiting for next HTTP request)
                if ($consoleKeys -and -not $script:PromptParleConsoleBusy) {
                    try {
                        $hk = Read-PromptParleConsoleHotkey
                        if ($hk) {
                            $breakWait = Invoke-PromptParleConsoleHotkey -Action $hk -Port $Port -Url $url -Listener $listener
                            if ($breakWait) { break }
                        }
                    } catch { }
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
                # --- Local UI auth gate (Achilles heel) ---
                # Static shell + logo: no token. Everything under /api/* needs
                # X-PromptParle-Local matching this process's per-run token.
                # Also reject non-loopback Host and bad Origin/Referer.
                $isStaticShell = (
                    ($req.HttpMethod -eq 'GET') -and (
                        $path -eq '/' -or
                        $path -eq '/index.html' -or
                        $path -eq '/logo.png' -or
                        $path -eq '/favicon.ico' -or
                        $path -eq '/favicon-32.png' -or
                        $path -eq '/apple-touch-icon.png' -or
                        $path -match '\.(png|ico|svg|css|js|woff2?)$'
                    )
                )
                if (-not $isStaticShell) {
                    $authOk = Test-PromptParleLocalUiRequest -Request $req -ExpectedToken $localUiToken -Port $Port
                    if (-not $authOk) {
                        Write-PromptParleHttpResponse -Context $ctx -StatusCode 401 -ContentType 'application/json; charset=utf-8' -Body '{"error":"local_ui_unauthorized","message":"Missing or invalid local UI token. Open the UI from the PowerShell session (pp), not a bookmark from another origin."}'
                        continue
                    }
                }

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

                # Brand assets for browser tab + sidebar (no auth; loopback only via listener bind)
                if ($req.HttpMethod -eq 'GET' -and (
                        $path -eq '/logo.png' -or $path -eq '/local-ui/logo.png' -or
                        $path -eq '/favicon.ico' -or $path -eq '/favicon-32.png' -or
                        $path -eq '/apple-touch-icon.png'
                    )) {
                    $assetName = switch -Regex ($path) {
                        'favicon\.ico$' { 'favicon.ico' }
                        'favicon-32\.png$' { 'favicon-32.png' }
                        'apple-touch-icon\.png$' { 'apple-touch-icon.png' }
                        default { 'logo.png' }
                    }
                    $assetPath = Join-Path $root ("local-ui\" + $assetName)
                    if (-not (Test-Path -LiteralPath $assetPath)) {
                        $assetPath = Join-Path $root ("local-ui/" + $assetName)
                    }
                    # Fall back to logo.png when a size-specific icon is missing
                    if (-not (Test-Path -LiteralPath $assetPath) -and $assetName -ne 'logo.png') {
                        $assetPath = Join-Path $root 'local-ui\logo.png'
                        if (-not (Test-Path -LiteralPath $assetPath)) {
                            $assetPath = Join-Path $root 'local-ui/logo.png'
                        }
                        $assetName = 'logo.png'
                    }
                    if (Test-Path -LiteralPath $assetPath) {
                        $bytes = [System.IO.File]::ReadAllBytes($assetPath)
                        $ctype = if ($assetName -match '\.ico$') { 'image/x-icon' } else { 'image/png' }
                        Write-PromptParleHttpResponse -Context $ctx -ContentType $ctype -Bytes $bytes
                    } else {
                        Write-PromptParleHttpResponse -Context $ctx -StatusCode 404 -ContentType 'text/plain; charset=utf-8' -Body 'icon not found'
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
                        # 0.25 Local-first: keys on this PC; curated model lists (no portal key vault)
                        if (-not (Get-Command Get-PromptParleLocalProvidersPublic -ErrorAction SilentlyContinue)) {
                            throw 'Get-PromptParleLocalProvidersPublic missing — reinstall module (LocalFirst.ps1).'
                        }
                        $result = Get-PromptParleLocalProvidersPublic
                        $json = $null
                        try {
                            $json = ($result | ConvertTo-Json -Depth 10 -Compress)
                        } catch {
                            throw "ConvertTo-Json failed for providers: $_"
                        }
                        if (-not $json -or $json -eq 'null') {
                            throw 'Providers JSON was empty (serialization). Update to 0.25.7+.'
                        }
                        Write-PromptParleHttpResponse -Context $ctx -ContentType 'application/json; charset=utf-8' -Body $json
                    } catch {
                        $err = @{ error = "$_" } | ConvertTo-Json -Compress
                        Write-PromptParleHttpResponse -Context $ctx -StatusCode 500 -ContentType 'application/json; charset=utf-8' -Body $err
                    }
                    continue
                }

                # Local-first: store provider key on this PC only (never uploaded to portal)
                if ($req.HttpMethod -eq 'POST' -and $path -eq '/api/providers/local-key') {
                    try {
                        $encPk = $req.ContentEncoding
                        if (-not $encPk) { $encPk = [System.Text.Encoding]::UTF8 }
                        $readerPk = New-Object System.IO.StreamReader($req.InputStream, $encPk)
                        $rawPk = $readerPk.ReadToEnd()
                        $readerPk.Close()
                        $bodyPk = ConvertFrom-PromptParleJson -Json $rawPk
                        $provPk = [string](Get-PromptParleProp $bodyPk 'provider' '')
                        $keyPk = [string](Get-PromptParleProp $bodyPk 'api_key' (Get-PromptParleProp $bodyPk 'apiKey' ''))
                        if (-not $provPk -or -not $keyPk) { throw 'provider and api_key required' }
                        Set-PromptParleProviderKey -Provider $provPk.ToLowerInvariant() -ApiKey $keyPk
                        $outPk = @{
                            ok         = $true
                            provider   = $provPk.ToLowerInvariant()
                            local_first = $true
                            message    = 'Key stored on this PC only (DPAPI when available).'
                        } | ConvertTo-Json -Compress
                        Write-PromptParleHttpResponse -Context $ctx -ContentType 'application/json; charset=utf-8' -Body $outPk
                    } catch {
                        $err = @{ error = "$_" } | ConvertTo-Json -Compress
                        Write-PromptParleHttpResponse -Context $ctx -StatusCode 400 -ContentType 'application/json; charset=utf-8' -Body $err
                    }
                    continue
                }

                # Dynamic model list for one provider (local curated catalog; no portal key)
                if ($req.HttpMethod -eq 'GET' -and $path -eq '/api/models') {
                    try {
                        $qM = [string]$req.Url.Query
                        $provM = ''
                        if ($qM -and $qM -match '(?:^|[?&])provider=([^&]*)') {
                            $provM = [Uri]::UnescapeDataString(($Matches[1] -replace '\+', ' '))
                        }
                        if (-not $provM) { throw 'Query provider=openai|anthropic|gemini|grok required' }
                        $allP = Get-PromptParleLocalProvidersPublic
                        $hit = $null
                        foreach ($pr in @($allP.providers)) {
                            if ([string](Get-PromptParleProp $pr 'id' '') -eq $provM.ToLowerInvariant()) { $hit = $pr; break }
                        }
                        if (-not $hit) { throw "Unknown provider: $provM" }
                        $result = [ordered]@{
                            provider    = $provM.ToLowerInvariant()
                            models      = @(Get-PromptParleProp $hit 'models' @())
                            default     = Get-PromptParleProp $hit 'default_model' ''
                            local_first = $true
                        }
                        $json = ($result | ConvertTo-Json -Depth 8 -Compress)
                        Write-PromptParleHttpResponse -Context $ctx -ContentType 'application/json; charset=utf-8' -Body $json
                    } catch {
                        $err = @{ error = "$_" } | ConvertTo-Json -Compress
                        Write-PromptParleHttpResponse -Context $ctx -StatusCode 400 -ContentType 'application/json; charset=utf-8' -Body $err
                    }
                    continue
                }

                # Portal ↔ client settings (GET pull / PATCH push)
                if (($req.HttpMethod -eq 'GET' -or $req.HttpMethod -eq 'PATCH' -or $req.HttpMethod -eq 'POST') -and $path -eq '/api/settings') {
                    try {
                        if ($req.HttpMethod -eq 'GET') {
                            $result = Invoke-PromptParleApi -Method GET -Path '/api/v1/settings'
                            # Also apply to local session so UI + chat match portal
                            try { $null = Sync-PromptParlePortalSettings -Quiet } catch { }
                            $json = ($result | ConvertTo-Json -Depth 8 -Compress)
                            Write-PromptParleHttpResponse -Context $ctx -ContentType 'application/json; charset=utf-8' -Body $json
                        } else {
                            $encS = $req.ContentEncoding
                            if (-not $encS) { $encS = [System.Text.Encoding]::UTF8 }
                            $readerS = New-Object System.IO.StreamReader($req.InputStream, $encS)
                            $rawS = $readerS.ReadToEnd()
                            $readerS.Close()
                            $bodyS = ConvertFrom-PromptParleJson -Json $rawS
                            # Normalize client shape → portal v1 settings
                            $patch = [ordered]@{}
                            $pp = Get-PromptParleProp $bodyS 'preferred_provider' (Get-PromptParleProp $bodyS 'preferredProvider' $null)
                            if ($null -ne $pp) { $patch.preferred_provider = $pp }
                            $pm = Get-PromptParleProp $bodyS 'preferred_models' (Get-PromptParleProp $bodyS 'preferredModels' $null)
                            if ($null -ne $pm) { $patch.preferred_models = $pm }
                            $one = Get-PromptParleProp $bodyS 'preferred_model' (Get-PromptParleProp $bodyS 'preferredModel' $null)
                            if ($null -ne $one) { $patch.preferred_model = $one }
                            $dd = Get-PromptParleProp $bodyS 'default_dial' (Get-PromptParleProp $bodyS 'defaultDial' (Get-PromptParleProp $bodyS 'dial' $null))
                            if ($null -ne $dd) { try { $patch.default_dial = [int]$dd } catch { } }
                            $dt = Get-PromptParleProp $bodyS 'default_tools_enabled' (Get-PromptParleProp $bodyS 'defaultToolsEnabled' (Get-PromptParleProp $bodyS 'tools_enabled' $null))
                            if ($null -ne $dt) { $patch.default_tools_enabled = [bool]$dt }
                            $result = Invoke-PromptParleApi -Method PATCH -Path '/api/v1/settings' -Body $patch
                            # Mirror into local session
                            try {
                                $baseS = Get-PromptParleSessionState
                                $sp = @{ Base = $baseS }
                                $np = Get-PromptParleProp $result 'preferred_provider' $null
                                if ($np) { $sp.Provider = [string]$np }
                                $nd = Get-PromptParleProp $result 'default_dial' $null
                                if ($null -ne $nd) { try { $sp.Dial = [int]$nd } catch { } }
                                $nt = Get-PromptParleProp $result 'default_tools_enabled' $null
                                if ($null -ne $nt) { $sp.ToolsEnabled = [bool]$nt }
                                $modelsR = Get-PromptParleProp $result 'preferred_models' $null
                                $provForM = if ($np) { [string]$np } else { [string](Get-PromptParleProp $baseS 'provider' '') }
                                if ($modelsR -and $provForM) {
                                    $mv = Get-PromptParleProp $modelsR $provForM $null
                                    if (-not $mv) { try { $mv = [string]$modelsR.$provForM } catch { } }
                                    if ($mv) { $sp.Model = [string]$mv }
                                }
                                # Single model update from preferred_model
                                $oneR = Get-PromptParleProp $bodyS 'preferred_model' $null
                                if ($oneR) {
                                    $om = Get-PromptParleProp $oneR 'model' $null
                                    if ($om) { $sp.Model = [string]$om }
                                    $op = Get-PromptParleProp $oneR 'provider' $null
                                    if ($op) { $sp.Provider = [string]$op }
                                }
                                $nextS = New-PromptParleSessionSnapshot @sp
                                Save-PromptParleSessionState -State $nextS
                            } catch { }
                            $json = ($result | ConvertTo-Json -Depth 8 -Compress)
                            Write-PromptParleHttpResponse -Context $ctx -ContentType 'application/json; charset=utf-8' -Body $json
                        }
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
                        # Piggyback: flush accumulated per-tool savings to the portal
                        # (aggregate numbers only). Best-effort; failure never blocks heartbeat.
                        try { Send-PromptParleToolSavings } catch { }
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
                            ssh_name         = [string](Get-PromptParleProp $ws 'ssh_name' (Get-PromptParleProp $st 'ssh_name' ''))
                            connections      = @(Get-PromptParleConnections)
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

                # Persist local session fields immediately (model/provider/dial) so mid-chat switches stick
                if (($req.HttpMethod -eq 'POST' -or $req.HttpMethod -eq 'PATCH') -and $path -eq '/api/session') {
                    try {
                        $encSess = $req.ContentEncoding
                        if (-not $encSess) { $encSess = [System.Text.Encoding]::UTF8 }
                        $readerSess = New-Object System.IO.StreamReader($req.InputStream, $encSess)
                        $rawSess = $readerSess.ReadToEnd()
                        $readerSess.Close()
                        $bodySess = ConvertFrom-PromptParleJson -Json $rawSess
                        $baseSess = Get-PromptParleSessionState
                        $sp = @{ Base = $baseSess }
                        $provS = Get-PromptParleProp $bodySess 'provider' $null
                        if ($provS) { $sp.Provider = [string]$provS }
                        # Always apply model when key present (including explicit switch to grok-3 etc.)
                        if ($null -ne (Get-PromptParleProp $bodySess 'model' $null) -or
                            ($bodySess.PSObject.Properties.Name -contains 'model')) {
                            $modS = [string](Get-PromptParleProp $bodySess 'model' '')
                            $sp.Model = $modS
                        }
                        $dialS = Get-PromptParleProp $bodySess 'dial' (Get-PromptParleProp $bodySess 'compression_level' $null)
                        if ($null -ne $dialS) {
                            try {
                                $di = [int]$dialS
                                if ($di -ge 1 -and $di -le 5) { $sp.Dial = $di }
                            } catch { }
                        }
                        $teS = Get-PromptParleProp $bodySess 'tools_enabled' (Get-PromptParleProp $bodySess 'toolsEnabled' $null)
                        if ($null -ne $teS) { $sp.ToolsEnabled = [bool]$teS }
                        $nextSess = New-PromptParleSessionSnapshot @sp
                        Save-PromptParleSessionState -State $nextSess
                        $payloadS = @{
                            ok       = $true
                            provider = $nextSess.provider
                            model    = $nextSess.model
                            dial     = [int]$nextSess.dial
                            tools_enabled = [bool]$nextSess.tools_enabled
                        } | ConvertTo-Json -Depth 4 -Compress
                        Write-PromptParleHttpResponse -Context $ctx -ContentType 'application/json; charset=utf-8' -Body $payloadS
                    } catch {
                        $err = @{ ok = $false; error = "$_" } | ConvertTo-Json -Compress
                        Write-PromptParleHttpResponse -Context $ctx -StatusCode 400 -ContentType 'application/json; charset=utf-8' -Body $err
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

                # SSH connection history (friendly names; no passwords) — sorted recent-first
                if ($req.HttpMethod -eq 'GET' -and $path -eq '/api/ssh/history') {
                    try {
                        $hist = @(Get-PromptParleSshHistory -Max 30)
                        $payload = @{
                            ok      = $true
                            history = @($hist | ForEach-Object {
                                [ordered]@{
                                    name      = [string]$_.name
                                    target    = [string]$_.target
                                    port      = ConvertTo-PromptParleSshPort -Value $_.port
                                    cwd       = [string]$_.cwd
                                    last_used = [string]$_.last_used
                                }
                            })
                        } | ConvertTo-Json -Depth 5 -Compress
                        Write-PromptParleHttpResponse -Context $ctx -ContentType 'application/json; charset=utf-8' -Body $payload
                    } catch {
                        $err = @{ ok = $false; error = "$_"; history = @() } | ConvertTo-Json -Compress
                        Write-PromptParleHttpResponse -Context $ctx -StatusCode 400 -ContentType 'application/json; charset=utf-8' -Body $err
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
                                ok          = $true
                                path        = $ws.path
                                kind        = $ws.kind
                                exists      = $ws.exists
                                is_git      = $ws.is_git
                                branch      = $ws.branch
                                remote      = $ws.remote
                                recent      = @($ws.recent)
                                connections = @(Get-PromptParleConnections)
                            } | ConvertTo-Json -Depth 6 -Compress
                            Write-PromptParleHttpResponse -Context $ctx -ContentType 'application/json; charset=utf-8' -Body $payload
                        } else {
                            $encW = $req.ContentEncoding
                            if (-not $encW) { $encW = [System.Text.Encoding]::UTF8 }
                            $readerW = New-Object System.IO.StreamReader($req.InputStream, $encW)
                            $rawW = $readerW.ReadToEnd()
                            $readerW.Close()
                            $bodyW = ConvertFrom-PromptParleJson -Json $rawW
                            $action = ConvertTo-PromptParleSingleString (Get-PromptParleProp $bodyW 'action' 'add')
                            if (-not $action) { $action = 'add' }
                            $action = $action.ToLowerInvariant()
                            if ($action -eq 'clear' -or $action -eq 'clear_all') {
                                Clear-PromptParleWorkspace -All
                                $payload = @{ ok = $true; path = ''; kind = 'none'; connections = @(Get-PromptParleConnections); message = 'All local folders detached.' } | ConvertTo-Json -Depth 6 -Compress
                            } elseif ($action -eq 'remove' -or $action -eq 'detach') {
                                $rid = ConvertTo-PromptParleSingleString (Get-PromptParleProp $bodyW 'id' '')
                                if (-not $rid) {
                                    $rp = ConvertTo-PromptParleSingleString (Get-PromptParleProp $bodyW 'path' '')
                                    if ($rp) {
                                        foreach ($c in @(Get-PromptParleConnections)) {
                                            if ($c.kind -eq 'local' -and $c.path -and (Test-PromptParlePathEqual -A $c.path -B $rp)) {
                                                $rid = $c.id; break
                                            }
                                        }
                                    }
                                }
                                if (-not $rid) { throw 'Missing id for remove' }
                                $null = Remove-PromptParleConnection -Id $rid
                                $wsNow = Get-PromptParleWorkspace
                                $payload = @{
                                    ok = $true; path = $wsNow.path; kind = $wsNow.kind
                                    connections = @(Get-PromptParleConnections)
                                    message = "Detached $rid"
                                } | ConvertTo-Json -Depth 6 -Compress
                            } elseif ($action -eq 'active') {
                                $aid = ConvertTo-PromptParleSingleString (Get-PromptParleProp $bodyW 'id' (Get-PromptParleProp $bodyW 'label' ''))
                                if (-not $aid) { throw 'Missing id for active' }
                                $hit = Set-PromptParleActiveLocalConnection -IdOrLabel $aid
                                $wsNow = Get-PromptParleWorkspace
                                $payload = @{
                                    ok = $true; path = $wsNow.path; kind = $wsNow.kind
                                    active_id = $hit.id; connections = @(Get-PromptParleConnections)
                                    message = "Active local: $($hit.label)"
                                } | ConvertTo-Json -Depth 6 -Compress
                            } elseif ($action -eq 'reindex') {
                                $rid = ConvertTo-PromptParleSingleString (Get-PromptParleProp $bodyW 'id' '')
                                $cHit = $null
                                foreach ($c in @(Get-PromptParleConnections)) {
                                    if (-not $rid -or $c.id -eq $rid) {
                                        if ($c.kind -in @('local', 'knowledge')) {
                                            $cHit = $c
                                            if ($rid) { break }
                                            if ($c.active) { break }
                                        }
                                    }
                                }
                                if (-not $cHit) { throw 'No connection to reindex' }
                                $idx = Update-PromptParleConnectionCatalog -Connection $cHit
                                $list = @(Get-PromptParleConnections)
                                foreach ($c in $list) {
                                    if ($c.id -eq $cHit.id) {
                                        $c.indexed_at = [string]$idx.indexed_at
                                        $c.file_count = [int]$idx.file_count
                                    }
                                }
                                $null = Save-PromptParleConnectionsState -Connections $list
                                $payload = @{
                                    ok = $true; id = $cHit.id; file_count = [int]$idx.file_count
                                    connections = @(Get-PromptParleConnections)
                                    message = "Indexed $($idx.file_count) files for $($cHit.label)"
                                } | ConvertTo-Json -Depth 6 -Compress
                            } else {
                                # add (default) or replace
                                $wp = ConvertTo-PromptParleSingleString (Get-PromptParleProp $bodyW 'path' '')
                                if (-not $wp) { throw 'Missing path' }
                                $mode = if ($action -eq 'replace' -or $action -eq 'set') { 'replace' } else { 'add' }
                                $lab = ConvertTo-PromptParleSingleString (Get-PromptParleProp $bodyW 'label' '')
                                $wsSet = Set-PromptParleWorkspace -Path $wp -Mode $mode -Label $lab
                                $wsFull = Get-PromptParleWorkspace
                                $recentOut = @()
                                foreach ($r in @($wsSet.recent)) {
                                    $rs = ConvertTo-PromptParleSingleString $r
                                    if ($rs) { $recentOut += $rs }
                                }
                                $payload = @{
                                    ok          = $true
                                    path        = [string]$wsSet.path
                                    kind        = [string]$wsSet.kind
                                    is_git      = [bool]$wsSet.is_git
                                    branch      = $wsFull.branch
                                    remote      = $wsFull.remote
                                    recent      = $recentOut
                                    id          = [string](Get-PromptParleProp $wsSet 'id' '')
                                    label       = [string](Get-PromptParleProp $wsSet 'label' '')
                                    file_count  = $(try { [int](Get-PromptParleProp $wsSet 'file_count' 0) } catch { 0 })
                                    connections = @(Get-PromptParleConnections)
                                    message     = "Attached $($wsSet.path) ($mode · idx $(try { [int](Get-PromptParleProp $wsSet 'file_count' 0) } catch { 0 }) on disk)"
                                } | ConvertTo-Json -Depth 6 -Compress
                            }
                            Write-PromptParleHttpResponse -Context $ctx -ContentType 'application/json; charset=utf-8' -Body $payload
                        }
                    } catch {
                        $errMsg = "$_"
                        $exType = ''
                        try {
                            Write-PromptParleDebugLog ("/api/workspace FAIL: " + $_.Exception.ToString() + " :: " + $_.ScriptStackTrace)
                            $exType = $_.Exception.GetType().FullName
                            $errMsg = $_.Exception.Message
                            if ($_.ScriptStackTrace) {
                                $top = @($_.ScriptStackTrace -split "`r?`n" | Select-Object -First 4)
                                $errMsg = $errMsg + ' | ' + ($top -join ' > ')
                            }
                        } catch {
                            $errMsg = "$_"
                        }
                        $err = @{ ok = $false; error = $errMsg; exception_type = $exType } | ConvertTo-Json -Compress
                        Write-PromptParleHttpResponse -Context $ctx -StatusCode 400 -ContentType 'application/json; charset=utf-8' -Body $err
                    }
                    continue
                }

                if (($req.HttpMethod -eq 'GET' -or $req.HttpMethod -eq 'POST') -and $path -eq '/api/knowledge') {
                    try {
                        if ($req.HttpMethod -eq 'GET') {
                            $know = @((Get-PromptParleConnections) | Where-Object { $_.kind -eq 'knowledge' })
                            $payload = @{ ok = $true; knowledge = $know; connections = @(Get-PromptParleConnections) } | ConvertTo-Json -Depth 6 -Compress
                            Write-PromptParleHttpResponse -Context $ctx -ContentType 'application/json; charset=utf-8' -Body $payload
                        } else {
                            $encK = $req.ContentEncoding
                            if (-not $encK) { $encK = [System.Text.Encoding]::UTF8 }
                            $readerK = New-Object System.IO.StreamReader($req.InputStream, $encK)
                            $rawK = $readerK.ReadToEnd()
                            $readerK.Close()
                            $bodyK = ConvertFrom-PromptParleJson -Json $rawK
                            $actionK = (ConvertTo-PromptParleSingleString (Get-PromptParleProp $bodyK 'action' 'add')).ToLowerInvariant()
                            if ($actionK -eq 'remove' -or $actionK -eq 'detach') {
                                $kid = ConvertTo-PromptParleSingleString (Get-PromptParleProp $bodyK 'id' '')
                                if (-not $kid) { throw 'Missing id' }
                                $null = Remove-PromptParleConnection -Id $kid
                                $payload = @{ ok = $true; connections = @(Get-PromptParleConnections); message = "Knowledge detached $kid" } | ConvertTo-Json -Depth 6 -Compress
                            } else {
                                $src = (ConvertTo-PromptParleSingleString (Get-PromptParleProp $bodyK 'source' 'local')).ToLowerInvariant()
                                if ($src -ne 'ssh') { $src = 'local' }
                                $kpath = ConvertTo-PromptParleSingleString (Get-PromptParleProp $bodyK 'path' '')
                                $klab = ConvertTo-PromptParleSingleString (Get-PromptParleProp $bodyK 'label' '')
                                $kst = ConvertTo-PromptParleSingleString (Get-PromptParleProp $bodyK 'ssh_target' (Get-PromptParleProp $bodyK 'target' ''))
                                $ksp = 22
                                try { $ksp = [int](Get-PromptParleProp $bodyK 'ssh_port' (Get-PromptParleProp $bodyK 'port' 22)) } catch { $ksp = 22 }
                                $ksc = ConvertTo-PromptParleSingleString (Get-PromptParleProp $bodyK 'ssh_cwd' (Get-PromptParleProp $bodyK 'cwd' ''))
                                $ksn = ConvertTo-PromptParleSingleString (Get-PromptParleProp $bodyK 'ssh_name' (Get-PromptParleProp $bodyK 'name' ''))
                                $added = Add-PromptParleKnowledgeConnection -Path $kpath -Label $klab -Source $src -SshTarget $kst -SshPort $ksp -SshCwd $ksc -SshName $ksn
                                $payload = @{
                                    ok = $true
                                    id = $added.id
                                    label = $added.label
                                    path = $added.path
                                    file_count = $added.file_count
                                    connections = @(Get-PromptParleConnections)
                                    message = "Knowledge attached: $($added.label) (indexed $($added.file_count) files; not dumped into chat)"
                                } | ConvertTo-Json -Depth 6 -Compress
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

                if ($req.HttpMethod -eq 'POST' -and $path -eq '/api/feedback') {
                    $enc = $req.ContentEncoding
                    if (-not $enc) { $enc = [System.Text.Encoding]::UTF8 }
                    $reader = New-Object System.IO.StreamReader($req.InputStream, $enc)
                    $rawBody = $reader.ReadToEnd()
                    $reader.Close()
                    try {
                        if ([string]::IsNullOrWhiteSpace($rawBody)) { throw 'Empty body' }
                        $fb = ConvertFrom-PromptParleJson -Json $rawBody
                        $kind = [string](Get-PromptParleProp $fb 'kind' 'suggest')
                        $title = [string](Get-PromptParleProp $fb 'title' '')
                        $bodyText = [string](Get-PromptParleProp $fb 'body' '')
                        $payload = [ordered]@{
                            kind  = $kind
                            title = $title
                            body  = $bodyText
                        }
                        $result = Invoke-PromptParleApi -Method POST -Path '/api/v1/feedback' -Body $payload
                        $json = $result | ConvertTo-Json -Depth 8 -Compress
                        Write-PromptParleHttpResponse -Context $ctx -StatusCode 200 -ContentType 'application/json; charset=utf-8' -Body $json
                    } catch {
                        $err = @{ ok = $false; error = "$_" } | ConvertTo-Json -Compress
                        Write-PromptParleHttpResponse -Context $ctx -StatusCode 400 -ContentType 'application/json; charset=utf-8' -Body $err
                    }
                    continue
                }

                if ($req.HttpMethod -eq 'POST' -and $path -eq '/api/chat') {
                    $enc = $req.ContentEncoding; if (-not $enc) { $enc = [System.Text.Encoding]::UTF8 }
                    $reader = New-Object System.IO.StreamReader($req.InputStream, $enc)
                    $rawBody = $reader.ReadToEnd(); $reader.Close()
                    try {
                        $body = ConvertFrom-PromptParleJson -Json $rawBody
                        # 0.30: background handoff. When the UI asks (turn is running long),
                        # spawn a detached child pwsh and return a job_id immediately so the
                        # single-threaded server stays free and the user can keep chatting.
                        $bg = Get-PromptParleProp $body 'background' $false
                        if ($bg -eq $true) {
                            $bhash = @{}
                            foreach ($p in $body.PSObject.Properties) { $bhash[$p.Name] = $p.Value }
                            $bhash.Remove('background') | Out-Null
                            $sid = [string](Get-PromptParleProp $body 'client_session_id' (Get-PromptParleProp $body 'clientSessionId' ''))
                            $ttl = [string](Get-PromptParleProp $body 'session_title' (Get-PromptParleProp $body 'sessionTitle' ''))
                            $started = Start-PromptParleChatJob -Payload $bhash -SessionId $sid -Title $ttl
                            $json = ConvertTo-PromptParleJson -InputObject $started -Depth 6
                            Write-PromptParleHttpResponse -Context $ctx -ContentType 'application/json; charset=utf-8' -Body $json
                        } else {
                            $payload = Invoke-PromptParleChatTurnCore -Body $body
                            $json = ConvertTo-PromptParleJson -InputObject $payload -Depth 12
                            Write-PromptParleHttpResponse -Context $ctx -ContentType 'application/json; charset=utf-8' -Body $json
                        }
                    } catch {
                        $err = @{ error = "$_" } | ConvertTo-Json -Compress
                        Write-PromptParleHttpResponse -Context $ctx -StatusCode 502 -ContentType 'application/json; charset=utf-8' -Body $err
                    }
                    continue
                }

                # 0.30: poll a background chat job by id
                if ($req.HttpMethod -eq 'GET' -and $path -eq '/api/chat/job') {
                    try {
                        $jid = [string]$req.QueryString['id']
                        if (-not $jid) { throw 'missing id' }
                        $job = Read-PromptParleJob -Id $jid
                        if ($null -eq $job) {
                            Write-PromptParleHttpResponse -Context $ctx -StatusCode 404 -ContentType 'application/json; charset=utf-8' -Body (@{ error = 'no such job' } | ConvertTo-Json -Compress)
                        } else {
                            $json = ConvertTo-PromptParleJson -InputObject $job -Depth 12
                            Write-PromptParleHttpResponse -Context $ctx -ContentType 'application/json; charset=utf-8' -Body $json
                        }
                    } catch {
                        Write-PromptParleHttpResponse -Context $ctx -StatusCode 400 -ContentType 'application/json; charset=utf-8' -Body (@{ error = "$_" } | ConvertTo-Json -Compress)
                    }
                    continue
                }

                # 0.30: list pending/recent background jobs (for the UI badge)
                if ($req.HttpMethod -eq 'GET' -and $path -eq '/api/chat/jobs') {
                    try {
                        $list = Get-PromptParleJobList
                        $json = ConvertTo-PromptParleJson -InputObject @{ jobs = @($list) } -Depth 8
                        Write-PromptParleHttpResponse -Context $ctx -ContentType 'application/json; charset=utf-8' -Body $json
                    } catch {
                        Write-PromptParleHttpResponse -Context $ctx -StatusCode 500 -ContentType 'application/json; charset=utf-8' -Body (@{ error = "$_" } | ConvertTo-Json -Compress)
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
        # Cleanup only — PowerShell forbids return/break/continue (and prefer no exit) in finally.
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
        # Drop per-run local UI token so a dead port cannot be abused with a stale token file
        try {
            $script:PromptParleLocalUiToken = $null
            $tokPath = Join-Path $script:PromptParleConfigDir 'local-ui.token'
            if (Test-Path -LiteralPath $tokPath) {
                Remove-Item -LiteralPath $tokPath -Force -ErrorAction SilentlyContinue
            }
        } catch { }
        $script:PromptParleShouldStop = $false
        $script:PromptParleStopAnnounced = $false
        $script:PromptParleListener = $null
        # Capture post-stop actions into function-scope flags (handled AFTER finally)
        $script:PromptParlePostStopExit = $false
        $script:PromptParlePostStopRestart = $false
        $script:PromptParlePostStopPort = $Port
        try {
            $gv = Get-Variable -Name PromptParleExitProcessAfterStop -Scope Script -ErrorAction SilentlyContinue
            if ($null -ne $gv -and [bool]$gv.Value) { $script:PromptParlePostStopExit = $true }
        } catch { }
        try {
            $gvR = Get-Variable -Name PromptParleConsoleRestart -Scope Script -ErrorAction SilentlyContinue
            if ($null -ne $gvR -and [bool]$gvR.Value) { $script:PromptParlePostStopRestart = $true }
        } catch { }
        try { $script:PromptParleExitProcessAfterStop = $false } catch { }
        try { $script:PromptParleConsoleRestart = $false } catch { }
        try { $script:PromptParleConsoleBusy = $false } catch { }
    }

    # Post-finally control flow (return / re-enter / exit are illegal inside finally)
    $postExit = $false
    $postRestart = $false
    $postPort = $Port
    try {
        $gvE = Get-Variable -Name PromptParlePostStopExit -Scope Script -ErrorAction SilentlyContinue
        if ($null -ne $gvE) { $postExit = [bool]$gvE.Value }
        $gvS = Get-Variable -Name PromptParlePostStopRestart -Scope Script -ErrorAction SilentlyContinue
        if ($null -ne $gvS) { $postRestart = [bool]$gvS.Value }
        $gvP = Get-Variable -Name PromptParlePostStopPort -Scope Script -ErrorAction SilentlyContinue
        if ($null -ne $gvP -and $gvP.Value) { $postPort = [int]$gvP.Value }
    } catch { }
    try { $script:PromptParlePostStopExit = $false } catch { }
    try { $script:PromptParlePostStopRestart = $false } catch { }

    if ($postExit) {
        Write-Host 'Local PromptParle server stopped — update handoff complete.' -ForegroundColor Green
        Write-Host 'Closing this window (new server is in the other PowerShell window)...' -ForegroundColor Cyan
        Start-Sleep -Milliseconds 400
        try {
            [System.Environment]::Exit(0)
        } catch {
            exit 0
        }
    }
    if ($postRestart) {
        Write-Host 'Local PromptParle server stopped — restarting...' -ForegroundColor Green
        Start-Sleep -Milliseconds 250
        Start-PromptParleLocalServer -Port $postPort
        return
    }
    Write-Host 'Local PromptParle server stopped.' -ForegroundColor Green
    Write-Host 'You can close this window or run:  pp' -ForegroundColor DarkGray
}

function Start-PromptParle {
    <#
    .SYNOPSIS
      Start PromptParle - local browser chat by default.

    .DESCRIPTION
      Default: starts a LOCAL web UI on http://127.0.0.1:7788 and opens it.
      The chat page runs on your machine (not hosted as your daily UI on AWS).

      -Cli     terminal chat
      -Cloud   open portal dashboard on promptparle.com (chat is desktop-only)

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
        Open-PromptParleBrowser -Cloud -Path '/app'
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
                $cliPrepRaw = Invoke-PromptParleAgentLocalPrep @cliPrepParams
                $cliPrep = $cliPrepRaw
                if ($cliPrepRaw -is [System.Array]) {
                    $cliPrep = $null
                    for ($ci = $cliPrepRaw.Length - 1; $ci -ge 0; $ci--) {
                        $c = $cliPrepRaw[$ci]
                        if ($null -eq $c -or $c -is [int] -or $c -is [long]) { continue }
                        if ($null -ne (Get-PromptParleProp $c 'prompt' $null) -or $null -ne (Get-PromptParleProp $c 'context' $null)) {
                            $cliPrep = $c; break
                        }
                    }
                    if ($null -eq $cliPrep -and $cliPrepRaw.Length -gt 0) { $cliPrep = $cliPrepRaw[-1] }
                }
                $cp = Get-PromptParleProp $cliPrep 'prompt' $null
                if ($null -ne $cp -and [string]$cp) { $trimmed = [string]$cp }
                $cc = Get-PromptParleProp $cliPrep 'context' $null
                if ($null -ne $cc) { $cliCtx = [string]$cc }
                $cn = Get-PromptParleProp $cliPrep 'notes' $null
                if ($cn) {
                    Write-Host ("  local: {0}" -f (@($cn) -join ', ')) -ForegroundColor DarkGray
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
                    } elseif ($qgCli.reason -match 'clean-silent|partial-silent') {
                        Write-Host ("  quality: silent ({0} {1}%)" -f $qgCli.reason, $qgCli.score_pct) -ForegroundColor DarkGray
                    } else {
                        # 0.22.3: high-severity only; never n-gram near-quote spam after gate
                        $gateEvalCli = $qgCli.applied -or ($null -ne $qgCli.score_pct) -or (
                            [string]$qgCli.reason -match 'clean-silent|partial-silent|no-claims|no-scored|no-evidence|thin-evidence|empty-evidence|too-short|no-evidence-meta'
                        )
                        if (-not $gateEvalCli) {
                            $gpCli = Invoke-PromptParleGroundingPostPass -ResponseText $txt -Context $gctxCli
                            if ($gpCli.applied) { $txt = [string]$gpCli.text; Write-Host ("  grounding: {0} high-severity flag(s)" -f $gpCli.flagged.Count) -ForegroundColor Yellow }
                        }
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
    'Sync-PromptParlePortalSettings',
    'Get-PromptParleConfig',
    'Get-PromptParleProvider',
    'Set-PromptParleProviderKey',
    'Remove-PromptParleProviderKey',
    'Set-PromptParleSecretPolicy',
    'Get-PromptParleUsage',
    'Invoke-PromptParle',
    'Invoke-PromptParleLocalFirst',
    'Invoke-PromptParleAgentTurn',
    'Invoke-PromptParleNativeAgentTurn',
    'Invoke-PromptParleChatTurnCore',
    'Invoke-PromptParleRunChatJob',
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
    'Get-PromptParleConnections',
    'Set-PromptParleActiveLocalConnection',
    'Add-PromptParleKnowledgeConnection',
    'Remove-PromptParleConnection',
    'Update-PromptParleConnectionCatalog',
    'Search-PromptParleKnowledgeCatalog',
    'Read-PromptParleKnowledgeFile',
    'Get-PromptParleConnections',
    'Set-PromptParleActiveLocalConnection',
    'Add-PromptParleKnowledgeConnection',
    'Remove-PromptParleConnection',
    'Update-PromptParleConnectionCatalog',
    'Search-PromptParleKnowledgeCatalog',
    'Read-PromptParleKnowledgeFile',
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
