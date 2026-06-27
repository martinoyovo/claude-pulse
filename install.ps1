#!/usr/bin/env pwsh
#
# claude-pulse installer (Windows / PowerShell).
#
# Installs the status line + notification hook into %USERPROFILE%\.claude\claude-pulse\
# and merges the `statusLine` and `hooks` blocks into ~/.claude/settings.json
# WITHOUT clobbering any existing configuration. Re-running is idempotent.
#
# This is the Windows counterpart to install.sh. Because Claude Code executes the
# settings `command` strings directly, we wire the PowerShell scripts as
#   powershell -NoProfile -ExecutionPolicy Bypass -File "<path>"
# so a bare .ps1 path is never handed to the shell.

$ErrorActionPreference = 'Stop'

$ScriptDir   = Split-Path -Parent $MyInvocation.MyCommand.Path
$ClaudeDir   = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $HOME '.claude' }
$InstallDir  = Join-Path $ClaudeDir 'claude-pulse'
$SettingsFile = Join-Path $ClaudeDir 'settings.json'
$PrevStatuslineFile = Join-Path $InstallDir 'statusline.prev.json'
$RawUrl      = if ($env:PULSE_RAW_URL) { $env:PULSE_RAW_URL } else { 'https://raw.githubusercontent.com/martinoyovo/claude-pulse/main' }

# Write text as UTF-8 WITHOUT a BOM. settings.json must be BOM-less so strict
# JSON parsers don't choke (Windows PowerShell 5.1's `Set-Content -Encoding UTF8`
# would prepend a BOM).
function Write-Utf8NoBom([string]$path, [string]$text) {
    [System.IO.File]::WriteAllText($path, $text, (New-Object System.Text.UTF8Encoding($false)))
}

New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
New-Item -ItemType Directory -Force -Path $ClaudeDir  | Out-Null

# --- Install the scripts --------------------------------------------------------
# Copy from $ScriptDir for a git-clone install; fall back to fetching from the raw
# repo URL when a source is missing (e.g. `claude-pulse update`, which downloads
# only install.ps1 into a temp dir and runs it). Mirrors install.sh's
# install_file -> fetch_file behavior.
$files = @(
    @{ src = (Join-Path $ScriptDir 'statusline.ps1');   url = 'statusline.ps1';       dst = (Join-Path $InstallDir 'statusline.ps1') },
    @{ src = (Join-Path $ScriptDir 'hooks\notify.ps1'); url = 'hooks/notify.ps1';     dst = (Join-Path $InstallDir 'notify.ps1') },
    @{ src = (Join-Path $ScriptDir 'uninstall.ps1');    url = 'uninstall.ps1';        dst = (Join-Path $InstallDir 'uninstall.ps1') },
    @{ src = (Join-Path $ScriptDir 'claude-pulse.ps1'); url = 'claude-pulse.ps1';     dst = (Join-Path $InstallDir 'claude-pulse.ps1') }
)
foreach ($f in $files) {
    if (Test-Path -LiteralPath $f.src) {
        Copy-Item -LiteralPath $f.src -Destination $f.dst -Force
    } elseif ($RawUrl) {
        try {
            Invoke-WebRequest -UseBasicParsing -Uri "$RawUrl/$($f.url)" -OutFile $f.dst
        } catch {
            Write-Error "Could not download $RawUrl/$($f.url): $($_.Exception.Message)"
            exit 1
        }
    } else {
        Write-Error "Local source not found and no PULSE_RAW_URL set: $($f.src)"
        exit 1
    }
}

$StatuslineDst = Join-Path $InstallDir 'statusline.ps1'
$NotifyDst     = Join-Path $InstallDir 'notify.ps1'
$CliDst        = Join-Path $InstallDir 'claude-pulse.ps1'

# --- Create a config file (dot-sourced by the scripts) if absent -----------------
$ConfigDst = Join-Path $InstallDir 'config.ps1'
if (-not (Test-Path -LiteralPath $ConfigDst)) {
@'
# claude-pulse config (Windows) - edit to taste. Dot-sourced by the scripts;
# survives updates. Uncomment a line to enable it.

# Icons (default is clean text - no icons, works on every terminal):
#   Nerd Font glyphs (crisp, but NEEDS a Nerd Font installed + selected):
# $env:CLAUDE_PULSE_NERD = '1'
#   Emoji icons (work on any terminal, no font needed):
# $env:CLAUDE_PULSE_EMOJI = '1'
#   Plain-text Unicode symbols (no font, no emoji; mostly universal):
# $env:CLAUDE_PULSE_SYMBOLS = '1'

# Show/hide the token counts after the % (1 = show, 0 = hide):
# $env:CLAUDE_PULSE_TOKENS = '1'

# Context bar width, in cells:
# $env:CLAUDE_PULSE_BAR_WIDTH = '10'

# Hide status-line segments (comma list): mode,model,dir,branch,tools,lines,context,duration,cost
# $env:CLAUDE_PULSE_HIDE = ''

# Notifications:
#   Backend: auto | burnttoast | balloon | beep | off
# $env:CLAUDE_PULSE_NOTIFY = 'auto'
# $env:CLAUDE_PULSE_NOTIFY_TITLE = ''
#   Keep Claude Code's ~60s idle reminder (off by default - duplicates Stop):
# $env:CLAUDE_PULSE_NOTIFY_IDLE = '0'
'@ | Set-Content -LiteralPath $ConfigDst -Encoding UTF8
}

