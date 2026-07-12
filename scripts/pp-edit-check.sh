#!/bin/bash
########################################################################
# PromptParle — PostToolUse edit check (quiet, high-signal)
#
# Runs after Edit|Write|MultiEdit. Per-language, fast, SILENT on pass;
# prints NEW syntax/type errors inline so they're fixed before moving on.
#   .psm1 / .ps1  → PowerShell parser (AST parse; catches the exact class
#                    of error that breaks the module on import)
#   .ts / .tsx    → eslint on the file (type-aware lint if configured)
#   .prisma       → prisma validate
#   .json         → jq empty (valid JSON?)
#
# Reads the hook payload on stdin (Claude Code passes tool input as JSON).
# Never fails the tool call for style; only reports. Exit 0 always.
########################################################################
set -uo pipefail
export PATH="/home/linuxbrew/.linuxbrew/bin:/home/ubuntu/.nvm/versions/node/v22.19.0/bin:$PATH:/usr/local/bin:/usr/bin:/bin"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Extract the edited file path from the hook JSON on stdin (best-effort).
payload="$(cat 2>/dev/null || true)"
file=""
if command -v jq >/dev/null 2>&1 && [[ -n "$payload" ]]; then
    file="$(printf '%s' "$payload" | jq -r '.tool_input.file_path // .tool_input.path // empty' 2>/dev/null || true)"
fi
[[ -z "$file" ]] && exit 0
[[ -f "$file" ]] || exit 0

report() { echo ""; echo "── pp-edit-check: $file"; echo "$1"; }

case "$file" in
    *.psm1|*.ps1)
        command -v pwsh >/dev/null 2>&1 || exit 0
        out="$(pwsh -NoProfile -Command "
            \$t=\$null; \$e=\$null
            [System.Management.Automation.Language.Parser]::ParseFile('$file',[ref]\$t,[ref]\$e) | Out-Null
            if (\$e -and \$e.Count -gt 0) { \$e | ForEach-Object { '  line ' + \$_.Extent.StartLineNumber + ': ' + \$_.Message } }
        " 2>/dev/null || true)"
        [[ -n "$out" ]] && report "PowerShell parse errors:
$out"
        ;;
    *.ts|*.tsx)
        cd "$REPO" || exit 0
        if [[ -x node_modules/.bin/eslint ]]; then
            out="$(node_modules/.bin/eslint --no-warn-ignored --format compact "$file" 2>/dev/null | grep -iE 'error' | head -15 || true)"
            [[ -n "$out" ]] && report "eslint:
$out"
        fi
        ;;
    *.prisma)
        cd "$REPO" || exit 0
        out="$(npx --no-install prisma validate 2>&1 | grep -iE 'error|invalid' | head -10 || true)"
        [[ -n "$out" ]] && report "prisma validate:
$out"
        ;;
    *.json)
        command -v jq >/dev/null 2>&1 || exit 0
        jq empty "$file" 2>/tmp/pp-jq-err || report "invalid JSON: $(cat /tmp/pp-jq-err 2>/dev/null | head -3)"
        ;;
esac
exit 0
