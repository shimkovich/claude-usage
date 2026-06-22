#!/usr/bin/env bash
# Installer for claude-usage: the `cu` CLI + Übersicht widget. macOS only.
#
# Two ways to run it:
#   1. No clone (just use the tool):
#        curl -fsSL https://raw.githubusercontent.com/shimkovich/claude-usage/main/install.sh | bash
#      cu is copied to ~/.local/bin; nothing else stays on disk, so the repo is
#      not needed afterward.
#   2. From a clone (to hack on it):
#        ./install.sh
#      cu is symlinked to the checkout so your edits are live — keep the folder.
set -euo pipefail

RAW="https://raw.githubusercontent.com/shimkovich/claude-usage/main"
BIN_DIR="$HOME/.local/bin"
LABEL="com.$USER.claude-usage"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
WIDGETS_DIR="$HOME/Library/Application Support/Übersicht/widgets"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-.}")" 2>/dev/null && pwd || pwd)"

say()  { printf '\033[36m==>\033[0m %s\n' "$1"; }
warn() { printf '\033[33m!  \033[0m %s\n' "$1"; }

# 1. Requirements
if [[ "$(uname)" != "Darwin" ]]; then
  echo "This widget is macOS-only (Übersicht + launchd)." >&2; exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 not found. Install it (e.g. 'brew install python') and re-run." >&2; exit 1
fi

# 2. Locate sources. Clone => use local files (symlink). Piped => download (copy).
if [[ -f "$SCRIPT_DIR/cu" && -f "$SCRIPT_DIR/claude-usage.jsx" ]]; then
  MODE="clone"
  SRC_CU="$SCRIPT_DIR/cu"
  SRC_JSX="$SCRIPT_DIR/claude-usage.jsx"
else
  MODE="remote"
  TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP"' EXIT
  say "Downloading cu and widget from GitHub"
  curl -fsSL "$RAW/cu" -o "$TMP/cu"
  curl -fsSL "$RAW/claude-usage.jsx" -o "$TMP/claude-usage.jsx"
  SRC_CU="$TMP/cu"
  SRC_JSX="$TMP/claude-usage.jsx"
fi

# 3. Put the cu CLI on PATH
mkdir -p "$BIN_DIR"
if [[ "$MODE" == "clone" ]]; then
  say "Linking cu -> $BIN_DIR/cu (live from this checkout)"
  ln -sf "$SRC_CU" "$BIN_DIR/cu"
  CU_PATH="$SRC_CU"
else
  say "Installing cu -> $BIN_DIR/cu"
  cp "$SRC_CU" "$BIN_DIR/cu"
  CU_PATH="$BIN_DIR/cu"
fi
chmod +x "$CU_PATH"
if ! command -v cu >/dev/null 2>&1; then
  warn "$BIN_DIR is not on your PATH. Add to your shell profile (the widget works regardless):"
  warn "  export PATH=\"\$HOME/.local/bin:\$PATH\""
fi

# 4. launchd agent: refresh widget data every 5 minutes
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
		<string>$CU_PATH</string>
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

# 5. Seed widget data once so the widget isn't empty on first load
say "Generating initial widget data"
"$CU_PATH" widget-data || warn "First data run failed (will retry on the 5-min timer)."

# 6. Install the Übersicht widget
if [[ -d "/Applications/Übersicht.app" || -d "$HOME/Applications/Übersicht.app" ]]; then
  say "Copying widget into Übersicht"
  mkdir -p "$WIDGETS_DIR"
  cp "$SRC_JSX" "$WIDGETS_DIR/claude-usage.jsx"
  osascript -e 'tell application "Übersicht" to refresh' 2>/dev/null || true
  say "Done. The widget appears bottom-left on your desktop."
else
  warn "Übersicht is not installed. Install it, then re-run this script:"
  warn "  brew install --cask ubersicht   (or download from https://tracesof.net/uebersicht/)"
  warn "After installing, launch Übersicht once, then re-run the installer."
fi
