# PromptParle Portal

**Trim the prompt. Keep the signal.**

PromptParle is an AI context optimization gateway. This repo is the **cloud portal** for [promptparle.com](https://promptparle.com):

- User registration / login
- Encrypted AI provider key storage (OpenAI, Anthropic, Gemini, Grok)
- Desktop API key generation (`pp_live_…`)
- Usage history and token savings dashboard
- Retention / prompt storage settings
- Public desktop API (`/api/v1`) with optimizer + provider adapters
- **PowerShell module** (this repo → `powershell/`)

VS Code extension is next.

## Stack

- **Next.js 16** (App Router) + TypeScript + Tailwind
- **Postgres** via Prisma
- **AES-256-GCM** for provider API keys at rest
- **HTTP-only session cookies** + bcrypt password hashes
- Desktop keys stored as **SHA-256 hashes only**

## Quick start

### 1. Prerequisites

- Node.js 20+
- Docker (for Postgres) or any Postgres 14+

### 2. Database

```bash
docker compose up -d
# or use the existing container on port 5433
```

### 3. Environment

```bash
cp .env.example .env
# Generate secrets:
# openssl rand -hex 32   → ENCRYPTION_KEY
# openssl rand -hex 32   → SESSION_SECRET
```

Required vars:

| Variable | Purpose |
|----------|---------|
| `DATABASE_URL` | Postgres connection string |
| `ENCRYPTION_KEY` | 64-char hex (32 bytes) for provider key encryption |
| `SESSION_SECRET` | Session signing / app secret |
| `NEXT_PUBLIC_APP_URL` | e.g. `http://localhost:3000` or `https://promptparle.com` |

### 4. Migrate & run

```bash
npm install
npx prisma migrate dev
npm run dev
```

Open [http://localhost:3000](http://localhost:3000).

## Portal routes

| Path | Description |
|------|-------------|
| `/` | Marketing landing |
| `/register` | Create account |
| `/login` | Sign in |
| `/app` | Dashboard + setup checklist |
| `/app/providers` | Add/delete encrypted provider keys |
| `/app/api-keys` | Create/revoke desktop API keys |
| `/app/usage` | Token savings history |
| `/app/settings` | Profile + retention |

## API (portal session)

Authenticated with the browser session cookie:

| Method | Path | Purpose |
|--------|------|---------|
| POST | `/api/auth/register` | Create account |
| POST | `/api/auth/login` | Sign in |
| POST | `/api/auth/logout` | Sign out |
| GET | `/api/auth/me` | Current user |
| GET/POST | `/api/providers` | List / upsert provider keys |
| DELETE | `/api/providers/:id` | Delete provider key |
| GET/POST | `/api/api-keys` | List / create desktop keys |
| DELETE | `/api/api-keys/:id` | Revoke desktop key |
| GET | `/api/usage` | Usage summary |
| PATCH | `/api/settings` | Update profile / retention |

## PowerShell module (Windows)

### Install from GitHub (recommended)

Requires [Git for Windows](https://git-scm.com/download/win).

```powershell
# Clone + install into your user Modules path
irm https://raw.githubusercontent.com/exiled4disco/promptparle/main/powershell/Install-FromGitHub.ps1 | iex
```

Or clone manually:

```powershell
git clone https://github.com/exiled4disco/promptparle.git $env:USERPROFILE\src\promptparle
cd $env:USERPROFILE\src\promptparle
.\powershell\Install-PromptParle.ps1 -Force
```

### Configure & first call

```powershell
Import-Module PromptParle -Force

# Portal: https://promptparle.com → Providers (add AI key) → API Keys (create pp_live_…)
Set-PromptParleApiKey -ApiKey 'pp_live_xxxxx'

Get-PromptParleConfig
Get-PromptParleProvider

# Optimize only (no AI spend)
Invoke-PromptParle -Provider openai -Prompt 'Summarize' -Context 'noise...' -OptimizeOnly

# Full call
Get-Content .\firewall-rules.txt -Raw |
  Invoke-PromptParle -Provider openai -Profile security-review `
    -Prompt 'Find risky firewall rules'

Get-PromptParleUsage
```

See `powershell/PromptParle/README.md` for profiles, env vars, and more examples.

Also available as a tarball on the site: https://promptparle.com/PromptParle-PowerShell.tgz

## Public desktop API (`/api/v1`)

Auth: `Authorization: Bearer pp_live_...` (or `X-PromptParle-Key`).

| Method | Path | Purpose |
|--------|------|---------|
| POST | `/api/v1/prompt` | Optimize + route to provider (or `optimize_only: true`) |
| POST | `/api/v1/prompt/optimize` | Optimize only |
| GET | `/api/v1/providers` | List providers + which keys are configured |
| GET | `/api/v1/usage` | Usage summary |

Example:

```bash
curl -s https://promptparle.com/api/v1/prompt \
  -H "Authorization: Bearer pp_live_..." \
  -H "Content-Type: application/json" \
  -d '{
    "provider": "openai",
    "model": "gpt-4o",
    "optimization_profile": "security-review",
    "prompt": "Find risky firewall rules",
    "context": "...rules...",
    "return_metadata": true
  }'
```

Providers with key storage + routing: OpenAI, Anthropic, Gemini, Grok.

## Security model (MVP)

1. **Provider keys** — encrypted with AES-256-GCM; only last 4 chars shown in UI.
2. **Desktop API keys** — full key shown once; only SHA-256 hash stored.
3. **Passwords** — bcrypt (cost 12).
4. **Sessions** — random token, hashed in DB, HTTP-only cookie.
5. **No plaintext secrets in logs** by design.

## Product context

See the product plan: context optimizer, PowerShell-first client, VS Code later, provider adapters, secret masking, optimization profiles.

## Deploy notes for promptparle.com

1. Point DNS A/AAAA (or CNAME) for `promptparle.com` to your host (Vercel, Fly, VPS, etc.).
2. Set production env vars (`DATABASE_URL`, `ENCRYPTION_KEY`, `SESSION_SECRET`, `NEXT_PUBLIC_APP_URL=https://promptparle.com`).
3. Run migrations against production Postgres.
4. `npm run build && npm start` (or platform build command `next build`).

## Scripts

```bash
npm run dev       # local dev
npm run build     # production build
npm run start     # run production server
npx prisma studio # inspect DB
```

## Roadmap

Done: portal, email verification, `/api/v1`, providers (OpenAI/Anthropic/Gemini/Grok), secret masking, profiles, PowerShell module.

Next: VS Code extension, richer optimizer, PSGallery publish.

## Production (this host)

Live on **https://promptparle.com** (A → `3.140.203.94`).

| Piece | Location |
|-------|----------|
| App code | `/var/www/promptparle` |
| Systemd | `promptparle.service` (Next.js on `127.0.0.1:3110`) |
| Nginx | `/etc/nginx/sites-available/promptparle.com` |
| TLS | Let's Encrypt `promptparle.com` (webroot `/var/www/html`) |
| Postgres | Docker `promptparle-db` on host port `5433` |
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

## Email verification

New accounts must click a verification link before sign-in.

### Amazon SES (production on this host)

1. Domain identity: `promptparle.com` (created in SES `us-east-2`)
2. Add these DNS records at Squarespace:

**SPF** (replace the current `v=spf1 -all` TXT):
```
v=spf1 include:amazonses.com ~all
```

**DKIM** (3 CNAMEs):
```
t6as4qsirdsid7v4fd2qog5mbdeogbti._domainkey  →  t6as4qsirdsid7v4fd2qog5mbdeogbti.dkim.amazonses.com
lxfq3vffj25l5xlfojdmslvg2tjirybq._domainkey  →  lxfq3vffj25l5xlfojdmslvg2tjirybq.dkim.amazonses.com
udyw2q4fcaufvwkqoivhuirrrzhhm5h6._domainkey  →  udyw2q4fcaufvwkqoivhuirrrzhhm5h6.dkim.amazonses.com
```

3. Wait until SES shows domain **Verified**
4. Request SES production access (sandbox can only send to verified addresses)

Env:
```
MAIL_TRANSPORT=ses
MAIL_FROM=PromptParle <noreply@promptparle.com>
AWS_REGION=us-east-2
```
