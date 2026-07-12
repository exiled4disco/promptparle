# Changelog

All notable changes to PromptParle are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project aims to follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Entries are newest first. "Version" here refers to the desktop client / release
version stamped in the six version spots described in
[CONTRIBUTING.md](CONTRIBUTING.md#release-process).

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
