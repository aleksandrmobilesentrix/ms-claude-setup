# =============================================================================
#  MobileSentrix - Switch Codex CLI between the new-api gateway and its default
#
#  One script, two directions:
#    [1] New API gateway  -> Codex talks to ai.mobilesentrix.com (needs a new-api token)
#    [2] Default          -> Codex goes back to its normal ChatGPT / OpenAI login
#
#  - Asks what you want to do, then (only for [1]) asks for your token.
#  - The token is remembered in ~/.codex/newapi-provider.conf, so switching
#    back and forth does NOT ask for it again.
#  - Only the gateway bits of ~/.codex/config.toml are added/removed; anything
#    else in that file (MCP servers, other settings) is left untouched.
#  - Installs the Codex CLI if it is missing (only when switching to [1]).
#  - Safe to re-run as many times as you like.
#
#  Run it with:   irm https://tinyurl.com/ms-codex-switch-win | iex
#  Restart Codex after switching for it to take effect.
# =============================================================================

$ErrorActionPreference = 'Stop'
$Gateway = 'https://ai.mobilesentrix.com/v1'

$codexDir   = Join-Path $env:USERPROFILE '.codex'
$configPath = Join-Path $codexDir 'config.toml'
$confPath   = Join-Path $codexDir 'newapi-provider.conf'
$Utf8NoBom  = New-Object System.Text.UTF8Encoding($false)
New-Item -ItemType Directory -Force -Path $codexDir | Out-Null

# --- helpers -----------------------------------------------------------------
function Read-Config {
    if (Test-Path $configPath) { return (Get-Content $configPath -Raw) }
    return ''
}
function Test-OnGateway([string]$content) {
    return ($content -match 'model_provider\s*=\s*"newapi"') -or ($content -match '\[model_providers\.newapi\]')
}
function Get-TokenFromConfig([string]$content) {
    # Only trust a token that sits inside OUR provider table.
    $m = [regex]::Match($content, '(?s)\[model_providers\.newapi\].*?experimental_bearer_token\s*=\s*"([^"]+)"')
    if ($m.Success) { return $m.Groups[1].Value }
    return ''
}
function Get-SavedToken {
    if (Test-Path $confPath) {
        foreach ($l in Get-Content $confPath) {
            if ($l -match '^\s*NEWAPI_TOKEN\s*=\s*(.+)$') { return $Matches[1].Trim() }
        }
    }
    return ''
}
function Save-Token([string]$tok) {
    [System.IO.File]::WriteAllText($confPath, "NEWAPI_URL=$Gateway`r`nNEWAPI_TOKEN=$tok`r`n", $Utf8NoBom)
}
function Remove-GatewayBits([string]$content) {
    # Drop `model_provider = "newapi"` and the whole [model_providers.newapi] table; keep everything else.
    $out       = New-Object System.Collections.Generic.List[string]
    $skipTable = $false
    foreach ($ln in ($content -split "`r?`n")) {
        if ($ln -match '^\s*\[') {
            $skipTable = ($ln -match '^\s*\[model_providers\.newapi\]\s*$')
            if ($skipTable) { continue }
        }
        if ($skipTable) { continue }
        if ($ln -match '^\s*model_provider\s*=\s*"newapi"\s*$') { continue }
        $out.Add($ln)
    }
    return (($out -join "`r`n") -replace '(\r?\n){3,}', "`r`n`r`n").Trim()
}
function Write-Config([string]$content) {
    # UTF-8 without BOM (TOML parsers dislike a BOM).
    [System.IO.File]::WriteAllText($configPath, $content.TrimEnd() + "`r`n", $Utf8NoBom)
}

# --- Detect current state ----------------------------------------------------
$content   = Read-Config
$onGateway = Test-OnGateway $content

# Remember a token that is already in the config (e.g. from the old installer),
# so a later round-trip (default -> gateway) does not ask for it again.
if ($onGateway -and (Get-SavedToken) -eq '') {
    $t = Get-TokenFromConfig $content
    if (-not [string]::IsNullOrWhiteSpace($t)) { Save-Token $t }
}

$currentLabel = if ($onGateway) { "New API gateway ($Gateway)" } else { 'Default (ChatGPT / OpenAI login)' }

Write-Host ''
Write-Host '=== MobileSentrix - Codex provider switch ===' -ForegroundColor Cyan
Write-Host ("Current provider: {0}" -f $currentLabel) -ForegroundColor Yellow
Write-Host ''
Write-Host '  [1] New API gateway   (ai.mobilesentrix.com)'
Write-Host '  [2] Default           (ChatGPT / OpenAI login)'
$default = if ($onGateway) { '2' } else { '1' }
$choice  = Read-Host ("Switch to [1/2]  (ENTER = {0}, the other one)" -f $default)
if ([string]::IsNullOrWhiteSpace($choice)) { $choice = $default }

