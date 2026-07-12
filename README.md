# PromptParle

**Trim the prompt. Keep the signal.**

AI context optimization gateway: thin bloated context, keep the signal, route cleaner prompts to OpenAI, Claude, Gemini, or Grok — all on your own PC, with your own provider keys.

**Free for everyone.** No paid tier, no paywall, no features locked behind money. Optimization and provider calls run on your PC with your own keys (BYOK), so the portal never proxies your prompts and there is no per-request server cost to charge for. If PromptParle saves you tokens and you'd like to help keep it maintained, there's an optional [pay-what-you-can](#support-the-project) donation — nothing is gated behind it.

| Surface | What it is |
|---------|------------|
| **Desktop (recommended)** | Free local PowerShell chat UI on your PC — optimize + model calls stay here |
| **Portal** | https://promptparle.com: account, per-desktop license key (`pp_live_`), usage/savings stats, public user guide, bug tracker, settings — **not** a paywall and **not** a prompt or key vault |
| **API** | Local desktop API for optimize + route; portal API is licensing + entitlements only |

This repo contains both the **portal** (Next.js) and the **PowerShell module** (`powershell/`).

---

## Install desktop client (Windows)

**You need:** [Git for Windows](https://git-scm.com/download/win), PowerShell 5.1+, and a free [promptparle.com](https://promptparle.com) account.

### 1. Portal (2 minutes) — free account + license key

1. Create a free account and sign in with **Google**, **GitHub**, or email
2. **API Keys** → create a desktop license key → copy `pp_live_...` (shown once)
3. **Do not** put OpenAI/Claude/Gemini/Grok keys in the portal for desktop chat — those go on the PC (step 3)

Each desktop needs its own `pp_live_` license key.

### 2. Install module

```powershell
irm https://promptparle.com/install.ps1 | iex
```

Paste your `pp_live_...` license key when prompted.

### 3. Chat + provider keys on this PC

```powershell
pp
```

Browser opens **http://127.0.0.1:7788/** (local only). Leave the PowerShell window open.

Then set model keys (local-first):

- Local UI: **⋯ → Providers** → paste key → **Save on this PC**
- Or PowerShell: `Set-PromptParleProviderKey -Provider openai -ApiKey '…'`

### Update

```powershell
Update-PromptParleClient -Force
pp
```

Or click **Update** in the local UI (red when a newer version is available).

### Full docs (install options, slash commands, troubleshooting)

→ **[powershell/PromptParle/README.md](powershell/PromptParle/README.md)**

Includes: alternate install paths, uninstall, workspace/SSH/Git, and a **Troubleshooting** section (module not found, old UI, ports, keys, execution policy, etc.).

---

## Install desktop client (Linux / macOS)

The desktop client is a PowerShell module, so Linux and macOS run it on
**PowerShell 7+** (`pwsh`). Verified running on **PowerShell 7.4.6** on Ubuntu:
the module imports and the local UI server serves on `127.0.0.1`.

**You need:** [PowerShell 7+](https://learn.microsoft.com/powershell/scripting/install/install-linux) (`pwsh`), `git`, a free [promptparle.com](https://promptparle.com) account, and a `pp_live_` license key.

### 1. Portal (2 minutes) — free account + license key

1. Create a free account and sign in with **Google**, **GitHub**, or email
2. **API Keys** → create a desktop license key → copy `pp_live_...` (shown once)

Each desktop needs its own `pp_live_` license key.

### 2. Install

```bash
curl -fsSL https://promptparle.com/install.sh | bash
```

This clones the repo, installs the module, and prompts for your `pp_live_...`
license key. If `pwsh` or `git` is missing, the installer tells you how to
install it and stops.

### 3. Chat + provider keys on this PC

```bash
pp
```

The local UI serves on **http://127.0.0.1:7788/** (local only). Then set model
keys the same way as on Windows — local UI **⋯ → Providers**, or
`Set-PromptParleProviderKey -Provider openai -ApiKey '…'`. Provider keys and
prompt bodies stay on your PC.

---

## Support the project

PromptParle is **free** and always will be - the whole gateway, no feature paywall. Running it costs *you* only your own provider tokens; it costs the project only maintenance time.

If it saves you tokens and you'd like to help keep it maintained, you can chip in whatever it's worth to you:

**→ [Support the project](https://github.com/sponsors/exiled4disco)** (pay what you can, monthly, cancel anytime)

- It is **optional**.
- It is **pay-what-you-can** - you set the amount.
- **No features are locked behind it.** Supporters and non-supporters get the identical client.

**Newsletter:** project updates in GitHub Discussions  
→ [Announcements / Newsletter](https://github.com/exiled4disco/promptparle/discussions/categories/announcements)  
→ [Issue #1](https://github.com/exiled4disco/promptparle/discussions/1)

Not up for a donation? Contributing code, filing good bug reports, or telling a colleague helps just as much. See **[CONTRIBUTING.md](CONTRIBUTING.md)**.

---

## Help / support

Support is **free** and optional. If PromptParle earns its keep and you'd like
to help, chip in what you can - see [Support the project](#support-the-project)
(sponsor: https://github.com/sponsors/exiled4disco).

- **Bugs / questions:** file an issue, or use the bug tracker on the portal.
- **Newsletter:** [GitHub Discussions (Announcements)](https://github.com/exiled4disco/promptparle/discussions/categories/announcements)
- **Contact form:** a contact form is being added at
  [promptparle.com/contact](https://promptparle.com/contact).

There is no paid support tier - supporters and non-supporters get the same help.

---

## Quick links

| Link | Purpose |
|------|---------|
| https://promptparle.com | Portal (account, license keys, stats, user guide, bug tracker) |
| https://promptparle.com/install.ps1 | Installer script |
| https://promptparle.com/PromptParle-PowerShell.tgz | Module tarball |
| https://promptparle.com/PromptParle.psd1 | Published module version |
| [powershell/PromptParle/README.md](powershell/PromptParle/README.md) | Desktop client docs |
| [powershell/examples/](powershell/examples/) | Scripted examples |
| [CHANGELOG.md](CHANGELOG.md) | Release history |
| [CONTRIBUTING.md](CONTRIBUTING.md) | Build, dev tooling, release process |

---

## How it works

```text
You (PowerShell / browser local UI)          [desktop 0.25+ local-first]
  ↓  secret gate (strict by default)
  ↓  local optimize (dial / profile / drop journal)
  ↓  provider key from local DPAPI store
Your provider  →  OpenAI / Claude / Gemini / Grok
  ↓
Response + savings metadata (on PC)

PromptParle portal (separate, rare):
  license / plan / pp_live_ desktop key / usage stats only
  — no prompt bodies, no provider keys
```

**Local-first:** optimize, provider keys, and model calls run on your PC. The portal handles **licensing, stats, and support only**.

- **Provider keys** → `Set-PromptParleProviderKey` (DPAPI on Windows); never uploaded.
- **Desktop key** `pp_live_…` → license/entitlements only; hash on server; one per machine.
- **Local UI** binds to `127.0.0.1` with a **per-run local token**.
- **SSH / git tool credentials** stay on your PC.
- **Secret gate** masks credential-shaped patterns on the PC before the provider call.

Security policy & reporting: **[SECURITY.md](SECURITY.md)** · Threat model: **[docs/THREAT-MODEL.md](docs/THREAT-MODEL.md)**

---

## Public desktop API

Auth: `Authorization: Bearer pp_live_...` (or `X-PromptParle-Key`).

| Method | Path | Purpose |
|--------|------|---------|
| POST | `/api/v1/prompt` | Optimize + route (or `optimize_only: true`) |
| POST | `/api/v1/prompt/optimize` | Optimize only |
| GET | `/api/v1/providers` | Legacy portal vault flags (desktop uses local keys) |
| GET | `/api/v1/usage` | Optional usage summary |

```bash
curl -s https://promptparle.com/api/v1/prompt \
  -H "Authorization: Bearer pp_live_..." \
  -H "Content-Type: application/json" \
  -d '{
    "provider": "openai",
    "optimization_profile": "security-review",
    "prompt": "Find risky firewall rules",
    "context": "...rules...",
    "return_metadata": true
  }'
```

---

## Portal development (this repo)

For contributing to the **website / API**, not required for desktop install. Full setup, dev token-tooling, edit-check hook, and release process are in **[CONTRIBUTING.md](CONTRIBUTING.md)**.

### Stack

- Next.js 16 (App Router) + TypeScript + Tailwind
- Postgres via Prisma
- HTTP-only sessions · bcrypt · desktop license key hashes · (legacy portal key vault AES-256-GCM if used)

### Quick start

```bash
# Prerequisites: Node v22.19.0, Docker (or Postgres 14+)
docker compose up -d
cp .env.example .env
# Set ENCRYPTION_KEY + SESSION_SECRET (openssl rand -hex 32 each)
# Set DATABASE_URL, NEXT_PUBLIC_APP_URL

npm install
npx prisma migrate dev
npm run dev
```

Open [http://localhost:3000](http://localhost:3000).

| Variable | Purpose |
|----------|---------|
| `DATABASE_URL` | Postgres connection string |
| `ENCRYPTION_KEY` | 64-char hex for provider key encryption |
| `SESSION_SECRET` | Session / OAuth state signing |
| `NEXT_PUBLIC_APP_URL` | e.g. `http://localhost:3000` |
| `GOOGLE_CLIENT_ID` / `SECRET` | Optional one-click Google signup |
| `GITHUB_CLIENT_ID` / `SECRET` | Optional one-click GitHub signup |
| `TRUSTED_PROXY_HOPS` | X-Forwarded-For trust depth (default 1) |

### Portal routes

| Path | Description |
|------|-------------|
| `/` | Marketing |
| `/register` · `/login` | Auth |
| `/app` | Portal dashboard (chat is desktop client only) |
| `/app/providers` | Guidance: set model keys on the PC (legacy vault optional) |
| `/app/api-keys` | Desktop license keys (`pp_live_`) |
| `/app/usage` | Token savings |
| `/app/settings` | Profile / retention |

### Scripts

```bash
npm run dev
npm run build
npm run start
npx prisma studio
```

---

## Security model

1. **Provider keys**: AES-256-GCM; only last 4 chars shown in UI.
2. **Desktop API keys**: full key once; SHA-256 hash stored.
3. **Passwords**: bcrypt (cost 12).
4. **Sessions**: random token, hashed in DB, HTTP-only cookie.
5. **No plaintext secrets in logs** by design.

---

## Production ops (promptparle.com host)

Live: **https://promptparle.com**

| Piece | Location |
|-------|----------|
| App code | `/var/www/promptparle` |
| Systemd | `promptparle.service` (Next.js on `127.0.0.1:3110`) |
| Nginx | `/etc/nginx/sites-available/promptparle.com` |
| Postgres | Docker `promptparle-db` host port `5433` |
| Env | `/var/www/promptparle/.env` (mode 600) |

### Redeploy after code changes

```bash
export PATH="/home/ubuntu/.nvm/versions/node/v22.19.0/bin:$PATH"
rsync -a --delete \
  --exclude node_modules --exclude .next --exclude .git --exclude .env \
  /home/ubuntu/projects/promptparle/ /var/www/promptparle/
cd /var/www/promptparle
npm ci
npx prisma migrate deploy
npm run build
sudo systemctl restart promptparle.service
```

### Useful commands

```bash
sudo systemctl status promptparle
sudo journalctl -u promptparle -f
sudo nginx -t && sudo systemctl reload nginx
docker ps --filter name=promptparle-db
```

### Email (Amazon SES)

Domain identity in SES `us-east-2`, SPF + DKIM at DNS, then:

```
MAIL_TRANSPORT=ses
MAIL_FROM=PromptParle <noreply@promptparle.com>
AWS_REGION=us-east-2
```

New accounts must verify email before full use.

---

## Roadmap

**Done:** portal, email verification, `/api/v1`, multi-provider adapters, secret masking, profiles, PowerShell module + local UI (workspace / git / SSH / chat history), honest savings metering + cumulative stats, free-for-everyone release.

**Next:** VS Code extension, richer optimizer, PSGallery publish.
