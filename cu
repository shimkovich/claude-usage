#!/usr/bin/env python3
"""cu - Claude Code usage tracker. Shows per-project token breakdown."""

import argparse
import json
import os
import signal
import ssl
import subprocess
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

CLAUDE_DIR = Path.home() / ".claude"
PROJECTS_DIR = CLAUDE_DIR / "projects"
SESSIONS_DIR = CLAUDE_DIR / "sessions"
CONFIG_DIR = Path.home() / ".config" / "claude-usage"
CONFIG_FILE = CONFIG_DIR / "config.json"
WIDGET_DATA_FILE = CONFIG_DIR / "widget-data.json"
SCAN_CACHE_FILE = CONFIG_DIR / "scan-cache.json"

# ── Colors ─────────────────────────────────────────────────────────────────

RESET = "\033[0m"
BOLD = "\033[1m"
DIM = "\033[2m"
GREEN = "\033[32m"
YELLOW = "\033[33m"
CYAN = "\033[36m"
RED = "\033[31m"
MAGENTA = "\033[35m"

PROJECT_COLORS = [CYAN, GREEN, YELLOW, MAGENTA, "\033[34m", "\033[91m", "\033[92m", "\033[93m"]


def color(text, c):
    return f"{c}{text}{RESET}"


# ── Claude API ─────────────────────────────────────────────────────────────

USAGE_CACHE_FILE = CONFIG_DIR / "usage-api-cache.json"
USAGE_CACHE_TTL = 300  # 5 minutes


def _ssl_context():
    ctx = ssl.create_default_context()
    try:
        import certifi
        ctx.load_verify_locations(certifi.where())
    except ImportError:
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
    return ctx


def _load_usage_cache():
    try:
        with open(USAGE_CACHE_FILE) as f:
            cached = json.load(f)
        cached_at = datetime.fromisoformat(cached["_cached_at"])
        return cached, cached_at
    except (json.JSONDecodeError, OSError, KeyError, ValueError):
        return None, None


def _cached_usage_has_current_window(cached, now):
    if not cached:
        return False
    try:
        resets_at = datetime.fromisoformat(cached["seven_day"]["resets_at"])
        return resets_at > now
    except (TypeError, ValueError, KeyError):
        return False


def fetch_usage_api():
    """Fetch usage windows from Claude API. Returns cached if fresh."""
    now = datetime.now(timezone.utc)
    cached, cached_at = _load_usage_cache()
    if cached_at and (now - cached_at).total_seconds() < USAGE_CACHE_TTL and _cached_usage_has_current_window(cached, now):
        return cached

    # Get OAuth token from keychain
    try:
        result = subprocess.run(
            ["security", "find-generic-password", "-s", "Claude Code-credentials", "-w"],
            capture_output=True, text=True, timeout=5,
        )
        if result.returncode != 0:
            return cached if _cached_usage_has_current_window(cached, now) else None
        creds = json.loads(result.stdout.strip())
        token = creds["claudeAiOauth"]["accessToken"]
    except (json.JSONDecodeError, KeyError, subprocess.TimeoutExpired, OSError):
        return cached if _cached_usage_has_current_window(cached, now) else None

    # Call API
    try:
        import urllib.request
        req = urllib.request.Request("https://api.anthropic.com/api/oauth/usage")
        req.add_header("Authorization", f"Bearer {token}")
        req.add_header("anthropic-beta", "oauth-2025-04-20")
        with urllib.request.urlopen(req, timeout=10, context=_ssl_context()) as resp:
            data = json.loads(resp.read())
    except Exception:
        return cached if _cached_usage_has_current_window(cached, now) else None

    # Cache it
    data["_cached_at"] = datetime.now(timezone.utc).isoformat()
    try:
        CONFIG_DIR.mkdir(parents=True, exist_ok=True)
        with open(USAGE_CACHE_FILE, "w") as f:
            json.dump(data, f)
    except OSError:
        pass

    return data


