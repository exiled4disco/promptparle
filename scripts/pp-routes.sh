#!/bin/bash
########################################################################
# PromptParle — Next.js API route map (one call)
#
# "What API routes exist / which HTTP methods does route X export / where
# is the handler for /api/v1/prompt?" Answering by hand means walking
# src/app/api/**/route.ts. This returns a COMPACT map from the live tree.
#
# Usage:
#   scripts/pp-routes.sh                 # all routes + exported methods
#   scripts/pp-routes.sh <substr>        # routes whose path matches substr
########################################################################
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO" || exit 1
API="src/app/api"
[[ -d "$API" ]] || { echo "no $API" >&2; exit 2; }
filter="${1:-}"
bar="════════════════════════════════════════════════════════════"

echo "$bar"
echo "API ROUTES (src/app/api/**/route.ts)"
echo "$bar"
# Each route.ts → URL path from its dir; methods = exported HTTP verbs.
while IFS= read -r f; do
    # dir → URL: strip src/app, drop /route.ts, keep [param] segments as-is
    url="${f#src/app}"; url="${url%/route.ts}"
    [[ -z "$url" ]] && url="/"
    [[ -n "$filter" && "$url" != *"$filter"* ]] && continue
    methods="$(grep -oE '^export (async )?function (GET|POST|PUT|PATCH|DELETE|HEAD|OPTIONS)' "$f" 2>/dev/null \
        | grep -oE '(GET|POST|PUT|PATCH|DELETE|HEAD|OPTIONS)' | sort -u | paste -sd, -)"
    [[ -z "$methods" ]] && methods="(none exported)"
    printf "  %-7s %s\n" "$methods" "$url"
done < <(find "$API" -name route.ts | sort)
echo "$bar"
[[ -n "$filter" ]] && echo "(filtered by: $filter)"
echo "-> handler file: src/app<url>/route.ts   ·   locate a symbol: scripts/pp-locate.sh <name>"
