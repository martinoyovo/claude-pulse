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
# The notification mirrors Claude.app's structure: the TITLE is the project
# folder name (so you can tell which session is waiting when several are open),
# and the MESSAGE is the status.
#
# Configuration (environment variables):
#   CLAUDE_PULSE_NOTIFY        Backend: auto (default), terminal-notifier,
#                              alerter, notify-send, osa, osc9, bell, off.
#   CLAUDE_PULSE_NOTIFY_TITLE  Override the title (default: project folder name).
#   CLAUDE_PULSE_NOTIFY_ICON   PNG path for terminal-notifier / notify-send.
#   CLAUDE_PULSE_NOTIFY_SENDER macOS bundle id for terminal-notifier (opt-in).

payload=$(cat 2>/dev/null) || payload=
[ -n "$payload" ] || exit 0

# Hooks are not supported on Windows shells.
case "$(uname -s 2>/dev/null)" in
    CYGWIN*|MINGW*|MSYS*|Windows_NT*) exit 0 ;;
esac

# Where this script lives, so we can find a bundled logo next to it.
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd) || SCRIPT_DIR=
# Load user config (sourced; survives `claude-pulse update`).
[ -n "${SCRIPT_DIR:-}" ] && [ -f "$SCRIPT_DIR/config.sh" ] && . "$SCRIPT_DIR/config.sh"

# ─── Parse the event name (jq → python3 → sed fallback) ──────────────────────
event=
detail=
cwd=
transcript=
if command -v jq >/dev/null 2>&1; then
    event=$(printf '%s' "$payload" | jq -r '.hook_event_name // ""' 2>/dev/null) || event=
    detail=$(printf '%s' "$payload" | jq -r '.message // ""' 2>/dev/null) || detail=
    cwd=$(printf '%s' "$payload" | jq -r '.cwd // .workspace.current_dir // ""' 2>/dev/null) || cwd=
    transcript=$(printf '%s' "$payload" | jq -r '.transcript_path // ""' 2>/dev/null) || transcript=
fi

if [ -z "$cwd" ]; then
    cwd=$(printf '%s' "$payload" |
        sed -n 's/.*"cwd"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | sed -n '1p')
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

# ─── Title: session title → project folder name (like Claude.app) ────────────
# Prefer the conversation's custom title (set in the transcript), so you can
# tell which session pinged you; fall back to the folder name.
session_title=
if [ -n "$transcript" ] && [ -f "$transcript" ] && command -v jq >/dev/null 2>&1; then
    title_line=$(grep '"type":"custom-title"' "$transcript" 2>/dev/null | tail -n 1)
    [ -n "$title_line" ] && session_title=$(printf '%s' "$title_line" | jq -r '.customTitle // ""' 2>/dev/null)
fi

if [ -n "${CLAUDE_PULSE_NOTIFY_TITLE:-}" ]; then
    title="$CLAUDE_PULSE_NOTIFY_TITLE"
elif [ -n "$session_title" ]; then
    title="$session_title"
elif [ -n "$cwd" ]; then
    title=$(basename -- "$cwd")
else
    title="Claude Code"
fi

# ─── Map event → message ─────────────────────────────────────────────────────
case "$event" in
    Stop|SubagentStop) message="Claude Code is waiting for your input" ;;
    Notification)
        # Claude Code's idle reminder ("Claude is waiting for your input"), sent
        # ~60s after a turn ends, DUPLICATES our Stop notification (which already
        # fired the moment the turn finished). Skip it by default; still deliver
        # permission prompts and other notifications. Set CLAUDE_PULSE_NOTIFY_IDLE=1
        # to keep the idle reminder too.
        if [ "${CLAUDE_PULSE_NOTIFY_IDLE:-0}" != "1" ]; then
            case "$detail" in
                *"waiting for your input"*) exit 0 ;;
            esac
        fi
        # Otherwise (e.g. a permission prompt) prefer the payload text, rebranding
        # a leading bare "Claude" to "Claude Code".
        if [ -n "$detail" ]; then
            case "$detail" in
                "Claude Code"*) message="$detail" ;;
                "Claude "*)     message="Claude Code ${detail#Claude }" ;;
                *)              message="$detail" ;;
            esac
        else
            message="Claude Code needs your attention"
        fi
        ;;
    *) exit 0 ;;
esac

