# =============================================================================
#  MobileSentrix - Switch Claude Code between New-API and native Anthropic
#
#  For people who ALREADY have Claude Code installed. Flips the provider:
#    - New API      -> route through ai.mobilesentrix.com (needs a new-api token)
#    - Anthropic    -> direct claude.ai subscription (no proxy)
#
#  The new-api token is remembered in ~/.claude/claude-provider.conf, so
#  switching back and forth does NOT ask for it again. If it is not stored
#  yet, the script asks for it once (only when switching TO New API).
#
#  Run it with:   irm https://<your-tiny-url> | iex
#  Restart Claude Code after switching for it to take effect.
# =============================================================================

$ErrorActionPreference = 'Stop'
$Gateway = 'https://ai.mobilesentrix.com'

$claudeDir    = Join-Path $env:USERPROFILE '.claude'
$settingsPath = Join-Path $claudeDir 'settings.json'
$confPath     = Join-Path $claudeDir 'claude-provider.conf'
New-Item -ItemType Directory -Force -Path $claudeDir | Out-Null

function Read-Settings {
    $h = @{}
    if (Test-Path $settingsPath) {
        try {
            $o = Get-Content $settingsPath -Raw | ConvertFrom-Json
            foreach ($p in $o.PSObject.Properties) { $h[$p.Name] = $p.Value }
        } catch {
            Write-Host '(existing settings.json was invalid - starting a clean one)' -ForegroundColor DarkGray
        }
    }
    return $h
}
function Write-Settings($h) {
    # UTF-8 without BOM (Node/Claude Code parses JSON strictly; a BOM breaks it).
    [System.IO.File]::WriteAllText($settingsPath, ($h | ConvertTo-Json -Depth 20), (New-Object System.Text.UTF8Encoding($false)))
}
function Get-SavedToken {
    if (Test-Path $confPath) {
        foreach ($l in Get-Content $confPath) {
            if ($l -match '^\s*NEWAPI_TOKEN\s*=\s*(.+)$') { return $Matches[1].Trim() }
        }
    }
    return ''
}
function Save-Token($tok) {
    [System.IO.File]::WriteAllText($confPath, "NEWAPI_URL=$Gateway`r`nNEWAPI_TOKEN=$tok`r`n", (New-Object System.Text.UTF8Encoding($false)))
}

# --- Detect current provider ------------------------------------------------
$settings = Read-Settings
$curBase = ''; $curToken = ''
if ($settings['env']) {
    $curBase  = "$($settings['env'].ANTHROPIC_BASE_URL)"
    $curToken = "$($settings['env'].ANTHROPIC_AUTH_TOKEN)"
}
$onNewApi = -not [string]::IsNullOrWhiteSpace($curBase)

# Remember a token that is already in settings (e.g. from the installer script).
if ($onNewApi -and (Get-SavedToken) -eq '' -and -not [string]::IsNullOrWhiteSpace($curToken)) {
    Save-Token $curToken
}

$currentLabel = if ($onNewApi) { "New API gateway ($curBase)" } else { 'Native Anthropic (claude.ai subscription)' }

Write-Host ''
Write-Host '=== MobileSentrix - Claude Code provider switch ===' -ForegroundColor Cyan
Write-Host ("Current provider: {0}" -f $currentLabel) -ForegroundColor Yellow
Write-Host ''
Write-Host '  [1] New API gateway   (ai.mobilesentrix.com)'
Write-Host '  [2] Native Anthropic  (claude.ai subscription)'
$default = if ($onNewApi) { '2' } else { '1' }
$choice  = Read-Host ("Switch to [1/2]  (ENTER = {0}, the other one)" -f $default)
if ([string]::IsNullOrWhiteSpace($choice)) { $choice = $default }

if ($choice -eq '1') {
    # --- New API gateway ---
    $token = Get-SavedToken
    if ([string]::IsNullOrWhiteSpace($token)) {
        Write-Host ''
        Write-Host 'No saved new-api token. Enter it now (asked only this once).' -ForegroundColor Yellow
        Write-Host ("Where to get it: open $Gateway -> log in -> Tokens -> copy/create a key (sk-...)") -ForegroundColor DarkGray
        $secure = Read-Host '  new-api token' -AsSecureString
        $token  = [System.Net.NetworkCredential]::new('', $secure).Password
        if ([string]::IsNullOrWhiteSpace($token)) {
            Write-Host 'No token entered - nothing changed.' -ForegroundColor Red
            return
        }
        Save-Token $token
    }
    $settings['env'] = [ordered]@{
        ANTHROPIC_BASE_URL   = $Gateway
        ANTHROPIC_AUTH_TOKEN = $token
    }
    $result = "New API gateway ($Gateway)"
}
elseif ($choice -eq '2') {
    # --- Native Anthropic: drop the gateway vars, keep any other env keys ---
    if ($settings.ContainsKey('env') -and $settings['env']) {
        $kept = [ordered]@{}
        foreach ($name in $settings['env'].PSObject.Properties.Name) {
            if ($name -notin @('ANTHROPIC_BASE_URL', 'ANTHROPIC_AUTH_TOKEN', 'ANTHROPIC_API_KEY')) {
                $kept[$name] = $settings['env'].$name
            }
        }
        if ($kept.Count -gt 0) { $settings['env'] = $kept } else { $settings.Remove('env') | Out-Null }
    }
    $result = 'Native Anthropic (claude.ai subscription)'
}
else {
    Write-Host ("Invalid choice '{0}' - nothing changed." -f $choice) -ForegroundColor Red
    return
}

Write-Settings $settings

Write-Host ''
Write-Host ("Switched to: {0}" -f $result) -ForegroundColor Green
Write-Host ("Settings: {0}" -f $settingsPath) -ForegroundColor DarkGray
Write-Host ''
Write-Host 'Restart Claude Code (close all sessions and relaunch) for it to take effect.' -ForegroundColor Cyan
Write-Host ''
