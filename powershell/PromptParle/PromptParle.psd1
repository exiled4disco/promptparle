@{
    RootModule        = 'PromptParle.psm1'
    ModuleVersion     = '0.10.4'
    GUID              = 'a8c3e2f1-9b4d-4e6a-8f2c-1d5e7a9b0c3d'
    Author            = 'PromptParle'
    CompanyName       = 'PromptParle'
    Copyright         = '(c) PromptParle. All rights reserved.'
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
        'Invoke-PromptParleSlashCommand',
        'Get-PromptParleWorkspace',
        'Set-PromptParleWorkspace',
        'Clear-PromptParleWorkspace',
        'Get-PromptParleGitHubStatusText',
        'Set-PromptParleSshTarget',
        'Clear-PromptParleSshTarget',
        'Invoke-PromptParleSsh',
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
0.10.4: Compact Project connections rows + Browse/Connect/Detach buttons (no slash required)
0.10.3: Sidebar: Project folder vs Connections (Git/GitHub + SSH) with clear status cards
0.10.2: Fix attach local folder "Argument types do not match" (path string coercion on Windows PS 5.1)
0.10.1: Local directory browser UI + recent folders; /workspace ls|cd|recent
0.10.0: Local workspace + git/GitHub clone + SSH (keys stay on PC); /workspace /git /github /ssh
0.9.3: Fix Update button — do not unload module mid self-update (Get-PromptParleClientVersion error)
0.9.2: Account glance modals via API (Providers/Usage/API keys) — portal only for edit
0.9.1: Help modal + ⋯ menu (Providers/Usage/API keys/Update/Stop); single Agent control; Update always available
0.9.0: Local agents + / commands (shared CLI/UI); product surface for free desktop / paid cloud
0.8.3: Drop Extra text panel — one chat box for message + paste
0.8.2: Fixed chat viewport (only replies scroll) + always-visible savings
0.8.1: Update button in local UI (self-update + version check)
0.8.0: Compression dial 1-5 + left tools rail in local/web chat
0.7.0: Context fleet — CODE BRIEF, SHEET CARD, IMAGE SIGNAL + doc hybrid
'@
        }
    }
}
