# claude-usage

A macOS menu of where your Claude Code tokens are going. The `cu` CLI shows a
per-project token breakdown across all your sessions — which project folder is
eating your weekly limit — and an [Übersicht](https://tracesof.net/uebersicht/)
desktop widget keeps a live 7-day chart in the corner of your screen.

It reads the JSONL logs Claude Code already writes to `~/.claude/projects/` and
pulls your real 5-hour / weekly limit utilization from the Claude usage API
(using the OAuth token already in your macOS Keychain — nothing is stored or sent
anywhere else). When Codex is installed and signed in, the same widget also shows
your remaining Codex weekly limit through Codex's local app-server interface.

## Requirements

- macOS
- Python 3 (stdlib only — no `pip install`)
- [Übersicht](https://tracesof.net/uebersicht/) for the desktop widget
  (`brew install --cask ubersicht`). The `cu` CLI works without it.
- Optional: a signed-in `codex` CLI to show the Codex weekly limit row.

## Install

**Just use it — no clone needed.** One line copies the `cu` CLI to `~/.local/bin`
and the widget into Übersicht; nothing else stays on disk, so you don't need to
keep (or even download) the repo:

```sh
curl -fsSL https://raw.githubusercontent.com/shimkovich/claude-usage/main/install.sh | bash
```

**Clone it** if you want to read the code or hack on it. This symlinks `cu` to the
checkout so your edits are live, so keep the folder around:

```sh
git clone https://github.com/shimkovich/claude-usage.git
cd claude-usage
./install.sh
```

Either way, the installer puts `cu` on your `PATH`, installs a launchd agent that
refreshes the widget data every 5 minutes, and drops the widget into Übersicht. If
Übersicht isn't installed yet, the script tells you how and you re-run it afterward.

### Install with Claude Code

If you use Claude Code, just say:

> Install the widget from https://github.com/shimkovich/claude-usage

Claude will read this README and run the one-liner above for you.

## CLI usage

```
cu                     # 7-day rolling week breakdown (default)
cu today               # today's usage
cu daily [--days 7]    # day-by-day table
cu 5h                  # current 5h sliding window
cu widget-data         # write JSON for the Übersicht widget
cu widget-data --json  # same, but print JSON to stdout
cu config              # open config in $EDITOR
```

The primary metric is `output_tokens` — the main rate-limited resource on Max
plans.

## How it works

```
~/.claude/projects/*/*.jsonl  ->  cu (scan + aggregate)  ->  terminal output
                              \->  ~/.config/claude-usage/widget-data.json  ->  Übersicht widget
codex app-server              ->  cu (weekly limit)      ->  widget-data.json
```

- `cu` scans the JSONL session logs and groups usage by project (from each
  entry's `cwd`). An incremental cache (`~/.config/claude-usage/scan-cache.json`,
  keyed by file mtime + size) keeps repeat runs fast.
- The launchd agent runs `cu widget-data` every 5 minutes, writing
  `~/.config/claude-usage/widget-data.json`.
- `cu` asks the authenticated local Codex app-server for the seven-day rate-limit
  window. It does not read or store Codex credentials.
- The widget (`claude-usage.jsx`) just `cat`s that JSON, so rendering is instant.

## Uninstall

```sh
curl -fsSL https://raw.githubusercontent.com/shimkovich/claude-usage/main/uninstall.sh | bash
```

Or, from a clone, `./uninstall.sh`.

Removes the launchd agent, the `cu` symlink, and the widget. Your cached data in
`~/.config/claude-usage` is left in place — delete it manually if you want.

## License

[MIT](LICENSE) © Vlad Shimkovich
