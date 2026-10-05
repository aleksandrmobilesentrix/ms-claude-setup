# =============================================================================
#  MobileSentrix - force Claude Code tool search on (Windows)
#
#  Behind a non-Anthropic ANTHROPIC_BASE_URL (our gateway) Claude Code turns
#  tool search off and sends every MCP tool schema with every request. This
#  puts ENABLE_TOOL_SEARCH=true into the machine-wide managed settings file,
#  which outranks every user setting, so nothing in ~/.claude/settings.json
#  (or a provider switch) can turn it off again.
#
#  Only that one key is written: the gateway URL and token are NOT managed,
#  so /newapi and /anthropic keep switching providers as before. Other keys
#  already in the managed file are kept; the old file is backed up.
#
#  Run in an ELEVATED PowerShell (Run as administrator):
#     irm https://tinyurl.com/ms-tool-search | iex
#  Restart Claude Code afterwards.
# =============================================================================

$ErrorActionPreference = 'Stop'

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host 'This needs administrator rights (the managed settings file lives in Program Files).' -ForegroundColor Red
    Write-Host 'Open PowerShell with "Run as administrator" and run the same command again.' -ForegroundColor Yellow
    return
}

$dir  = Join-Path $env:ProgramFiles 'ClaudeCode'
$path = Join-Path $dir 'managed-settings.json'
New-Item -ItemType Directory -Force -Path $dir | Out-Null

$settings = [pscustomobject]@{}
if (Test-Path $path) {
    $backup = "$path.bak-" + (Get-Date -Format 'yyyyMMdd-HHmmss')
    Copy-Item $path $backup
    try {
        $settings = Get-Content $path -Raw | ConvertFrom-Json
    } catch {
        Write-Host "Existing $path is not valid JSON - nothing changed (backup: $backup)." -ForegroundColor Red
        return
    }
}
if (-not $settings.PSObject.Properties['env'] -or -not $settings.env) {
    $settings | Add-Member -Force -NotePropertyName env -NotePropertyValue ([pscustomobject]@{})
}
$settings.env | Add-Member -Force -NotePropertyName ENABLE_TOOL_SEARCH -NotePropertyValue 'true'

# UTF-8 without BOM (Claude Code parses JSON strictly; a BOM breaks it).
[System.IO.File]::WriteAllText($path, ($settings | ConvertTo-Json -Depth 20), (New-Object System.Text.UTF8Encoding($false)))

Write-Host ''
Write-Host 'Done: tool search is now forced on for Claude Code on this machine.' -ForegroundColor Green
Write-Host ("  Managed settings: {0}" -f $path) -ForegroundColor DarkGray
Write-Host '  /newapi and /anthropic still switch providers as before.' -ForegroundColor DarkGray
Write-Host ''
Write-Host 'Restart Claude Code (close all sessions and relaunch) for it to take effect.' -ForegroundColor Cyan
Write-Host ''
