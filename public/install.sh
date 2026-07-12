#!/usr/bin/env bash
# PromptParle Linux/macOS install from GitHub
# Same flow as install.ps1: clone repo → Install-PromptParle.ps1 (module → license key)
# Registration is open and free — create an account at promptparle.com/register,
# make a pp_live_ license key, and paste it when prompted. No invitation code.
#
# Usage:
#   curl -fsSL https://promptparle.com/install.sh | bash
#
# Optional env overrides:
#   PROMPTPARLE_CLONE_PATH=$HOME/src/promptparle
#   PROMPTPARLE_REPO_URL=https://github.com/exiled4disco/promptparle.git
#   PROMPTPARLE_BRANCH=main
#   PROMPTPARLE_SKIP_KEY=1
#   PROMPTPARLE_START=1
#   PROMPTPARLE_BASE_URL=https://promptparle.com

set -euo pipefail

# curl | bash leaves stdin as the script stream. Reattach so the PowerShell
# installer can still prompt (pwsh inherits our stdin after this).
if [ ! -t 0 ]; then
  if [ -r /dev/tty ]; then
    exec </dev/tty
  else
    echo "Interactive install needs a terminal." >&2
    echo "Download and run:" >&2
    echo "  curl -fsSL https://promptparle.com/install.sh -o /tmp/pp-install.sh && bash /tmp/pp-install.sh" >&2
    exit 1
  fi
fi

REPO_URL="${PROMPTPARLE_REPO_URL:-https://github.com/exiled4disco/promptparle.git}"
BRANCH="${PROMPTPARLE_BRANCH:-main}"
CLONE_PATH="${PROMPTPARLE_CLONE_PATH:-$HOME/src/promptparle}"
SKIP_KEY="${PROMPTPARLE_SKIP_KEY:-0}"
DO_START="${PROMPTPARLE_START:-0}"
BASE_URL="${PROMPTPARLE_BASE_URL:-https://promptparle.com}"

CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
DIM='\033[0;90m'
NC='\033[0m'

info()  { printf '%b%s%b\n' "$CYAN" "$*" "$NC"; }
ok()    { printf '%b%s%b\n' "$GREEN" "$*" "$NC"; }
warn()  { printf '%b%s%b\n' "$YELLOW" "$*" "$NC"; }
err()   { printf '%b%s%b\n' "$RED" "$*" "$NC" >&2; }
dim()   { printf '%b%s%b\n' "$DIM" "$*" "$NC"; }

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    err "Missing required command: $1"
    return 1
  fi
}

find_pwsh() {
  if command -v pwsh >/dev/null 2>&1; then
    command -v pwsh
    return 0
  fi
  for c in /usr/bin/pwsh /usr/local/bin/pwsh "$HOME/.dotnet/tools/pwsh"; do
    if [ -x "$c" ]; then
      echo "$c"
      return 0
    fi
  done
  return 1
}

print_pwsh_help() {
  err "PowerShell 7+ (pwsh) is required."
  echo ""
  echo "Install, then re-run this installer:"
  echo "  https://learn.microsoft.com/powershell/scripting/install/install-linux"
  echo "  # Debian/Ubuntu example: sudo apt-get install -y powershell"
  echo "  # or: sudo snap install powershell --classic"
  echo "  # macOS: brew install --cask powershell"
  echo ""
  echo "Then:"
  echo "  curl -fsSL https://promptparle.com/install.sh | bash"
}

print_git_help() {
  err "git is required (same as the Windows installer)."
  echo ""
  echo "  # Debian/Ubuntu"
  echo "  sudo apt-get install -y git"
  echo ""
  echo "  # Fedora"
  echo "  sudo dnf install -y git"
  echo ""
  echo "  # macOS"
  echo "  xcode-select --install   # or: brew install git"
}

# --- main ---
info "PromptParle install from GitHub"
dim "  Repo   : $REPO_URL"
dim "  Path   : $CLONE_PATH"
dim "  Branch : $BRANCH"
echo ""

if ! need_cmd git; then
  print_git_help
  exit 1
fi

PWSH="$(find_pwsh || true)"
if [ -z "${PWSH:-}" ]; then
  print_pwsh_help
  exit 1
fi
ok "Found PowerShell: $PWSH"

if [ -d "$CLONE_PATH/.git" ]; then
  warn "Updating existing clone..."
  git -C "$CLONE_PATH" fetch origin
  git -C "$CLONE_PATH" checkout "$BRANCH"
  git -C "$CLONE_PATH" pull --ff-only origin "$BRANCH"
elif [ -e "$CLONE_PATH" ]; then
  err "Path exists but is not a git repo: $CLONE_PATH"
  err "Remove it or set PROMPTPARLE_CLONE_PATH to another location."
  exit 1
else
  parent="$(dirname "$CLONE_PATH")"
  mkdir -p "$parent"
  info "Cloning..."
  git clone --branch "$BRANCH" --single-branch "$REPO_URL" "$CLONE_PATH"
fi

INSTALL_SCRIPT="$CLONE_PATH/powershell/Install-PromptParle.ps1"
if [ ! -f "$INSTALL_SCRIPT" ]; then
  err "Install script not found: $INSTALL_SCRIPT"
  exit 1
fi

info "Running installer (module → license key)..."
dim "Create a free account at promptparle.com/register and make a pp_live_ license key."
echo ""

# Build pwsh argument list (mirrors install.ps1 → Install-PromptParle.ps1)
ARGS=(-NoProfile -File "$INSTALL_SCRIPT" -BaseUrl "$BASE_URL")
if [ "$DO_START" = "1" ]; then
  ARGS+=(-Start)
fi
if [ "$SKIP_KEY" = "1" ]; then
  ARGS+=(-SkipKeyPrompt)
fi

"$PWSH" "${ARGS[@]}"

echo ""
dim "Clone location: $CLONE_PATH"
info "After install, start local chat with:  pp"
dim "Local UI has an Update button for future upgrades."
dim "Re-run this script anytime to git pull + reinstall."
