@{
    RootModule        = 'PromptParle.psm1'
    ModuleVersion     = '0.6.0'
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
        'Uninstall-PromptParle'
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
0.6.0: Attach files + paste images in local chat; vision to providers
0.5.6: StrictMode-safe JSON props (optimizeOnly) on local chat
0.5.5: Fix local chat Send hang (context char-unroll); loading UI feedback
0.5.4: Fix empty-array Get-Process crash; instant Ctrl+C feedback
0.5.3: Fix StrictMode Count error when checking local ports
0.5.2: Fast port clear (no multi-second timeouts on free ports)
0.5.1: Uninstall-PromptParle; auto-free busy ports on start
0.5.0: Installer prompts for API key and finishes setup
0.4.2: Fix stuck local server - Ctrl+C, Stop button, Stop-PromptParleLocalServer
0.4.1: ASCII/BOM fix for Windows PS 5.1 parse errors
0.4.0: pp starts LOCAL chat UI on 127.0.0.1 (not cloud HTML)
'@
        }
    }
}
