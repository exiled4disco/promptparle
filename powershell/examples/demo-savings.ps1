#Requires -Version 5.1
<#
.SYNOPSIS
  Prove PromptParle is optimizing - noisy context in, lean context out.

.DESCRIPTION
  1) Optimize-only (no AI spend) - shows token reduction banner
  2) Optional full AI call with -Full
  3) Prints portal Usage reminder

.EXAMPLE
  .\demo-savings.ps1
  .\demo-savings.ps1 -Full
#>
[CmdletBinding()]
param(
    [switch]$Full,
    [ValidateSet('openai', 'anthropic', 'gemini', 'grok')]
    [string]$Provider = 'openai'
)

$ErrorActionPreference = 'Stop'

Import-Module PromptParle -Force -ErrorAction Stop

$noise = Join-Path $PSScriptRoot 'demo-noise.txt'
if (-not (Test-Path -LiteralPath $noise)) {
    throw "Missing demo file: $noise (git pull the repo)"
}

$raw = Get-Content -LiteralPath $noise -Raw
Write-Host ''
Write-Host '=== PromptParle savings demo ===' -ForegroundColor Cyan
Write-Host ("Noise file : {0}" -f $noise)
Write-Host ("Raw size   : {0:N0} characters" -f $raw.Length)
Write-Host ''

Write-Host 'Step 1: Optimize only (no OpenAI spend)' -ForegroundColor Yellow
$result = Invoke-PromptParle `
    -Provider $Provider `
    -Profile security-review `
    -Prompt 'Find the highest risk items and recommend actions' `
    -Path $noise `
    -OptimizeOnly

Write-Host '--- Optimized text sent to the model would be: ---' -ForegroundColor DarkGray
Write-Host $result.OptimizedPrompt
Write-Host ''

if ($result.Metadata) {
    $m = $result.Metadata
    $orig = $m.original_tokens
    $opt = $m.optimized_tokens
    $pct = $m.token_reduction_percent
    Write-Host '=== RESULT ===' -ForegroundColor Green
    Write-Host ("  Original tokens  : {0}" -f $orig)
    Write-Host ("  Optimized tokens : {0}" -f $opt)
    Write-Host ("  Reduction        : {0}%" -f $pct) -ForegroundColor Green
    if ($pct -lt 20) {
        Write-Host '  Unexpected low savings - update module (git pull + Install-PromptParle.ps1)' -ForegroundColor Yellow
    } else {
        Write-Host '  Savings look good. Check portal Usage for before/after text.' -ForegroundColor Green
    }
}

if ($Full) {
    Write-Host ''
    Write-Host 'Step 2: Full AI call with same noisy context' -ForegroundColor Yellow
    $ai = Invoke-PromptParle `
        -Provider $Provider `
        -Profile security-review `
        -Prompt 'Find the highest risk items and recommend actions in 5 bullets' `
        -Path $noise
    Write-Host $ai.Response
}

Write-Host ''
Write-Host 'Portal: https://promptparle.com/app/usage' -ForegroundColor Cyan
Write-Host 'Expand the latest row to see Before vs After text.'
Write-Host ''
