# GitHub Sponsors webhook

Optional ops hook so you get notified when someone sponsors PromptParle.
**No product features are gated** on these events.

## Endpoint

| Item | Value |
|------|--------|
| URL | `https://promptparle.com/api/webhooks/github` |
| Method | `POST` |
| Content type | `application/json` |
| Secret env | `GITHUB_WEBHOOK_SECRET` |
| Health | `GET` same path → `{ configured: true/false }` |

## What it does

On each verified delivery:

1. Checks `X-Hub-Signature-256` against `GITHUB_WEBHOOK_SECRET`
2. Writes an audit row (`sponsors.event`, `sponsors.webhook_ping`, or `sponsors.webhook_other`)
3. If mail is configured, emails every admin recipient (`isAdmin` users + `ADMIN_EMAIL` / `INVITE_REQUEST_TO` / `FEEDBACK_TO`)

It does **not** change plans, unlock features, or store card data.

## Configure in GitHub

### Option A: Sponsors dashboard (preferred)

1. Open [Sponsors dashboard](https://github.com/sponsors/exiled4disco/dashboard)
2. **Settings** (or **Webhooks**, depending on GitHub UI)
3. Add webhook:
   - **Payload URL:** `https://promptparle.com/api/webhooks/github`
   - **Content type:** `application/json`
   - **Secret:** generate with `openssl rand -hex 32`, paste the same value into `GITHUB_WEBHOOK_SECRET` on the server
   - **Events:** Sponsorship (and allow Ping)
4. Save, then use **Redeliver** / wait for the automatic `ping`
5. Confirm `GET https://promptparle.com/api/webhooks/github` returns `"configured": true` after deploy

### Option B: User or org webhook

If Sponsors settings do not show webhooks yet:

1. GitHub → Settings → Webhooks (account) or org webhooks
2. Same URL, secret, and enable the **Sponsorship** event

## Server env

```bash
GITHUB_WEBHOOK_SECRET="paste_the_same_secret_as_github"
```

Redeploy / restart the portal after setting the env var.

## Useful events

| `action` | Meaning |
|----------|---------|
| `created` | New sponsor |
| `cancelled` | Sponsorship ended |
| `pending_cancellation` | Will cancel at period end |
| `tier_changed` / `pending_tier_change` | Amount or tier changed |
| `edited` | Metadata edit |

Full payload reference: [sponsorship event](https://docs.github.com/en/webhooks/webhook-events-and-payloads#sponsorship)

## Newsletter (not a webhook)

Public project updates live in GitHub Discussions:

- Category: [Announcements](https://github.com/exiled4disco/promptparle/discussions/categories/announcements)
- Issue #1: https://github.com/exiled4disco/promptparle/discussions/1

Tip: in the repo **Settings → General → Discussions**, rename the Announcements category to **Newsletter** if you want that label in the UI (API cannot rename categories).