# =============================================================================
if ($choice -eq '1') {
    # --- [1] New API gateway --------------------------------------------------

    # 1) Make sure the Codex CLI exists (install if missing).
    Write-Host ''
    if (Get-Command codex -ErrorAction SilentlyContinue) {
        Write-Host '[1/3] Codex CLI already installed - OK.' -ForegroundColor Green
    } else {
        Write-Host '[1/3] Codex CLI not found - installing (official native installer)...' -ForegroundColor Yellow
        try {
            Invoke-Expression (Invoke-RestMethod -Uri 'https://chatgpt.com/codex/install.ps1')
        } catch {
            Write-Host "Install failed: $($_.Exception.Message)" -ForegroundColor Red
            Write-Host 'Try manually:  irm https://chatgpt.com/codex/install.ps1 | iex' -ForegroundColor DarkGray
            Write-Host '(or, if you use Node.js:  npm install -g @openai/codex)' -ForegroundColor DarkGray
            Write-Host 'Then run this script again.' -ForegroundColor DarkGray
            return
        }
        # Put codex on PATH for this session + future terminals.
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
            Write-Host '      Note: codex not found after install - open a NEW PowerShell later and check `codex --version`.' -ForegroundColor DarkGray
        }
    }

    # 2) Token: saved one (ENTER to keep) or ask for it.
    Write-Host ''
    $saved = Get-SavedToken
    if (-not [string]::IsNullOrWhiteSpace($saved)) {
        Write-Host '[2/3] A new-api token is already saved.' -ForegroundColor Green
        Write-Host '      Press ENTER to keep it, or paste a new one to replace it.' -ForegroundColor DarkGray
        $secure  = Read-Host '      new-api token (ENTER = keep)' -AsSecureString
        $entered = [System.Net.NetworkCredential]::new('', $secure).Password
        $token   = if ([string]::IsNullOrWhiteSpace($entered)) { $saved } else { $entered }
    } else {
        Write-Host '[2/3] Enter your NEW-API token.' -ForegroundColor Yellow
        Write-Host '      Where to get it: open https://ai.mobilesentrix.com -> log in -> Tokens -> copy/create a key (sk-...)' -ForegroundColor DarkGray
        Write-Host '      The token must be in the "codex" group (it has the gpt/codex models).' -ForegroundColor DarkGray
        $secure = Read-Host '      new-api token' -AsSecureString
        $token  = [System.Net.NetworkCredential]::new('', $secure).Password
        if ([string]::IsNullOrWhiteSpace($token)) {
            Write-Host 'No token entered - nothing was changed. Re-run when you have it.' -ForegroundColor Red
            return
        }
    }
    Save-Token $token

    # 3) Add the gateway provider to config.toml (keep everything else).
    Write-Host ''
    Write-Host '[3/3] Pointing Codex at the MobileSentrix gateway...' -ForegroundColor Yellow
    if (Test-Path $configPath) { Copy-Item $configPath "$configPath.bak" -Force }

    $rest = Remove-GatewayBits $content

    $providerTable = @"
[model_providers.newapi]
# MobileSentrix new-api gateway. Model is intentionally NOT set - Codex uses its
# own default gpt/codex model. Your token must be in the "codex" group.
name = "new-api gateway"
base_url = "$Gateway"
experimental_bearer_token = "$token"
wire_api = "responses"
request_max_retries = 4
"@
    # Codex on Windows needs an elevated sandbox to run commands; add it once if absent.
    $windowsTable = if ($rest -match '(?m)^\s*\[windows\]\s*$') { '' } else { "[windows]`r`nsandbox = `"elevated`"`r`n" }

    $header = 'model_provider = "newapi"'
    # `model_provider` is a top-level key, so it must come BEFORE any [table] -> put it first.
    $new = $header + "`r`n`r`n" + $rest + "`r`n`r`n" + $providerTable + "`r`n`r`n" + $windowsTable
    Write-Config ($new -replace '(\r?\n){3,}', "`r`n`r`n")

    Write-Host ''
    Write-Host 'Done! Codex is set to the MobileSentrix gateway.' -ForegroundColor Green
    Write-Host ("  Endpoint : {0}" -f $Gateway)
    Write-Host ("  Config   : {0}" -f $configPath)
    if (Test-Path "$configPath.bak") { Write-Host ("  Backup   : {0}.bak (previous config)" -f $configPath) -ForegroundColor DarkGray }
    Write-Host ''
    Write-Host 'Restart Codex (open a NEW PowerShell), then smoke-test:' -ForegroundColor Cyan
    Write-Host '  codex exec "reply with exactly: ok"'
    Write-Host ''
    Write-Host 'If you see "No available channel for model <x> under group default" -> your' -ForegroundColor DarkGray
    Write-Host 'new-api token is not in the "codex" group; ask the admin to move it there.' -ForegroundColor DarkGray
    Write-Host ''
}
elseif ($choice -eq '2') {
    # --- [2] Default (ChatGPT / OpenAI) ---------------------------------------
    Write-Host ''
    if (-not $onGateway) {
        Write-Host 'Codex is already on its default provider - nothing to change.' -ForegroundColor Green
        Write-Host ''
        return
    }

    Copy-Item $configPath "$configPath.gateway.bak" -Force

    $rest = Remove-GatewayBits $content
    $meaningful = ($rest -replace '(?m)^\s*#.*$', '').Trim()
    if ([string]::IsNullOrWhiteSpace($meaningful)) {
        Remove-Item $configPath -Force
        Write-Host 'Removed the gateway config; Codex will use its built-in defaults.' -ForegroundColor Green
    } else {
        Write-Config $rest
        Write-Host 'Removed the new-api provider; everything else in config.toml was kept.' -ForegroundColor Green
    }

    Write-Host ''
    Write-Host ("  Config   : {0}" -f $configPath) -ForegroundColor DarkGray
    Write-Host ("  Backup   : {0}.gateway.bak (the gateway config)" -f $configPath) -ForegroundColor DarkGray
    Write-Host ("  Token    : kept in {0} (re-run and pick [1] to go back - no re-entry needed)" -f $confPath) -ForegroundColor DarkGray
    Write-Host ''
    Write-Host 'Restart Codex. It now uses your normal ChatGPT / OpenAI login.' -ForegroundColor Cyan
    Write-Host 'If it asks you to sign in, run:  codex login' -ForegroundColor DarkGray
    Write-Host ''
}
else {
    Write-Host ("Invalid choice '{0}' - nothing changed." -f $choice) -ForegroundColor Red
    return
}
