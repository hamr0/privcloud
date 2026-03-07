#!/usr/bin/env bash
#
# backup.sh — rsync backup with progress
#
# Usage:
#   ./backup.sh
#   ./backup.sh /source /destination
#
# Copies source to destination using rsync with progress.
# Incremental — only transfers changed/new files after first run.
# Uses sudo when needed for permission-locked files.

set -euo pipefail

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

info()  { echo -e "${GREEN}[+]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
error() { echo -e "${RED}[x]${NC} $*"; exit 1; }
bold()  { echo -e "${BOLD}$*${NC}"; }

command -v rsync &>/dev/null || error "rsync not found. Install it first (e.g. sudo dnf install rsync / sudo apt install rsync)."

# --- Get source and destination -----------------------------------------------

SRC="${1:-}"
DEST="${2:-}"

if [ -z "$SRC" ]; then
  printf "Source path: "
  read -r SRC
fi
SRC="${SRC/#\~/$HOME}"
SRC="${SRC//\'/}"
SRC="${SRC//\"/}"

if [ -z "$SRC" ] || [ ! -e "$SRC" ]; then
  error "Not found: $SRC"
fi

if [ -z "$DEST" ]; then
  printf "Destination path: "
  read -r DEST
fi
DEST="${DEST/#\~/$HOME}"
DEST="${DEST//\'/}"
DEST="${DEST//\"/}"

if [ -z "$DEST" ] || [ ! -d "$DEST" ]; then
  error "Not a valid directory: $DEST"
fi

# --- Show summary -------------------------------------------------------------

SRC_SIZE="$(sudo du -sh "$SRC" 2>/dev/null | awk '{print $1}' || du -sh "$SRC" 2>/dev/null | awk '{print $1}' || echo "unknown")"
AVAIL="$(df -h "$DEST" 2>/dev/null | awk 'NR==2{print $4}')"

echo ""
bold "Backup summary"
echo "  Source:      $SRC ($SRC_SIZE)"
echo "  Destination: $DEST"
echo "  Available:   $AVAIL"
echo ""

printf "Start backup? [Y/n]: "
read -r confirm
if [[ "$confirm" =~ ^[Nn] ]]; then
  warn "Cancelled."
  exit 0
fi

# --- Run rsync ----------------------------------------------------------------

echo ""
info "Starting backup..."
echo ""

# Try without sudo first, fall back to sudo if permission denied
if rsync -a --info=progress2 "$SRC" "$DEST" 2>/dev/null; then
  true
else
  warn "Permission issue detected, retrying with sudo..."
  sudo rsync -a --info=progress2 "$SRC" "$DEST"
fi

echo ""
info "Backup complete!"
echo "  From: $SRC"
echo "  To:   $DEST"
