#!/bin/sh
#
# claude-pulse — desktop notification hook for the Claude Code CLI.
#
# Claude Code runs configured hooks for lifecycle events and pipes one JSON
# object on STDIN. We fire a quick local alert when Claude finishes a turn
# (Stop) or needs your attention (Notification — e.g. a permission prompt).
#
# Cross-platform: macOS (terminal-notifier / osascript), Linux (notify-send),
# with terminal-bell / OSC-9 / no-op fallbacks.
#
# Configuration (environment variables):
#   CLAUDE_PULSE_NOTIFY        Backend: auto (default), terminal-notifier,
#                              alerter, notify-send, osa, osc9, bell, off.
#   CLAUDE_PULSE_NOTIFY_ICON   Image path for terminal-notifier / notify-send.
#   CLAUDE_PULSE_NOTIFY_SENDER macOS bundle id for terminal-notifier.

payload=$(cat 2>/dev/null) || payload=
[ -n "$payload" ] || exit 0

# Hooks are not supported on Windows shells.
case "$(uname -s 2>/dev/null)" in
    CYGWIN*|MINGW*|MSYS*|Windows_NT*) exit 0 ;;
esac

# ─── Parse the event name (jq → python3 → sed fallback) ──────────────────────
event=
detail=
if command -v jq >/dev/null 2>&1; then
    event=$(printf '%s' "$payload" | jq -r '.hook_event_name // ""' 2>/dev/null) || event=
    detail=$(printf '%s' "$payload" | jq -r '.message // ""' 2>/dev/null) || detail=
fi

if [ -z "$event" ] && command -v python3 >/dev/null 2>&1; then
    event=$(printf '%s' "$payload" | python3 -c '
import json, sys
try:
    data = json.loads(sys.stdin.read() or "{}")
    v = data.get("hook_event_name", "")
    print(v if isinstance(v, str) else "")
except Exception:
    print("")
' 2>/dev/null) || event=
fi

if [ -z "$event" ]; then
    event=$(printf '%s' "$payload" |
        sed -n 's/.*"hook_event_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' |
        sed -n '1p')
fi

# ─── Map event → message ─────────────────────────────────────────────────────
case "$event" in
    Stop|SubagentStop) message="Claude finished" ;;
    Notification)
        # Claude Code sends a human-readable `message` for Notification events
        # (e.g. permission prompts, idle reminders). Prefer it when present.
        if [ -n "$detail" ]; then
            message="$detail"
        else
            message="Claude needs you"
        fi
        ;;
    *) exit 0 ;;
esac

# ─── Notifier backends ───────────────────────────────────────────────────────
notify_icon() {
    if [ -n "${CLAUDE_PULSE_NOTIFY_ICON:-}" ] && [ -f "$CLAUDE_PULSE_NOTIFY_ICON" ]; then
        printf '%s' "$CLAUDE_PULSE_NOTIFY_ICON"; return 0
    fi
    if [ -f "/Applications/Claude.app/Contents/Resources/electron.icns" ]; then
        printf '%s' "/Applications/Claude.app/Contents/Resources/electron.icns"; return 0
    fi
    return 1
}

notify_sender() {
    # `-sender <bundleid>` makes the alert appear *as* that app (and shows its
    # icon), but terminal-notifier HANGS on `-sender` on recent macOS — the
    # process never returns, so the notification never posts and zombie
    # processes pile up. We therefore do NOT auto-use it; it's opt-in only via
    # CLAUDE_PULSE_NOTIFY_SENDER for users on setups where it works. By default
    # we use `-appIcon` (below), which returns cleanly and still shows the
    # Claude icon.
    if [ -n "${CLAUDE_PULSE_NOTIFY_SENDER:-}" ]; then
        printf '%s' "$CLAUDE_PULSE_NOTIFY_SENDER"; return 0
    fi
    return 1
}

notify_terminal_notifier() {
    command -v terminal-notifier >/dev/null 2>&1 || return 1
    icon=$(notify_icon || printf '')
    sender=$(notify_sender || printf '')
    # Run synchronously (no `&`): a hook is a short-lived process, and Claude
    # Code reaps it as soon as it returns. A backgrounded notifier gets killed
    # before macOS posts it — which is why "Claude finished" never showed.
    # terminal-notifier returns immediately after posting (we don't pass -wait),
    # so this is fast and stays within the hook timeout.
    if [ -n "$sender" ]; then
        terminal-notifier -title "Claude Code" -message "$message" \
            -group "claude-pulse" -sender "$sender" >/dev/null 2>&1
        return 0
    fi
    if [ -n "$icon" ]; then
        terminal-notifier -title "Claude Code" -message "$message" \
            -group "claude-pulse" -appIcon "$icon" >/dev/null 2>&1
        return 0
    fi
    terminal-notifier -title "Claude Code" -message "$message" \
        -group "claude-pulse" >/dev/null 2>&1
    return 0
}

notify_alerter() {
    command -v alerter >/dev/null 2>&1 || return 1
    alerter -title "Claude Code" -message "$message" \
        -group "claude-pulse" >/dev/null 2>&1 &
    return 0
}

notify_send() {
    command -v notify-send >/dev/null 2>&1 || return 1
    icon=$(notify_icon || printf '')
    if [ -n "$icon" ]; then
        notify-send -a "Claude Code" -i "$icon" "Claude Code" "$message" >/dev/null 2>&1
    else
        notify-send -a "Claude Code" "Claude Code" "$message" >/dev/null 2>&1
    fi
    return 0
}

notify_osa() {
    command -v osascript >/dev/null 2>&1 || return 1
    osascript -e "display notification \"$message\" with title \"Claude Code\"" >/dev/null 2>&1
    return 0
}

notify_osc9() { printf '\033]9;%s\007' "$message"; }
notify_bell() { printf '\a'; }

case "${CLAUDE_PULSE_NOTIFY:-auto}" in
    off) ;;
    terminal-notifier|notifier) notify_terminal_notifier || notify_osa || notify_osc9 ;;
    alerter) notify_alerter || notify_osa || notify_osc9 ;;
    notify-send) notify_send || notify_osc9 ;;
    osa) notify_osa || notify_osc9 ;;
    osc9) notify_osc9 ;;
    bell) notify_bell ;;
    *)
        notify_terminal_notifier || notify_alerter || notify_send \
            || notify_osa || notify_osc9 || notify_bell
        ;;
esac

exit 0
