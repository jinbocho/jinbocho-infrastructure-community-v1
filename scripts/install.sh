#!/usr/bin/env bash
#
# Jinbocho — true one-shot installer entry point. Fetched and run directly
# via curl, no prior `git clone` needed:
#
#   curl -fsSL https://raw.githubusercontent.com/jinbocho/jinbocho-install-community-v1/main/scripts/install.sh \
#     | sudo bash -s -- --domain library.example.com --email you@example.com --google-books-key AIza...
#
# Clones (or updates, if re-run in a directory that already has the checkout)
# this repo, then hands off every argument unchanged to
# scripts/setup-vps-community.sh, which does the actual install. See that
# script (--help) for the full flag list — this file only exists so the repo
# doesn't need to be checked out by hand first.
set -euo pipefail

REPO_URL="${JINBOCHO_REPO_URL:-https://github.com/jinbocho/jinbocho-install-community-v1.git}"
BRANCH="${JINBOCHO_REPO_BRANCH:-main}"
TARGET_DIR="${JINBOCHO_INSTALL_DIR:-$PWD/jinbocho-install-community-v1}"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31mxx\033[0m %s\n' "$*" >&2; exit 1; }

command -v git &>/dev/null || die "git richiesto ma non trovato. Installalo (es. 'apt-get install -y git') e rilancia."

if [[ -d "$TARGET_DIR/.git" ]]; then
  log "Checkout già presente in $TARGET_DIR: aggiorno (git fetch + checkout $BRANCH)"
  git -C "$TARGET_DIR" fetch origin "$BRANCH"
  git -C "$TARGET_DIR" checkout "$BRANCH"
  git -C "$TARGET_DIR" pull --ff-only origin "$BRANCH"
else
  log "Clono jinbocho-install-community-v1 ($REPO_URL@$BRANCH) in $TARGET_DIR"
  git clone --branch "$BRANCH" "$REPO_URL" "$TARGET_DIR"
fi

exec "$TARGET_DIR/scripts/setup-vps-community.sh" "$@"
