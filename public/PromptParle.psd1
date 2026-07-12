@{
    RootModule        = 'PromptParle.psm1'
    ModuleVersion     = '0.32.1'
    GUID              = 'a8c3e2f1-9b4d-4e6a-8f2c-1d5e7a9b0c3d'
    Author            = 'PromptParle'
    CompanyName       = 'PromptParle'
    Copyright         = '(c) 2026 PromptParle. All rights reserved. PromptParle and the PromptParle logo are trademarks of PromptParle.'
    Description       = 'PowerShell client for PromptParle - AI context optimization gateway. Trim the prompt. Keep the signal.'
    PowerShellVersion = '5.1'
    FunctionsToExport = @(
        'Set-PromptParleApiKey',
        'Sync-PromptParlePortalSettings',
        'Get-PromptParleConfig',
        'Get-PromptParleProvider',
        'Set-PromptParleProviderKey',
        'Remove-PromptParleProviderKey',
        'Set-PromptParleSecretPolicy',
        'Get-PromptParleUsage',
        'Invoke-PromptParle',
        'Invoke-PromptParleLocalFirst',
        'Invoke-PromptParleAgentTurn',
        'Invoke-PromptParleChatTurnCore',
        'Invoke-PromptParleRunChatJob',
        'Invoke-PromptParleSecurityReview',
        'Start-PromptParle',
        'Start-PromptParleLocalServer',
        'Stop-PromptParleLocalServer',
        'Open-PromptParleBrowser',
        'Uninstall-PromptParle',
        'Get-PromptParleClientVersion',
        'Get-PromptParleUpdateStatus',
        'Update-PromptParleClient',
        'Get-PromptParleAgent',
        'Get-PromptParleAgentList',
        'Save-PromptParleAgent',
        'Remove-PromptParleAgent',
        'Set-PromptParleActiveAgent',
        'Get-PromptParleToolCatalog',
        'Invoke-PromptParleLocalTool',
        'Invoke-PromptParleAgentLocalPrep',
        'Optimize-PromptParleAgent',
        'Invoke-PromptParleSlashCommand',
        'Get-PromptParleWorkspace',
        'Set-PromptParleWorkspace',
        'Clear-PromptParleWorkspace',
        'Get-PromptParleConnections',
        'Set-PromptParleActiveLocalConnection',
        'Add-PromptParleKnowledgeConnection',
        'Remove-PromptParleConnection',
        'Update-PromptParleConnectionCatalog',
        'Search-PromptParleKnowledgeCatalog',
        'Read-PromptParleKnowledgeFile',
        'Get-PromptParleGitHubStatusText',
        'Set-PromptParleSshTarget',
        'Clear-PromptParleSshTarget',
        'Invoke-PromptParleSsh',
        'Test-PromptParleSshWorkingDirectory',
        'Get-PromptParleSshDirCompletions',
        'Invoke-PromptParleTerminal',
        'Invoke-PromptParleGitClone'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @(
        'pp',
        'promptparle'
    )
    PrivateData       = @{
        PSData = @{
            Tags         = @('AI', 'Prompt', 'OpenAI', 'Claude', 'Gemini', 'Grok', 'PromptParle')
            ProjectUri   = 'https://promptparle.com'
            ReleaseNotes = @'
0.31.2: Simpler top savings strip. The top strip is no longer a dense per-turn dump — it's now a clean SESSION summary for the open chat: "Session Stats · Messages N · Total Tokens A → B · Saved Tokens N · Est $ Saved · Framing N". The detailed per-turn breakdown still lives in the per-message line under each answer. Refreshes when you switch chats.
0.31.1: Savings UX polish. Per-message savings line now spans the full chat width (both Terminal + Web modes). Background-job status ("⏳ N running · ✓ N ready") moved inline into the composer status row — one row, no floating element. Usage & savings alert checkboxes are on one row with simple labels: "Play Sound" · "Animate Stats".
0.31.0: Honest generation metering + cumulative stats + savings alerts. (1) Fixed HTML deliverables downloading as .json (download uses the real filename). (2) Meter truth: generation turns (build a 14KB file + local quality-gate) no longer read as "expanded" — the quality gate self-checks locally at 0 AI tokens (work a raw provider would bill), now credited as an avoided-ingest saving; the strip separates context-in from generated output and leads with local-tool savings. (3) Running stats are now CUMULATIVE — deleting a chat no longer lowers your totals (increment-only store, id-keyed; Reset still zeroes it). (4) Sound + visual savings alerts: speaker mute toggle in the Running Stats card, a one-shot grow/glow on the Est-value cell + a synthesized "cha-ching" when a turn saves, both toggleable (pp_savings_sound / pp_savings_visual). (5) Usage & savings modal: only the Recent history scrolls now (header/stats/buttons stay put) and the action buttons moved above Recent.
0.30.1: Background UX + deliverables + framing memoization. (1) Fixed a 0.30.0 regression — the "working in the background" note went to the Activity log instead of the chat; now it's a visible pending bubble that becomes the answer in place. (2) "create/build/make me a web form/app/script/page/tool" now produces a downloadable FILE (not code pasted in chat) — with no bound workspace these artifact asks resolve to deliver, not mutate. (3) Framing memoization: the [SELF] identity card is sent in full only on turn 1 of a chat; later turns send a 1-line pointer (~1.3k chars / ~325 tok saved per turn), so short follow-ups stop reading as "expanded" and the saving is credited to the framing tool.
0.30.0: Background turns — keep chatting while long work runs. Turns likely to run long (implement/build/create, or a large attachment) now run in a detached child process on your PC so the local server stays free. You get a "working in the background" note and can keep chatting immediately; the answer lands back in its origin chat when ready (with a badge if you moved to another chat). Provider keys and work stay local. New local endpoints: POST /api/chat {background:true} → job_id, GET /api/chat/job?id=, GET /api/chat/jobs. The /api/chat turn logic was refactored into Invoke-PromptParleChatTurnCore (shared by inline + background paths). Soft-deadline (0.29.1) stays as the safety net.
0.29.1: No more empty timeouts on implement turns. The agent loop now has a soft wall-clock deadline (≤540s): when it's close, it does one final "answer now from evidence gathered" synthesis and returns the best result so far — instead of looping silently until the client aborts and discards the work. Tokens spent are captured even on early return. Client abort is now tiered by turn kind (implement/tool ~600s > server deadline; quick Q&A 240s) so it's a backstop, not the normal path. Timeout message no longer says "fewer attachments" when there were none.
0.29.0: Tool-savings bridge + avoided-ingest attribution. Local tools that do work the model can't (git, ssh_read, relevant_slice) now report an honest avoided-ingest saving (raw output that never hit the model vs the compact result sent). Per-turn savings roll up locally and flush to the portal on heartbeat (aggregate numbers only — no prompt bodies), so the Usage page shows a "Savings by tool" breakdown across devices. In-chat savings strip gains a "By tool" line. Also synced the Windows/Linux/FromGitHub installers to parity (BaseUrl + SkipInvitePrompt).
0.28.0: Per-tool savings breakdown + head-strip fix. Prep now emits a vendor-neutral tool_breakdown ([{tool,kind,chars_without,chars_with,chars_saved}]) shown per turn ("By tool: fleet -12573t, …"). Fixed a greedy framing head-strip regex that absorbed document context into the protected head so the fleet compressors never ran — the root cause of ~0% savings on chat turns. With the fix a 50k-char doc now compresses 95% (13255->684 tok) and the saving is attributed to the fleet tool.
0.27.2: Honest savings baseline — always-on client framing ([SELF]/[CONN]/[PROJECT]) now counted into "before" so identical framing nets to 0% instead of showing as expansion. Accounting only; model input unchanged.
0.27.1: Session catch-up product path — SELF knows chat history is UI/localStorage not .parle/sessions; catch-up modes; quality gate skips menus/hands-only non-product
0.27.0: Evidence mode session|live|refresh — prep owns depth, chat dispatches hands_allowed; kill 0.26.24–26 hotfixes (no avoided-fleet fiction, no always-true product pack, no chat MEM salvage)
0.26.26: Session-memory = single model call (no hands/synthesis bill); avoided-fleet savings credit; sanitize tool-theater replies
0.26.25: Fix local prep crash (ArrayList.Add pipeline pollution) — restore MEM/context; stop 8-round SSH re-fleet
0.26.24: Session-memory path — re-asks answer from [MEM]/[KNOW], skip heavy SSH re-fleet; honest before/after
0.26.23: Session Knowledge pins — mark key replies as priority [KNOW] for the chat (survives densify)
0.26.22: Turn-level token savings include prep densify (MEM/budget) — stop 18k→18k flat when tools saved
0.26.21: Fix Claude model-call Argument types — Anthropic body + List[string] PS 5.1
0.26.20: High-fidelity session memory — densify noise/age only, keep recent project signal
0.26.19: Rolling session memory — compact older turns, keep project spine + recent chat
0.26.18: Conversational answers after tools — never dump [HANDS] packs to chat
0.26.17: Live-info web observe + Gemini google_search/tool_call map; emergency web_search never dead-ends
0.26.16: Bare [HANDS] + tool:arg (Gemini-style) enters hands loop — never shown as final answer
0.26.15: Deliver FAIL-CLOSED only on real doc asks; session web ledger stops research amnesia
0.26.14: OpenAI o-series/gpt-5 use max_completion_tokens (fix unsupported max_tokens)
0.26.13: Running stats static aggregates + usage icon; Bug/Suggest text under composer (no FAB)
0.26.12: Dark brand scrollbars — color-scheme dark so Windows/WebView2 never paints light OS bars
0.26.11: Brand dark scrollbars on desktop local-UI (sidebar/chat — no light OS chrome)
0.26.10: Fix chat Argument types — ArrayList not List[string]; plain hashtables + staged chat errors; safe provider JSON
0.26.9: Fix chat "Argument types do not match" — LocalFirst metadata used OrderedDictionary cast (every completion)
0.26.8: Fix chat with Tools ON — Invoke-PromptParleAgentTurn accepts ClientSessionId/SessionTitle (UI splat)
0.26.7: Fix attach/SSH "Argument types do not match" — never cast OrderedDictionary to PSCustomObject (session load + snapshot)
0.26.6: Fix module parse — $etype: in throw strings broke PS parser (blocked 0.26.5 update)
0.26.5: Bulletproof session save (plain hashtables + File.WriteAllText); no TrimEnd/TryParse-ref; versioned errors + debug log
0.26.4: Hardening PS 5.1 attach/SSH — safe int/path coercion, no List[string].Add, staged error messages for Argument types mismatches
0.26.3: Fix local folder Add + SSH history connect on Windows PS 5.1 (TrimEnd/TrimStart Argument types do not match); resilient history cwd
0.26.2: Collapsible left-menu sections (Chat history, Chat, Project connections, Running stats) with remembered open/closed state
0.26.1: Fix Project connections + buttons (fsTitleEl/knowAddBtn bindings); compact + icons; custom hover help popover
0.26.0: Multi This PC folders (up to 5) + Knowledge Repo (up to 2). On-disk catalogs; skinny [CONN]; know_search/know_read on demand (no prompt dump)
0.25.14: Browser tab shows PromptParle favicon (local UI)
0.25.13: Fix SSH name parse — /ssh name "Label" user@host no longer glues host into sidebar label
0.25.12: Running stats at bottom of left menu; Tools/Optimize/Terminal pinned in top bar; SSH sidebar never shows host or directories
0.25.11: Left menu Running stats — tokens, savings %, est. $, messages + per-model breakdown
0.25.10: Providers Get key buttons open OpenAI / Anthropic / Gemini / xAI key pages
0.25.9: Fix Providers dark form controls; hide empty Edit pill; fix Bug/Suggest (bind after FAB/modal in DOM)
0.25.8: Help + docs messaging — provider keys on PC (⋯ → Providers); portal licensing only
0.25.7: Fix empty providers dropdown — LocalFirst list uses pscustomobject (ConvertTo-Json-safe)
0.25.6: Fix 0.25.5 package parse — no return inside finally (console restart after stop)
0.25.5: Console hotkeys while pp runs — [U]pdate [R]estart [Q]uit [O]pen UI [H]elp (works when browser UI is dead)
0.25.4: Parse-fail recovery banner + package preflight for dead local-ui script (nothing clickable)
0.25.3: Silence Set-Acl SeSecurityPrivilege on pp start; fix local-ui JS parse (version badge + Update button dead)
0.25.2: Fix LocalFirst PS5.1 (hashtable case-insensitive keys + multi-assign)
0.25.1: Fix LocalFirst.ps1 for Windows PowerShell 5.1 parse (hashtable multi-assign broke import probe)
0.25.0: LOCAL-FIRST — provider keys + optimize + model calls on this PC; portal is licensing only (pp_live_). Set-PromptParleProviderKey; secret gate; drop journal metadata
0.24.2: Fix module parse — missing comma after ClientSessionId param (blocked 0.24.1 updates on Windows)
0.24.1: Bug/Suggest floating button (bottom-left) + fixed modal close (backdrop/Escape/Cancel); session titles on chat; feedback proxy to portal
0.24.0: Terminal savings polish + sticky mid-session model switch
0.23.8: Fix module parse (try/catch inside hashtable broke PS 5.1)
0.23.7: SSH privacy — friendly name in sidebar; sorted connection history (no passwords); hide host/cwd
0.23.6: Live model lists always refresh (Claude/GPT/Grok newest); fix providers curated-only bug
0.23.5: Composer live model + as-you-type token/cost estimate; fix dial meta (tools-on was stuck at 1/5)
0.23.4: Savings line explains before/after/tok/$ est + model (green); mid-session model switch sticks (sticky + /api/session)
0.23.3: Compact chat savings (one thin line; no giant 0% wow cards; quieter top strip)
0.23.2: Terminal AI chat layout option; slash / command autocomplete in bubble + terminal; /mode /model
0.23.1: Model list strictly per provider (no GPT under Grok); race-safe refresh; expanded curated catalogs (Grok 4, GPT-5, Claude 4.5, Gemini 2.5)
0.23.0: Dynamic model select from provider list (live+curated); portal Settings chat defaults; bidirectional portal↔client settings sync; install pulls prefs after API key
0.22.4: Local dir list on this PC (C:\); no hardcoded /home/ubuntu product root; [SELF] capabilities + portal/help; local_list tool
0.22.3: Stop Grounding 0.20 near-quote spam after clean quality gate; high-severity-only grounding; AMTD expansion not flagged when AMTD in evidence
0.22.2: Quality gate scores product bullets (not markdown-skip / grounding theater); silent when research is source-backed; package always includes local-ui
0.22.1: Research hands — HTML DDG fallback + domain page auto-fetch into [WEB]/[OBSERVE]; quality gate skips no-evidence meta / thin shells (no 0% spam)
0.22.0: Multi-AI native agent client — pass-through tools (OpenAI/Anthropic/Gemini/Grok), desktop tool loop, capture requests/responses; optimize deferred
0.21.1: Fix research-on-domain observe miss; intercept foreign toolcall/XML as hands (never show raw tool markup)
0.21.0: Quality gate MVP — extract claims, match evidence, score %, soft-correct high-severity inventions, 0 extra AI tokens
0.20.0: Structural confidence — [PROVENANCE] claim audit vs page+prior assistant, [GROUNDING] + post-pass flags, provenance fail-closed, evidence spine across agent rounds
0.19.0: Brain+hands agent loop — token-first multi-round hands (web/SSH/workspace), compact [HANDS] packs, natural eng client (not mode box)
0.18.0: Client-first observe (SSH list, web page) + deliver fail-closed + sticky open obligation
0.17.1: Fix doc2 poisoned by doc1 — collapse prior file deliverables in [MEM]/history; THIS-turn ATTACH is primary
0.17.0: Document deliverables — ```file name=Report.docx``` (pdf/docx/xlsx/csv/md/html/txt/json) builds a real file; chat shows Download buttons via /api/exports/{token}
0.16.1: Doctrine capability=obligation — homework interceptor, auto prisma follow-through, fail-closed implement, theater detect
0.16.0: Implement pipeline — read-before-write apply, ```run``` allowlisted remote cmds; portal API IP/CIDR allowlist
0.15.5: Safe apply — source_root only, auto *.pp-bak backup, never live /var/www, refuse stubs/destructive shrinks
0.15.4: Clear ## What changed header after apply; refuse stub/destructive overwrites (schema gutting)
0.15.3: Natural-language implement (lets do it / leave it to you / stop asking) + history sticky — model already understands English; prep must not underrun
0.15.2: Sticky implement + hard CLIENT DIRECTIVE on prompt — stop multi-turn ask loops that waste session tokens
0.15.1: Apply path= blocks write via SSH; implement turns no permission theater; 'lets do it' = implement
0.15.0: Architecture — normal AI client + token optimize; durable product bind; always-on [PROJECT] card; turn-kind prep; drop ban-list moles
0.14.15: Portal product pack + ban false "handoff has no portal"; handoff is MAP; monorepo paths in brief
0.14.14: Fix empty ship-mode theater — answer factual/handoff questions first; ban "Ready/Name it and I ship/spine locked"
0.14.13: Remove ops log number/indicator from upper-right ⋯ menu entirely (Activity log left only)
0.14.12: Native role:system + provider cache; usage Before excludes product brief; local work-thinking (no tokens); no log number badges; composer ~10 rows
0.14.11: Dense [SYS]/[RT] framing (~60% fewer tokens/turn) — same hard bans, less wasteful "You are a…" every call
0.14.10: Fix Update not offering newer version — robust remote parse + portal text/plain version.txt; never fake "Up to date"
0.14.9: Fix attach stick after send — epoch cancels in-flight compress; hard wipe chips; visible "composer cleared"
0.14.8: Stop lost PP — ban invent Tailwind/fake diffs/homework; clear attachments on submit; [ATTACH] as relevant evidence
0.14.7: Version-aware Update — skip download when already current; force reinstall only on confirm / Shift+click
0.14.6: Activity log always visible (left menu above footer); continuous [MEM] auto-compact (spine+tiers); seamless system brief
0.14.5: Fix images nested array (expected object, received array) — flatten PS wrap + portal coerce
0.14.4: Fix multi-image paste — large JSON serialize (PS 5.1 2MB cap) + tighter compress + nginx 32M
0.14.3: Fix Invalid request — coerce API body types; clearer validation errors
0.14.2: Ban user homework lists; auto SSH product-work pack so model acts on evidence instead of asking you to run 1-2-3
0.14.1: Rename chat history labels; action-first system brief (less questionnaire, more do-the-work)
0.14.0: Agents out — continuous chat + dial-only high-fidelity optimize (you → shrink → model)
0.13.9: Fix StrictMode crash on restart (PromptParleExitProcessAfterStop unset)
0.13.8: Update closes the old PowerShell window after successful restart handoff
0.13.7: Auto default — deterministic best-lens router each message (specialists optional)
0.13.6: Turn-lens agents — sticky preference, not a prison; topic shift escapes security corridor
0.13.5: SSH cwd is live — auto-fetch files named in the prompt into [SSH] evidence
0.13.4: Update restart hardened — overlay install + durable restart.ps1 (no silent dead client)
0.13.3: Activity log window (⋯ menu) — ops messages stream there, chat stays conversation-only
0.13.2: Safe Update — validate/backup/install/re-check; on failure keep previous + message, no restart
0.13.1: Fix module parse error ($tag:) that blocked Import-Module after Update
0.13.0: Fidelity-first token cut — error_brief, relevant_slice, chat [MEM], prompt-hot keep, head+tail budget
0.12.9: Chat always gets [CONN] Project connections brief; optimized web_search (+ /search); CLI uses LocalPrep
0.12.8: Live SSH folder list while typing (Dir field + terminal cd/path)
0.12.7: SSH cwd validates remote path; live directory autocomplete; fix ~ expansion
0.12.6: Fix Update red state — reliable version check + inline red label
0.12.5: Pop-out terminal fills window; docked panel closes on Pop out
0.12.4: Update available = red label text (no glow/fill)
0.12.3: Terminal Pop out — separate window for local/SSH shells
0.12.2: Fix Update to install portal tarball first (not stale GitHub zip); push pipeline
0.12.1: Compact portal Settings; SSH edit cwd; terminal panel under chat (local + SSH)
0.12.0: Uniform top chrome; soft Update glow + poll; SSH/Git working dir; portal feature lockdown; Free 1 desktop seat
0.11.2: Brief-first local shrink (mask→brief→budget; one pack max); tighter tool outputs
0.11.1: Session Tools toggle (default ON) next to Dial; wider Help + dark scrollbars
0.11.0: Create/optimize local agents in UI; local-first tools catalog
0.10.9: Copyright + trademark in local UI
0.10.8: Align left menu top with chat; larger brand + logo; history no longer stretches mid-gap
0.10.7: Version/Update pinned top-right next to Help; red Update when available; Chat history first in left menu
0.10.6: Version/Update next to Help; local chat history (new/switch/delete)
0.10.5: Sidebar fully compacted — Chat + Project connections only (no stacked cards)
0.10.4: Compact Project connections rows + Browse/Connect/Detach buttons (no slash required)
0.10.3: Sidebar: Project folder vs Connections (Git/GitHub + SSH) with clear status cards
0.10.2: Fix attach local folder "Argument types do not match" (path string coercion on Windows PS 5.1)
0.10.1: Local directory browser UI + recent folders; /workspace ls|cd|recent
0.10.0: Local workspace + git/GitHub clone + SSH (keys stay on PC); /workspace /git /github /ssh
0.9.0: Local agents + / commands (shared CLI/UI); product surface for free desktop / paid cloud
'@
        }
    }
}
