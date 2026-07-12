# PromptParle threat model (public)

Short model for reviewers. Details that would only help attackers are omitted.

## Assets

| Asset | Owner impact if lost |
|-------|----------------------|
| User provider API keys (BYOK on PC) | Direct cloud spend / data exfil via provider |
| Desktop license keys (`pp_live_…`) | Act as user for license/entitlements against portal |
| User prompts & context | Confidential code, infra, PII |
| Portal account (session) | Change license keys, allowlists, plan features |
| Local desktop tools (FS, SSH, terminal) | RCE as the logged-in user |

## Trust boundaries (local-first desktop 0.25+)

```text
[Browser local UI] --127.0.0.1 + local token--> [PowerShell HttpListener]
        |                                              |
        |  provider keys (DPAPI / config)              | tools, FS, SSH stay local
        |  secret gate + local optimize                |
        v                                              v
[OpenAI / Claude / Gemini / Grok]  <--- HTTPS direct from PC ---

[PromptParle portal]  <--- pp_live_ license only ---  (no prompt bodies, no provider keys)
```

1. **Local UI ↔ PowerShell**: same machine; must not be callable by random
   web origins without a per-run local token.
2. **PowerShell ↔ Provider**: HTTPS with local BYOK; keys never uploaded to
   PromptParle for day-to-day chat.
3. **PowerShell ↔ Portal**: desktop license key for entitlements/install only;
   optional IP allowlist; TLS.

## Primary adversaries

| Adversary | Likely path |
|-----------|-------------|
| Malicious webpage on same PC | CSRF/local-service call to `127.0.0.1:7788` |
| Stolen `pp_live_` key | License/API abuse until revoked / allowlist |
| Stolen local provider key | Direct provider spend on user account |
| Credential stuffing | Portal login without lockout/rate limits |
| Curious GitHub reviewer | Source audit of auth, crypto, client surface |
| Malicious dependency | Supply chain in npm or install scripts |

## Controls (summary)

- Desktop license keys hashed server-side; provider keys on PC (DPAPI when available)
- bcrypt passwords; hashed sessions
- Email verification or OAuth (Google / GitHub) for account bootstrap
- Rate limits + login lockout
- Local UI token + Origin/Referer checks
- Secret gate on the PC before provider calls
- Config key material protected (DPAPI on Windows; mode 600 on Unix)
