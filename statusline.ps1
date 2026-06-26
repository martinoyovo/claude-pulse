#!/usr/bin/env pwsh
#
# claude-pulse - status line for the Claude Code CLI (Windows / PowerShell port).
#
# Claude Code pipes a JSON object on STDIN every render; the FIRST line we print
# becomes the status bar. We show:
#   [mode] model - cwd (basename) - git branch (+dirty) - tools - lines - context % - duration - cost
#
# Claude Code does NOT report context-window usage in the payload, so we read it
# from the session transcript (the last assistant turn's token usage).
#
# This is the Windows counterpart to statusline.sh. It uses the built-in
# ConvertFrom-Json (no jq dependency) and works on Windows PowerShell 5.1+ and
# PowerShell 7+. Degrades gracefully when fields, the transcript, or git are
# missing.
#
# Configuration (environment variables; or a config.ps1 next to this script):
#   CLAUDE_PULSE_NERD=1            Use Nerd Font glyphs instead of plain labels.
#   CLAUDE_PULSE_EMOJI=1           Use emoji glyphs (no special font needed).
#   CLAUDE_PULSE_SYMBOLS=1         Use plain-text Unicode symbols.
#   CLAUDE_PULSE_CONTEXT_LIMIT=N   Override the context-window size (tokens).
#   CLAUDE_PULSE_BAR_WIDTH=N       Context bar width in cells (default 10).
#   CLAUDE_PULSE_TOKENS=0          Hide the (used/limit) token counts.
#   CLAUDE_PULSE_HIDE=a,b,...      Comma list of segments to hide:
#                                  mode,model,dir,branch,tools,lines,context,duration,cost
#   NO_COLOR=1                     Disable ANSI colors entirely.

$ErrorActionPreference = 'SilentlyContinue'

# Glyphs and the smooth block bar are Unicode; force UTF-8 so they don't mojibake.
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

# --- Read the payload from STDIN -------------------------------------------------
$InputJson = ''
try { $InputJson = [Console]::In.ReadToEnd() } catch { $InputJson = '' }

# --- Load user config (dot-sourced; survives `claude-pulse update`) ---------------
$SelfDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$cfg = Join-Path $SelfDir 'config.ps1'
if (Test-Path -LiteralPath $cfg) { . $cfg }

function Env-Val([string]$name) {
    $v = [Environment]::GetEnvironmentVariable($name)
    if ($null -eq $v) { return '' }
    return $v
}

# --- ANSI helpers ----------------------------------------------------------------
$ESC = [char]27
if ((Env-Val 'NO_COLOR') -ne '') {
    $R=''; $B=''; $D=''
    $C_MODE='';$C_MODEL='';$C_DIR='';$C_BRANCH='';$C_DIRTY='';$C_COST='';$C_SEP=''
    $C_CTX_LOW='';$C_CTX_MID='';$C_CTX_HIGH='';$C_BAR_EMPTY=''
} else {
    $R="$ESC[0m"; $B="$ESC[1m"; $D="$ESC[2m"
    $C_MODE="$ESC[38;5;141m"  # purple (plan badge)
    $C_MODEL="$ESC[95m"       # bright magenta
    $C_DIR="$ESC[96m"         # bright cyan
    $C_BRANCH="$ESC[94m"      # bright blue
    $C_DIRTY="$ESC[93m"       # bright yellow
    $C_COST="$ESC[92m"        # bright green
    $C_SEP="$ESC[90m"         # gray
    $C_CTX_LOW="$ESC[32m"     # green
    $C_CTX_MID="$ESC[93m"     # bright yellow
    $C_CTX_HIGH="$ESC[91m"    # bright red
    $C_BAR_EMPTY=''           # default fg - adapts to light/dark
}