def get_week_boundaries(usage_data=None):
    """Return (week_start, week_end, utilization) from API data.

    Falls back to rolling 7 days if API unavailable.
    """
    now = datetime.now(timezone.utc)
    if usage_data and "seven_day" in usage_data and usage_data["seven_day"]:
        sd = usage_data["seven_day"]
        try:
            resets_at = datetime.fromisoformat(sd["resets_at"])
            week_end = resets_at
            week_start = resets_at - timedelta(days=7)
            utilization = sd.get("utilization")
            return week_start, week_end, utilization
        except (TypeError, ValueError, KeyError):
            pass
    return now - timedelta(days=7), now, None


def get_5h_boundaries(usage_data=None):
    """Return (window_start, window_end, utilization) from API data."""
    now = datetime.now(timezone.utc)
    if usage_data and "five_hour" in usage_data and usage_data["five_hour"]:
        fh = usage_data["five_hour"]
        try:
            resets_at = datetime.fromisoformat(fh["resets_at"])
            window_end = resets_at
            window_start = resets_at - timedelta(hours=5)
            utilization = fh.get("utilization")
            return window_start, window_end, utilization
        except (TypeError, ValueError, KeyError):
            pass
    return now - timedelta(hours=5), now, None


# ── Config ─────────────────────────────────────────────────────────────────

def load_config():
    if not CONFIG_FILE.exists():
        return {}
    try:
        with open(CONFIG_FILE) as f:
            return json.load(f)
    except (json.JSONDecodeError, OSError):
        return {}


def get_project_color(project, index, config):
    colors = config.get("colors", {})
    if project in colors:
        return colors[project]
    return PROJECT_COLORS[index % len(PROJECT_COLORS)]


# ── Scanner ────────────────────────────────────────────────────────────────

def _load_scan_cache():
    try:
        if SCAN_CACHE_FILE.exists():
            with open(SCAN_CACHE_FILE) as f:
                cache = json.load(f)
            if cache.get("v") == 1:
                return cache.get("files", {})
    except (json.JSONDecodeError, OSError, KeyError):
        pass
    return {}


def _save_scan_cache(files_cache):
    try:
        CONFIG_DIR.mkdir(parents=True, exist_ok=True)
        with open(SCAN_CACHE_FILE, "w") as f:
            json.dump({"v": 1, "files": files_cache}, f)
    except OSError:
        pass


def _parse_jsonl_file(jsonl_file):
    """Parse a single JSONL file for usage entries. Returns (project, entries_list)."""
    project = None
    file_entries = []
    with open(jsonl_file) as f:
        for line in f:
            if '"usage"' not in line:
                continue
            try:
                obj = json.loads(line)
            except (json.JSONDecodeError, ValueError):
                continue
            if obj.get("type") != "assistant":
                continue

            if not project:
                cwd = obj.get("cwd", "")
                project = os.path.basename(cwd) if cwd else "unknown"

            ts_str = obj.get("timestamp", "")
            if not ts_str:
                continue

            msg = obj.get("message", {})
            usage = msg.get("usage", {})
            out = usage.get("output_tokens", 0)
            inp = usage.get("input_tokens", 0)
            if out == 0 and inp == 0:
                continue

            file_entries.append({
                "ts": ts_str,
                "out": out,
                "inp": inp,
                "cc": usage.get("cache_creation_input_tokens", 0),
                "cr": usage.get("cache_read_input_tokens", 0),
                "model": msg.get("model", ""),
            })
    return project, file_entries


def _cached_entries_to_results(project, cached_entries, since_dt):
    """Convert compact cached entries to full result dicts, filtering by since_dt."""
    results = []
    for e in cached_entries:
        try:
            ts = datetime.fromisoformat(e["ts"].replace("Z", "+00:00"))
        except (ValueError, TypeError):
            continue
        if ts < since_dt:
            continue
        results.append({
            "timestamp": ts,
            "project": project,
            "output": e["out"],
            "input": e["inp"],
            "cache_create": e["cc"],
            "cache_read": e["cr"],
            "model": e["model"],
        })
    return results


