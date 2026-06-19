#!/usr/bin/env bash
#
# claude-pulse — status line for the Claude Code CLI.
#
# Claude Code pipes a JSON object on STDIN every render; the FIRST line we print
# becomes the status bar. We show:
#   model display_name · cwd (basename) · git branch (+dirty) · context % · cost
#
# Claude Code does NOT report context-window usage in the payload, so we read it
# from the session transcript (the last assistant turn's token usage).
#
# Dependencies: bash + jq (git optional). Degrades gracefully when fields,
# the transcript, jq, or git are missing.
#
# Configuration (environment variables):
#   CLAUDE_PULSE_NERD=1            Use Nerd Font glyphs instead of plain labels.
#   CLAUDE_PULSE_CONTEXT_LIMIT=N   Override the context-window size (tokens).
#   CLAUDE_PULSE_HIDE=a,b,...      Comma list of segments to hide:
#                                  model,dir,branch,context,cost
#   NO_COLOR=1                     Disable ANSI colors entirely.

set -uo pipefail

INPUT_JSON=$(cat 2>/dev/null) || INPUT_JSON=""

# Load user config (sourced; survives `claude-pulse update`). Sets CLAUDE_PULSE_*.
SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd)
[ -n "${SELF_DIR:-}" ] && [ -f "$SELF_DIR/config.sh" ] && . "$SELF_DIR/config.sh"

# ─── ANSI helpers ────────────────────────────────────────────────────────────
if [ -n "${NO_COLOR:-}" ]; then
  R="" B="" D="" I=""
  C_MODEL="" C_DIR="" C_BRANCH="" C_DIRTY="" C_COST="" C_SEP="" C_MODE=""
  C_CTX_LOW="" C_CTX_MID="" C_CTX_HIGH="" C_BAR_EMPTY=""
else
  R=$'\033[0m'; B=$'\033[1m'; D=$'\033[2m'; I=$'\033[3m'
  C_MODE=$'\033[38;5;141m' # purple (plan badge)
  C_MODEL=$'\033[95m'      # bright magenta
  C_DIR=$'\033[96m'        # bright cyan
  C_BRANCH=$'\033[94m'     # bright blue
  C_DIRTY=$'\033[93m'      # bright yellow
  C_COST=$'\033[92m'       # bright green
  C_SEP=$'\033[90m'        # gray
  C_CTX_LOW=$'\033[32m'    # green
  C_CTX_MID=$'\033[93m'    # bright yellow
  C_CTX_HIGH=$'\033[91m'   # bright red
  C_BAR_EMPTY=""           # default fg — adapts to light/dark (90 washed out on light)
fi

# ─── Glyphs (Nerd Font opt-in, plain by default) ─────────────────────────────
if [ "${CLAUDE_PULSE_NERD:-0}" = "1" ]; then
  # Nerd Font glyphs — crisp, but need a Nerd Font installed + selected.
  G_MODEL=" "
  G_DIR=" "
  G_BRANCH=" "
  G_CTX="󰓅 "
  G_COST=" "
  G_TOOL=" "
  G_DUR=" "
elif [ "${CLAUDE_PULSE_EMOJI:-0}" = "1" ]; then
  # Emoji — render on any terminal with zero setup (no font needed).
  G_MODEL="🤖 "
  G_DIR="📁 "
  G_BRANCH="🌿 "
  G_CTX="📊 "
  G_COST="💰 "
  G_TOOL="🛠️ "
  G_DUR="⏱️ "
elif [ "${CLAUDE_PULSE_SYMBOLS:-0}" = "1" ]; then
  # Plain-text Unicode symbols — monochrome, no special font, no emoji.
  # Widely supported in standard terminal fonts (not Nerd Font glyphs).
  G_MODEL="✦ "
  G_DIR="▸ "
  G_BRANCH="⎇ "
  G_CTX="▦ "
  G_COST=""
  G_TOOL="⚙ "
  G_DUR="◷ "
else
  # Plain — no icons, universally renderable text.
  G_MODEL=""
  G_DIR=""
  G_BRANCH=""
  G_CTX=""
  G_COST=""
  G_TOOL=""
  G_DUR=""
fi

SEP="${C_SEP} │ ${R}"

# ─── Single jq pass over the payload ─────────────────────────────────────────
if command -v jq >/dev/null 2>&1 && [ -n "$INPUT_JSON" ]; then
  {
    read -r MODEL
    read -r MODEL_ID
    read -r CWD
    read -r TRANSCRIPT
    read -r COST
    read -r LINES_ADD
    read -r LINES_DEL
    read -r DURATION_MS
  } <<EOF
