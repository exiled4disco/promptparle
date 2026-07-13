# PromptParle — Known Issues Board

Single source of truth. We work from here. Status values:
- **OPEN** — confirmed broken, not fixed.
- **FIXED-UNVERIFIED** — fix shipped to code, but NOT yet confirmed working on the user's running client.
- **VERIFIED** — confirmed working on the user's machine.
- **INVESTIGATING** — cause not yet pinned.

> Hard rule (learned this session): a fix is not "done" until it's **VERIFIED on the running client**.
> Repo-green ≠ working. Several fixes below shipped but the client failed to restart onto them,
> so they were never actually tested by the user.

Last updated: 2026-07-13 · latest shipped version: **0.32.41**

---

## P0 — Delivery / blocks everything

### BUG-1 · Updates fail to restart ("did not come back on this port")
- **Status:** FIXED-UNVERIFIED (0.32.41)
- **Symptom:** After an update, the server comes back on a different port (or fails to bind); the browser shows `127.0.0.1 refused to connect`. User must open PowerShell and run `pp` manually.
- **Impact:** THE root blocker — while broken, the user runs stale code and never receives any other fix. This is why bugs "kept coming back."
- **Cause:** update handoff bound the port while the old server was still releasing it; `-StrictPort` refused to drift → stranded.
- **Fix:** wait for port release + retry bind with backoff (verified against real socket contention). Note: cannot fix the restart that *installs* it — only subsequent restarts.
- **Verify:** on 0.32.41, trigger an update or restart and confirm it comes back on the same port with no manual `pp`.

---

## P1 — "Dumb as a rock" answering (the muzzle family)

### BUG-2 · Refuses to answer simple knowledge questions ("say refresh" / "I don't have it stored")
- **Status:** FIXED-UNVERIFIED (root fix 0.32.41)
- **Symptom:** "capital of Ohio", "list all cities in Texas", "find me a recipe" → "I don't have that stored in this session, say refresh" or a clarifying-question stall.
- **Cause (root):** the evidence resolver DEFAULTED to gather-before-answer; answering from the model's own knowledge was a special case.
- **Fix:** flipped the default — answer from own knowledge by default; session/web/tools/refresh only on genuine need.
- **Verify:** on 0.32.41, ask "capital of Ohio" and "list all time zones" → expect a direct answer, no refresh/fetch.

### BUG-3 · Fetches irrelevant web pages for a knowledge question, then quality-gates the garbage
- **Status:** FIXED-UNVERIFIED (0.32.41, via the same default flip)
- **Symptom:** "list all the time zones" → tried to scrape texas-demographics.com / packetviper.com / fandango.com, then "Quality gate: 0% evidence-backed, unverified".
- **Cause:** same gather-first default routed a plain question to web/observe.
- **Verify:** "list all the time zones" on 0.32.41 → direct answer, no web fetch, no quality-gate report.

### BUG-4 · Interrogates before answering (4-part clarifying questions)
- **Status:** FIXED-UNVERIFIED (0.32.38 + 0.32.41)
- **Symptom:** "find all Texas cities" → "do you mean incorporated places or top 100? which census year? CSV or table?" before doing anything.
- **Fix:** general directive = answer-first with sensible defaults, offer refinements in one line at the end.

---

## P1 — Wrong pipeline fires on normal turns

### BUG-5 · FAIL-CLOSED implement report stapled on top of normal answers
- **Status:** FIXED-UNVERIFIED (0.32.41 containment; root partially 0.32.40)
- **Symptom:** a recipe/review answer comes back buried under `## What changed / FAIL-CLOSED: implement turn produced no apply/run action / apply-channel: C:\Users\frank\Downloads`.
- **Cause:** a stale `implement` obligation from prior code work mislabels an unrelated later turn as implement; the apply pipeline runs, finds nothing, and prepends its report.
- **Fix:** (a) 0.32.40 clears a stale implement obligation on a plain-question pivot; (b) 0.32.41 containment — the report only prepends when the pipeline did real work (files/commands/real apply-run blocks), never onto a plain answer.
- **Verify:** on 0.32.41, do code work, then ask for a recipe → recipe only, no "What changed" block.