# --- Glyphs (Nerd Font opt-in, plain by default) ---------------------------------
if ((Env-Val 'CLAUDE_PULSE_NERD') -eq '1') {
    $G_MODEL=" "; $G_DIR=" "; $G_BRANCH=" "; $G_CTX="󰓅 "; $G_COST=" "; $G_TOOL=" "; $G_DUR=" "
} elseif ((Env-Val 'CLAUDE_PULSE_EMOJI') -eq '1') {
    $G_MODEL="🤖 "; $G_DIR="📁 "; $G_BRANCH="🌿 "; $G_CTX="📊 "; $G_COST="💰 "; $G_TOOL="🛠️ "; $G_DUR="⏱️ "
} elseif ((Env-Val 'CLAUDE_PULSE_SYMBOLS') -eq '1') {
    $G_MODEL="✦ "; $G_DIR="▸ "; $G_BRANCH="⎇ "; $G_CTX="▦ "; $G_COST=""; $G_TOOL="⚙ "; $G_DUR="◷ "
} else {
    $G_MODEL=""; $G_DIR=""; $G_BRANCH=""; $G_CTX=""; $G_COST=""; $G_TOOL=""; $G_DUR=""
}

$SEP = "$C_SEP | $R"

# --- Parse the payload (single ConvertFrom-Json pass) ----------------------------
$MODEL=''; $MODEL_ID=''; $CWD=''; $TRANSCRIPT=''
$COST=0.0; $LINES_ADD=0; $LINES_DEL=0; $DURATION_MS=0
if ($InputJson.Trim().Length -gt 0) {
    try {
        $p = $InputJson | ConvertFrom-Json
        if ($p.model) {
            if ($p.model.display_name) { $MODEL = [string]$p.model.display_name }
            elseif ($p.model.id)       { $MODEL = [string]$p.model.id }
            if ($p.model.id)           { $MODEL_ID = [string]$p.model.id }
        }
        if ($p.workspace -and $p.workspace.current_dir) { $CWD = [string]$p.workspace.current_dir }
        elseif ($p.cwd)                                 { $CWD = [string]$p.cwd }
        if ($p.transcript_path)                         { $TRANSCRIPT = [string]$p.transcript_path }
        if ($p.cost) {
            if ($null -ne $p.cost.total_cost_usd)      { $COST = [double]$p.cost.total_cost_usd }
            if ($null -ne $p.cost.total_lines_added)   { $LINES_ADD = [int]$p.cost.total_lines_added }
            if ($null -ne $p.cost.total_lines_removed) { $LINES_DEL = [int]$p.cost.total_lines_removed }
            if ($null -ne $p.cost.total_duration_ms)   { $DURATION_MS = [long]$p.cost.total_duration_ms }
        }
    } catch {}
}
if ([string]::IsNullOrEmpty($CWD)) { $CWD = (Get-Location).Path }

# Read the transcript once (fast): only the lines we actually need.
$TX_LINES = $null
if ($TRANSCRIPT -and (Test-Path -LiteralPath $TRANSCRIPT)) {
    try { $TX_LINES = [System.IO.File]::ReadAllLines($TRANSCRIPT) } catch { $TX_LINES = $null }
}

function Is-Hidden([string]$name) {
    $h = Env-Val 'CLAUDE_PULSE_HIDE'
    if ([string]::IsNullOrEmpty($h)) { return $false }
    return (",$h," -like "*,$name,*")
}

# Human-readable token counts, e.g. 368K / 1.0M.
function Human([int]$n) {
    if     ($n -ge 1000000) { return "$([int][math]::Floor($n/1000000)).$([int][math]::Floor(($n%1000000)/100000))M" }
    elseif ($n -ge 1000)    { return "$([int][math]::Floor($n/1000))K" }
    else                    { return "$n" }
}

# --- Segment: session mode (plan / auto-accept / bypass) -------------------------
$SEG_MODE = ''
if (-not (Is-Hidden 'mode') -and $TX_LINES) {
    $pmode = ''
    for ($i = $TX_LINES.Length - 1; $i -ge 0; $i--) {
        $m = [regex]::Match($TX_LINES[$i], '"permissionMode":"([^"]*)"')
        if ($m.Success) { $pmode = $m.Groups[1].Value; break }
    }
    switch ($pmode) {
        'plan'              { $SEG_MODE = "$C_MODE$B◆ PLAN$R" }
        'auto'              { $SEG_MODE = "$C_CTX_MID$B◆ AUTO$R" }
        'acceptEdits'       { $SEG_MODE = "$C_CTX_MID$B◆ AUTO$R" }
        'bypassPermissions' { $SEG_MODE = "$C_CTX_HIGH$B◆ BYPASS$R" }
        'bypass'            { $SEG_MODE = "$C_CTX_HIGH$B◆ BYPASS$R" }
    }
}

