#!/bin/bash
########################################################################
# PromptParle — optimizer pipeline map (the product's heart, one call)
#
# The optimize path spans several files (optimizer → context-fleet →
# per-modality compressors → secrets/tokens). "How does compression flow
# / which file handles logs vs code vs docs / what does the dial control?"
# is a recurring question. This returns a COMPACT map sourced live from
# src/lib, so you don't re-read the whole pipeline each time.
#
# Usage:
#   scripts/pp-optimizer.sh              # pipeline stages + files + entry fns
#   scripts/pp-optimizer.sh <keyword>    # grep the pipeline files (capped)
########################################################################
set -uo pipefail
export PATH="/home/linuxbrew/.linuxbrew/bin:$PATH:/usr/bin:/bin"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO" || exit 1
LIB="src/lib"
bar="════════════════════════════════════════════════════════════"

# Ordered pipeline: file : role. Kept terse; edit if the pipeline changes.
STAGES=(
  "optimizer.ts|orchestrator: mask → filler → fleet → image → budget → never-expand guard"
  "secrets.ts|secret detection + masking (runs first)"
  "context-fleet.ts|modality router: splits parts, dispatches to specialists, merges"
  "content-detect.ts|classify a part: document | code | sheet | log | mixed"
  "document-compress.ts|SIGNAL BRIEF for prose/markdown docs"
  "code-compress.ts|CODE BRIEF: signatures + query-relevant bodies"
  "sheet-compress.ts|SHEET CARD: schema + stats + sample rows"
  "image-signal.ts|IMAGE focus brief (pixels still go multimodal)"
  "compression-level.ts|dial 1..5 → aggressiveness (sample rows, keep ratios)"
  "tokens.ts|token estimation (chars/4 family)"
  "system-framing.ts|split product framing from user content (kept out of Before)"
  "run-prompt.ts|shared optimize → provider call → usage row"
)

if [[ $# -eq 0 ]]; then
    echo "$bar"
    echo "OPTIMIZER PIPELINE  (src/lib/)"
    echo "$bar"
    for s in "${STAGES[@]}"; do
        file="${s%%|*}"; role="${s#*|}"
        mark="  "; [[ -f "$LIB/$file" ]] || mark="!!"
        # entry function(s): first exported fn in the file
        fn="$(grep -oE '^export (async )?function [A-Za-z0-9_]+' "$LIB/$file" 2>/dev/null \
              | head -2 | sed -E 's/^export (async )?function //' | paste -sd, -)"
        printf "  %s %-22s %s\n" "$mark" "$file" "$role"
        [[ -n "$fn" ]] && printf "        entry: %s\n" "$fn"
    done
    echo "$bar"
    echo "!! = referenced here but file missing.  Deep-dive: scripts/pp-locate.sh <fn>"
    exit 0
fi

# keyword mode: capped grep across just the pipeline files
kw="$1"
files=()
for s in "${STAGES[@]}"; do f="$LIB/${s%%|*}"; [[ -f "$f" ]] && files+=("$f"); done
echo "$bar"; echo "OPTIMIZER grep '$kw' (pipeline files only, capped 40)"; echo "$bar"
rg -n --color=never -e "$kw" "${files[@]}" 2>/dev/null | sed "s|$LIB/||" | head -40
n="$(rg --count-matches "$kw" "${files[@]}" 2>/dev/null | awk -F: '{s+=$NF} END{print s+0}')"
(( n > 40 )) && echo "" && echo "[capped: 40 of $n — narrow the keyword]"
