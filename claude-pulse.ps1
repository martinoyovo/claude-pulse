#!/usr/bin/env pwsh
#
# claude-pulse - manage your claude-pulse install (Windows / PowerShell).

param(
    [Parameter(Position = 0)] [string] $Command = 'help',
    [Parameter(Position = 1)] [string] $Arg
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

$CLAUDE_PULSE_VERSION = '0.7.1'
$ClaudeDir  = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $HOME '.claude' }
$InstallDir = Join-Path $ClaudeDir 'claude-pulse'
$RawUrl     = if ($env:PULSE_RAW_URL) { $env:PULSE_RAW_URL } else { 'https://raw.githubusercontent.com/martinoyovo/claude-pulse/main' }

function Show-Usage {
@"
claude-pulse $CLAUDE_PULSE_VERSION - status line + notifications for Claude Code (Windows)

Usage: claude-pulse <command>

  update              Re-install the latest version from GitHub.
  install, reinstall  Alias for update (fetch + (re)install latest).
  uninstall           Remove claude-pulse entirely.
  test [stop|notify]  Fire a test desktop notification (default: stop).
  icons [MODE]        Set status-line icons: nerd | emoji | symbols | off.
                      No MODE shows the current setting.
  version             Print the installed version.
  help                Show this help.
"@ | Write-Host
}

switch ($Command.ToLower()) {
    { $_ -in @('update','install','reinstall','-u') } {
        Write-Host "Installing claude-pulse (latest) from $RawUrl ..."
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("claude-pulse-install-" + [guid]::NewGuid().ToString() + ".ps1")
        Invoke-WebRequest -UseBasicParsing -Uri "$RawUrl/install.ps1" -OutFile $tmp
        & powershell -NoProfile -ExecutionPolicy Bypass -File $tmp
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        break
    }
    'uninstall' {
        $u = Join-Path $InstallDir 'uninstall.ps1'
        if (Test-Path -LiteralPath $u) {
            & powershell -NoProfile -ExecutionPolicy Bypass -File $u
        } else {
            Write-Host "uninstall.ps1 not found at $InstallDir - is claude-pulse installed?"
            exit 1
        }
        break
    }
    'test' {
        $what = if ($Arg) { $Arg } else { 'stop' }
        $cwd = (Get-Location).Path
        switch ($what) {
            'notify' { $ev = '{"hook_event_name":"Notification","message":"claude-pulse test notification","cwd":"' + ($cwd -replace '\\','\\') + '"}' }
            'stop'   { $ev = '{"hook_event_name":"Stop","cwd":"' + ($cwd -replace '\\','\\') + '"}' }
            default  { Write-Host "Unknown test type: $what (use stop|notify)"; exit 2 }
        }
        $notify = Join-Path $InstallDir 'notify.ps1'
        if (Test-Path -LiteralPath $notify) {
            $ev | & powershell -NoProfile -ExecutionPolicy Bypass -File $notify
            Write-Host "Fired a `"$what`" test notification."
        } else {
            Write-Host "notify.ps1 not found at $InstallDir - is claude-pulse installed?"
            exit 1
        }
        break
    }
    'icons' {
        $cfg = Join-Path $InstallDir 'config.ps1'
        if (-not (Test-Path -LiteralPath $cfg)) { Write-Host 'config.ps1 not found - run claude-pulse update first.'; exit 1 }
        $mode = $Arg
        if (-not $mode) {
            $cur = Select-String -LiteralPath $cfg -Pattern '^\s*\$env:CLAUDE_PULSE_(NERD|EMOJI|SYMBOLS)\s*=' | Select-Object -First 1
            if ($cur -match 'NERD')    { Write-Host 'Icons: nerd' }
            elseif ($cur -match 'EMOJI')   { Write-Host 'Icons: emoji' }
            elseif ($cur -match 'SYMBOLS') { Write-Host 'Icons: symbols' }
            else { Write-Host 'Icons: off (plain text)' }
            Write-Host 'Usage: claude-pulse icons [nerd|emoji|symbols|off]'
            exit 0
        }
        # Remove any existing icon-mode lines (set or commented), then set one.
        $kept = Get-Content -LiteralPath $cfg | Where-Object { $_ -notmatch '^\s*#?\s*\$env:CLAUDE_PULSE_(NERD|EMOJI|SYMBOLS)\s*=' }
        $kept | Set-Content -LiteralPath $cfg -Encoding UTF8
        switch ($mode) {
            'nerd'    { Add-Content -LiteralPath $cfg "`$env:CLAUDE_PULSE_NERD = '1'"; Write-Host 'Icons set to nerd (needs a Nerd Font selected in your terminal).' }
            'emoji'   { Add-Content -LiteralPath $cfg "`$env:CLAUDE_PULSE_EMOJI = '1'"; Write-Host 'Icons set to emoji.' }
            'symbols' { Add-Content -LiteralPath $cfg "`$env:CLAUDE_PULSE_SYMBOLS = '1'"; Write-Host 'Icons set to symbols.' }
            { $_ -in @('off','plain','none') } { Write-Host 'Icons set to off (plain text).' }
            default { Write-Host "Unknown mode: $mode (use nerd|emoji|symbols|off)"; exit 2 }
        }
        Write-Host 'Open a new Claude Code session to see the change.'
        break
    }
    { $_ -in @('version','-v') } { Write-Host "claude-pulse $CLAUDE_PULSE_VERSION"; break }
    { $_ -in @('help','-h') }    { Show-Usage; break }
    default { Write-Host "Unknown command: $Command`n"; Show-Usage; exit 2 }
}
