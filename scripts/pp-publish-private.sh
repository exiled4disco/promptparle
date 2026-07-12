#!/usr/bin/env bash
# Sync the FULL working tree (including the internal files that are gitignored
# for the public repo) to the private dev repo (promptparle_repo).
#
# Why a separate script: this working copy's git tracks the PUBLIC, sanitized
# subset on `origin`. The private repo must also carry the internal harness
# (.claude/, CLAUDE.md, AGENTS.md, product plan, planning docs) which the public
# .gitignore excludes. So we can't just `git push private` — we build the private
# commit from the actual on-disk files.
#
# Usage:  scripts/pp-publish-private.sh ["commit message"]
# Safe to run repeatedly. Never touches the public `origin`.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MSG="${1:-"Dev workspace sync $(date -u +%Y-%m-%dT%H:%MZ)"}"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

echo "Staging full workspace → $STAGE"
# Copy everything on disk EXCEPT derived/secret dirs. Internal files (.claude,
# CLAUDE.md, etc.) ARE included on purpose — this is the private repo.
rsync -a \
  --exclude '.git' \
  --exclude 'node_modules' \
  --exclude '.next' \
  --exclude '.env' \
  --exclude '.env.*' \
  --exclude '**/local-ui.token' \
  --exclude '.claude/scheduled_tasks.lock' \
  "$REPO"/ "$STAGE"/

cd "$STAGE"
# A private-repo gitignore (keeps internal files; only drops build/secret noise).
cat > .gitignore <<'EOF'
/node_modules
/.next/
/out/
/build
.env
.env.*
*.pem
*.key
*credentials*.json
service-account*.json
*.tsbuildinfo
next-env.d.ts
/src/generated/prisma
.promptparle/
**/local-ui.token
.claude/scheduled_tasks.lock
EOF

git init -q -b main
git remote add origin git@github-exiled4disco:exiled4disco/promptparle_repo.git
# Fetch existing private history so we append, not clobber.
git fetch -q origin main || true
if git rev-parse --verify -q origin/main >/dev/null; then
  git reset --soft origin/main
fi
git add -A
if git diff --cached --quiet; then
  echo "No changes vs private main — nothing to publish."
  exit 0
fi
git -c user.name="exiled4disco" -c user.email="noreply@users.noreply.github.com" \
  commit -q -m "$MSG"
git push -q origin main
echo "✅ Pushed full workspace to private promptparle_repo (main)."
