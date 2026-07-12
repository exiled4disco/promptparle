# Security Policy

Security is the first-class requirement for PromptParle: protecting **users**,
**our IP**, and the **portal**.

## Supported versions

| Component | Support |
|-----------|---------|
| Desktop client (latest published on portal) | Active |
| Portal at https://promptparle.com | Active |
| Older client packages | Best-effort; update via `Update-PromptParleClient` |

## Report a vulnerability

**Do not open a public GitHub issue for security findings.**

Email: **security@promptparle.com** (or the contact listed on https://promptparle.com)

Please include:

- Affected surface (portal API, desktop local UI, install scripts, etc.)
- Steps to reproduce
- Impact (auth bypass, secret leak, RCE, cost amplification, …)
- Your preferred credit name (optional)

We aim to acknowledge within **72 hours** and provide a status update within
**7 days**. Coordinated disclosure is preferred.

## What we consider in-scope

- Authentication / session / OAuth flaws
- Desktop API key (`pp_live_…`) theft or forgery
- Local UI (`127.0.0.1`) abuse from a malicious page or process
- Provider key (BYOK) exposure on the desktop (local store / DPAPI)
- Local UI abuse that could exfiltrate provider keys or prompt content
- Prompt / secret leakage via desktop optimize or local logs
- Privilege issues in portal multi-tenant isolation
- Dependency supply-chain issues in published artifacts

## Out of scope (examples)

- Social engineering of individual users
- Physical access to an unlocked workstation
- Denial of service that only saturates a single free-tier account without a
  broader platform impact (still report if easy and severe)
- Issues only present in unreleased / local-dev configurations with default
  secrets left unchanged

## Hardening expectations (public reviewers)

We design for:

| Boundary | Expectation |
|----------|-------------|
| Portal | Session cookies httpOnly; passwords bcrypt; desktop license keys hashed (licensing only for day-to-day chat) |
| Desktop license key | `pp_live_…` shown once; SHA-256 at rest server-side; optional IP allowlist |
| Provider keys (BYOK) | Stored on the PC only for desktop chat (DPAPI when available); never required in the portal |
| Local UI | Bound to `127.0.0.1`; per-session local token on `/api/*`; Origin checks |
| Secrets in prompts | Secret gate on the PC before provider calls |
| SSH / git | Credentials never leave the PC |

## Safe harbor

Good-faith security research that avoids privacy violations, data destruction,
and service disruption is welcome. We will not pursue legal action against
researchers who follow this policy and give us a reasonable chance to fix
issues before public disclosure.