def scan_projects(since_dt):
    """Scan JSONL files for usage entries since since_dt.

    Uses incremental cache: only re-parses files whose mtime/size changed.
    Returns list of dicts: {timestamp, project, output, input, cache_create, cache_read, model}
    """
    since_ts = since_dt.timestamp()
    entries = []
    cache = _load_scan_cache()
    new_cache = {}

    if not PROJECTS_DIR.exists():
        return entries

    def _collect_jsonl_files():
        for project_dir in PROJECTS_DIR.iterdir():
            if not project_dir.is_dir():
                continue
            for f in project_dir.iterdir():
                if f.name.endswith(".jsonl"):
                    yield f
            # Subagent JSONL files, including workflow agents nested in
            # subagents/workflows/<wf_id>/agent-*.jsonl
            for session_dir in project_dir.iterdir():
                if not session_dir.is_dir():
                    continue
                subagents_dir = session_dir / "subagents"
                if not subagents_dir.exists():
                    continue
                yield from subagents_dir.rglob("*.jsonl")

    for jsonl_file in _collect_jsonl_files():
        try:
            st = jsonl_file.stat()
            if st.st_mtime < since_ts:
                continue
        except OSError:
            continue

        fkey = str(jsonl_file)
        mt = st.st_mtime
        sz = st.st_size

        cached = cache.get(fkey)
        if cached and cached.get("mt") == mt and cached.get("sz") == sz:
            new_cache[fkey] = cached
            project = cached.get("pr", "unknown")
            entries.extend(_cached_entries_to_results(project, cached.get("entries", []), since_dt))
        else:
            try:
                project, file_entries = _parse_jsonl_file(jsonl_file)
                project = project or "unknown"
                new_cache[fkey] = {"mt": mt, "sz": sz, "pr": project, "entries": file_entries}
                entries.extend(_cached_entries_to_results(project, file_entries, since_dt))
            except OSError:
                continue

    _save_scan_cache(new_cache)
    return entries


# ── Aggregation ────────────────────────────────────────────────────────────

def aggregate_by_project(entries):
    """Group entries by project, return sorted list of (project, totals) by output desc."""
    by_project = {}
    for e in entries:
        p = e["project"]
        if p not in by_project:
            by_project[p] = {"output": 0, "input": 0, "cache_create": 0, "cache_read": 0, "count": 0}
        by_project[p]["output"] += e["output"]
        by_project[p]["input"] += e["input"]
        by_project[p]["cache_create"] += e["cache_create"]
        by_project[p]["cache_read"] += e["cache_read"]
        by_project[p]["count"] += 1
    return sorted(by_project.items(), key=lambda x: -x[1]["output"])


def aggregate_by_day(entries, days=7):
    """Group entries by project and calendar day.

    Returns {date_str: {project: output_tokens}}, sorted_projects, project_totals
    """
    now = datetime.now(timezone.utc)
    daily = {}
    project_totals = {}

    for e in entries:
        date_str = e["timestamp"].strftime("%Y-%m-%d")
        p = e["project"]
        daily.setdefault(date_str, {})
        daily[date_str][p] = daily[date_str].get(p, 0) + e["output"]
        project_totals[p] = project_totals.get(p, 0) + e["output"]

    sorted_projects = sorted(project_totals.keys(), key=lambda p: -project_totals[p])
    return daily, sorted_projects, project_totals


# ── Active sessions ────────────────────────────────────────────────────────

def active_sessions():
    """Return {project: count} of live Claude sessions."""
    result = {}
    if not SESSIONS_DIR.exists():
        return result

    for f in SESSIONS_DIR.iterdir():
        if not f.name.endswith(".json"):
            continue
        try:
            with open(f) as fh:
                data = json.load(fh)
            pid = data.get("pid")
            cwd = data.get("cwd", "")
            if not pid:
                continue
            os.kill(pid, 0)
            project = os.path.basename(cwd) if cwd else "unknown"
            result[project] = result.get(project, 0) + 1
        except (OSError, ProcessLookupError, PermissionError, json.JSONDecodeError, ValueError):
            continue
    return result


# ── Formatting ─────────────────────────────────────────────────────────────

def fmt_tokens(n):
    if n >= 1_000_000:
        return f"{n / 1_000_000:.1f}M"
    if n >= 1_000:
        return f"{n / 1_000:.0f}K"
    return str(n)


