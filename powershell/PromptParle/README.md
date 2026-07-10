# PromptParle PowerShell Module

**Trim the prompt. Keep the signal.**

Client for the [PromptParle](https://promptparle.com) API — optimize context, mask secrets, and route to OpenAI, Claude, Gemini, or Grok.

## Install

### Option A — from GitHub (recommended on Windows)

Requires [Git for Windows](https://git-scm.com/download/win).

```powershell
# One-liner: clone to %USERPROFILE%\src\promptparle and install module
irm https://raw.githubusercontent.com/exiled4disco/promptparle/main/powershell/Install-FromGitHub.ps1 | iex
```

Or:

```powershell
git clone https://github.com/exiled4disco/promptparle.git $env:USERPROFILE\src\promptparle
cd $env:USERPROFILE\src\promptparle
.\powershell\Install-PromptParle.ps1 -Force
```

### Option B — copy into your modules path

**Windows (PowerShell 5.1 or 7):**

```powershell
$dest = "$env:USERPROFILE\Documents\PowerShell\Modules\PromptParle"
# Windows PowerShell 5.1:
# $dest = "$env:USERPROFILE\Documents\WindowsPowerShell\Modules\PromptParle"

New-Item -ItemType Directory -Force -Path $dest | Out-Null
Copy-Item -Recurse -Force .\powershell\PromptParle\* $dest
Import-Module PromptParle -Force
```

**Linux / macOS (PowerShell 7):**

```powershell
$dest = "$HOME/.local/share/powershell/Modules/PromptParle"
New-Item -ItemType Directory -Force -Path $dest | Out-Null
Copy-Item -Recurse -Force ./powershell/PromptParle/* $dest
Import-Module PromptParle -Force
```

### Option C — import from a local checkout

```powershell
Import-Module ./powershell/PromptParle/PromptParle.psd1 -Force
# or
./powershell/Install-PromptParle.ps1 -Force
```

### Option D — site tarball

https://promptparle.com/PromptParle-PowerShell.tgz

## Setup

1. Create an account at https://promptparle.com and verify email  
2. **Providers** → add OpenAI / Claude / Gemini / Grok key  
3. **API Keys** → create a desktop key (`pp_live_…`)  
4. Configure the module:

```powershell
Set-PromptParleApiKey -ApiKey 'pp_live_xxxxx'
Get-PromptParleConfig
```

Config is stored at `~/.promptparle/config.json` (or `%USERPROFILE%\.promptparle\config.json`).

Environment overrides:

| Variable | Purpose |
|----------|---------|
| `PROMPTPARLE_API_KEY` | Desktop API key |
| `PROMPTPARLE_BASE_URL` | Default `https://promptparle.com` |
| `PROMPTPARLE_CONFIG_DIR` | Override config directory |

## Start chatting (recommended)

```powershell
Import-Module PromptParle
Set-PromptParleApiKey -ApiKey 'pp_live_...'   # once
pp
```

**`pp` starts a LOCAL chat UI** at `http://127.0.0.1:7788` and opens your browser.

- HTML UI runs **on your PC** (not the cloud site as the daily chat shell)
- Leave the PowerShell window open while chatting (Ctrl+C stops the local server)
- Provider keys stay in the portal; desktop key authorizes this PC

```text
========================================
  PromptParle  (LOCAL)
  Browser UI on this PC only
========================================
  http://127.0.0.1:7788/
```

Optional:

```powershell
Start-PromptParle -Cli          # terminal chat
Start-PromptParle -Cloud        # portal web chat (account admin)
Start-PromptParle -Port 7790    # different local port
```

Auto-load every PowerShell window:

```powershell
Add-Content $PROFILE "Import-Module PromptParle"
```

## Costs (important)

| Cost | Who pays |
|------|----------|
| OpenAI / Claude / Gemini / Grok tokens | **You** (keys you added under Providers) |
| Local chat UI | Free — runs on your PC |
| PromptParle server (optimize + route + usage) | PromptParle infra (small API calls) |

Portal **Usage** still records savings. We are not putting the full chat SPA load on AWS for every keystroke of HTML.

## Commands

| Command | Description |
|---------|-------------|
| `Start-PromptParle` / `pp` | **Local browser chat** on 127.0.0.1 |
| `Start-PromptParleLocalServer` | Same local server |
| `Start-PromptParle -Cli` | Terminal chat |
| `Start-PromptParle -Cloud` | Open portal chat (optional) |
| `Set-PromptParleApiKey` | Save `pp_live_…` key |
| `Get-PromptParleConfig` | Show config (key masked) |
| `Get-PromptParleProvider` | List providers + which keys are set |
| `Get-PromptParleUsage` | Token savings summary |
| `Invoke-PromptParle` | One-shot scripted call (automation) |
| `Invoke-PromptParleSecurityReview` | Same with `security-review` profile |

## Examples

```powershell
# Interactive (preferred)
pp

# Scripted one-shot
Invoke-PromptParle -Provider openai -Prompt 'Explain this script' -Path .\deploy.ps1

# Pipeline context (logs / configs / code)
Get-Content .\firewall-rules.txt -Raw |
  Invoke-PromptParle `
    -Provider openai `
    -Profile security-review `
    -Prompt 'Find risky firewall rules and recommend safer alternatives'

# Optimize only (no provider call, no AI spend)
Invoke-PromptParle -Provider openai -Prompt 'Clean this up' -Path .\huge.log -OptimizeOnly

# Claude
Invoke-PromptParle -Provider anthropic -Model 'claude-sonnet-4-20250514' `
  -Profile developer -Prompt 'Review for bugs' -Path .\app.py

# Capture result
$r = Invoke-PromptParle -Provider openai -Prompt 'Summarize' -Context $text -Quiet
$r.Response
$r.Metadata.token_reduction_percent

# Usage
Get-PromptParleUsage
Get-PromptParleUsage -Recent
Get-PromptParleProvider
```

## Profiles

`general` · `developer` · `security-review` · `log-analysis` · `documentation` · `executive-summary`

## Output

Default return object:

```text
Response   - AI text (or omitted when -OptimizeOnly)
OptimizedPrompt - when -OptimizeOnly
Metadata   - original_tokens, optimized_tokens, reduction, secrets_masked, ...
Provider / Model / Profile
```

Host banner (unless `-Quiet`):

```text
PromptParle optimized your context:
  Original tokens : 18450
  Optimized tokens: 6230
  Reduction       : 66%
  ...
AI Response:
...
```

## Requirements

- PowerShell 5.1+ or PowerShell 7+
- Network access to `https://promptparle.com`
- Verified PromptParle account + desktop API key
- At least one provider key in the portal (for full AI calls)
