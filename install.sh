#!/bin/sh
#
# claude-pulse installer.
#
# Installs the status line + notification hook into ~/.claude/claude-pulse/ and
# merges the `statusLine` and `hooks` blocks into ~/.claude/settings.json
# WITHOUT clobbering any existing configuration. Re-running is idempotent.

set -u

SCRIPT_DIR=$(unset CDPATH; cd -- "$(dirname -- "$0")" && pwd) || exit 1
CLAUDE_DIR=${CLAUDE_CONFIG_DIR:-"$HOME/.claude"}
INSTALL_DIR="$CLAUDE_DIR/claude-pulse"
SETTINGS_FILE="$CLAUDE_DIR/settings.json"

STATUSLINE_SRC="$SCRIPT_DIR/statusline.sh"
STATUSLINE_DST="$INSTALL_DIR/statusline.sh"
NOTIFY_SRC="$SCRIPT_DIR/hooks/notify.sh"
NOTIFY_DST="$INSTALL_DIR/notify.sh"
PREV_STATUSLINE_FILE="$INSTALL_DIR/statusline.prev.json"

RAW_URL=${PULSE_RAW_URL:-"https://raw.githubusercontent.com/martinoyovo/claude-pulse/main"}

mkdir -p "$INSTALL_DIR" "$CLAUDE_DIR"

