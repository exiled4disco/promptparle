@{
    RootModule        = 'PromptParle.psm1'
    ModuleVersion     = '0.2.0'
    GUID              = 'a8c3e2f1-9b4d-4e6a-8f2c-1d5e7a9b0c3d'
    Author            = 'PromptParle'
    CompanyName       = 'PromptParle'
    Copyright         = '(c) PromptParle. All rights reserved.'
    Description       = 'PowerShell client for PromptParle — AI context optimization gateway. Trim the prompt. Keep the signal.'
    PowerShellVersion = '5.1'
    FunctionsToExport = @(
        'Set-PromptParleApiKey',
        'Get-PromptParleConfig',
        'Get-PromptParleProvider',
        'Get-PromptParleUsage',
        'Invoke-PromptParle',
        'Invoke-PromptParleSecurityReview',
        'Start-PromptParle'
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
0.2.0: Start-PromptParle interactive chat (aliases: pp, promptparle)
0.1.2: Install always overwrites module
0.1.1: Fix PowerShell 5.1 StrictMode crash ($IsWindows undefined)
0.1.0: Initial MVP client
'@
        }
    }
}
