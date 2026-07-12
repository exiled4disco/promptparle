#!/bin/bash
########################################################################
# PromptParle — PowerShell module function index (read ONE function, not 17k lines)
#
# PromptParle.psm1 is ~17.5k lines. Reading it whole to find or study one
# function is the biggest avoidable token cost in this repo. This lists
# every function with its line range, or prints just one function's body
# with a Read hint — so you load a 40-line function, not the file.
#
# Usage:
#   scripts/pp-psm1.sh                    # all functions: line + name
#   scripts/pp-psm1.sh <name>             # one function's line range + Read hint
#   scripts/pp-psm1.sh <name> --body      # print that function's body
#   scripts/pp-psm1.sh --grep <keyword>   # functions whose name matches keyword
########################################################################
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO" || exit 1
PSM1="powershell/PromptParle/PromptParle.psm1"
[[ -f "$PSM1" ]] || { echo "no $PSM1" >&2; exit 2; }
bar="════════════════════════════════════════════════════════════"

# Build "startLine:name" list once.
index() { grep -nE '^function [A-Za-z0-9_-]+' "$PSM1" | sed -E 's/^([0-9]+):function ([A-Za-z0-9_-]+).*/\1 \2/'; }

if [[ $# -eq 0 ]]; then
    total="$(wc -l < "$PSM1" | tr -d ' ')"
    n="$(index | grep -c . || true)"
    echo "$bar"
    echo "PromptParle.psm1 — $n functions across $total lines"
    echo "$bar"
    index | awk '{printf "  %6s  %s\n", $1, $2}'
    echo "$bar"
    echo "-> one function: scripts/pp-psm1.sh <name>   (add --body to print it)"
    exit 0
fi

if [[ "$1" == "--grep" ]]; then
    [[ $# -lt 2 ]] && { echo "usage: $0 --grep <keyword>" >&2; exit 2; }
    kw="$2"
    echo "functions matching '$kw':"
    index | grep -iE " .*${kw}" | awk '{printf "  %6s  %s\n", $1, $2}' || echo "  (none)"
    exit 0
fi

name="$1"
start="$(index | awk -v n="$name" '$2==n {print $1; exit}')"
[[ -z "$start" ]] && { echo "no function named '$name'. Try: scripts/pp-psm1.sh --grep $name"; exit 1; }
# End = line before the next function, or EOF.
next="$(index | awk -v s="$start" '$1>s {print $1; exit}')"
if [[ -z "$next" ]]; then end="$(wc -l < "$PSM1" | tr -d ' ')"; else end=$((next - 1)); fi
lines=$((end - start + 1))

echo "$bar"
echo "FUNCTION $name  —  lines $start-$end  ($lines lines)"
echo "  Read hint: Read $PSM1 offset=$start limit=$lines"
echo "$bar"
if [[ "${2:-}" == "--body" ]]; then
    sed -n "${start},${end}p" "$PSM1"
fi
