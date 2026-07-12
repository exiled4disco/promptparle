# PromptParle

**Trim the prompt. Keep the signal.**

AI context optimization gateway: thin bloated context, keep the signal, route cleaner prompts to OpenAI, Claude, Gemini, or Grok.

| Surface | What it is |
|---------|------------|
| **Desktop (recommended)** | Free local PowerShell chat UI on your PC |
| **Portal** | https://promptparle.com: account, plan, desktop license key (`pp_live_`) — licensing only |
| **API** | License/entitlements; day-to-day chat is local-first on the desktop |

This repo contains both the **portal** (Next.js) and the **PowerShell module** (`powershell/`).

---

## Install desktop client (Windows)

**You need:** [Git for Windows](https://git-scm.com/download/win), PowerShell 5.1+, and a free [promptparle.com](https://promptparle.com) account.

### 1. Portal (2 minutes) — licensing only

1. Sign in with **Google** or **GitHub** (or email)  
2. **API Keys** → create desktop license key → copy `pp_live_...` (shown once)  
3. **Do not** put OpenAI/Claude/Gemini/Grok keys in the portal for desktop chat  

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

## Quick links

| Link | Purpose |
|------|---------|
| https://promptparle.com | Portal |
| https://promptparle.com/install.ps1 | Installer script |
| https://promptparle.com/PromptParle-PowerShell.tgz | Module tarball |
| https://promptparle.com/PromptParle.psd1 | Published module version |
| [powershell/PromptParle/README.md](powershell/PromptParle/README.md) | Desktop client docs |
| [powershell/examples/](powershell/examples/) | Scripted examples |

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
  license / invite / plan / pp_live_ desktop key only
  — no prompt bodies, no provider keys
```

**Local-first:** optimize, provider keys, and model calls run on your PC. The portal is **licensing only**.

- **Provider keys** → `Set-PromptParleProviderKey` (DPAPI on Windows); never uploaded.  
- **Desktop key** `pp_live_…` → license/entitlements only; hash on server.  
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

For contributing to the **website / API**, not required for desktop install.

### Stack

- Next.js 16 (App Router) + TypeScript + Tailwind  
- Postgres via Prisma  
- HTTP-only sessions · bcrypt · desktop license key hashes · (legacy portal key vault AES-256-GCM if used)  

### Quick start

```bash
# Prerequisites: Node 20+, Docker (or Postgres 14+)
docker compose up -d
cp.env.example.env
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
| `/app` | Dashboard |
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
  --exclude node_modules --exclude.next --exclude.git --exclude.env \
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

**Done:** portal, email verification, `/api/v1`, multi-provider adapters, secret masking, profiles, PowerShell module + local UI (workspace / git / SSH / chat history).

**Next:** VS Code extension, richer optimizer, PSGallery publish.
