# Contributing to PromptParle

Thanks for helping out. PromptParle is **free for everyone** and open to outside
contributors. This guide covers how to build and run the two halves of the
project (the Next.js **portal** and the PowerShell **desktop module**), the
dev-time token tooling, the automatic edit-check hook, the engineering rules we
enforce, and the release process.

If you just want to *use* PromptParle, you don't need any of this — see
[README.md](README.md).

---

## What's in this repo

| Path | What |
|------|------|
| `src/` | The portal — Next.js 16 (App Router) + TypeScript + Tailwind |
| `prisma/` | Prisma schema + migrations (Postgres) |
| `powershell/PromptParle/` | The desktop PowerShell module (client + local UI) |
| `powershell/` | Installers (`Install-PromptParle.ps1`, `Install-FromGitHub.ps1`) + examples |
| `public/` | Static site assets, installer scripts, published module tarball, `llms*.txt` |
| `scripts/pp-*.sh` | Dev-time token-tooling helpers (see below) |
| `docs/` | Threat model, checklists, plans |
| `.claude/agents/` | Repo-specific specialist agents + `guardian.md` (engineering rules) |

**Local-first contract:** prompt bodies and provider keys never leave the user's
PC. The portal handles licensing, stats, and support only — never proxy prompts
or store provider keys for desktop chat. Keep this true in any change you make.

---

## Build & run the portal (Next.js 16)

**Prerequisites:** Node **v22.19.0**, and Docker (or a local Postgres 14+).

> This is Next.js 16 (App Router) — APIs and conventions may differ from older
> Next.js you know. When in doubt, read the relevant guide under
> `node_modules/next/dist/docs/` before writing code (see [AGENTS.md](AGENTS.md)).

```bash
# 1. Postgres
docker compose up -d

# 2. Env
cp .env.example .env
# Set ENCRYPTION_KEY + SESSION_SECRET  (openssl rand -hex 32 each)
# Set DATABASE_URL, NEXT_PUBLIC_APP_URL

# 3. Install + migrate + run
npm install
npx prisma migrate dev
npm run dev
```

Open http://localhost:3000.

| Script | Purpose |
|--------|---------|
| `npm run dev` | Dev server |
| `npm run build` | Production build |
| `npm run start` | Serve the production build |
| `npx prisma studio` | Inspect the database |
| `npx prisma migrate dev` | Create/apply a migration in dev |

**Gotcha:** on any change that touches the Prisma schema, run
`npx prisma generate` before `npm run build`, or the build uses a stale client.

Key env vars: `DATABASE_URL`, `ENCRYPTION_KEY` (64-char hex), `SESSION_SECRET`,
`NEXT_PUBLIC_APP_URL`, optional `GOOGLE_CLIENT_ID/SECRET`,
`GITHUB_CLIENT_ID/SECRET`, `TRUSTED_PROXY_HOPS`.

---

## The PowerShell desktop module

Layout under `powershell/PromptParle/`:

| File | Role |
|------|------|
| `PromptParle.psd1` | Module manifest — `ModuleVersion` lives here |
| `PromptParle.psm1` | The client (~17.5k lines): commands, local UI server, optimizer bridge, tools. `$ver` self-card near the top |
| `local-ui/index.html` | The `127.0.0.1:7788` chat UI served by `pp` |
| `README.md` | End-user desktop docs |

Installers live one level up in `powershell/` and must stay in sync with the
published `public/install.ps1`. See the "Installers" note in project memory:
the three entry scripts (`public/install.ps1`,
`powershell/Install-PromptParle.ps1`, `powershell/Install-FromGitHub.ps1`) are
kept consistent.

To test locally, import the module directly from the clone:

```powershell
Import-Module ./powershell/PromptParle/PromptParle.psd1 -Force
pp   # starts the local UI on 127.0.0.1:7788
```

Because the `.psm1` is large, **don't read the whole file** — use the tooling
below to jump to a function.

---

## Dev token tooling (`scripts/pp-*.sh`)