### BUG-6 · Apply channel resolves to LOCAL Downloads when the user meant SSH
- **Status:** OPEN (investigating)
- **Symptom:** "look at my SSH connection directory / code repo" → the app reports `apply-channel: local (C:\Users\frank\Downloads)` and ignores the SSH repo.
- **Cause (suspected):** the local-vs-SSH target picker (0.32.35) chooses the local workspace even when the active connection / the ask points at SSH; possibly compounded by BUG-5's wrong implement routing.
- **Note:** needs the decision log (BUG-11) to see which channel/obligation fired. Do NOT guess-fix.

---

## P2 — Model selection / routing

### BUG-7 · Base model drifts to the routed model ("gets stuck on the model")
- **Status:** OPEN (fix designed, not written)
- **Symptom:** user sets base = gpt-5; app routes a simple turn to gpt-5-mini; next turn the app treats gpt-5-mini as the base. Savings then measured against the cheap model; routing floor drifts down.
- **Cause:** `getBaseModel()` falls back to the live model selection when no explicit base is set, and the routed/answered model can leak into the selection/session sync.
- **Decided fix (user):** the user's pick = fixed base + floor; the app may route DOWN but never rewrites the base or selection. Selecting a model sets the base explicitly; routing never writes back.

---

## P2 — UI / metering

### BUG-8 · Running stats update only on next send, not when the answer lands
- **Status:** FIXED-UNVERIFIED (0.32.41)
- **Cause:** stats walk stored messages, but the answer persists on a debounced timer that hadn't fired.
- **Fix:** persist + refresh stats in the send `finally` the moment the answer lands.
- **Verify:** send a question on 0.32.41 → sidebar stats update immediately on the answer.

### BUG-9 · Activity log window "127.0.0.1 refused to connect"
- **Status:** LIKELY-FIXED via BUG-1 (unverified)
- **Symptom:** activity-log pop-out refuses to connect.
- **Cause:** same as BUG-1 — server drifted to a different port; the pop-out (and main tab) pointed at the dead one.
- **Verify:** on a stable 0.32.41, open the Activity log pop-out → connects and streams.

---

## Features requested (not bugs, but tracked here so nothing is lost)

### FEAT-10 · Log levels (base / detailed / verbose) + per-turn decision log
- **Status:** IN PROGRESS (0.32.42, not shipped)
- **Ask:** show what the AI is actually doing — a per-turn decision chain (turn-kind, obligation, evidence mode+reason, channel+why, model routed, contract, pipeline) in the Activity log, gated by a Settings level. Metadata only (no prompt bodies).
- **Built so far:** server assembles `meta.decision`; client `getLogLevel`/`logDecision` written. TODO: Settings toggle, wire the emit on answer-land, ship.
- **Why it matters:** ends the "guess from a screenshot of stale code" loop — this is the instrument for diagnosing BUG-6 and any remaining muzzle.

### FEAT-11 · CAR (cost per accepted resolution) on dashboard
- **Status:** SHIPPED 0.32.40 (unverified on client)

### FEAT-12 · Live streaming usage graphs + separate dashboard window
- **Status:** SHIPPED 0.32.36–0.32.37 (unverified on client)

### FEAT-13 · Output contracts per service class (diff/structured/terse)
- **Status:** SHIPPED 0.32.39 (unverified on client)

---

## Working agreement (this board)
1. Nothing is closed until **VERIFIED on the running client**.
2. Fix delivery (BUG-1) first-class — a fix that can't be received is not a fix.
3. Before fixing a "why did it do that" bug (BUG-6), use the decision log (FEAT-10), don't guess.
4. One change → verify on the client → then next. Stop the shotgun releases.
