#!/bin/bash
########################################################################
# PromptParle — Claude setup index (one call, answers from repo/config)
#
# "What agents / token-tools / hooks do we have here?" Answering by hand
# means reading .claude/agents/*.md + settings.json + the scripts dir.
# This reads it all LIVE and returns a terse index — one call, not many.
#
# Usage:
#   scripts/pp-claude.sh                # overview of everything
#   scripts/pp-claude.sh agents [name]  # agents (+ detail for one)
#   scripts/pp-claude.sh tools          # token-efficiency scripts
#   scripts/pp-claude.sh hooks          # configured hooks (settings.json)
########################################################################
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CL="$REPO/.claude"
AGENTS="$CL/agents"
SCRIPTS="$REPO/scripts"
bar="════════════════════════════════════════════════════════════"

agent_oneliner() { grep -m1 '^description:' "$1" 2>/dev/null | sed 's/^description:[[:space:]]*//' | sed -E 's/([.]) .*/\1/' | cut -c1-100; }
agent_model()    { local m; m="$(grep -m1 '^model:' "$1" 2>/dev/null | sed 's/^model:[[:space:]]*//')"
    case "$m" in *opus*) echo Opus;; *sonnet*) echo Sonnet;; *haiku*) echo Haiku;; *fable*) echo Fable;; "") echo inherit;; *) echo "$m";; esac; }

show_agents() {
    if [[ -n "${1:-}" ]]; then
        local f="$AGENTS/$1.md"; [[ -f "$f" ]] || { echo "no such agent: $1"; return; }
        echo "$bar"; echo "AGENT  $1   [$(agent_model "$f")]"; echo "  $(agent_oneliner "$f")"; echo "$bar"; return
    fi
    local n; n="$(ls "$AGENTS"/*.md 2>/dev/null | wc -l | tr -d ' ')"
    echo "$bar"; echo "AGENTS ($n) — model | name | domain"; echo "$bar"
    for f in "$AGENTS"/*.md; do [[ -f "$f" ]] || continue
        printf "  %-7s %-24s %s\n" "$(agent_model "$f")" "$(basename "$f" .md)" "$(agent_oneliner "$f")"; done
}

show_tools() {
    echo "$bar"; echo "TOKEN-EFFICIENCY TOOLS (scripts/pp-*.sh)"; echo "$bar"
    for f in "$SCRIPTS"/pp-*.sh; do [[ -f "$f" ]] || continue
        # 3rd comment line of each tool is its one-liner purpose
        desc="$(sed -n '3p' "$f" | sed 's/^# *//' | cut -c1-80)"
        printf "  %-18s %s\n" "$(basename "$f")" "$desc"; done
}

show_hooks() {
    echo "$bar"; echo "HOOKS (.claude/settings.json)"; echo "$bar"
    [[ -f "$CL/settings.json" ]] || { echo "  (none)"; return; }
    if command -v jq >/dev/null 2>&1; then
        jq -r '.hooks | to_entries[] | .key as $ev | .value[] | "  \($ev)  [\(.matcher // "*")]  -> \(.hooks[].command)"' "$CL/settings.json" 2>/dev/null \
            | sed "s|$REPO/||g" || cat "$CL/settings.json"
    else cat "$CL/settings.json"; fi
}

case "${1:-overview}" in
    agents) show_agents "${2:-}";;
    tools)  show_tools;;
    hooks)  show_hooks;;
    overview|*) show_tools; echo; show_agents; echo; show_hooks;;
esac
