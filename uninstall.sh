#!/bin/sh
#
# claude-pulse uninstaller / revert.
#
# Usage:
#   uninstall.sh                Remove claude-pulse entirely: strip its
#                               statusLine + hook entries from
#                               ~/.claude/settings.json (restoring your
#                               previous status line if one was saved) and
#                               delete ~/.claude/claude-pulse/.
#
#   uninstall.sh --statusline   Revert ONLY the status line — restore your
#                               previous one (or clear ours) and leave the
#                               notification hook + installed files in place.
#                               Lets you back out the status-line takeover at
#                               any time without losing notifications.

set -u

MODE="all"
case "${1:-}" in
    --statusline|--statusline-only) MODE="statusline" ;;
    -h|--help)
        sed -n '3,16p' "$0" | sed 's/^# \{0,1\}//'
        exit 0 ;;
    "") ;;
    *)
        printf 'Unknown option: %s\n' "$1" >&2
        printf 'Run with --help for usage.\n' >&2
        exit 2 ;;
esac

CLAUDE_DIR=${CLAUDE_CONFIG_DIR:-"$HOME/.claude"}
INSTALL_DIR="$CLAUDE_DIR/claude-pulse"
SETTINGS_FILE="$CLAUDE_DIR/settings.json"
STATUSLINE_DST="$INSTALL_DIR/statusline.sh"
NOTIFY_DST="$INSTALL_DIR/notify.sh"
PREV_STATUSLINE_FILE="$INSTALL_DIR/statusline.prev.json"
NOTIFIER_APP="$INSTALL_DIR/ClaudePulse.app"

if [ -f "$SETTINGS_FILE" ] && command -v python3 >/dev/null 2>&1; then
    MODE=$MODE \
    SETTINGS_FILE=$SETTINGS_FILE \
    STATUSLINE_DST=$STATUSLINE_DST \
    NOTIFY_DST=$NOTIFY_DST \
    PREV_STATUSLINE_FILE=$PREV_STATUSLINE_FILE \
    python3 - <<'PY'
from pathlib import Path
import json, os

mode = os.environ["MODE"]
path = Path(os.environ["SETTINGS_FILE"])
statusline = os.environ["STATUSLINE_DST"]
notify = os.environ["NOTIFY_DST"]
prev_file = Path(os.environ["PREV_STATUSLINE_FILE"])

try:
    data = json.loads(path.read_text())
except Exception:
    raise SystemExit(0)
if not isinstance(data, dict):
    raise SystemExit(0)

# ── statusLine: restore the saved one, else clear ours ────────────────────────
sl = data.get("statusLine")
if isinstance(sl, dict) and sl.get("command") == statusline:
    restored = None
    if prev_file.exists():
        try:
            restored = json.loads(prev_file.read_text())
        except Exception:
            restored = None
    if isinstance(restored, dict):
        data["statusLine"] = restored
    else:
        data.pop("statusLine", None)
    # The backup has now been consumed.
    try:
        prev_file.unlink()
    except OSError:
        pass

# ── hooks: only when fully uninstalling ───────────────────────────────────────
if mode == "all":
    def is_pulse_handler(item):
        return isinstance(item, dict) and item.get("command") == notify

    def is_pulse_group(item):
        return (
            isinstance(item, dict)
            and isinstance(item.get("hooks"), list)
            and any(is_pulse_handler(h) for h in item["hooks"])
        )

    hooks = data.get("hooks")
    if isinstance(hooks, dict):
        for event in ("Stop", "Notification"):
            entries = hooks.get(event)
            if isinstance(entries, list):
                entries = [e for e in entries
                           if not is_pulse_handler(e) and not is_pulse_group(e)]
                if entries:
                    hooks[event] = entries
                else:
                    hooks.pop(event, None)
        if not hooks:
            data.pop("hooks", None)

path.write_text(json.dumps(data, indent=2) + "\n")
print("ok")
PY
else
    printf 'Could not auto-edit %s.\n' "$SETTINGS_FILE" >&2
    printf 'Remove the claude-pulse statusLine and hook entries manually.\n' >&2
fi

if [ "$MODE" = "statusline" ]; then
    printf '\nclaude-pulse status line reverted.\n'
    printf 'Notifications and installed files are left in place.\n'
    printf 'Restart Claude Code for the change to take effect.\n'
    exit 0
fi

# macOS: deregister the bundled notifier app from LaunchServices before deleting
# it, so it doesn't linger as a stale record.
if [ "$(uname -s 2>/dev/null)" = "Darwin" ] && [ -d "$NOTIFIER_APP" ]; then
    lsr="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
    [ -x "$lsr" ] && "$lsr" -u "$NOTIFIER_APP" >/dev/null 2>&1
fi

rm -rf "$INSTALL_DIR"

printf '\nclaude-pulse uninstalled.\n'
printf 'Removed: %s\n' "$INSTALL_DIR"
printf 'Cleaned claude-pulse entries from: %s\n' "$SETTINGS_FILE"
if [ "$(uname -s 2>/dev/null)" = "Darwin" ]; then
    printf 'Note: macOS may keep a "Claude Code" entry under System Settings >\n'
    printf 'Notifications for a while; it is harmless and clears on its own.\n'
fi
printf 'Restart Claude Code for the change to take effect.\n'

exit 0
