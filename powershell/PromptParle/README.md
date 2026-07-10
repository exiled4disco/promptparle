# PromptParle PowerShell Module

**Trim the prompt. Keep the signal.**

Local desktop client for [PromptParle](https://promptparle.com): optimize context, mask secrets, and route to **your** OpenAI, Claude, Gemini, or Grok keys.

| What | Where it runs |
|------|----------------|
| Chat UI | **Your PC** (`http://127.0.0.1:7788`) |
| Optimize + route API | promptparle.com |
| AI provider keys | Encrypted in your portal account |
| Desktop API key | On your PC (`~/.promptparle/config.json`) |
| SSH / git credentials | **Never leave your PC** |

---

## First-time setup (5 minutes)

Do these **in order**. Skipping a step is the #1 support issue.

### 1. Account + provider key (portal)

1. Create an account: https://promptparle.com/register  
2. **Verify your email** (required before sign-in works fully).  
3. Sign in → **Providers** → add at least one AI key (OpenAI / Claude / Gemini / Grok).  
4. **API Keys** → create a desktop key → copy `pp_live_...` (shown **once**).

### 2. Install the module (Windows)

**Prerequisites**

- Windows 10/11  
- PowerShell 5.1 (built-in) **or** PowerShell 7+  
- [Git for Windows](https://git-scm.com/download/win)  
- Network access to `https://promptparle.com` and GitHub  

**Recommended (one line)**

Open **PowerShell** and run:

```powershell
irm https://promptparle.com/install.ps1 | iex
```

Alternate bootstrap (downloads the script to a temp file first):

```powershell
irm https://promptparle.com/get.ps1 | iex
```

The installer will:

1. Clone/update the repo (default: `%USERPROFILE%\src\promptparle`)  
2. Copy the module into your user Modules folder  
3. Ask for your `pp_live_...` key (or open the portal)  
4. Verify the key  
5. Offer to start local chat (`pp`)

**Optional flags before install**

```powershell
$PromptParleStart = $true          # auto-start local chat after install
$PromptParleSkipKeyPrompt = $true  # skip key prompt (automation)
$PromptParleClonePath = 'D:\src\promptparle'  # custom clone path
irm https://promptparle.com/install.ps1 | iex
```

### 3. Start local chat

```powershell
Import-Module PromptParle
# only if the installer did not already save your key:
Set-PromptParleApiKey -ApiKey 'pp_live_xxxxx'
pp
```

Your browser should open **http://127.0.0.1:7788/**.

**Leave the PowerShell window open** while chatting. Ctrl+C (or **⋯ → Stop server**) stops the local server.

---

## Update the client

From the local UI: click **Update** (turns **red** when a newer version is available).

From PowerShell:

```powershell
Update-PromptParleClient -Force
Stop-PromptParleLocalServer   # if still running
pp
```

Then hard-refresh the browser: **Ctrl+F5**.

Check versions:

```powershell
Get-PromptParleClientVersion
Get-PromptParleUpdateStatus
```

---

## Other install options

### From a git clone

```powershell
cd $env:USERPROFILE\src\promptparle
git pull
.\powershell\Install-PromptParle.ps1
# or with auto-start:
.\powershell\Install-PromptParle.ps1 -Start
```

### Manual copy into Modules path

**Windows PowerShell 5.1:**

```powershell
$dest = "$env:USERPROFILE\Documents\WindowsPowerShell\Modules\PromptParle"
New-Item -ItemType Directory -Force -Path $dest | Out-Null
Copy-Item -Recurse -Force .\powershell\PromptParle\* $dest
Import-Module PromptParle -Force
```

**PowerShell 7 (Windows / Linux / macOS):**

```powershell
# Windows PS7
$dest = "$env:USERPROFILE\Documents\PowerShell\Modules\PromptParle"
# Linux/macOS PS7
# $dest = "$HOME/.local/share/powershell/Modules/PromptParle"

New-Item -ItemType Directory -Force -Path $dest | Out-Null
Copy-Item -Recurse -Force ./powershell/PromptParle/* $dest
Import-Module PromptParle -Force
```

### Site tarball

https://promptparle.com/PromptParle-PowerShell.tgz — extract and copy the `PromptParle` folder into your Modules path (paths above).

### Uninstall

```powershell
# From the clone:
.\powershell\Uninstall-PromptParle.ps1
# Also remove saved API key:
.\powershell\Uninstall-PromptParle.ps1 -RemoveConfig
# Also remove the git clone:
.\powershell\Uninstall-PromptParle.ps1 -RemoveConfig -RemoveClone
```

---

## Daily use

```powershell
Import-Module PromptParle   # once per window, or add to $PROFILE
pp                          # local browser chat
```

| Command | What it does |
|---------|----------------|
| `pp` / `Start-PromptParle` | Local browser chat on 127.0.0.1 |
| `Start-PromptParle -Cli` | Terminal chat |
| `Start-PromptParle -Cloud` | Open portal web chat |
| `Start-PromptParle -Port 7790` | Different local port |
| `Set-PromptParleApiKey` | Save `pp_live_...` |
| `Get-PromptParleConfig` | Show config (key masked) |
| `Get-PromptParleProvider` | Providers + which keys are set |
| `Get-PromptParleUsage` | Token savings |
| `Invoke-PromptParle` | Scripted one-shot call |
| `Update-PromptParleClient` | Reinstall latest client |
| `Stop-PromptParleLocalServer` | Stop local UI server |

Auto-load in every PowerShell window:

```powershell
Add-Content $PROFILE "Import-Module PromptParle"
```

### Local UI features

- **Left menu:** Chat history · Agent / Provider / Dial · Project connections (This PC / SSH / Git)  
- **Top right:** version badge · **Update** · Help · ⋯ menu  
- **Chat history** is stored in the browser (localStorage) on this PC only  

### Slash commands (type in chat)

```text
/help                 help
/status               agent, workspace, ssh, dial
/agents · /agent name
/dial 1-5 · /provider · /optimize · /usage · /clear

# Project folder on this PC
/workspace C:\path    attach folder
/workspace ls|cd|tree|cat|pack|recent

# Git / GitHub (uses YOUR local git + credentials)
/git status|diff|log|branch
/github               status
/github clone owner/repo

# SSH (keys stay on this PC)
/ssh user@host
/ssh ls|cat|run …
```

Or use the **sidebar buttons** (Browse / Connect / Detach) instead of slash commands.

---

## Costs

| Cost | Who pays |
|------|----------|
| OpenAI / Claude / Gemini / Grok tokens | **You** (keys under Providers) |
| Local chat UI | Free — runs on your PC |
| PromptParle optimize + route + usage | PromptParle API (small) |

---

## Config & environment

Config file: `~/.promptparle/config.json`  
(Windows: `%USERPROFILE%\.promptparle\config.json`)

| Variable | Purpose |
|----------|---------|
| `PROMPTPARLE_API_KEY` | Desktop API key |
| `PROMPTPARLE_BASE_URL` | Default `https://promptparle.com` |
| `PROMPTPARLE_CONFIG_DIR` | Override config directory |

```powershell
Set-PromptParleApiKey -ApiKey 'pp_live_xxxxx'
Get-PromptParleConfig
```

---

## Troubleshooting

### Install fails: `git is required`

Install [Git for Windows](https://git-scm.com/download/win), **close and reopen PowerShell**, then rerun:

```powershell
irm https://promptparle.com/install.ps1 | iex
```

### Execution policy blocks `irm | iex`

```powershell
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
# or run once:
powershell -ExecutionPolicy Bypass -Command "irm https://promptparle.com/install.ps1 | iex"
```

### `Import-Module PromptParle` not found

Module is not on your `PSModulePath`, or you installed under PS7 but are running 5.1 (or the reverse).

```powershell
# Where PowerShell looks:
$env:PSModulePath -split ';'

# Force reinstall:
irm https://promptparle.com/install.ps1 | iex

# Or import by full path (5.1):
Import-Module "$env:USERPROFILE\Documents\WindowsPowerShell\Modules\PromptParle\PromptParle.psd1" -Force
# PS7:
Import-Module "$env:USERPROFILE\Documents\PowerShell\Modules\PromptParle\PromptParle.psd1" -Force
```

### “Need a desktop API key” / 401 unauthorized

```powershell
Set-PromptParleApiKey -ApiKey 'pp_live_YOUR_KEY'
Get-PromptParleProvider   # should list providers without error
```

- Create a new key: https://promptparle.com/app/api-keys  
- Confirm email is **verified**  
- Key must start with `pp_live_`  

### “No provider keys” / provider not configured

Portal → **Providers** → add OpenAI / Claude / Gemini / Grok.  
Local chat uses those keys; the desktop key only authorizes *this PC* to call PromptParle.

### Browser does not open / blank page

```powershell
Stop-PromptParleLocalServer
pp
# Then open manually:
start http://127.0.0.1:7788/
```

Hard-refresh: **Ctrl+F5**.  
If another app uses 7788:

```powershell
Start-PromptParle -Port 7790
```

### UI looks old / no Chat history / version stuck

The browser is still loading an old module. Update must reinstall files **and** restart the local server:

```powershell
Update-PromptParleClient -Force
Stop-PromptParleLocalServer
pp
# In browser: Ctrl+F5
Get-PromptParleClientVersion   # should match GitHub / site
```

Version sources:

- Local: `Get-PromptParleClientVersion`  
- Remote: `Get-PromptParleUpdateStatus` (checks GitHub, then promptparle.com)  

### Update button errors mid-update

```powershell
Update-PromptParleClient -Force
# Fully exit old PowerShell window, open a new one:
Import-Module PromptParle -Force
pp
```

### Port already in use

```powershell
Stop-PromptParleLocalServer
# or pick another port
Start-PromptParle -Port 7790
```

### Attach folder: “Argument types do not match”

Fixed in **0.10.2+**. Update the client (see above). Prefer **Browse** in the sidebar over hand-typed paths if issues persist.

### SSH / Git / GitHub not working

These use **tools on your PC**, not the cloud:

| Need | Install / check |
|------|------------------|
| Git | `git --version` |
| OpenSSH client | `ssh -V` (Windows optional feature) |
| GitHub CLI (optional) | `gh auth status` |

Private keys and `gh` tokens **never** upload to PromptParle.

### Firewall / proxy blocks API

```powershell
# Can you reach the API?
Invoke-WebRequest https://promptparle.com/PromptParle.psd1 -UseBasicParsing | Select-Object StatusCode
```

Corporate proxies may need `HTTPS_PROXY` / system proxy settings. `PROMPTPARLE_BASE_URL` only if you run a private portal.

### Email verification / cannot log in

Check spam for the verification link, or use **resend verification** on the portal. Unverified accounts cannot use the full app.

### Still stuck

1. `Get-PromptParleConfig`  
2. `Get-PromptParleUpdateStatus`  
3. `Get-PromptParleClientVersion`  
4. Note the exact error text from the PowerShell window (local server logs print there)  
5. Confirm portal: Providers + API Keys + verified email  

---

## Scripted examples

```powershell
# Optimize only (no AI spend)
Invoke-PromptParle -Provider openai -Prompt 'Clean this up' -Path .\huge.log -OptimizeOnly

# Full call with file context
Get-Content .\firewall-rules.txt -Raw |
  Invoke-PromptParle `
    -Provider openai `
    -Profile security-review `
    -Prompt 'Find risky firewall rules'

# Capture result
$r = Invoke-PromptParle -Provider openai -Prompt 'Summarize' -Context $text -Quiet
$r.Response
$r.Metadata.token_reduction_percent

Get-PromptParleUsage
Get-PromptParleUsage -Recent
```

Also see `powershell/examples/quickstart.ps1` and `demo-savings.ps1` in the repo.

## Profiles

`general` · `developer` · `security-review` · `log-analysis` · `documentation` · `executive-summary`

## Requirements

- PowerShell 5.1+ or PowerShell 7+  
- Network access to `https://promptparle.com`  
- Verified PromptParle account + desktop API key (`pp_live_...`)  
- At least one provider key in the portal (for full AI calls)  
- Git (for the recommended installer and git features)  