# --- Segment: model --------------------------------------------------------------
$SEG_MODEL = ''
if ($MODEL -and -not (Is-Hidden 'model')) {
    $SEG_MODEL = "$C_MODEL$B$G_MODEL$MODEL$R"
}

# --- Segment: directory (basename) -----------------------------------------------
$SEG_DIR = ''
if ($CWD -and -not (Is-Hidden 'dir')) {
    $base = Split-Path -Leaf $CWD
    if ($CWD -eq $HOME) { $base = '~' }
    $SEG_DIR = "$C_DIR$G_DIR$base$R"
}

# --- Segment: git branch (+ dirty) -----------------------------------------------
$SEG_BRANCH = ''
if (-not (Is-Hidden 'branch') -and (Get-Command git -ErrorAction SilentlyContinue)) {
    $branch = (git -C "$CWD" rev-parse --abbrev-ref HEAD 2>$null)
    if ($branch) {
        if ($branch -eq 'HEAD') {
            $short = (git -C "$CWD" rev-parse --short HEAD 2>$null)
            if ($short) { $branch = $short } else { $branch = 'HEAD' }
        }
        $dirty = (git -C "$CWD" status --porcelain 2>$null)
        if ($dirty) {
            $SEG_BRANCH = "$C_BRANCH$G_BRANCH$branch$C_DIRTY*$R"
        } else {
            $SEG_BRANCH = "$C_BRANCH$G_BRANCH$branch$R"
        }
    }
}

# --- Segment: tool activity (most-used tool + count) -----------------------------
$SEG_TOOLS = ''
if (-not (Is-Hidden 'tools') -and $TX_LINES) {
    $counts = @{}
    foreach ($line in $TX_LINES) {
        if ($line -notlike '*"tool_use"*') { continue }
        try {
            $obj = $line | ConvertFrom-Json
            if ($obj.type -ne 'assistant') { continue }
            foreach ($c in $obj.message.content) {
                if ($c.type -eq 'tool_use' -and $c.name) {
                    if ($counts.ContainsKey($c.name)) { $counts[$c.name]++ } else { $counts[$c.name] = 1 }
                }
            }
        } catch {}
    }
    if ($counts.Count -gt 0) {
        $top = $counts.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 1
        $SEG_TOOLS = "$C_MODE$G_TOOL$($top.Key)$R $D$($top.Value)$R"
    }
}

# --- Segment: lines changed this session (+added / -removed) ---------------------
$SEG_LINES = ''
if (-not (Is-Hidden 'lines')) {
    if ($LINES_ADD -lt 0) { $LINES_ADD = 0 }
    if ($LINES_DEL -lt 0) { $LINES_DEL = 0 }
    if ($LINES_ADD -gt 0 -or $LINES_DEL -gt 0) {
        $SEG_LINES = "$C_CTX_LOW+$LINES_ADD$R$C_SEP/$R$C_CTX_HIGH−$LINES_DEL$R"
    }
}

