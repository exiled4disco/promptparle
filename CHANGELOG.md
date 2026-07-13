# Changelog

All notable changes to PromptParle are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project aims to follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Entries are newest first. "Version" here refers to the desktop client / release
version stamped in the six version spots described in
[CONTRIBUTING.md](CONTRIBUTING.md#release-process).

## [0.32.31] - 2026-07-13

### Added
- **Live auto-escalate redo** — routing now self-heals. When a routed (cheaper) model
  returns a genuine non-attempt (empty/garbled), the turn is automatically re-run ONCE
  on one tier stronger, and the escalation outcome is logged (did the stronger answer
  stick? → feeds the per-cell tuning readout). Hard guards, all verified in logic:
  one retry only (a redo can never trigger another — no loop, no runaway spend);
  fires only when routing mode = Live AND the auto-escalate dial is on; NEVER on a
  refusal (no self-built jailbreak loop) and never on calibrated hedging; steps exactly
  one tier up (no-op if already top). Manual "↑ stronger" remains for user-triggered redo.

### Needs your verification
- The redo makes a SECOND provider call, which can only be truly tested on the running
  client with a real key. All guards + the tier-step + the one-retry invariant are driven
  green in logic, but before trusting it: set routing to **Live**, force a weak-model miss,
  and confirm it retries exactly once on a stronger model and logs the escalation (no loop,
  no double answer). Until you've done that, treat the redo path as unverified.

## [0.32.30] - 2026-07-13

### Added
- **Live progress feedback during long turns.** A slow turn was a black box — you
  couldn't tell it was doing anything. Now a background turn writes its REAL stage to
  the job file as it works (local tools & memory → routing → model working → agent
  round N/M → quality-gate verifying), and the browser's pending bubble shows that
  stage plus a live elapsed counter, polling every 2s. Not a wall-clock guess — the
  actual phase. The stage writer is null-safe (no-op on inline turns, can never break
  the turn; it only writes a status field, no extra API call).
- **Total work time.** Each answer shows "took Xs" (send → answer), and Running Stats
  shows a cumulative "Total time" across the session.
- **Cumulative output spend** stays surfaced in Running Stats ("Output spend": total
  output tokens · $ at each model's output rate) — the costly side, session-wide.

## [0.32.29] - 2026-07-13

### Added
- **Routing outcome-measurement (the tuning layer).** Shadow mode validates the routing
  DECISION; this measures the OUTCOME — was the routed answer actually good enough? —
  which shadow structurally can't see. Per-cell (persona × ask-category × tier) quality
  log fed by weighted signals: 👍/👎 and a "↑ stronger" button per answer (ground truth),
  retry/rephrase detection (probable-miss, reduced weight), and non-attempt detection.
  Distinctions that matter, all verified: **correction ≠ iteration** ("that's wrong" is a
  miss; "make it shorter" / "now add error handling" is a spec change on a good answer, not
  a miss); **calibrated hedging is not a failure** (only empty/garbled/non-attempt outputs
  count); **refusals are never auto-escalated** (logged to their own human-reviewed
  category — no self-built jailbreak loop) and **deduped per answer** (one bad response =
  one miss at the strongest signal, not three).
- **Per-cell tuning readout** in Settings: miss rate + escalation-stick rate → guidance.
  Escalations that STICK ⇒ the cell's default tier is too low (raise it); escalations that
  also fail ⇒ the category is just hard (raising only makes failure costlier — hold).
- Privacy: retry similarity is computed client-side; only the boolean signal is stored —
  prompt text never leaves the machine.

### Notes
- The LIVE auto-escalate redo (which fires a second provider call to a stronger model on a
  non-attempt) is intentionally NOT in this release — it's an API-calling hot-path change
  that must be built and verified on the running client together, not shipped from repo.
  Everything here is client-side logging only. Routing remains SHADOW by default.

## [0.32.28] - 2026-07-13

### Fixed
- **Persona merge review had the safety asymmetry backwards.** The expensive error is a
  false MERGE — it silently deletes a persona's force-top safety behavior (e.g. routing
  "drop this table" to a weak model). Classification-agreement alone is blind to keyword
  escalation, and that blind spot sat exactly on the merge verdict. Corrected with two
  changes, no privacy impact:
  - **Keyword fires are now logged as metadata** — `fired_rule: <rule_id>`, the rule ID
    only, never the matched string (the substring would be prompt content). This turns
    keyword divergence into a measurement: each persona gets an observed keyword-fire rate.
  - **A merge now requires BOTH** ≥90% classification agreement AND comparable keyword-fire
    profiles; an unknown fire rate blocks the recommendation (fail-safe). And the merge
    operation itself **unions force-top rules unconditionally** — escalators migrate, never
    drop — so even a recommended merge can't lose a safety keyword. Verified: Ops (fires 53%)
    vs Writer (0%) at 100% classification agreement now correctly does NOT recommend a merge.

## [0.32.27] - 2026-07-13

### Added
- **Smart routing (shadow mode) — the mechanism that generates output-token savings.**
  A local classifier reads each ask on two independent axes (category + complexity
  C1–C3) plus an INFERRED high-stakes flag (never a user self-declare lever), and
  routes to the right model tier. Personas are PRIORS, not separate routers:
  **Developer** (code→top, non-code→cheap), **Ops/SecOps** (force-top vocabulary —
  drop/rm/revoke/prod/incident pin to top even on a trivial-looking ask),
  **Writer** (mergeable), **General** (cheap-unless-hard). Global overrides apply on
  top: C3→top, high-stakes bump, low-confidence bump, ADVICE never cheapest.
- **Dials** (collapsed to the ones that aren't redundant): one *Prefer savings ↔
  quality* slider, a *model floor* (hard constraint — never route below), a *concise ↔
  thorough* verbosity slider (code/drafts always exempt), and an *auto-escalate*
  toggle (retry stronger if the answer looks off).
- **Shadow mode is the default:** the router classifies every turn and LOGS the model
  it *would* pick + the $ it would save (real tokens, output-weighted), but changes
  nothing. Review it in Settings; flip to **Live** only when the calls look right.
- **Standing persona merge review:** replays every persona against logged
  classifications and flags any pair routing ≥90% identically as a merge candidate —
  so the persona set shrinks/grows by real divergence, not upfront theory. (Classification-
  driven: keyword-override divergence isn't replayed since no prompt bodies are stored —
  the safe direction; it under-counts divergence, never over-recommends a merge.)

### Notes
- Routing is client-side, local, and privacy-preserving (no prompt bodies stored; the
  merge review replays on stored classifications only). Rule-based classifier — shadow
  mode exists precisely to surface misroutes against real traffic before Live.

## [0.32.26] - 2026-07-12

### Added
- **Model-spread savings engine.** You declare a base model (the top model you'd
  otherwise run everything on, e.g. Opus 4.8). Each turn already records real
  input/output tokens + the model that answered, so we compute: base cost (same
  tokens on the base model) − actual cost = the model-spread saving, output-weighted,
  from real tokens. Shown in Running Stats as **"Model-spread saved"** with a tooltip
  breaking down base-vs-spread cost. Honest by construction: a turn that ran on the
  base model saves $0, and an all-on-base session shows $0 (no fabricated number).
  Set/clear the base model in Settings → "Base model".
- **Output spend** cell in Running Stats: real output tokens this session · $ at each
  model's published output rate — the costly side (5–8× input), now visible.

### Notes
- Input-side savings (prep compression, doc dedup, carried-context, doc-summary
  source→summary) are unchanged and still shown — the output/spread figures are
  additive. Input savings are small in $ (input is cheap); output/spread is where the
  real dollars are. The spread engine currently MEASURES the saving; per-turn model
  routing (intent parser + personas + dials) is the next step.

## [0.32.25] - 2026-07-12

### Fixed
- **Document-summary savings were meaningless ($0.0012 for 50 pages).** The meter
  compared input-in vs input-out; on a summarize turn we deliberately send the docs
  uncompressed (for a faithful answer), so that difference is ~0. But a summary's
  real efficiency is OUTPUT compression: 50 pages of source (~22k tok) become a
  ~500-token summary that represents them going forward. Doc-summary turns now meter
  **source documents in → summary out** (e.g. 22k → 500 = −98%), the honest number.
- **Per-model prices were wrong/stale.** Corrected to published rates: Claude Opus
  4.5–4.8 **$5 in / $25 out** (was mispriced as the retired 4.1's $15/$75 — a regex
  matched "opus-4-8" as "opus-4"), Sonnet $3/$15, Haiku $1/$5, Fable $10/$50, gpt-5
  $1.25/$10, Grok 4.5 $2/$6, Gemini 3.5 Flash $1.50/$9, 2.5 Flash $0.30/$2.50. Each
  turn is priced at the model that actually answered it.
- Reverted the "docs kept intact · fidelity preserved" wording that replaced the
  numbers on doc turns — every turn now shows the same plain before→after line.

### Added
- **Real output-token spend, surfaced at last.** OUTPUT is where the cost is (5–8×
  input). LocalFirst.ps1 already captured each provider's real output-token count
  (`usage`) but it never reached the UI. Now forwarded (single-shot + agent paths)
  and shown per turn as **"output N tok · $X"**, priced at the model's published
  OUTPUT rate. You can finally see where the money actually goes, per model.
- No savings row / stats pulse / fireworks on an empty or errored answer (carried
  over from the honest-metering pass).

## [0.32.24] - 2026-07-12

### Fixed
- **"(empty response)" after an update — the real cause.** On the post-update
  restart, the local server's bind loop could silently fall through to a
  *different* port (7788–7798) if the intended port wasn't instantly reclaimable.
  The browser kept polling the original port, reported "local chat did not come
  back," and the next turn hit a dead/wrong listener → an empty response. The
  restart log ended at "import ok" and never said where the server bound, so the
  drift was invisible. Fix: the restart now binds the intended port **strictly**
  (`-StrictPort`) — no silent drift; if it truly can't bind, it fails loudly and
  the previous server is kept alive instead of stranding the browser.
- **No savings line / fireworks on an empty or failed answer.** A "$ saved" on
  "(empty response)" is a dishonest number (guardian Rule 6). The savings row,
  running-stats pulse, and fireworks are now suppressed when the answer is empty
  or errored.

### Changed
- **Restart logging (`%TEMP%\promptparle-restart.log`) now records the truth.** A
  background health probe logs whether the server is actually accepting
  connections and **on which port** ("HEALTH ok/FAIL"), plus the bound port on
  return. No more silence after "import ok."
- **Actionable UI messages.** "Did not come back" and empty-response notices now
  explain the likely cause (restart on another port) and tell you to run `pp` or
  reload — instead of implying the turn simply failed. Both also write an
  Activity-log entry pointing at the restart log's HEALTH line.

## [0.32.23] - 2026-07-12

### Added
- **Carried-context savings — the biggest hidden win, now metered honestly.** A
  standard AI API is stateless: it re-sends the entire conversation, *including
  attached document bodies*, on every turn, re-billing each token. PromptParle
  carries a compact summary forward instead, so a document discussed earlier is
  not re-sent full each turn. That avoided re-ingestion was previously credited
  $0. It is now credited as **"Carried docs (not re-sent)"** in the per-turn
  breakdown — the doc's real token size, credited on every follow-up turn while
  the doc is still within the window a plain client would carry, and $0 once it
  ages out (a plain client would drop it too). Measured client-side because only
  the client knows the doc's full size (history is capped before it reaches the
  server). This is why a summarize turn shows little input savings ("docs kept
  intact") but the following turns finally show the value.

### Documented
- README now states the stateless-API counterfactual as a **fact about how AI
  clients work, not a PromptParle claim** ("How savings are measured"), and the
  carried-docs figure carries the same explanation in its tooltip. Upfront about
  the basis for every number.

## [0.32.22] - 2026-07-12

### Changed
- **Honest cost estimates (the "$ saved" was inflated).** The est. $ figure used a
  single *blended* rate per model (e.g. gpt-5 at $8/M) applied to input-side
  savings. Savings are almost entirely input tokens, so blending in the (much
  higher) output rate overstated the dollars — gpt-5 read ~6.4× too high. Now
  each model carries published **input/output** list prices and saved tokens are
  priced at the **input** rate. Composer estimate, per-message, and the running
  stats all inherit the corrected rate. (guardian Rule 0 + Rule 6)
- **Attached-doc summarize turns tell the honest story.** On a read/summarize ask
  we deliberately keep the documents uncompressed (the answer needs them intact),
  so a big "% saved" was misleading. The meter now shows "✓ docs kept intact ·
  N tok of source sent in full · answer fidelity preserved" instead of a
  confusing number. New `docs_kept_fidelity` signal flows prep → meta → UI.

### Added
- **Duplicate-document collapse (server-side, lossless).** If the same document
  body appears more than once in a single turn's context (the file attached
  twice, or a double-add), the copies are collapsed to one full body plus a
  pointer — byte-identical dedup, credited honestly through the tool ledger as
  `doc_dedup`. Cross-turn re-attaches are intentionally NOT faked: history is a
  lossy brief, so re-sending a doc for a fresh summary is real cost for real
  fidelity, not waste.
- **Savings celebration on Running Stats.** When savings increase, the "Est. value
  saved" figure racks up slot-machine style from the old total to the new one,
  then fireworks burst from the bottom-right to the center of the stats block. A
  new 🎆 toggle (next to the sound icon) enables/disables it; honors the existing
  "savings visual" setting and `prefers-reduced-motion`.
- **Guardian RULE 0: optimize token spend, always.** Codifies token optimization
  as the permanent top mandate — cost AND fidelity, never one at the expense of
  the other. Rising model prices push users toward weaker models; PP's promise is
  that they keep a top model and a lower bill. A "saving" that degrades the answer
  is a regression, not a win.

## [0.32.21] - 2026-07-12

### Fixed
- Attached-document summary STILL returned "I don't have the contents … say
  refresh" on turns with an established chat history — the real root cause,
  upstream of the 0.32.18/0.32.20 fixes. The evidence-mode resolver decided
  `session` (answer from memory only, tell the user to say "refresh") for a
  prompt like "summarize these documents in chat" because it inspected only the
  prompt text — which has no file path or extension — and never saw that the
  documents were attached in the turn context. It then returned before the
  fidelity guard could run, so the attached docs were never read. Composer
  attachments are now recognized as fresh primary evidence and force `live`
  mode, so prep keeps the document at full fidelity and the model reads it.
  Plain memory-recall turns (no attachment) still resolve to `session` — no
  regression. This is the fix that makes 0.32.18 + 0.32.20 actually reachable.

## [0.32.20] - 2026-07-12

### Fixed
- Attaching documents and asking for a summary still returned *"I don't have the
  contents of the attached files"* on turns that ran in agent/tools mode. The
  document's full text was ingested and kept at high fidelity through prep
  (0.32.18), but the multi-round agent loop then (a) treated "summarize these
  files" as a tool task — so the model requested tools for files it already had
  instead of answering — and (b) from round 2 on replaced the full documents with
  a 3,200-character "evidence spine," leaving the model an ~847-token stub. An
  attached-document read/summarize ask has no tool need: it now answers in a
  single shot over the full-fidelity document context, skipping the hands loop
  entirely. Turns that genuinely need tools are unchanged.

## [0.32.19] - 2026-07-12

### Fixed
- Attaching documents and asking for a summary returned "Deliver FAIL-CLOSED"
  (or web-searched) instead of summarizing them. "Executive summary" was
  classified as owing a downloadable FILE (so no-file-built → fail-closed), and
  "summary" tripped web intent. Now, when composer attachments are present and
  the ask is to read/summarize/analyze them (with no explicit URL/domain or
  "as a PDF/DOCX"), the turn answers from the attachments in chat — no forced
  deliverable, no web lookup. Explicit "as a pdf" or a domain still route to
  deliver/web as before.

## [0.32.18] - 2026-07-12

### Fixed
- "Summarize this document" said *"I don't have the document's contents"* even
  though the file was attached. The attached doc's text WAS ingested, but the
  fidelity fleet then summarized it down to a stub before the model saw it
  (7.2k → 758 tokens), so the model had nothing to summarize. Now, when a
  composer-attached document is present AND the ask is to read/summarize/extract
  from it, the document is kept at high fidelity (the budget cap is lifted to
  match) so the model receives the real content. Unrelated asks with an attached
  doc still compress normally.

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
