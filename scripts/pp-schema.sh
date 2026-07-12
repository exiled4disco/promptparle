#!/bin/bash
########################################################################
# PromptParle — Prisma schema index (read the schema, don't re-read it)
#
# prisma/schema.prisma is the source of truth. This returns a COMPACT
# answer so an agent spends one call instead of scrolling the whole schema
# to learn a model's fields — and shows which migrations touch a model.
#
# Usage:
#   scripts/pp-schema.sh                # every model + field count
#   scripts/pp-schema.sh <Model>        # a model's fields + @@map + migrations
########################################################################
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO" || exit 1
SCHEMA="prisma/schema.prisma"
MIGR="prisma/migrations"
[[ -f "$SCHEMA" ]] || { echo "no $SCHEMA" >&2; exit 2; }
bar="════════════════════════════════════════════════════════════"

if [[ $# -eq 0 ]]; then
    echo "MODELS in $SCHEMA:"
    awk '
        /^model[[:space:]]+[A-Za-z0-9_]+[[:space:]]*\{/ { name=$2; count=0; next }
        /^\}/ { if (name!="") { printf "  %-24s %d fields\n", name, count; name="" } }
        name!="" && /^[[:space:]]*[A-Za-z0-9_]+[[:space:]]/ && $0 !~ /^[[:space:]]*(\/\/|@@|\/\*)/ { count++ }
    ' "$SCHEMA"
    echo "-> run: scripts/pp-schema.sh <Model>  for its fields + migrations"
    exit 0
fi

model="$1"
echo "$bar"
echo "MODEL '$model'"
echo "── definition (prisma/schema.prisma):"
awk -v m="$model" '
    $0 ~ "^model[[:space:]]+" m "[[:space:]]*\\{" { grab=1 }
    grab { print "   " $0 }
    grab && /^\}/ { exit }
' "$SCHEMA" | head -80
found="$(awk -v m="$model" '$0 ~ "^model[[:space:]]+" m "[[:space:]]*\\{"{f=1} END{print f+0}' "$SCHEMA")"
[[ "$found" == "0" ]] && echo "   (no such model — check spelling/case; run with no args to list)"

echo "── migrations touching '$model' (table map):"
# Prisma maps models to snake_case tables via @@map; grep both the model and a likely table name.
tbl="$(awk -v m="$model" '$0 ~ "^model[[:space:]]+" m {g=1} g && /@@map/{gsub(/[^a-z0-9_]/,"",$2); print $2; exit}' "$SCHEMA")"
if [[ -d "$MIGR" ]]; then
    pat="$model"; [[ -n "$tbl" ]] && pat="$model|$tbl"
    grep -rliE "$pat" "$MIGR" 2>/dev/null | sed "s|$REPO/||" | sed 's/^/   /' | head -20 || echo "   (none)"
    [[ -n "$tbl" ]] && echo "   (table: $tbl)"
fi
echo "$bar"
