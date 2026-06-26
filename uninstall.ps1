#!/usr/bin/env pwsh
#
# claude-pulse uninstaller (Windows / PowerShell).
#
# Removes the claude-pulse statusLine + hooks from ~/.claude/settings.json and
# deletes the install dir. Restores a previously-saved status line if one was
# backed up at install time. Leaves all OTHER settings untouched.

$ErrorActionPreference = 'Stop'

$ClaudeDir    = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $HOME '.claude' }
$InstallDir   = Join-Path $ClaudeDir 'claude-pulse'
$SettingsFile = Join-Path $ClaudeDir 'settings.json'
$PrevStatuslineFile = Join-Path $InstallDir 'statusline.prev.json'

if (Test-Path -LiteralPath $SettingsFile) {
    try {
        $data = Get-Content -LiteralPath $SettingsFile -Raw | ConvertFrom-Json
    } catch {
        Write-Host "Could not parse $SettingsFile - leaving it untouched."
        $data = $null
    }

    if ($data) {
        # -- statusLine: restore the saved original, or drop ours -----------------
        $isPulseSl = ($data.PSObject.Properties.Name -contains 'statusLine') -and
                     $data.statusLine -and $data.statusLine.command -and
                     ($data.statusLine.command -like '*statusline.ps1*')
        if ($isPulseSl) {
            if (Test-Path -LiteralPath $PrevStatuslineFile) {
                $prev = Get-Content -LiteralPath $PrevStatuslineFile -Raw | ConvertFrom-Json
                $data.statusLine = $prev
            } else {
                $data.PSObject.Properties.Remove('statusLine')
            }
        }

        # -- hooks: drop pulse groups from Stop / Notification --------------------
        if ($data.PSObject.Properties.Name -contains 'hooks' -and $data.hooks) {
            foreach ($evt in @('Stop','Notification')) {
                if ($data.hooks.PSObject.Properties.Name -contains $evt -and $data.hooks.$evt) {
                    $kept = @()
                    foreach ($g in @($data.hooks.$evt)) {
                        $isPulse = $false
                        if ($g.hooks) {
                            foreach ($h in $g.hooks) {
                                if ($h.command -and ($h.command -like '*notify.ps1*')) { $isPulse = $true }
                            }
                        }
                        if (-not $isPulse) { $kept += $g }
                    }
                    if ($kept.Count -gt 0) { $data.hooks.$evt = $kept }
                    else { $data.hooks.PSObject.Properties.Remove($evt) }
                }
            }
        }

        ($data | ConvertTo-Json -Depth 20) | Set-Content -LiteralPath $SettingsFile -Encoding UTF8
    }
}

if (Test-Path -LiteralPath $InstallDir) {
    Remove-Item -LiteralPath $InstallDir -Recurse -Force
}

Write-Host 'claude-pulse uninstalled. Restart Claude Code (or start a new session).'