resolve_link() {
    p=$1
    while [ -L "$p" ]; do
        t=$(readlink "$p")
        case "$t" in /*) p=$t ;; *) p=$(dirname "$p")/$t ;; esac
    done
    printf '%s' "$p"
}

fetch_file() {
    url=$1; dst=$2
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$url" -o "$dst"
    elif command -v wget >/dev/null 2>&1; then
        wget -qO "$dst" "$url"
    else
        return 1
    fi
}

install_file() {
    src=$1; url_path=$2; dst=$3
    if [ -f "$src" ]; then
        cp "$src" "$dst"
        return 0
    fi
    case "$RAW_URL" in
        "")
            printf 'Local source %s was not found.\n' "$src" >&2
            printf 'For piped installs, set PULSE_RAW_URL to the raw repository URL.\n' >&2
            exit 1 ;;
    esac
    if ! fetch_file "$RAW_URL/$url_path" "$dst"; then
        printf 'Could not download %s/%s.\n' "$RAW_URL" "$url_path" >&2
        exit 1
    fi
}

install_file "$STATUSLINE_SRC" "statusline.sh" "$STATUSLINE_DST"
install_file "$NOTIFY_SRC" "hooks/notify.sh" "$NOTIFY_DST"
chmod +x "$STATUSLINE_DST" "$NOTIFY_DST" || exit 1

# Generate the notification logo (PNG) from the local Claude.app icon, so
# desktop alerts carry the Claude mark. macOS only; a .icns can suppress the
# banner, so we convert to PNG with sips. Degrades to no-icon if unavailable.
CLAUDE_ICNS="/Applications/Claude.app/Contents/Resources/electron.icns"
LOGO_DST="$INSTALL_DIR/claude-logo.png"
if command -v sips >/dev/null 2>&1 && [ -f "$CLAUDE_ICNS" ]; then
    sips -s format png "$CLAUDE_ICNS" --out "$LOGO_DST" >/dev/null 2>&1 || rm -f "$LOGO_DST"
fi

# macOS: build a Claude-branded notifier app so desktop alerts show the Claude
# logo. A notification shows the icon of the app that POSTS it; terminal-
# notifier's -sender (the only other way to set the icon) hangs for Claude's
# bundle id, so we post through a rebranded copy of terminal-notifier whose own
# icon is the Claude mark. Degrades silently to the plain notifier otherwise.
NOTIFIER_APP="$INSTALL_DIR/ClaudePulse.app"
build_macos_notifier() {
    [ "$(uname -s)" = "Darwin" ] || return 0
    [ -f "$CLAUDE_ICNS" ] || return 0
    command -v codesign >/dev/null 2>&1 || return 0
    tn=$(command -v terminal-notifier 2>/dev/null) || return 0
    [ -n "$tn" ] || return 0
    tn=$(resolve_link "$tn")

    app_src=""
    for cand in \
        "$(dirname "$(dirname "$tn")")/terminal-notifier.app" \
        "${tn%/Contents/MacOS/*}"; do
        if [ -d "$cand" ] && [ -x "$cand/Contents/MacOS/terminal-notifier" ]; then
            app_src=$cand; break
        fi
    done
    [ -n "$app_src" ] || return 0

    rm -rf "$NOTIFIER_APP"
    cp -R "$app_src" "$NOTIFIER_APP" 2>/dev/null || return 0

    plist="$NOTIFIER_APP/Contents/Info.plist"
    icon_file=$(defaults read "$plist" CFBundleIconFile 2>/dev/null || echo "Terminal")
    case "$icon_file" in *.icns) : ;; *) icon_file="$icon_file.icns" ;; esac
    cp "$CLAUDE_ICNS" "$NOTIFIER_APP/Contents/Resources/$icon_file" 2>/dev/null || true
    defaults write "$plist" CFBundleIdentifier "com.claudepulse.notifier" 2>/dev/null || true
    defaults write "$plist" CFBundleName "Claude Code" 2>/dev/null || true
    defaults write "$plist" CFBundleDisplayName "Claude Code" 2>/dev/null || true
    plutil -convert xml1 "$plist" 2>/dev/null || true

    # Re-sign (modifying the bundle broke the original signature) or bail.
    if ! codesign --force --deep --sign - "$NOTIFIER_APP" >/dev/null 2>&1; then
        rm -rf "$NOTIFIER_APP"; return 0
    fi
    lsr="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
    [ -x "$lsr" ] && "$lsr" -f "$NOTIFIER_APP" >/dev/null 2>&1
    killall iconservicesagent >/dev/null 2>&1 || true
}
build_macos_notifier

merge_settings() {
    if command -v python3 >/dev/null 2>&1; then
        SETTINGS_FILE=$SETTINGS_FILE \
        STATUSLINE_DST=$STATUSLINE_DST \
        NOTIFY_DST=$NOTIFY_DST \
        PREV_STATUSLINE_FILE=$PREV_STATUSLINE_FILE \
        python3 - <<'PY'
from pathlib import Path
import json, os

path = Path(os.environ["SETTINGS_FILE"])
statusline = os.environ["STATUSLINE_DST"]
notify = os.environ["NOTIFY_DST"]
prev_file = Path(os.environ["PREV_STATUSLINE_FILE"])

try:
    data = json.loads(path.read_text()) if path.exists() else {}
except Exception:
    # Never destroy an unparseable file silently — back it up first.
    if path.exists():
        path.rename(path.with_suffix(".json.bak"))
    data = {}
if not isinstance(data, dict):
    data = {}

# ── statusLine ───────────────────────────────────────────────────────────────
# Back up any pre-existing status line that isn't ours, so uninstall (or the
# `--statusline` revert) can restore it. We only capture a non-pulse status
# line, so re-running install never overwrites the saved original.
existing_sl = data.get("statusLine")
if isinstance(existing_sl, dict) and existing_sl.get("command") != statusline:
    prev_file.write_text(json.dumps(existing_sl, indent=2) + "\n")

data["statusLine"] = {
    "type": "command",
    "command": statusline,
    "padding": 0,
}

# ── hooks (Stop, Notification) ────────────────────────────────────────────────
hooks = data.setdefault("hooks", {})
if not isinstance(hooks, dict):
    hooks = {}
    data["hooks"] = hooks

def is_pulse_handler(item):
    return isinstance(item, dict) and item.get("command") == notify

def is_pulse_group(item):
    return (
        isinstance(item, dict)
        and isinstance(item.get("hooks"), list)
        and any(is_pulse_handler(h) for h in item["hooks"])
    )

def pulse_group():
    return {"hooks": [{"type": "command", "command": notify, "timeout": 5}]}

for event in ("Stop", "Notification"):
    entries = hooks.get(event)
    if not isinstance(entries, list):
        entries = []
    # Drop any prior claude-pulse entries so re-running stays idempotent.
    entries = [e for e in entries if not is_pulse_handler(e) and not is_pulse_group(e)]
    entries.append(pulse_group())
    hooks[event] = entries

path.write_text(json.dumps(data, indent=2) + "\n")
print("ok")
PY
    else
        if [ ! -f "$SETTINGS_FILE" ]; then
            cat > "$SETTINGS_FILE" <<EOF
{
  "statusLine": {
    "type": "command",
    "command": "$STATUSLINE_DST",
    "padding": 0
  },
  "hooks": {
    "Stop": [
      { "hooks": [ { "type": "command", "command": "$NOTIFY_DST", "timeout": 5 } ] }
    ],
    "Notification": [
      { "hooks": [ { "type": "command", "command": "$NOTIFY_DST", "timeout": 5 } ] }
    ]
  }
}
EOF
        else
            printf '\nPython 3 was not found and %s already exists.\n' "$SETTINGS_FILE" >&2
            printf 'Merge these blocks into it manually (see settings.example.json):\n' >&2
            printf '  statusLine.command -> %s\n' "$STATUSLINE_DST" >&2
            printf '  hooks.Stop / hooks.Notification -> %s\n' "$NOTIFY_DST" >&2
            return 1
        fi
    fi
}

merge_settings || true

if command -v claude >/dev/null 2>&1; then
    claude_version=$(claude --version 2>/dev/null || printf 'unknown')
else
    claude_version="not found on PATH"
fi

printf '\nclaude-pulse installed.\n\n'
printf 'Installed files:\n'
printf '  %s\n' "$STATUSLINE_DST"
printf '  %s\n\n' "$NOTIFY_DST"
printf 'Wired into:\n'
printf '  %s  (statusLine + hooks.Stop + hooks.Notification)\n\n' "$SETTINGS_FILE"
printf 'Claude Code version: %s\n\n' "$claude_version"
if [ -f "$PREV_STATUSLINE_FILE" ]; then
    printf 'Your previous status line was saved. Restore it any time with:\n'
    printf '  %s/uninstall.sh --statusline\n\n' "$SCRIPT_DIR"
fi
printf 'Restart Claude Code (or start a new session) to see the status line.\n'
printf 'Test the notification hook with:\n'
printf '  echo '\''{"hook_event_name":"Stop"}'\'' | %s\n' "$NOTIFY_DST"

exit 0
