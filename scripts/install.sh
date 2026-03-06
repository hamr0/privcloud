#!/usr/bin/env bash
set -euo pipefail

# privcloud installer — downloads and installs to /usr/local/bin

REPO="https://raw.githubusercontent.com/hamr0/privcloud/main"
INSTALL_DIR="/usr/local/bin"
APP_DIR="$HOME/.privcloud"

echo "Installing privcloud..."

mkdir -p "$APP_DIR/scripts"

# Download files
curl -fsSL "$REPO/privcloud" -o "$APP_DIR/privcloud"
curl -fsSL "$REPO/docker-compose.yml" -o "$APP_DIR/docker-compose.yml"
curl -fsSL "$REPO/.env.example" -o "$APP_DIR/.env.example"
curl -fsSL "$REPO/scripts/google-takeout-fix.sh" -o "$APP_DIR/scripts/google-takeout-fix.sh"

chmod +x "$APP_DIR/privcloud"
chmod +x "$APP_DIR/scripts/google-takeout-fix.sh"

# Symlink to PATH
if [ -w "$INSTALL_DIR" ]; then
  ln -sf "$APP_DIR/privcloud" "$INSTALL_DIR/privcloud"
else
  sudo ln -sf "$APP_DIR/privcloud" "$INSTALL_DIR/privcloud"
fi

echo ""
echo "Installed to $APP_DIR"
echo "Run: privcloud"