# --- Segment: context-window usage -----------------------------------------------
$SEG_CTX = ''
if (-not (Is-Hidden 'context')) {
    $explicitLimit = Env-Val 'CLAUDE_PULSE_CONTEXT_LIMIT'
    $limit = 0
    if ($explicitLimit -match '^\d+$') { $limit = [int]$explicitLimit }
    if ($limit -le 0) {
        if ($MODEL_ID -match '(?i)1m|\[1m\]') { $limit = 1000000 } else { $limit = 200000 }
    }

    $used = 0
    if ($TX_LINES) {
        $usageLine = $null
        for ($i = $TX_LINES.Length - 1; $i -ge 0; $i--) {
            if ($TX_LINES[$i] -like '*"usage"*') { $usageLine = $TX_LINES[$i]; break }
        }
        if ($usageLine) {
            try {
                $obj = $usageLine | ConvertFrom-Json
                $u = $null
                if ($obj.message -and $obj.message.usage) { $u = $obj.message.usage }
                elseif ($obj.usage) { $u = $obj.usage }
                if ($u) {
                    $it  = if ($null -ne $u.input_tokens) { [int]$u.input_tokens } else { 0 }
                    $cr  = if ($null -ne $u.cache_read_input_tokens) { [int]$u.cache_read_input_tokens } else { 0 }
                    $cc  = if ($null -ne $u.cache_creation_input_tokens) { [int]$u.cache_creation_input_tokens } else { 0 }
                    $used = $it + $cr + $cc
                }
            } catch { $used = 0 }
        }
    }
    if ($used -lt 0) { $used = 0 }

    # Observed usage is ground truth: if it exceeds the assumed limit and no
    # explicit limit was set, the real window must be larger - step up to 1M.
    if ([string]::IsNullOrEmpty($explicitLimit) -and $used -gt $limit -and $limit -lt 1000000) {
        $limit = 1000000
    }

    if ($used -gt 0) {
        $pct = [int]([math]::Floor($used * 100 / $limit))
        if ($pct -gt 100) { $pct = 100 }

        if     ($pct -ge 80) { $ctxColor = $C_CTX_HIGH }
        elseif ($pct -ge 50) { $ctxColor = $C_CTX_MID }
        else                 { $ctxColor = $C_CTX_LOW }

        $bw = Env-Val 'CLAUDE_PULSE_BAR_WIDTH'
        if ($bw -match '^\d+$' -and [int]$bw -gt 0) { $len = [int]$bw } else { $len = 10 }
        $eighths = [int]([math]::Floor($pct * $len * 8 / 100))
        $full = [int]([math]::Floor($eighths / 8))
        $rem  = $eighths % 8
        $eighthChars = @('','▏','▎','▍','▌','▋','▊','▉')
        $bar = ''
        for ($i = 0; $i -lt $len; $i++) {
            if ($i -lt $full) {
                $bar += "$ctxColor█$R"
            } elseif ($i -eq $full -and $rem -gt 0) {
                $bar += "$ctxColor$($eighthChars[$rem])$R"
            } else {
                $bar += "$C_BAR_EMPTY░$R"
            }
        }

        $counts = ''
        if ((Env-Val 'CLAUDE_PULSE_TOKENS') -ne '0') {
            $counts = " ($(Human $used)/$(Human $limit))"
        }
        $SEG_CTX = "$ctxColor$G_CTX$R$bar $ctxColor$pct%$R$counts"
    }
}

# --- Segment: session duration ---------------------------------------------------
$SEG_DURATION = ''
if (-not (Is-Hidden 'duration')) {
    if ($DURATION_MS -gt 0) {
        $secs = [int]([math]::Floor($DURATION_MS / 1000))
        if     ($secs -ge 3600) { $dur = "$([int]([math]::Floor($secs / 3600)))h$([int]([math]::Floor(($secs % 3600) / 60)))m" }
        elseif ($secs -ge 60)   { $dur = "$([int]([math]::Floor($secs / 60)))m" }
        else                    { $dur = "${secs}s" }
        $SEG_DURATION = "$C_SEP$G_DUR$dur$R"
    }
}

# --- Segment: session cost -------------------------------------------------------
$SEG_COST = ''
if (-not (Is-Hidden 'cost')) {
    $costFmt = ('{0:0.00}' -f [double]$COST)
    $SEG_COST = "$C_COST$G_COST`$$costFmt$R"
}

# --- Assemble (skip empty segments, join with separator) -------------------------
$out = ''
foreach ($seg in @($SEG_MODE,$SEG_MODEL,$SEG_DIR,$SEG_BRANCH,$SEG_TOOLS,$SEG_LINES,$SEG_CTX,$SEG_DURATION,$SEG_COST)) {
    if ([string]::IsNullOrEmpty($seg)) { continue }
    if ([string]::IsNullOrEmpty($out)) { $out = $seg } else { $out = "$out$SEP$seg" }
}

[Console]::Out.Write($out + "`n")