def fmt_bar(fraction, width=20):
    filled = int(fraction * width)
    return "█" * filled + "░" * (width - filled)


def print_project_breakdown(projects, total_output, config, title_line):
    """Print the standard project breakdown view."""
    print(f"\n  {title_line}\n")

    if not projects:
        print(f"  {color('No usage data found.', DIM)}")
        return

    max_name = max(len(p) for p, _ in projects)
    max_name = max(max_name, 8)

    for i, (project, totals) in enumerate(projects):
        out = totals["output"]
        pct = (out / total_output * 100) if total_output else 0
        pc = get_project_color(project, i, config)
        bar = fmt_bar(out / total_output if total_output else 0)
        print(f"  {color(project.ljust(max_name), pc)} {color(bar, pc)} {fmt_tokens(out):>6s} out  {pct:5.1f}%")

    print(f"  {'─' * (max_name + 42)}")
    print(f"  {'Total'.ljust(max_name)}                      {color(fmt_tokens(total_output), BOLD):>6s} output tokens")


# ── Commands ───────────────────────────────────────────────────────────────

def cmd_status(args):
    """Weekly window — the primary view."""
    config = load_config()
    now = datetime.now(timezone.utc)
    usage = fetch_usage_api()
    week_start, week_end, utilization = get_week_boundaries(usage)

    entries = scan_projects(week_start)
    # Filter to exact window
    entries = [e for e in entries if e["timestamp"] >= week_start and e["timestamp"] <= min(week_end, now)]
    projects = aggregate_by_project(entries)
    total_output = sum(t["output"] for _, t in projects)

    today_start = now.replace(hour=0, minute=0, second=0, microsecond=0)
    today_entries = [e for e in entries if e["timestamp"] >= today_start]
    today_output = sum(e["output"] for e in today_entries)

    days_in = max(1, (min(now, week_end) - week_start).total_seconds() / 86400)
    avg_daily = total_output / days_in

    active = active_sessions()
    active_count = sum(active.values())

    status_dot = color("●", GREEN) if active_count > 0 else color("○", DIM)

    reset_str = ""
    if week_end > now:
        reset_local = week_end.astimezone()
        reset_str = f"  resets {reset_local.strftime('%a %b %d %H:%M')}"

    util_str = ""
    if utilization is not None:
        util_str = f"  {color(f'{utilization:.0f}% of limit', YELLOW)}"

    days_label = f"{int(days_in)}d" if days_in < 6.5 else "7d"
    title = f"{status_dot} {color('CLAUDE USAGE', BOLD)}  {color(f'week ({days_label})', DIM)}{reset_str}{util_str}"

    print_project_breakdown(projects, total_output, config, title)

    print()
    parts = [
        f"Today: {color(fmt_tokens(today_output), BOLD)} out",
        f"Avg/day: {fmt_tokens(int(avg_daily))}",
    ]
    if active_count > 0:
        parts.append(f"Active: {color(str(active_count), GREEN)} sessions")
    print(f"  {'  │  '.join(parts)}")
    print()


def cmd_today(args):
    """Today's usage breakdown."""
    config = load_config()
    now = datetime.now(timezone.utc)
    today_start = now.replace(hour=0, minute=0, second=0, microsecond=0)

    entries = scan_projects(today_start)
    projects = aggregate_by_project(entries)
    total_output = sum(t["output"] for _, t in projects)

    active = active_sessions()
    active_count = sum(active.values())

    status_dot = color("●", GREEN) if active_count > 0 else color("○", DIM)
    title = f"{status_dot} {color('CLAUDE USAGE', BOLD)}  {color('today', DIM)}"

    print_project_breakdown(projects, total_output, config, title)
    print()


