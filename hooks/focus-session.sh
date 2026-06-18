#!/bin/sh
#
# claude-pulse — focus the terminal tab/window whose TTY matches $1.
# Run by terminal-notifier's -execute when you click a claude-pulse notification,
# so clicking jumps you straight back to the exact session that pinged you.
# macOS, Terminal.app + iTerm2. No-ops quietly anywhere else.

[ -n "${1:-}" ] || exit 0
tty=$1
case "$tty" in /dev/*) : ;; *) tty="/dev/$tty" ;; esac

# Terminal.app: select the matching tab, raise its window, activate.
osascript <<OSA >/dev/null 2>&1
tell application "Terminal"
  repeat with w in windows
    repeat with t in tabs of w
      if tty of t is "$tty" then
        set selected of t to true
        set frontmost of w to true
        activate
        return
      end if
    end repeat
  end repeat
end tell
OSA

# iTerm2: select the matching session/tab/window, activate.
osascript <<OSA >/dev/null 2>&1
tell application "iTerm2"
  repeat with w in windows
    repeat with t in tabs of w
      repeat with s in sessions of t
        if tty of s is "$tty" then
          tell s to select
          tell t to select
          tell w to select
          activate
          return
        end if
      end repeat
    end repeat
  end repeat
end tell
OSA

exit 0
