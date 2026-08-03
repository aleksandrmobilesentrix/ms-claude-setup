# =============================================================================
#  MobileSentrix - Claude Code setup for the new-api gateway (Windows)
#
#  Safe to run MULTIPLE times - it only finishes what is missing:
#    1. Installs the Claude Code CLI (skips if already installed).
#    2. Makes sure `claude` is on PATH (this session + future terminals).
#    3. Asks for your new-api token (keeps the existing one if already set).
#    4. Points Claude Code at the MobileSentrix gateway (ai.mobilesentrix.com).
#
#  Run it with:   irm https://<your-tiny-url> | iex
# =============================================================================

$ErrorActionPreference = 'Stop'
$Gateway = 'https://ai.mobilesentrix.com'

Write-Host ''
Write-Host '=== MobileSentrix - Claude Code + new-api setup ===' -ForegroundColor Cyan
Write-Host '(Safe to re-run - it only completes what is missing.)' -ForegroundColor DarkGray
Write-Host ''

# --- 1) Install Claude Code CLI (skip if present) ---------------------------
if (Get-Command claude -ErrorAction SilentlyContinue) {
    Write-Host '[1/3] Claude Code CLI already installed - OK.' -ForegroundColor Green
} else {
    Write-Host '[1/3] Installing Claude Code CLI (official native installer)...' -ForegroundColor Yellow
    try {
        Invoke-Expression (Invoke-RestMethod -Uri 'https://claude.ai/install.ps1')
    } catch {
        Write-Host "Install failed: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host 'Try manually:  irm https://claude.ai/install.ps1 | iex' -ForegroundColor DarkGray
        return
    }
}

# --- Make sure `claude` is on PATH (this session + future terminals) ---------
# Find claude.exe wherever the installer put it (default ~/.local/bin, but be robust).
$claudeExe = $null
$cmd = Get-Command claude -ErrorAction SilentlyContinue
if ($cmd) {
    $claudeExe = $cmd.Source
} else {
    $roots = @("$env:USERPROFILE\.local", "$env:USERPROFILE\.claude", "$env:LOCALAPPDATA", "$env:APPDATA")
    $claudeExe = $roots | Where-Object { Test-Path $_ } |
        ForEach-Object { Get-ChildItem $_ -Recurse -Filter claude.exe -ErrorAction SilentlyContinue -Depth 4 } |
        Select-Object -First 1 -ExpandProperty FullName
}
if ($claudeExe) {
    $binDir = Split-Path $claudeExe
    if (($env:Path -split ';') -notcontains $binDir) { $env:Path = "$binDir;$env:Path" }
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    if (($userPath -split ';') -notcontains $binDir) {
        [Environment]::SetEnvironmentVariable('Path', ("$userPath;$binDir").Trim(';'), 'User')
        Write-Host "      Added $binDir to PATH." -ForegroundColor DarkGray
    }
} else {
    Write-Host '      Note: claude.exe not found after install.' -ForegroundColor Red
    Write-Host '      Open a NEW normal (non-admin) PowerShell and run this again.' -ForegroundColor DarkGray
}

# --- 2) Load current settings + detect existing gateway config --------------
$claudeDir    = Join-Path $env:USERPROFILE '.claude'
$settingsPath = Join-Path $claudeDir 'settings.json'
New-Item -ItemType Directory -Force -Path $claudeDir | Out-Null

$settings = @{}
if (Test-Path $settingsPath) {
    try {
        $existing = Get-Content $settingsPath -Raw | ConvertFrom-Json
        foreach ($p in $existing.PSObject.Properties) { $settings[$p.Name] = $p.Value }
    } catch {
        Write-Host '      (existing settings.json was invalid - starting a clean one)' -ForegroundColor DarkGray
    }
}

$curBase = ''; $curToken = ''
if ($settings['env']) {
    $curBase  = "$($settings['env'].ANTHROPIC_BASE_URL)"
    $curToken = "$($settings['env'].ANTHROPIC_AUTH_TOKEN)"
}
$alreadyConfigured = ($curBase -eq $Gateway) -and (-not [string]::IsNullOrWhiteSpace($curToken))

Write-Host ''
if ($alreadyConfigured) {
    Write-Host '[2/3] Gateway + token are already set.' -ForegroundColor Green
    Write-Host '      Press ENTER to keep the current token, or paste a new one to replace it.' -ForegroundColor DarkGray
    $secure = Read-Host '      new-api token (ENTER = keep)' -AsSecureString
    $entered = [System.Net.NetworkCredential]::new('', $secure).Password
    if ([string]::IsNullOrWhiteSpace($entered)) { $token = $curToken } else { $token = $entered }
} else {
    Write-Host '[2/3] Enter your NEW-API token (not the UniFi token).' -ForegroundColor Yellow
    Write-Host "      Where to get it: open $Gateway -> log in -> Tokens -> copy/create a key (sk-...)" -ForegroundColor DarkGray
    $secure = Read-Host '      new-api token' -AsSecureString
    $token  = [System.Net.NetworkCredential]::new('', $secure).Password
    if ([string]::IsNullOrWhiteSpace($token)) {
        Write-Host 'No token entered - nothing was changed. Re-run when you have it.' -ForegroundColor Red
        return
    }
}

# --- 3) Point Claude Code at the gateway (~/.claude/settings.json) -----------
Write-Host ''
Write-Host '[3/3] Configuring Claude Code to use the MobileSentrix gateway...' -ForegroundColor Yellow
$settings['env'] = [ordered]@{
    ANTHROPIC_BASE_URL   = $Gateway
    ANTHROPIC_AUTH_TOKEN = $token
}
# Write UTF-8 WITHOUT BOM (Node/Claude Code parses JSON strictly; a BOM breaks it).
[System.IO.File]::WriteAllText($settingsPath, ($settings | ConvertTo-Json -Depth 20), (New-Object System.Text.UTF8Encoding($false)))

# --- Done -------------------------------------------------------------------
Write-Host ''
Write-Host 'Done! Claude Code is set to the MobileSentrix gateway.' -ForegroundColor Green
Write-Host ("  Endpoint : {0}" -f $Gateway)
Write-Host ("  Settings : {0}" -f $settingsPath)
Write-Host ''
Write-Host 'Next: open a NEW normal (non-admin) PowerShell and run:  claude' -ForegroundColor Cyan
Write-Host 'If claude is not found there, PATH just needs a fresh terminal - open a new one.' -ForegroundColor DarkGray
Write-Host ''