# --- Merge settings.json (native, non-clobbering, idempotent) --------------------
function Hook-Command([string]$scriptPath) {
    return "powershell -NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`""
}
$statusCmd = Hook-Command $StatuslineDst
$notifyCmd = Hook-Command $NotifyDst

$data = $null
if (Test-Path -LiteralPath $SettingsFile) {
    try {
        $data = Get-Content -LiteralPath $SettingsFile -Raw | ConvertFrom-Json
    } catch {
        # Never destroy an unparseable file silently - back it up first.
        Copy-Item -LiteralPath $SettingsFile -Destination "$SettingsFile.bak" -Force
        $data = $null
    }
}
if ($null -eq $data) { $data = [PSCustomObject]@{} }

# Helper: ensure a property exists on a PSCustomObject.
function Ensure-Prop($obj, [string]$name, $default) {
    if (-not ($obj.PSObject.Properties.Name -contains $name)) {
        $obj | Add-Member -NotePropertyName $name -NotePropertyValue $default
    }
}

# -- statusLine: back up a pre-existing non-pulse status line, then set ours ------
$existingSl = $null
if ($data.PSObject.Properties.Name -contains 'statusLine') { $existingSl = $data.statusLine }
if ($existingSl -and $existingSl.command -and $existingSl.command -ne $statusCmd -and ($existingSl.command -notlike '*statusline.ps1*')) {
    Write-Utf8NoBom $PrevStatuslineFile ($existingSl | ConvertTo-Json -Depth 10)
}
$newSl = [PSCustomObject]@{ type = 'command'; command = $statusCmd; padding = 0 }
if ($data.PSObject.Properties.Name -contains 'statusLine') { $data.statusLine = $newSl }
else { $data | Add-Member -NotePropertyName 'statusLine' -NotePropertyValue $newSl }

# -- hooks (Stop, Notification): dedupe prior pulse entries, append ours ----------
Ensure-Prop $data 'hooks' ([PSCustomObject]@{})
$hooks = $data.hooks

function Is-PulseGroup($group) {
    if ($null -eq $group -or -not $group.hooks) { return $false }
    foreach ($h in $group.hooks) {
        if ($h.command -and ($h.command -like '*notify.ps1*' -or $h.command -like '*notify.sh*')) { return $true }
    }
    return $false
}

foreach ($evt in @('Stop','Notification')) {
    $entries = @()
    if ($hooks.PSObject.Properties.Name -contains $evt -and $hooks.$evt) {
        foreach ($g in @($hooks.$evt)) {
            if (-not (Is-PulseGroup $g)) { $entries += $g }
        }
    }
    $entries += [PSCustomObject]@{
        hooks = @([PSCustomObject]@{ type = 'command'; command = $notifyCmd; timeout = 5 })
    }
    if ($hooks.PSObject.Properties.Name -contains $evt) { $hooks.$evt = $entries }
    else { $hooks | Add-Member -NotePropertyName $evt -NotePropertyValue $entries }
}

Write-Utf8NoBom $SettingsFile ($data | ConvertTo-Json -Depth 20)

# --- Summary --------------------------------------------------------------------
$claudeVersion = 'not found on PATH'
if (Get-Command claude -ErrorAction SilentlyContinue) {
    try { $claudeVersion = (claude --version 2>$null) } catch {}
}

Write-Host ''
Write-Host 'claude-pulse installed (Windows).'
Write-Host ''
Write-Host 'Installed files:'
Write-Host "  $StatuslineDst"
Write-Host "  $NotifyDst"
Write-Host "  $CliDst"
Write-Host ''
Write-Host 'Wired into:'
Write-Host "  $SettingsFile  (statusLine + hooks.Stop + hooks.Notification)"
Write-Host ''
Write-Host "Claude Code version: $claudeVersion"
Write-Host ''
Write-Host 'Manage it with:'
Write-Host "  powershell -File `"$CliDst`" test     # fire a test notification"
Write-Host "  powershell -File `"$CliDst`" update   # update to the latest version"
Write-Host "  powershell -File `"$CliDst`" uninstall"
if (Test-Path -LiteralPath $PrevStatuslineFile) {
    Write-Host ''
    Write-Host 'Your previous status line was saved and can be restored on uninstall.'
}
Write-Host ''
Write-Host 'Tip: install the BurntToast module for richer Action Center toasts:'
Write-Host '  Install-Module BurntToast -Scope CurrentUser'
Write-Host ''
Write-Host 'Restart Claude Code (or start a new session) to see the status line.'
