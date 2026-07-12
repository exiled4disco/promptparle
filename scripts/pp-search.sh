#!/bin/bash
########################################################################
# PromptParle — capped code search (opt-in, token-safe)
#
# A ripgrep wrapper that CAPS output so an exploratory search can't dump
# thousands of lines into an agent's context. If the cap is hit it SAYS
# so and tells you to narrow — it never silently truncates.
#
# Deliberately NOT a hook: a blanket output cap on all commands would
# break `git diff` review and file reads. Use it for discovery
# ("where does X appear?"), not for reading a specific file.
#
# Usage:  scripts/pp-search.sh <pattern> [path] [rg-args...]
#         PP_SEARCH_CAP=120 scripts/pp-search.sh ...     # override cap (default 60)
#         scripts/pp-search.sh --json <pattern> <file.json>
#             Flatten JSON to `path.to.key = value` (gron) and grep those,
#             so a deep config key is findable without reading the whole doc.
########################################################################
set -uo pipefail
export PATH="/home/linuxbrew/.linuxbrew/bin:$PATH:/usr/bin:/bin"
CAP="${PP_SEARCH_CAP:-60}"
[[ $# -lt 1 ]] && { echo "usage: $0 [--json] <pattern> [path] [rg-args...]" >&2; exit 2; }
command -v rg >/dev/null 2>&1 || { echo "ripgrep not installed" >&2; exit 0; }

if [[ "$1" == "--json" ]]; then
    shift
    command -v gron >/dev/null 2>&1 || { echo "gron not installed" >&2; exit 0; }
    [[ $# -lt 2 ]] && { echo "usage: $0 --json <pattern> <file.json>" >&2; exit 2; }
    jpattern="$1"; jfile="$2"
    [[ -f "$jfile" ]] || { echo "no such file: $jfile" >&2; exit 2; }
    out="$(gron "$jfile" 2>/dev/null | rg --color=never "$jpattern" 2>/dev/null || true)"
    n="$(printf '%s' "$out" | grep -c . || true)"
    printf '%s\n' "$out" | head -n "$CAP"
    (( n > CAP )) && echo "" && echo "[capped: $CAP of $n matching JSON paths — narrow the pattern]"
    exit 0
fi

pattern="$1"; shift
# Default to the whole repo; respects .gitignore + .ignore (vendor/build noise excluded).
total="$(rg --count-matches "$pattern" "$@" 2>/dev/null | awk -F: '{s+=$NF} END{print s+0}')"
files="$(rg --files-with-matches "$pattern" "$@" 2>/dev/null | wc -l | tr -d ' ')"

rg --line-number --color=never "$pattern" "$@" 2>/dev/null | head -n "$CAP"

if (( total > CAP )); then
    echo ""
    echo "[capped: showing $CAP of $total matches across $files file(s)]"
    echo "[narrow the query — add a path, use -w for whole word, or grep a more specific term]"
fi
