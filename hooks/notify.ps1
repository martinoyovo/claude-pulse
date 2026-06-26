#!/usr/bin/env pwsh
#
# claude-pulse - desktop notification hook for Claude Code (Windows / PowerShell).
#
# Claude Code runs configured hooks for lifecycle events and pipes one JSON
# object on STDIN. We fire a quick native Windows alert when Claude finishes a
# turn (Stop) or needs your attention (Notification - e.g. a permission prompt).
#
# This is the Windows counterpart to hooks/notify.sh, which intentionally no-ops
# on Windows shells. Backends, in order of preference:
#   1. BurntToast      - real Action Center toast (if the module is installed).
#   2. NotifyIcon      - a tray balloon tip via System.Windows.Forms (built in).
#   3. MessageBeep     - audible fallback so you still get *something*.
#
# The notification mirrors Claude.app's structure: the TITLE is the session
# title or project folder name (so you can tell which session is waiting when
# several are open), and the MESSAGE is the status.
#
# Configuration (environment variables; or a config.ps1 next to this script):
#   CLAUDE_PULSE_NOTIFY        Backend: auto (default), burnttoast, balloon,
#                              beep, off.
#   CLAUDE_PULSE_NOTIFY_TITLE  Override the title (default: session/folder name).
#   CLAUDE_PULSE_NOTIFY_IDLE=1 Keep Claude Code's ~60s idle reminder (off by
#                              default - it duplicates the Stop alert).

$ErrorActionPreference = 'SilentlyContinue'

$payload = ''
try { $payload = [Console]::In.ReadToEnd() } catch { $payload = '' }
if ([string]::IsNullOrWhiteSpace($payload)) { exit 0 }

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$cfg = Join-Path $ScriptDir 'config.ps1'
if (Test-Path -LiteralPath $cfg) { . $cfg }

function Env-Val([string]$name) {
    $v = [Environment]::GetEnvironmentVariable($name)
    if ($null -eq $v) { return '' }
    return $v
}

# --- Parse the event ------------------------------------------------------------
$event = ''; $detail = ''; $cwd = ''; $transcript = ''
try {
    $p = $payload | ConvertFrom-Json
    if ($p.hook_event_name) { $event = [string]$p.hook_event_name }
    if ($p.message)         { $detail = [string]$p.message }
    if ($p.cwd)             { $cwd = [string]$p.cwd }
    elseif ($p.workspace -and $p.workspace.current_dir) { $cwd = [string]$p.workspace.current_dir }
    if ($p.transcript_path) { $transcript = [string]$p.transcript_path }
} catch {}

# --- Title: session custom title -> project folder name (like Claude.app) -------
$sessionTitle = ''
if ($transcript -and (Test-Path -LiteralPath $transcript)) {
    try {
        $lines = [System.IO.File]::ReadAllLines($transcript)
        for ($i = $lines.Length - 1; $i -ge 0; $i--) {
            if ($lines[$i] -like '*"type":"custom-title"*') {
                $obj = $lines[$i] | ConvertFrom-Json
                if ($obj.customTitle) { $sessionTitle = [string]$obj.customTitle }
                break
            }
        }
    } catch {}
}

$titleOverride = Env-Val 'CLAUDE_PULSE_NOTIFY_TITLE'
if ($titleOverride)      { $title = $titleOverride }
elseif ($sessionTitle)   { $title = $sessionTitle }
elseif ($cwd)            { $title = Split-Path -Leaf $cwd }
else                     { $title = 'Claude Code' }

# --- Map event -> message -------------------------------------------------------
$message = ''
switch ($event) {
    { $_ -in @('Stop','SubagentStop') } { $message = 'Claude Code is waiting for your input' }
    'Notification' {
        # Claude Code's idle reminder duplicates our Stop notification; skip it
        # by default. Set CLAUDE_PULSE_NOTIFY_IDLE=1 to keep it.
        if ((Env-Val 'CLAUDE_PULSE_NOTIFY_IDLE') -ne '1' -and $detail -like '*waiting for your input*') {
            exit 0
        }
        if ($detail) {
            if ($detail -like 'Claude Code*')   { $message = $detail }
            elseif ($detail -like 'Claude *')   { $message = 'Claude Code ' + $detail.Substring(7) }
            else                                { $message = $detail }
        } else {
            $message = 'Claude Code needs your attention'
        }
    }
    default { exit 0 }
}

# --- Backends -------------------------------------------------------------------
function Notify-BurntToast {
    if (-not (Get-Module -ListAvailable -Name BurntToast)) { return $false }
    try {
        Import-Module BurntToast -ErrorAction Stop
        New-BurntToastNotification -Text $title, $message -ErrorAction Stop | Out-Null
        return $true
    } catch { return $false }
}

function Notify-Balloon {
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        Add-Type -AssemblyName System.Drawing -ErrorAction Stop
        $ni = New-Object System.Windows.Forms.NotifyIcon
        $ni.Icon = [System.Drawing.SystemIcons]::Information
        $ni.BalloonTipTitle = $title
        $ni.BalloonTipText = $message
        $ni.Visible = $true
        $ni.ShowBalloonTip(5000)
        # Keep the icon alive briefly so the balloon actually renders, then clean up.
        Start-Sleep -Milliseconds 200
        $ni.Dispose()
        return $true
    } catch { return $false }
}

function Notify-Beep {
    try { [System.Console]::Beep(); return $true } catch { return $false }
}

switch ((Env-Val 'CLAUDE_PULSE_NOTIFY')) {
    'off'        { }
    'burnttoast' { [void](Notify-BurntToast) }
    'balloon'    { [void](Notify-Balloon) }
    'beep'       { [void](Notify-Beep) }
    default {
        if (-not (Notify-BurntToast)) {
            if (-not (Notify-Balloon)) {
                [void](Notify-Beep)
            }
        }
    }
}

exit 0