def cmd_daily(args):
    """Day-by-day breakdown table."""
    config = load_config()
    days = args.days
    now = datetime.now(timezone.utc)
    usage = fetch_usage_api()
    week_start, week_end, _ = get_week_boundaries(usage)

    # Use week boundaries if default 7 days, otherwise use the explicit --days
    if days == 7:
        since = week_start
    else:
        since = now - timedelta(days=days)

    entries = scan_projects(since)
    entries = [e for e in entries if e["timestamp"] >= since]
    daily, sorted_projects, project_totals = aggregate_by_day(entries, days)

    if not sorted_projects:
        print(f"  {color('No usage data found.', DIM)}")
        return

    # Only include days that have data
    all_dates = []
    d = since
    while d <= now:
        all_dates.append(d.strftime("%Y-%m-%d"))
        d += timedelta(days=1)
    dates = [d for d in all_dates if daily.get(d)]

    day_labels = []
    for d in dates:
        dt = datetime.strptime(d, "%Y-%m-%d")
        day_labels.append(dt.strftime("%a"))

    max_name = max(len(p) for p in sorted_projects)
    max_name = max(max_name, 8)

    period_label = f"week ({len(dates)}d)" if days == 7 else f"daily ({days} days)"
    print(f"\n  {color('CLAUDE USAGE', BOLD)}  {color(period_label, DIM)}\n")

    header = f"  {'Project'.ljust(max_name)}  " + "  ".join(f"{l:>5s}" for l in day_labels) + f"  {'Total':>6s}"
    print(f"  {color(header.strip(), DIM)}")
    print(f"  {'─' * len(header.strip())}")

    for i, p in enumerate(sorted_projects[:12]):
        pc = get_project_color(p, i, config)
        row = f"  {color(p.ljust(max_name), pc)}  "
        for d in dates:
            val = daily.get(d, {}).get(p, 0)
            row += f"{fmt_tokens(val) if val else '·':>5s}  "
        row += f"{color(fmt_tokens(project_totals[p]), BOLD):>6s}"
        print(row)

    # Day totals row
    print(f"  {'─' * len(header.strip())}")
    totals_row = f"  {'Total'.ljust(max_name)}  "
    for d in dates:
        day_total = sum(daily.get(d, {}).values())
        totals_row += f"{fmt_tokens(day_total):>5s}  "
    grand_total = sum(project_totals.values())
    totals_row += f"{color(fmt_tokens(grand_total), BOLD):>6s}"
    print(totals_row)
    print()


def cmd_5h(args):
    """Current 5h sliding window."""
    config = load_config()
    now = datetime.now(timezone.utc)
    usage = fetch_usage_api()
    window_start, window_end, utilization = get_5h_boundaries(usage)

    entries = scan_projects(window_start)
    entries = [e for e in entries if e["timestamp"] >= window_start and e["timestamp"] <= min(window_end, now)]
    projects = aggregate_by_project(entries)
    total_output = sum(t["output"] for _, t in projects)

    elapsed = now - window_start
    remaining = window_end - now
    if remaining < timedelta(0):
        remaining = timedelta(0)

    elapsed_str = f"{int(elapsed.total_seconds() // 3600)}h {int((elapsed.total_seconds() % 3600) // 60)}m"
    remain_str = f"{int(remaining.total_seconds() // 3600)}h {int((remaining.total_seconds() % 3600) // 60)}m"

    util_str = ""
    if utilization is not None:
        util_str = f"  {color(f'{utilization:.0f}% of limit', YELLOW)}"

    active = active_sessions()
    active_count = sum(active.values())
    status_dot = color("●", GREEN) if active_count > 0 else color("○", DIM)
    title = f"{status_dot} {color('5H WINDOW', BOLD)}  {color(f'{elapsed_str} in', DIM)}  {' ' * 20}{color(f'{remain_str} left', DIM)}{util_str}"

    print_project_breakdown(projects, total_output, config, title)
    print()


