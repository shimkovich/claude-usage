#!/usr/bin/env bash
# Remove claude-usage: launchd agent, cu symlink, and the Übersicht widget.
# Leaves ~/.config/claude-usage (your cached data) in place.
set -euo pipefail

LABEL="com.$USER.claude-usage"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
WIDGET="$HOME/Library/Application Support/Übersicht/widgets/claude-usage.jsx"

say() { printf '\033[36m==>\033[0m %s\n' "$1"; }

say "Unloading launchd agent"
launchctl unload "$PLIST" 2>/dev/null || true
rm -f "$PLIST"

say "Removing cu symlink"
rm -f "$HOME/.local/bin/cu"

say "Removing Übersicht widget"
rm -f "$WIDGET"
osascript -e 'tell application "Übersicht" to refresh' 2>/dev/null || true

say "Done. Cached data left in ~/.config/claude-usage (delete it manually if you want)."
