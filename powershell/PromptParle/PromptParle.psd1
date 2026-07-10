@{
    RootModule        = 'PromptParle.psm1'
    ModuleVersion     = '0.12.1'
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
