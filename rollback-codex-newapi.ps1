# =============================================================================
#  MobileSentrix - ROLL BACK Codex from the new-api gateway to its default
#
#  Reverts what install-codex-newapi.ps1 did: removes the `newapi` provider from
#  ~/.codex/config.toml so Codex goes back to its normal ChatGPT / OpenAI login.
#  Safe to re-run. Nothing else in the config is touched.
#
#  Run it with:   irm https://<your-tiny-url> | iex
#  To go back to the gateway later:  irm https://tinyurl.com/ms-codex | iex
# =============================================================================

$ErrorActionPreference = 'Stop'

$codexDir   = Join-Path $env:USERPROFILE '.codex'
$configPath = Join-Path $codexDir 'config.toml'

Write-Host ''
Write-Host '=== MobileSentrix - Codex rollback (gateway -> default) ===' -ForegroundColor Cyan
Write-Host ''

if (-not (Test-Path $configPath)) {
    Write-Host 'No ~/.codex/config.toml found - Codex is already on its default (ChatGPT login). Nothing to roll back.' -ForegroundColor Green
    return
}

$content   = Get-Content $configPath -Raw
$onGateway = ($content -match 'model_provider\s*=\s*"newapi"') -or ($content -match '\[model_providers\.newapi\]')
if (-not $onGateway) {
    Write-Host 'Codex is not pointed at the new-api gateway - nothing to roll back.' -ForegroundColor Green
    return
}

# Keep a copy of the current (gateway) config before changing anything.
Copy-Item $configPath "$configPath.gateway.bak" -Force

# 1) Prefer restoring a genuine pre-gateway backup, if one exists and is clean.
$restored = $false
if (Test-Path "$configPath.bak") {
    $bak = Get-Content "$configPath.bak" -Raw
    if ($bak -notmatch 'model_provider\s*=\s*"newapi"' -and $bak -notmatch '\[model_providers\.newapi\]') {
        Copy-Item "$configPath.bak" $configPath -Force
        $restored = $true
        Write-Host 'Restored your previous (pre-gateway) config.toml from backup.' -ForegroundColor Green
    }
}

# 2) Otherwise surgically remove only the gateway bits.
if (-not $restored) {
    $lines     = $content -split "`r?`n"
    $out       = New-Object System.Collections.Generic.List[string]
    $skipTable = $false
    foreach ($ln in $lines) {
        if ($ln -match '^\s*\[') {
            $skipTable = ($ln -match '^\s*\[model_providers\.newapi\]\s*$')
            if ($skipTable) { continue }      # drop the [model_providers.newapi] header
        }
        if ($skipTable) { continue }          # drop lines inside that table
        if ($ln -match '^\s*model_provider\s*=\s*"newapi"\s*$') { continue }  # drop the pointer line
        $out.Add($ln)
    }
    $new = ($out -join "`r`n").Trim()
    $meaningful = ($new -replace '(?m)^\s*#.*$', '').Trim()
    if ([string]::IsNullOrWhiteSpace($meaningful)) {
        Remove-Item $configPath -Force
        Write-Host 'Removed the gateway config; Codex will use its built-in defaults.' -ForegroundColor Green
    } else {
        [System.IO.File]::WriteAllText($configPath, $new + "`r`n", (New-Object System.Text.UTF8Encoding($false)))
        Write-Host 'Removed the new-api provider; Codex reverts to its default provider.' -ForegroundColor Green
    }
}

# Done
Write-Host ''
Write-Host ("Config   : {0}" -f $configPath) -ForegroundColor DarkGray
Write-Host ("Backup   : {0}.gateway.bak (the gateway config, in case you want it back)" -f $configPath) -ForegroundColor DarkGray
Write-Host ''
Write-Host 'Restart Codex. It now uses your normal ChatGPT / OpenAI login.' -ForegroundColor Cyan
Write-Host 'If it asks you to sign in, run:  codex login' -ForegroundColor DarkGray
Write-Host 'To return to the MobileSentrix gateway:  irm https://tinyurl.com/ms-codex | iex' -ForegroundColor DarkGray
Write-Host ''
