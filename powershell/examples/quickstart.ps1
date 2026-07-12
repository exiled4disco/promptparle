# PromptParle quickstart examples
# Prerequisites:
#   Import-Module PromptParle
#   Set-PromptParleApiKey -ApiKey 'pp_live_...'   # desktop license (portal)
#   Set-PromptParleProviderKey -Provider openai -ApiKey 'sk-...'  # model key ON THIS PC
#   (or: pp → ⋯ → Providers → Save on this PC)

# 1) Config check
Get-PromptParleConfig
Get-PromptParleProvider

# 2) Optimize only (no AI spend)
Invoke-PromptParle -Provider openai `
  -Profile log-analysis `
  -Prompt 'Summarize anomalies' `
  -Context @"
ERROR login failed user=admin
ERROR login failed user=admin
ERROR login failed user=admin
ERROR login failed user=backup
OK login user=admin
"@ `
  -OptimizeOnly

# 3) Full call (requires local provider key on this PC)
# Get-Content .\firewall-rules.txt -Raw |
#   Invoke-PromptParle -Provider openai -Profile security-review `
#     -Prompt 'Identify overly permissive rules'

# 4) Usage
Get-PromptParleUsage
