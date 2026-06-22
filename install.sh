#!/usr/bin/env bash
# Installer for claude-usage: the `cu` CLI + Übersicht widget.
# macOS only. No dependencies beyond Python 3 and Übersicht.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="$HOME/.local/bin"
LABEL="com.$USER.claude-usage"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
WIDGETS_DIR="$HOME/Library/Application Support/Übersicht/widgets"

say()  { printf '\033[36m==>\033[0m %s\n' "$1"; }
warn() { printf '\033[33m!  \033[0m %s\n' "$1"; }

# 1. Requirements
if [[ "$(uname)" != "Darwin" ]]; then
  echo "This widget is macOS-only (Übersicht + launchd)." >&2; exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 not found. Install it (e.g. 'brew install python') and re-run." >&2; exit 1
fi

# 2. Symlink the cu CLI onto PATH
say "Linking cu -> $BIN_DIR/cu"
mkdir -p "$BIN_DIR"
ln -sf "$REPO_DIR/cu" "$BIN_DIR/cu"
chmod +x "$REPO_DIR/cu"
if ! command -v cu >/dev/null 2>&1; then
  warn "$BIN_DIR is not on your PATH. Add this to your shell profile:"
  warn "  export PATH=\"\$HOME/.local/bin:\$PATH\""
fi

# 3. launchd agent: refresh widget data every 5 minutes
say "Installing launchd agent ($LABEL)"
mkdir -p "$(dirname "$PLIST")"
cat > "$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$LABEL</string>
	<key>ProgramArguments</key>
	<array>
		<string>$REPO_DIR/cu</string>
		<string>widget-data</string>
	</array>
	<key>StartInterval</key>
	<integer>300</integer>
	<key>RunAtLoad</key>
	<true/>
	<key>StandardOutPath</key>
	<string>/tmp/claude-usage.log</string>
	<key>StandardErrorPath</key>
	<string>/tmp/claude-usage.log</string>
</dict>
</plist>
PLISTEOF
launchctl unload "$PLIST" 2>/dev/null || true
launchctl load -w "$PLIST"

# 4. Seed widget data once so the widget isn't empty on first load
say "Generating initial widget data"
"$REPO_DIR/cu" widget-data || warn "First data run failed (will retry on the 5-min timer)."

# 5. Install the Übersicht widget
if [[ -d "/Applications/Übersicht.app" || -d "$HOME/Applications/Übersicht.app" ]]; then
  say "Copying widget into Übersicht"
  mkdir -p "$WIDGETS_DIR"
  cp "$REPO_DIR/claude-usage.jsx" "$WIDGETS_DIR/claude-usage.jsx"
  osascript -e 'tell application "Übersicht" to refresh' 2>/dev/null || true
  say "Done. The widget appears bottom-left on your desktop."
else
  warn "Übersicht is not installed. Install it, then re-run this script:"
  warn "  brew install --cask ubersicht   (or download from https://tracesof.net/uebersicht/)"
  warn "After installing, launch Übersicht once, then re-run ./install.sh"
fi