def cmd_widget_data(args):
    """Write pre-computed JSON for the widget."""
    now = datetime.now(timezone.utc)
    config = load_config()
    usage = fetch_usage_api()

    # Week boundaries from API
    week_start, week_end, week_util = get_week_boundaries(usage)
    window_start_5h, window_end_5h, util_5h = get_5h_boundaries(usage)

    # 7-day data scoped to actual week
    entries_7d = scan_projects(week_start)
    entries_7d = [e for e in entries_7d if e["timestamp"] >= week_start and e["timestamp"] <= min(week_end, now)]
    projects_7d = aggregate_by_project(entries_7d)
    total_7d = sum(t["output"] for _, t in projects_7d)

    # 5h data
    entries_5h = [e for e in entries_7d if e["timestamp"] >= window_start_5h]
    projects_5h = aggregate_by_project(entries_5h)
    total_5h = sum(t["output"] for _, t in projects_5h)

    # daily breakdown
    daily, sorted_projects, project_totals = aggregate_by_day(entries_7d)

    active = active_sessions()
    active_count = sum(active.values())

    # Build daily array — all 7 days of the week, empty ones included for stable layout
    daily_arr = []
    d = week_start
    for _ in range(7):
        date_str = d.strftime("%Y-%m-%d")
        dt = datetime.strptime(date_str, "%Y-%m-%d")
        daily_arr.append({
            "date": date_str,
            "day": dt.strftime("%a"),
            "projects": daily.get(date_str, {}),
        })
        d += timedelta(days=1)

    # Colors for widget
    colors_map = {}
    widget_palette = ["#6EE7B7", "#67E8F9", "#A78BFA", "#FCA5A1",
                      "#FDBA74", "#86EFAC", "#7DD3FC", "#C4B5FD"]
    cfg_colors = config.get("colors", {})
    for i, p in enumerate(sorted_projects):
        if p in cfg_colors:
            colors_map[p] = cfg_colors[p]
        else:
            colors_map[p] = widget_palette[i % len(widget_palette)]

    data = {
        "generatedAt": now.isoformat(),
        "weekStart": week_start.isoformat(),
        "weekEnd": week_end.isoformat(),
        "weekUtilization": week_util,
        "weeklyWindow": {
            "projects": [{"name": p, "output": t["output"]} for p, t in projects_7d],
            "totalOutput": total_7d,
            "activeSessions": active_count,
        },
        "currentWindow5h": {
            "projects": [{"name": p, "output": t["output"]} for p, t in projects_5h],
            "totalOutput": total_5h,
            "utilization": util_5h,
            "windowEnd": window_end_5h.isoformat(),
        },
        "daily": daily_arr,
        "sortedProjects": sorted_projects,
        "projectTotals": project_totals,
        "colors": colors_map,
    }

    if getattr(args, 'json_stdout', False):
        print(json.dumps(data))
        return

    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    with open(WIDGET_DATA_FILE, "w") as f:
        json.dump(data, f, indent=2)
        f.write("\n")

    print(f"  Written to {WIDGET_DATA_FILE}")


def cmd_config(_args):
    """Open config in $EDITOR."""
    editor = os.environ.get("EDITOR", "vim")
    if not CONFIG_FILE.exists():
        CONFIG_DIR.mkdir(parents=True, exist_ok=True)
        with open(CONFIG_FILE, "w") as f:
            json.dump({"colors": {}}, f, indent=2)
            f.write("\n")
    subprocess.run([editor, str(CONFIG_FILE)])


# ── Main ───────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(
        prog="cu",
        description="Claude Code usage tracker — per-project token breakdown",
    )
    sub = parser.add_subparsers(dest="command")

    sub.add_parser("status", help="7-day rolling week breakdown (default)")
    sub.add_parser("today", help="Today's usage breakdown")


    p_daily = sub.add_parser("daily", help="Day-by-day breakdown table")
    p_daily.add_argument("--days", type=int, default=7, help="Number of days (default: 7)")

    sub.add_parser("5h", help="Current 5h sliding window")

    p_widget = sub.add_parser("widget-data", help="Write JSON for widget")
    p_widget.add_argument("--json", dest="json_stdout", action="store_true", help="Print JSON to stdout instead of writing file")

    sub.add_parser("config", help="Open config in $EDITOR")

    args = parser.parse_args()

    commands = {
        "status": cmd_status,
        "today": cmd_today,
        "daily": cmd_daily,
        "5h": cmd_5h,
        "widget-data": cmd_widget_data,
        "config": cmd_config,
    }

    cmd = args.command or "status"
    if cmd in commands:
        commands[cmd](args)
    else:
        parser.print_help()


if __name__ == "__main__":
    main()
