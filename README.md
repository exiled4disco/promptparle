# PromptParle

**Trim the prompt. Keep the signal.**

AI context optimization gateway — thin bloated context, keep the signal, route cleaner prompts to OpenAI, Claude, Gemini, or Grok.

| Surface | What it is |
|---------|------------|
| **Desktop (recommended)** | Free local PowerShell chat UI on your PC |
| **Portal** | https://promptparle.com — account, provider keys, usage, desktop API keys |
| **API** | `https://promptparle.com/api/v1` — optimize + route |

This repo contains both the **portal** (Next.js) and the **PowerShell module** (`powershell/`).

---

## Install desktop client (Windows)

**You need:** [Git for Windows](https://git-scm.com/download/win), PowerShell 5.1+, and a free [promptparle.com](https://promptparle.com) account.

### 1. Portal (2 minutes)

1. Register → **verify email**  
2. **Providers** → add OpenAI / Claude / Gemini / Grok key  
3. **API Keys** → create desktop key → copy `pp_live_...`  

### 2. Install module

```powershell
irm https://promptparle.com/install.ps1 | iex
```

Paste your `pp_live_...` key when prompted.

### 3. Chat

```powershell
pp
```

Browser opens **http://127.0.0.1:7788/** (local only). Leave the PowerShell window open.

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
You (PowerShell / browser local UI)
  ↓  desktop key pp_live_…
PromptParle API  →  auth · secret scan · optimize
  ↓
Your provider     →  OpenAI / Claude / Gemini / Grok
  ↓
Response + token reduction metadata
```

- **Provider keys** stay encrypted in the portal (AES-256-GCM).  
- **Desktop key** is shown once; only a hash is stored server-side.  
- **Local UI HTML** runs on your PC — not served as a full chat SPA from AWS per keystroke.  
- **SSH / git credentials never leave your PC.**

---

## Public desktop API

Auth: `Authorization: Bearer pp_live_...` (or `X-PromptParle-Key`).

| Method | Path | Purpose |
|--------|------|---------|
| POST | `/api/v1/prompt` | Optimize + route (or `optimize_only: true`) |
| POST | `/api/v1/prompt/optimize` | Optimize only |
| GET | `/api/v1/providers` | Providers + configured flags |
| GET | `/api/v1/usage` | Usage summary |

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
- AES-256-GCM provider keys · HTTP-only sessions · bcrypt  

### Quick start

```bash
# Prerequisites: Node 20+, Docker (or Postgres 14+)
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
| `SESSION_SECRET` | Session signing |
| `NEXT_PUBLIC_APP_URL` | e.g. `http://localhost:3000` |

### Portal routes

| Path | Description |
|------|-------------|
| `/` | Marketing |
| `/register` · `/login` | Auth |
| `/app` | Dashboard |
| `/app/chat` | Portal web chat |
| `/app/providers` | Provider keys |
| `/app/api-keys` | Desktop API keys |
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

1. **Provider keys** — AES-256-GCM; only last 4 chars shown in UI.  
2. **Desktop API keys** — full key once; SHA-256 hash stored.  
3. **Passwords** — bcrypt (cost 12).  
4. **Sessions** — random token, hashed in DB, HTTP-only cookie.  
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

**Done:** portal, email verification, `/api/v1`, multi-provider adapters, secret masking, profiles, PowerShell module + local UI (workspace / git / SSH / chat history).

**Next:** VS Code extension, richer optimizer, PSGallery publish.
