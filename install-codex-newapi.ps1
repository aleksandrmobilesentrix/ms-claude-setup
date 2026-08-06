# =============================================================================
#  MobileSentrix - Codex CLI setup for the new-api gateway (Windows)
#
#  Safe to run MULTIPLE times - it only finishes what is missing:
#    1. Installs the Codex CLI (skips if already installed).
#    2. Makes sure `codex` is on PATH (this session + future terminals).
#    3. Asks for your new-api token (keeps the existing one if already set).
#    4. Points Codex at the MobileSentrix gateway (ai.mobilesentrix.com).
#
#  Run it with:   irm https://<your-tiny-url> | iex
#  Restart Codex after setup, then smoke-test:  codex exec "reply with exactly: ok"
# =============================================================================

$ErrorActionPreference = 'Stop'
$Gateway = 'https://ai.mobilesentrix.com/v1'

Write-Host ''
Write-Host '=== MobileSentrix - Codex + new-api setup ===' -ForegroundColor Cyan
Write-Host '(Safe to re-run - it only completes what is missing.)' -ForegroundColor DarkGray
Write-Host ''

# --- 1) Install Codex CLI (skip if present) ---------------------------------
if (Get-Command codex -ErrorAction SilentlyContinue) {
    Write-Host '[1/3] Codex CLI already installed - OK.' -ForegroundColor Green
} else {
    Write-Host '[1/3] Installing Codex CLI (official native installer)...' -ForegroundColor Yellow
    try {
        Invoke-Expression (Invoke-RestMethod -Uri 'https://chatgpt.com/codex/install.ps1')
    } catch {
        Write-Host "Install failed: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host 'Try manually:  irm https://chatgpt.com/codex/install.ps1 | iex' -ForegroundColor DarkGray
        Write-Host '(or, if you use Node.js:  npm install -g @openai/codex)' -ForegroundColor DarkGray
        return
    }
}

# --- Make sure `codex` is on PATH (this session + future terminals) ---------
$codexExe = $null
$cmd = Get-Command codex -ErrorAction SilentlyContinue
if ($cmd) {
    $codexExe = $cmd.Source
} else {
    $roots = @("$env:USERPROFILE\.codex", "$env:USERPROFILE\.local", "$env:LOCALAPPDATA", "$env:APPDATA")
    $codexExe = $roots | Where-Object { Test-Path $_ } |
        ForEach-Object { Get-ChildItem $_ -Recurse -Include 'codex.exe', 'codex.cmd' -ErrorAction SilentlyContinue -Depth 4 } |
        Select-Object -First 1 -ExpandProperty FullName
}
if ($codexExe) {
    $binDir = Split-Path $codexExe
    if (($env:Path -split ';') -notcontains $binDir) { $env:Path = "$binDir;$env:Path" }
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    if (($userPath -split ';') -notcontains $binDir) {
        [Environment]::SetEnvironmentVariable('Path', ("$userPath;$binDir").Trim(';'), 'User')
        Write-Host "      Added $binDir to PATH." -ForegroundColor DarkGray
    }
} else {
    Write-Host '      Note: codex not found after install.' -ForegroundColor Red
    Write-Host '      Open a NEW normal PowerShell and run this again.' -ForegroundColor DarkGray
}

# --- 2) Token: reuse the one already in config, or ask for it ----------------
$codexDir   = Join-Path $env:USERPROFILE '.codex'
$configPath = Join-Path $codexDir 'config.toml'
New-Item -ItemType Directory -Force -Path $codexDir | Out-Null

$curToken = ''
if (Test-Path $configPath) {
    $existing = Get-Content $configPath -Raw
    $m = [regex]::Match($existing, 'experimental_bearer_token\s*=\s*"([^"]+)"')
    if ($m.Success) { $curToken = $m.Groups[1].Value }
}

Write-Host ''
if (-not [string]::IsNullOrWhiteSpace($curToken)) {
    Write-Host '[2/3] A new-api token is already in the Codex config.' -ForegroundColor Green
    Write-Host '      Press ENTER to keep it, or paste a new one to replace it.' -ForegroundColor DarkGray
    $secure  = Read-Host '      new-api token (ENTER = keep)' -AsSecureString
    $entered = [System.Net.NetworkCredential]::new('', $secure).Password
    $token   = if ([string]::IsNullOrWhiteSpace($entered)) { $curToken } else { $entered }
} else {
    Write-Host '[2/3] Enter your NEW-API token (not the UniFi token).' -ForegroundColor Yellow
    Write-Host "      Where to get it: open https://ai.mobilesentrix.com -> log in -> Tokens -> copy/create a key (sk-...)" -ForegroundColor DarkGray
    $secure = Read-Host '      new-api token' -AsSecureString
    $token  = [System.Net.NetworkCredential]::new('', $secure).Password
    if ([string]::IsNullOrWhiteSpace($token)) {
        Write-Host 'No token entered - nothing was changed. Re-run when you have it.' -ForegroundColor Red
        return
    }
}

# --- 3) Write ~/.codex/config.toml ------------------------------------------
Write-Host ''
Write-Host '[3/3] Pointing Codex at the MobileSentrix gateway...' -ForegroundColor Yellow

# Back up any existing config once, so nothing is lost.
if (Test-Path $configPath) { Copy-Item $configPath "$configPath.bak" -Force }

$config = @"
# Model is intentionally NOT set here - Codex uses its own default gpt/codex model.
# The gateway's Responses API works for gpt/codex models (Codex's native path);
# it is NOT implemented for Claude/GLM models. So your token must be in a group
# that has the gpt/codex channels (the 'codex' group), not the plain 'default' one.
model_provider = "newapi"

[model_providers.newapi]
name = "new-api gateway"
base_url = "$Gateway"
experimental_bearer_token = "$token"
wire_api = "responses"
request_max_retries = 4

[windows]
sandbox = "elevated"
"@

# UTF-8 without BOM (TOML parsers dislike a BOM).
[System.IO.File]::WriteAllText($configPath, $config, (New-Object System.Text.UTF8Encoding($false)))

# --- Done -------------------------------------------------------------------
Write-Host ''
Write-Host 'Done! Codex is set to the MobileSentrix gateway.' -ForegroundColor Green
Write-Host ("  Endpoint : {0}" -f $Gateway)
Write-Host ("  Config   : {0}" -f $configPath)
if (Test-Path "$configPath.bak") { Write-Host ("  Backup   : {0}.bak (previous config)" -f $configPath) -ForegroundColor DarkGray }
Write-Host ''
Write-Host 'Next: open a NEW PowerShell, then smoke-test:' -ForegroundColor Cyan
Write-Host '  codex exec "reply with exactly: ok"'
Write-Host ''
Write-Host 'Note: Codex uses its own default gpt/codex model. If you see' -ForegroundColor DarkGray
Write-Host '  "No available channel for model <x> under group default" -> your new-api token' -ForegroundColor DarkGray
Write-Host '  needs to be in the codex group (which has the gpt/codex channels), not default.' -ForegroundColor DarkGray
Write-Host ''