# ─── Skip when this exact terminal window/tab is focused (macOS) ─────────────
# If the specific terminal tab running this Claude Code session is the focused
# window, you can already see the result — so don't alert. We find the host
# terminal app AND this session's TTY from the hook's own process tree, then ask
# the terminal which tab is frontmost and compare TTYs. So: claude's own tab
# focused → skip; a DIFFERENT tab/window, or another app entirely → notify.
# Per-window precision works on Terminal.app and iTerm2. Fails OPEN (any
# uncertainty → still notify). Disable with CLAUDE_PULSE_NOTIFY_SKIP_FOCUSED=0.
if [ "${CLAUDE_PULSE_NOTIFY_SKIP_FOCUSED:-1}" != "0" ] \
   && [ "$(uname -s 2>/dev/null)" = "Darwin" ] \
   && command -v lsappinfo >/dev/null 2>&1; then
    host_app=""; my_tty=""
    pid=$$; n=0
    while [ "$n" -lt 20 ]; do
        exe=$(ps -o comm= -p "$pid" 2>/dev/null)
        case "$exe" in */*.app/Contents/MacOS/*) host_app="${exe%/Contents/MacOS/*}" ;; esac
        tt=$(ps -o tty= -p "$pid" 2>/dev/null | tr -d ' ')
        case "$tt" in ttys*) [ -z "$my_tty" ] && my_tty="$tt" ;; esac
        ppid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
        { [ -z "$ppid" ] || [ "$ppid" -le 1 ]; } && break
        pid=$ppid; n=$(( n + 1 ))
    done

    host_bid=""
    [ -n "$host_app" ] && [ -f "$host_app/Contents/Info.plist" ] \
        && host_bid=$(defaults read "$host_app/Contents/Info.plist" CFBundleIdentifier 2>/dev/null)
    front_bid=$(lsappinfo info -only bundleID "$(lsappinfo front 2>/dev/null)" 2>/dev/null \
                  | sed 's/.*"\(.*\)".*/\1/' | grep -v '^$' | tail -1)

    # Only consider skipping if the terminal hosting this session is frontmost.
    if [ -n "$host_bid" ] && [ "$host_bid" = "$front_bid" ]; then
        front_tty=""
        case "$host_bid" in
            com.apple.Terminal)
                front_tty=$(osascript -e 'tell application "Terminal" to get tty of selected tab of front window' 2>/dev/null) ;;
            com.googlecode.iterm2)
                front_tty=$(osascript -e 'tell application "iTerm2" to tell current session of current window to get tty' 2>/dev/null) ;;
        esac
        if [ -n "$front_tty" ] && [ -n "$my_tty" ]; then
            # Per-window precision: skip ONLY if the focused tab is this session's.
            [ "$front_tty" = "/dev/$my_tty" ] && exit 0
            # else: a different tab/window of the same terminal → fall through, notify.
        else
            # Non-scriptable terminal (or no TTY): host app is frontmost → skip.
            exit 0
        fi
    fi
fi

# ─── Notifier backends ───────────────────────────────────────────────────────
notify_icon() {
    # Manual override only (a PNG — NOT .icns, which can suppress the banner on
    # recent macOS). The macOS logo comes from the bundled ClaudePulse.app, not
    # from here; this is mainly useful for notify-send on Linux.
    if [ -n "${CLAUDE_PULSE_NOTIFY_ICON:-}" ] && [ -f "$CLAUDE_PULSE_NOTIFY_ICON" ]; then
        printf '%s' "$CLAUDE_PULSE_NOTIFY_ICON"; return 0
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
    # Prefer the bundled Claude-branded notifier (its own icon is the Claude
    # logo), built by install.sh. Fall back to the system terminal-notifier.
    tn=""
    if [ -n "${SCRIPT_DIR:-}" ] && [ -x "$SCRIPT_DIR/ClaudePulse.app/Contents/MacOS/terminal-notifier" ]; then
        tn="$SCRIPT_DIR/ClaudePulse.app/Contents/MacOS/terminal-notifier"
    elif command -v terminal-notifier >/dev/null 2>&1; then
        tn="terminal-notifier"
    else
        return 1
    fi
    sender=$(notify_sender || printf '')
    # Build the args. Default is the bare, proven-reliable form: just a title
    # and message. Everything else is opt-in because each one can stop the
    # banner from showing on recent macOS:
    #   -group   coalesces repeats — a new one silently REPLACES the previous,
    #            so no banner pops (this is why "Claude finished" never showed).
    #   -appIcon with an .icns can suppress the banner.
    #   -sender  HANGS indefinitely.
    # Run synchronously (no `&`): a backgrounded notifier gets reaped when the
    # hook exits, before macOS posts it. terminal-notifier returns right after
    # posting (no -wait), so this is fast and within the hook timeout.
    set -- -title "$title" -message "$message"
    [ -n "${CLAUDE_PULSE_NOTIFY_GROUP:-}" ] && set -- "$@" -group "$CLAUDE_PULSE_NOTIFY_GROUP"
    # The bundled app already carries the Claude icon. Only the plain system
    # notifier needs an explicit -appIcon (and only where the backend honors it).
    if [ "$tn" = "terminal-notifier" ]; then
        icon=$(notify_icon || printf '')
        [ -n "$icon" ] && set -- "$@" -appIcon "$icon"
    fi
    [ -n "$sender" ] && set -- "$@" -sender "$sender"
    "$tn" "$@" >/dev/null 2>&1
    return 0
}

notify_alerter() {
    command -v alerter >/dev/null 2>&1 || return 1
    alerter -title "$title" -message "$message" \
        -group "claude-pulse" >/dev/null 2>&1 &
    return 0
}

notify_send() {
    command -v notify-send >/dev/null 2>&1 || return 1
    icon=$(notify_icon || printf '')
    if [ -n "$icon" ]; then
        notify-send -a "Claude Code" -i "$icon" "$title" "$message" >/dev/null 2>&1
    else
        notify-send -a "Claude Code" "$title" "$message" >/dev/null 2>&1
    fi
    return 0
}

notify_osa() {
    command -v osascript >/dev/null 2>&1 || return 1
    osascript -e "display notification \"$message\" with title \"$title\"" >/dev/null 2>&1
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
