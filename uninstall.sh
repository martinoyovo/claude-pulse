#!/bin/sh
#
# claude-pulse uninstaller.
#
# Removes the installed scripts and strips claude-pulse's statusLine + hook
# entries from ~/.claude/settings.json, leaving the rest of your config intact.

set -u

CLAUDE_DIR=${CLAUDE_CONFIG_DIR:-"$HOME/.claude"}
INSTALL_DIR="$CLAUDE_DIR/claude-pulse"
SETTINGS_FILE="$CLAUDE_DIR/settings.json"
STATUSLINE_DST="$INSTALL_DIR/statusline.sh"
NOTIFY_DST="$INSTALL_DIR/notify.sh"

if [ -f "$SETTINGS_FILE" ] && command -v python3 >/dev/null 2>&1; then
    SETTINGS_FILE=$SETTINGS_FILE \
    STATUSLINE_DST=$STATUSLINE_DST \
    NOTIFY_DST=$NOTIFY_DST \
    python3 - <<'PY'
from pathlib import Path
import json, os

path = Path(os.environ["SETTINGS_FILE"])
statusline = os.environ["STATUSLINE_DST"]
notify = os.environ["NOTIFY_DST"]

try:
    data = json.loads(path.read_text())
except Exception:
    raise SystemExit(0)
if not isinstance(data, dict):
    raise SystemExit(0)

# Remove our statusLine only if it still points at claude-pulse.
sl = data.get("statusLine")
if isinstance(sl, dict) and sl.get("command") == statusline:
    data.pop("statusLine", None)

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
            entries = [e for e in entries if not is_pulse_handler(e) and not is_pulse_group(e)]
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

rm -rf "$INSTALL_DIR"

printf '\nclaude-pulse uninstalled.\n'
printf 'Removed: %s\n' "$INSTALL_DIR"
printf 'Cleaned claude-pulse entries from: %s\n' "$SETTINGS_FILE"
printf 'Restart Claude Code for the change to take effect.\n'

exit 0