$(printf '%s' "$INPUT_JSON" | jq -r '
    (.model.display_name // .model.id // ""),
    (.model.id // ""),
    (.workspace.current_dir // .cwd // ""),
    (.transcript_path // ""),
    (.cost.total_cost_usd // 0),
    (.cost.total_lines_added // 0),
    (.cost.total_lines_removed // 0),
    (.cost.total_duration_ms // 0)
  ' 2>/dev/null || printf '\n\n\n\n0\n0\n0\n0\n')
EOF
else
  MODEL=""; MODEL_ID=""; CWD="$PWD"; TRANSCRIPT=""; COST=0; LINES_ADD=0; LINES_DEL=0; DURATION_MS=0
fi

[ -n "$CWD" ] || CWD="$PWD"

# Which segments are hidden?
is_hidden() {
  case ",${CLAUDE_PULSE_HIDE:-}," in
    *",$1,"*) return 0 ;;
    *) return 1 ;;
  esac
}

# ─── Segment: model ──────────────────────────────────────────────────────────
SEG_MODEL=""
if [ -n "$MODEL" ] && ! is_hidden model; then
  SEG_MODEL="${C_MODEL}${B}${G_MODEL}${MODEL}${R}"
fi

# ─── Segment: directory (basename) ───────────────────────────────────────────
SEG_DIR=""
if [ -n "$CWD" ] && ! is_hidden dir; then
  base=$(basename -- "$CWD")
  [ "$CWD" = "$HOME" ] && base="~"
  SEG_DIR="${C_DIR}${G_DIR}${base}${R}"
fi

# ─── Segment: git branch (+ dirty) ───────────────────────────────────────────
SEG_BRANCH=""
if ! is_hidden branch && command -v git >/dev/null 2>&1; then
  branch=$(git -C "$CWD" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
  if [ -n "$branch" ]; then
    if [ "$branch" = "HEAD" ]; then
      # Detached: show short commit hash instead.
      branch=$(git -C "$CWD" rev-parse --short HEAD 2>/dev/null || echo "HEAD")
    fi
    if [ -n "$(git -C "$CWD" status --porcelain 2>/dev/null)" ]; then
      SEG_BRANCH="${C_BRANCH}${G_BRANCH}${branch}${C_DIRTY}*${R}"
    else
      SEG_BRANCH="${C_BRANCH}${G_BRANCH}${branch}${R}"
    fi
  fi
fi

# ─── Segment: context-window usage ───────────────────────────────────────────
SEG_CTX=""
if ! is_hidden context; then
  # Default limit: 200k, or 1M for 1M-context models (id contains "1m").
  limit=${CLAUDE_PULSE_CONTEXT_LIMIT:-0}
  if [ "$limit" -le 0 ] 2>/dev/null; then
    case "$MODEL_ID" in
      *1m*|*1M*|*\[1m\]*) limit=1000000 ;;
      *) limit=200000 ;;
    esac
  fi

  used=0
  if [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ] && command -v jq >/dev/null 2>&1; then
    # Fast path: grep the last line carrying a usage block, parse just that line.
    usage_line=$(grep '"usage"' "$TRANSCRIPT" 2>/dev/null | tail -n 1)
    if [ -n "$usage_line" ]; then
      used=$(printf '%s' "$usage_line" | jq -r '
        (.message.usage // .usage // {}) |
        ((.input_tokens // 0)
          + (.cache_read_input_tokens // 0)
          + (.cache_creation_input_tokens // 0))
      ' 2>/dev/null || echo 0)
    fi
  fi
  [ -n "$used" ] && [ "$used" -ge 0 ] 2>/dev/null || used=0

  # Safety net: a model id doesn't always reveal a 1M-context window, which
  # would peg the bar at 100% (stuck) once usage passes 200k. Observed usage is
  # ground truth — if it exceeds the assumed limit, the real window must be
  # larger, so step up to 1M (unless a limit was set explicitly).
  if [ -z "${CLAUDE_PULSE_CONTEXT_LIMIT:-}" ] && [ "$used" -gt "$limit" ] && [ "$limit" -lt 1000000 ]; then
    limit=1000000
  fi

  if [ "$used" -gt 0 ] 2>/dev/null; then
    pct=$(( used * 100 / limit ))
    [ "$pct" -gt 100 ] && pct=100

    if   [ "$pct" -ge 80 ]; then ctx_color="$C_CTX_HIGH"
    elif [ "$pct" -ge 50 ]; then ctx_color="$C_CTX_MID"
    else                         ctx_color="$C_CTX_LOW"
    fi

    # Smooth block bar. Each cell holds 8 sub-levels (⅛-block glyphs), so the
    # bar slides with small changes instead of jumping a whole cell at a time.
    len=${CLAUDE_PULSE_BAR_WIDTH:-10}
    eighths=$(( pct * len * 8 / 100 ))
    full=$(( eighths / 8 ))
    rem=$(( eighths % 8 ))
    bar=""
    i=0
    while [ "$i" -lt "$len" ]; do
      if [ "$i" -lt "$full" ]; then
        bar="${bar}${ctx_color}█${R}"
      elif [ "$i" -eq "$full" ] && [ "$rem" -gt 0 ]; then
        case "$rem" in
          1) ch="▏" ;; 2) ch="▎" ;; 3) ch="▍" ;; 4) ch="▌" ;;
          5) ch="▋" ;; 6) ch="▊" ;; 7) ch="▉" ;;
        esac
        bar="${bar}${ctx_color}${ch}${R}"
      else
        bar="${bar}${C_BAR_EMPTY}░${R}"
      fi
      i=$(( i + 1 ))
    done

    # Human-readable token counts, e.g. 368K / 1.0M.
    human() {
      n=$1
      if   [ "$n" -ge 1000000 ]; then printf '%d.%dM' "$((n/1000000))" "$(((n%1000000)/100000))"
      elif [ "$n" -ge 1000 ];    then printf '%dK' "$((n/1000))"
      else                            printf '%d' "$n"
      fi
    }
    counts=""
    if [ "${CLAUDE_PULSE_TOKENS:-1}" != "0" ]; then
      # Default fg (no dim) — dim washed out on light themes.
      counts=" ($(human "$used")/$(human "$limit"))"
    fi
    SEG_CTX="${ctx_color}${G_CTX}${R}${bar} ${ctx_color}${pct}%${R}${counts}"
  fi
fi

# ─── Segment: session cost ───────────────────────────────────────────────────
SEG_COST=""
if ! is_hidden cost; then
  cost_fmt=$(LC_NUMERIC=C printf '%.2f' "${COST:-0}" 2>/dev/null || echo "0.00")
  SEG_COST="${C_COST}${G_COST}\$${cost_fmt}${R}"
fi

# ─── Segment: lines changed this session (+added / −removed) ─────────────────
SEG_LINES=""
if ! is_hidden lines; then
  [ -n "$LINES_ADD" ] && [ "$LINES_ADD" -ge 0 ] 2>/dev/null || LINES_ADD=0
  [ -n "$LINES_DEL" ] && [ "$LINES_DEL" -ge 0 ] 2>/dev/null || LINES_DEL=0
  if [ "$LINES_ADD" -gt 0 ] || [ "$LINES_DEL" -gt 0 ] 2>/dev/null; then
    SEG_LINES="${C_CTX_LOW}+${LINES_ADD}${R}${C_SEP}/${R}${C_CTX_HIGH}−${LINES_DEL}${R}"
  fi
fi

# ─── Segment: session mode (plan / auto-accept / bypass) ─────────────────────
# A real "state" signal: Claude Code records the active permission mode as
# "permissionMode" on transcript entries (values: default, auto, plan,
# bypassPermissions). The {"type":"mode"} entries are unrelated and stay
# "normal", so we read the most recent permissionMode. Shown only when NOT the
# default, so it's silent during ordinary work and pops when noteworthy.
SEG_MODE=""
if ! is_hidden mode && [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ]; then
  pmode=$(grep -oE '"permissionMode":"[^"]*"' "$TRANSCRIPT" 2>/dev/null \
            | tail -n 1 | sed 's/.*:"\(.*\)"/\1/')
  case "$pmode" in
    plan)                     SEG_MODE="${C_MODE}${B}◆ PLAN${R}" ;;
    auto|acceptEdits)         SEG_MODE="${C_CTX_MID}${B}◆ AUTO${R}" ;;
    bypassPermissions|bypass) SEG_MODE="${C_CTX_HIGH}${B}◆ BYPASS${R}" ;;
    *) ;;  # default / normal / empty → no badge
  esac
fi

# ─── Segment: tool activity (most-used tool + count) ─────────────────────────
SEG_TOOLS=""
if ! is_hidden tools && [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ] && command -v jq >/dev/null 2>&1; then
  top=$(jq -rc 'select(.type=="assistant") | .message.content[]? | select(.type=="tool_use") | .name' \
          "$TRANSCRIPT" 2>/dev/null | sort | uniq -c | sort -rn | head -n 1)
  if [ -n "$top" ]; then
    t_count=$(printf '%s' "$top" | awk '{print $1}')
    t_name=$(printf '%s' "$top" | awk '{print $2}')
    [ -n "$t_name" ] && SEG_TOOLS="${C_MODE}${G_TOOL}${t_name}${R} ${D}${t_count}${R}"
  fi
fi

# ─── Segment: session duration ───────────────────────────────────────────────
SEG_DURATION=""
if ! is_hidden duration; then
  [ -n "$DURATION_MS" ] && [ "$DURATION_MS" -gt 0 ] 2>/dev/null || DURATION_MS=0
  if [ "$DURATION_MS" -gt 0 ] 2>/dev/null; then
    secs=$(( DURATION_MS / 1000 ))
    if   [ "$secs" -ge 3600 ]; then dur="$(( secs / 3600 ))h$(( (secs % 3600) / 60 ))m"
    elif [ "$secs" -ge 60 ];   then dur="$(( secs / 60 ))m"
    else                            dur="${secs}s"
    fi
    SEG_DURATION="${C_SEP}${G_DUR}${dur}${R}"
  fi
fi

# ─── Assemble (skip empty segments, join with separator) ─────────────────────
out=""
for seg in "$SEG_MODE" "$SEG_MODEL" "$SEG_DIR" "$SEG_BRANCH" "$SEG_TOOLS" "$SEG_LINES" "$SEG_CTX" "$SEG_DURATION" "$SEG_COST"; do
  [ -n "$seg" ] || continue
  if [ -z "$out" ]; then
    out="$seg"
  else
    out="${out}${SEP}${seg}"
  fi
done

printf '%b\n' "$out"
