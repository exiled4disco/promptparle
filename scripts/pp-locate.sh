#!/bin/bash
########################################################################
# PromptParle — symbol locator / blast radius (one call)
#
# "Where is <function> defined, and what calls it?" Answering that in the
# 17k-line PromptParle.psm1 (or across the Next.js src) normally means
# reading the whole file. This returns a COMPACT map: definition site(s)
# + reference count + callers-by-file (capped), so an agent spends tokens
# on the decision, not on reading raw output.
#
# Handles both worlds:
#   - PowerShell: `function Name`  (the desktop module)
#   - TS/TSX:     export function / const / class / route handlers
#
# Usage:  scripts/pp-locate.sh <symbol> [more symbols...]
########################################################################
set -uo pipefail
export PATH="/home/linuxbrew/.linuxbrew/bin:$PATH:/usr/bin:/bin"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO" || exit 1
command -v rg >/dev/null 2>&1 || { echo "ripgrep not installed" >&2; exit 0; }

[[ $# -lt 1 ]] && { echo "usage: $0 <symbol> [symbol...]" >&2; exit 2; }
bar="════════════════════════════════════════════════════════════"

# Source globs only — skip build output, deps, git, published tarballs.
GLOBS=(-g '!node_modules' -g '!.next' -g '!.git' -g '!public/*.tgz' -g '*.ts' -g '*.tsx' -g '*.js' -g '*.psm1' -g '*.ps1' -g '*.prisma')

for sym in "$@"; do
    echo "$bar"
    matches="$(rg -n --color=never "${GLOBS[@]}" -e "\b${sym}\b" 2>/dev/null || true)"
    total="$(printf '%s\n' "$matches" | grep -c . || true)"
    if [[ "$total" -eq 0 ]]; then
        echo "LOCATE '$sym': 0 references. Nothing here defines or uses it."
        continue
    fi
    nfiles="$(printf '%s\n' "$matches" | cut -d: -f1 | sort -u | grep -c . || true)"
    echo "LOCATE '$sym': $total refs across $nfiles file(s)"

    # Definition sites: PowerShell function, TS export/const/class, Prisma model, API route.
    echo "── definition site(s):"
    defs="$(printf '%s\n' "$matches" | rg -N \
        -e "function[[:space:]]+${sym}\b" \
        -e "(export[[:space:]]+)?(async[[:space:]]+)?function[[:space:]]+${sym}\b" \
        -e "(export[[:space:]]+)?(const|let|class|type|interface)[[:space:]]+${sym}\b" \
        -e "model[[:space:]]+${sym}\b" \
        2>/dev/null | head -12 || true)"
    if [[ -n "$defs" ]]; then
        printf '%s\n' "$defs" | sed 's/^/   /'
    else
        echo "   (no clear definition — may be external, a param, or a string literal)"
    fi

    echo "── refs by file (top 20):"
    printf '%s\n' "$matches" | cut -d: -f1 | sort | uniq -c | sort -rn | head -20 \
        | awk '{c=$1; $1=""; sub(/^ /,""); printf "   %5d  %s\n", c, $0}'
    (( nfiles > 20 )) && echo "   ... $((nfiles - 20)) more file(s)"
done
echo "$bar"
