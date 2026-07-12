# Changelog

All notable changes to PromptParle are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project aims to follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Entries are newest first. "Version" here refers to the desktop client / release
version stamped in the six version spots described in
[CONTRIBUTING.md](CONTRIBUTING.md#release-process).

## [0.32.17] - 2026-07-12

### Added
- **Attach documents to chat — PDF, DOCX, XLSX.** Attach a document and the
  AI reads it. Text is extracted **locally on your PC** (via the local server's
  `/api/extract`; the file never leaves the machine) and fed through the normal
  optimize → model path.
  - DOCX + XLSX: zero-dependency OOXML (ZIP+XML) extraction; XLSX resolves
    shared strings into a tab/newline grid across all sheets.
  - PDF: best-effort text extraction (content-stream text operators, inflates
    FlateDecode streams). Scanned/image-only PDFs report clearly that no text
    could be extracted rather than attaching garbage.
  Works on Windows PowerShell 5.1 and PS 7.

## [0.32.16] - 2026-07-12

### Fixed
- Savings row missing on some replies in web-chat mode. The per-message
  savings meter only rendered when the turn had top-level original/optimized
  token counts — but agent / web-search / tool turns keep their savings in
  `tool_breakdown` / `agent_cost_tokens`, so the row silently vanished. The
  render gate now also shows for agent turns and any turn with a tool
  breakdown, so the savings line appears consistently.

## [0.32.15] - 2026-07-12

### Fixed
- Garbled characters in AI replies on Windows PowerShell 5.1 (em-dashes and
  curly quotes showing as "â□□" / "â€""). Provider calls used
  `Invoke-RestMethod`, which on PS 5.1 mis-decodes UTF-8 response bodies. All
  provider calls (OpenAI, Anthropic, Gemini, Grok) now go through a UTF-8-safe
  helper that sends the request as UTF-8 bytes and decodes the response as
  UTF-8 — identical behavior on PS 5.1 and PS 7. This was the same root cause
  behind "older PowerShell" symptoms.

## [0.32.14] - 2026-07-12

### Changed
- Desktop client renames: "API keys" → **Desktop Licenses**, "Providers" →
  **AI Provider API** (menu + Help panel), clearer about what each is.

### Fixed
- Invite accept page (`/invite/[token]`) no longer tells new users to "check
  your email for your invitation code" — signup is code-free. It now creates
  the account and drops them straight into the setup walkthrough.

## [0.32.13] - 2026-07-12

### Changed
- Invitations are now code-free referrals (signup is open). The invite email
  no longer shows a PP-XXXX code — it shows who invited you, their personal
  message, and a "Create your free account" link. The post-signup welcome
  email likewise dropped the "enter invitation code in the installer"
  language for the current create-account → license-key-per-desktop flow.
- User invite is a modal (email + message → Send) opened from the Invites
  page; the sent list now shows the message, status, and whether they joined.
- Admin Invitations view swapped the Code column for "Invited by" and relabeled
  Note → Message, so admins see every invite and who sent it.

## [0.32.12] - 2026-07-12

### Added
- Desktop first-run guided tour (client): the local UI now walks new users
  through the app once on first launch — left menu / optimize dial, tools &
  chat-mode toggles, the bug/suggest link, Help & the ⋯ menu, Usage & savings,
  and finally opens Providers to add BYOK API keys ("your keys stay on this
  machine"). Coach-mark spotlight with Next/Back/Skip; one-time (localStorage
  `pp_tour_done_v1`). Replayable any time via Help → "Replay setup tour". This
  is the desktop half that pairs with the portal /welcome wizard (0.32.11).

## [0.32.11] - 2026-07-12

### Added
- First-run setup walkthrough (portal): new verified users are guided through
  a 5-step wizard at `/welcome` — welcome + pick Windows/Linux, create a license
  key, copy the install command + key (shown separately), the on-desktop steps
  (Run PowerShell as admin / open a terminal → paste → paste key), and a
  "look around + support the project" finish. Skippable; sets `onboardedAt` so
  it appears only once. Existing accounts are backfilled as already onboarded.

## [0.32.10] - 2026-07-12

### Fixed
- Downloads: the client no longer shows a "Downloads ready · click to
  download" header + link when zero files were actually written. A failed
  ```file``` block (empty/unsupported/oversized) previously produced a link to
  a token that was never registered → the browser got a 404 "file wasn't
  available on site" and the user was told a file existed that didn't. Now it
  reports "Deliverable not created" with the reason, and only emits download
  links for files that really landed.
- Web-search intent: a question about a LOCAL artifact (a filename with a
  doc/data extension, "this chat", "this PC", "workbook/spreadsheet",
  "downloads folder") no longer triggers a web search. This fixes turns like
  "what's in ALL_ISSUES.xlsx" wrongly searching the web (and returning
  irrelevant Google Drive / Windows-update results), and removes the ~2s+ that
  wasted per turn.

### Changed
- Tightened web-search / page-fetch timeouts during turn prep (12–18s → 6–7s)
  so a slow or hung fetch can't add 10s+ of latency to a turn.

## [0.32.9] - 2026-07-12

### Changed
- Portal cleanup now that the desktop client is the source of truth:
  - Settings: removed the "Chat defaults (provider/model/dial/tools)" and
    "Desktop project connections" editors — you set these in the desktop app,
    which syncs them to the portal via the heartbeat. The sync API is unchanged.
  - Admin nav: collapsed Messages / Accounts / Invitations into a single
    **Admin** dropdown so the header no longer overflows.
  - Dashboard: removed the "Manage provider keys" quick link (providers live on
    the PC) and the developer-facing `POST /api/v1/prompt` note.

## [0.32.8] - 2026-07-12

### Added
- Release automation: pushing a `vX.Y.Z` tag creates a GitHub Release and
  attaches the desktop client artifacts (`PromptParle-PowerShell.tgz`,
  `PromptParle.psd1`, version files). The workflow verifies `version.txt`
  matches the tag before releasing.
- Community files: issue templates (bug / feature), a Sponsor button
  (`FUNDING.yml`), and template config routing support questions to the
  `/contact` form and security reports to `SECURITY.md`.

## [0.32.7] - 2026-07-12

### Changed
- Privacy/repo hygiene: removed hardcoded company special-cases from the
  desktop client's web-search logic; genericized sample references; made the
  edit-check hook's PATH portable. The public repo now contains only the
  application and user-facing docs; internal development files live in a
  separate private workspace.

### Fixed
- Content-Security-Policy allows the official GitHub Sponsors iframes
  (`frame-src https://github.com`) on routes that carry a CSP.

## [0.32.6] - 2026-07-12

### Added

- GitHub Sponsors embeds on pricing (official card + button) and sponsor button
  in the site footer and homepage pricing teaser.
- GitHub Discussions newsletter channel (Announcements) with issue #1.
- Optional GitHub Sponsors webhook at `POST /api/webhooks/github` (signature
  verified; audit log + admin email). Set `GITHUB_WEBHOOK_SECRET`.

## [0.32.5] - 2026-07-12

### Fixed

- Left-aligned the per-message savings row (removed a 3.2rem indent gap in
  terminal-chat mode).
- Chat History is no longer crushed when all sidebar sections are expanded
  (flex fix).

## [0.32.4] - 2026-07-12

### Fixed

- Restored Google / GitHub OAuth on the register page (regression from the
  register rework).

### Changed

- Removed the sticky top signup banner.

## [0.32.3] - 2026-07-12

### Fixed

- Removed the duplicate savings bar — one row only.

## [0.32.2] - 2026-07-12

### Changed

- Unified savings accounting across the per-message bar, session strip, and
  running-stats sidebar (single canonical before→after figure).

### Fixed

- Discard the stale localStorage savings store via a schema bump so the three
  panels no longer disagree.

## [0.32.1] - 2026-07-12

### Fixed

- Honest agent-turn savings: credit avoided-ingest from local tools (context
  fleet / doc briefs) instead of only the tiny cross-round delta.

### Changed

- Response details collapsed to one row.
- Simple download link for artifacts.

## [0.32.0] - 2026-07-12

### Changed

- **PromptParle is now free for everyone.** No paid tier, no paywall, and no
  features gated behind money. Optimization and provider calls run on the user's
  own PC with their own keys (BYOK), so the portal never proxies prompts and
  carries no per-request server cost to charge for.
- Portal repositioned to **licensing + stats + change control + public user guide
  + bug tracker + settings** — it is no longer a price ladder or an
  invitation gate.

### Added

- **Optional, pay-what-you-can support.** A monthly donation to help keep the
  project maintained (sponsor link). No features are locked behind it —
  supporters and non-supporters run the identical client.

### Notes

- Each desktop still needs its own free license key (`pp_live_`) from the portal.
- Docs, `llms.txt`, and `llms-full.txt` updated to the free + pay-what-you-can
  positioning.

## [0.31.3] - 2026-07-11

### Fixed

- Honest agent-turn meter: the readout now reports actual cost/savings instead of
  a misleading "expanded" figure.

### Changed

- Unified the chat input into a single input box.

## [0.31.2] - 2026-07-11

### Changed

- Top savings strip is now a simple session summary rather than a per-turn dump.

## [0.31.1] - 2026-07-11

### Changed

- Savings UX polish: full-width savings line, one-row status, simpler toggles.

## [0.31.0] - 2026-07-11

### Added

- Honest generation metering, cumulative stats, and savings alerts.

### Fixed

- Download fix.

## [0.30.1] - 2026-07-10

### Fixed

- Background-turn UX fix, artifact deliverables, and framing memoization.

## [0.30.0] - 2026-07-10

### Added

- Background turns — keep chatting while long work runs.

## [0.29.1] - 2026-07-09

### Fixed

- No empty timeouts on implement turns: soft deadline plus best-so-far result.

## [0.29.0] - 2026-07-09

### Added

- Tool-savings bridge and avoided-ingest attribution.

### Changed

- Installer parity across entry scripts.

## [0.28.0] - 2026-07-08

### Added

- Per-tool savings breakdown.

### Fixed

- Head-strip fix — root cause of 0% chat savings.

## [0.27.2] - 2026-07-07

### Fixed

- Honest savings baseline for conversational turns.

## [0.23.4] - 2026-07-05

### Changed

- Clearer savings line and sticky mid-session model switch.

## [0.23.3] - 2026-07-05

### Changed

- Compact savings UI in chat.

## [0.23.2] - 2026-07-05

### Added

- Terminal AI chat layout and slash-command autocomplete.

## [0.23.1] - 2026-07-05

### Changed

- Per-provider model lists only, with fresher model catalogs.

## [0.23.0] - 2026-07-05

### Added

- Dynamic model select and portal ↔ client settings sync.
