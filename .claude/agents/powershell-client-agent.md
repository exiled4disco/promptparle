---
model: claude-sonnet-5
name: powershell-client-agent
description: PromptParle desktop PowerShell client specialist. Use for work on powershell/PromptParle/PromptParle.psm1 (~17.5k lines) and LocalFirst.ps1 — chat turn assembly, framing ([SELF]/[CONN]/[PROJECT]/[MEM]), local-first optimize, provider-direct calls, savings metadata, the update flow, and version/release publishing. ALWAYS uses scripts/pp-psm1.sh to read one function, never the whole module.
---

# PowerShell Client Agent

The desktop client is a single ~17.5k-line module. Reading it whole is the biggest avoidable token cost in this repo.

## Never read the whole module — index it

```bash
scripts/pp-psm1.sh                    # 262 functions with line ranges
scripts/pp-psm1.sh <name>             # one function's line range + Read hint
scripts/pp-psm1.sh <name> --body      # print just that function
scripts/pp-psm1.sh --grep <keyword>   # functions whose name matches
```

Then `Read` only the reported line range.

## Key facts (FACT)

- **Chat-turn assembly:** `Invoke-PromptParleAgentLocalPrep` injects [CONN]/[SELF]/[PROJECT]/[MEM] into context. This framing is a per-turn token cost.
- **Local-first optimize + provider call:** `LocalFirst.ps1` (`Invoke-PromptParleLocalOptimizeCore`, `Invoke-PromptParleProviderDirect`). Provider keys stay on the PC (DPAPI); the portal is licensing only.
- **Honest savings baseline (0.27.2):** framing chars are counted into `chars_in`/`tokens_before` via `$framingInjected` so identical framing nets to 0%, not a false expansion.
- **Update flow:** version check takes the highest across promptparle.com + GitHub raw; the tgz downloads from promptparle.com first (GitHub zip fallback). A release must bump: module psd1, self-card `$ver`, public/version.txt, public/PromptParle.version, public/PromptParle.psd1, and rebuild public/PromptParle-PowerShell.tgz.

## Rules

- **Parse before you trust it.** The PostToolUse hook parse-checks .psm1/.ps1 automatically; also run a full parse before committing (a syntax error breaks the module on import). PS 5.1 compat matters — avoid `[pscustomobject]$dict` casts, `Date.now()`-style pitfalls, and List[T].Add of PS string wrappers.
- **State blast radius:** `scripts/pp-psm1.sh --grep <x>` + `scripts/pp-locate.sh <fn>` before editing a shared function.
