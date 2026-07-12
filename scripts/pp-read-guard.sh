#!/bin/bash
########################################################################
# PromptParle — PreToolUse read guard (token discipline)
#
# Runs before Read. BLOCKS a full raw read of the repo's two heavy files
# (PromptParle.psm1 ~18.5k lines, local-ui/index.html ~5.7k lines) that
# would dump ~100-200k tokens into the (expensive, un-cacheable-on-output)
# main thread. A ranged Read (offset+limit) is allowed — the guard only
# fires when NO limit is set, or the limit is large.
#
# Why: caching never reduces OUTPUT tokens, and a raw dump of the psm1 is
# the single biggest avoidable cost on this project. pp-psm1.sh already
# indexes all 282 functions and prints a ranged Read hint. Use it.
#
# Reads the PreToolUse JSON payload on stdin. Exit 2 = block (message on
# stderr is shown to Claude). Exit 0 = allow. Fails OPEN (never blocks on
# its own error) so it can't wedge the session.
########################################################################
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

payload="$(cat 2>/dev/null || true)"
[ -z "$payload" ] && exit 0

# Extract file_path and limit from the Read tool input (best-effort via jq).
fp="$(printf '%s' "$payload" | jq -r '.tool_input.file_path // empty' 2>/dev/null || true)"
limit="$(printf '%s' "$payload" | jq -r '.tool_input.limit // empty' 2>/dev/null || true)"
[ -z "$fp" ] && exit 0

# Normalize to a repo-relative basename match (the guard targets specific files).
base="$(basename "$fp")"

# A ranged read of a bounded slice is fine. Only block unranged / huge-range reads.
# Threshold: 600 lines. A real "I need one function" read is well under that.
is_big_range=0
if [ -z "$limit" ]; then
    is_big_range=1                       # no limit = full file
elif [ "$limit" -gt 600 ] 2>/dev/null; then
    is_big_range=1                       # limit larger than any single function
fi
[ "$is_big_range" -eq 0 ] && exit 0

case "$base" in
  PromptParle.psm1)
    cat >&2 <<'MSG'
BLOCKED: full/large raw Read of PromptParle.psm1 (~18,500 lines ≈ 150-200k tokens).
Output tokens are the one cost caching never reduces — don't dump this file.

Use the token tool instead:
  scripts/pp-psm1.sh                 # index of all 282 functions + line ranges
  scripts/pp-psm1.sh <FnName>        # one function's line range + a Read hint
  scripts/pp-psm1.sh <FnName> --body # print just that function's body
  scripts/pp-psm1.sh --grep <kw>     # functions whose name matches a keyword
  scripts/pp-locate.sh <symbol>      # blast radius (definition + callers)

If you truly need a specific slice, re-run Read with a bounded range, e.g.
  Read file_path=<...>PromptParle.psm1 offset=<start> limit=<=600>
MSG
    exit 2
    ;;
  index.html)
    # Only the client's giant local-ui/index.html; other index.html files pass.
    case "$fp" in
      *local-ui/index.html)
        cat >&2 <<'MSG'
BLOCKED: full/large raw Read of local-ui/index.html (~5,700 lines).
Read a bounded range instead (offset + limit <=600), or grep for the block you
need first (rg -n "<pattern>" powershell/PromptParle/local-ui/index.html) and
Read only around that line.
MSG
        exit 2
        ;;
    esac
    ;;
esac

exit 0