This repo carries token-efficiency helper scripts so working on it costs fewer
tokens: answer from a tool, not a giant file load. Reach for these before
composing greps or reading large files.

| Tool | Answers, in one call |
|------|----------------------|
| `scripts/pp-psm1.sh [name]` | Function index of the 17.5k-line `PromptParle.psm1`; jump to one function's line range. `--grep <kw>`, `--body`. |
| `scripts/pp-optimizer.sh [kw]` | The optimize → fleet → compressor pipeline map (`src/lib`), or a capped grep across just those files. |
| `scripts/pp-routes.sh [substr]` | Every Next.js API route + its exported HTTP methods. |
| `scripts/pp-schema.sh [Model]` | Prisma models + fields + which migrations touch them. |
| `scripts/pp-locate.sh <symbol>` | Blast radius: where a fn/type/route is defined + callers by file (psm1 + TS). |
| `scripts/pp-search.sh <pat> [path]` | Capped ripgrep for discovery — says when capped, never silently truncates. `--json` via gron. |
| `scripts/pp-claude.sh [agents\|tools\|hooks]` | Index of this repo's Claude setup, from live config. |

`scripts/pp-claude.sh` lists all of the above live, so you don't have to read the
scripts to learn what exists.

---

## Automatic edit-check hook

A PostToolUse hook (`scripts/pp-edit-check.sh`) runs after any file edit/write:

- PowerShell files get an **AST parse** (catches the syntax errors that break the
  module on import).
- `.ts` / `.tsx` get **eslint**.
- `.prisma` gets `prisma validate`.
- `.json` gets `jq`.

It is silent on pass and flags **new** errors inline. Fix them before moving on.

---

## Engineering rules (`/guardian`)

Non-negotiable rules live in `.claude/agents/guardian.md`. In short:

- **State blast radius before editing a shared symbol** — use
  `scripts/pp-locate.sh` / `scripts/pp-psm1.sh --grep` first.
- **PARSE the module + DRIVE the changed behavior before saying done** — the repo
  is not the running client.
- **Evidence over theory** — a convincing explanation is still a hypothesis until
  a test would have disproved it.
- **Fix the root cause**, never paint over a wrong measurement.
- **Metering must be honest** — no "saved %" comparing unlike things.
- **Prompt bodies + provider keys never leave the PC.**
- **Behave the same across all four providers** (OpenAI / Anthropic / Gemini /
  Grok) — never bake in one vendor.

These exist because each was learned the hard way. Every specialist agent under
`.claude/agents/` cites guardian in its ENFORCEMENT line.

---

## Release process

A release stamps the **same version** in **six** spots. They must all match, or
clients see an inconsistent version and updates misbehave:

1. `powershell/PromptParle/PromptParle.psd1` — `ModuleVersion`
2. `powershell/PromptParle/PromptParle.psm1` — the `$ver` self-card near the top
3. `public/version.txt`
4. `public/PromptParle.version`
5. `public/PromptParle.psd1` — published manifest mirror
6. `public/PromptParle-PowerShell.tgz` — rebuilt tarball of the module

Follow [Semantic Versioning](https://semver.org/): bump patch for fixes, minor
for backward-compatible features, major for breaking changes.

Then:

- Add a top entry to [CHANGELOG.md](CHANGELOG.md) (newest first, Keep-a-Changelog
  style, grouped under Added / Changed / Fixed).
- Rebuild the tarball so `public/PromptParle-PowerShell.tgz` matches the module
  files.
- Deploy the portal per the "Production ops" section of [README.md](README.md)
  (remember `npx prisma generate` before `npm run build` on schema changes).

---

## Submitting changes

- Keep changes **docs/markdown/txt-only** or **code-only** unless a change
  legitimately spans both — version bumps and code are typically owned together.
- Run the portal (`npm run dev`) or import the module (`Import-Module … -Force`)
  and **drive the changed behavior** before opening a PR.
- Preserve the local-first / privacy contract and multi-vendor parity.
- Good bug reports and small focused PRs are the most helpful contributions. Not
  a coder? Filing issues or telling a colleague helps too.
