@{
    RootModule        = 'PromptParle.psm1'
    ModuleVersion     = '0.17.1'
    GUID              = 'a8c3e2f1-9b4d-4e6a-8f2c-1d5e7a9b0c3d'
    Author            = 'PromptParle'
    CompanyName       = 'PromptParle'
    Copyright         = '(c) 2026 PromptParle. All rights reserved. PromptParle and the PromptParle logo are trademarks of PromptParle.'
    Description       = 'PowerShell client for PromptParle - AI context optimization gateway. Trim the prompt. Keep the signal.'
    PowerShellVersion = '5.1'
    FunctionsToExport = @(
        'Set-PromptParleApiKey',
        'Get-PromptParleConfig',
        'Get-PromptParleProvider',
        'Get-PromptParleUsage',
        'Invoke-PromptParle',
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
