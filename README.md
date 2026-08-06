# ms-claude-setup

PowerShell helpers to set up and switch the **Claude Code CLI** for MobileSentrix
(Windows). Each script is self-contained and safe to re-run.

Endpoint: `https://ai.mobilesentrix.com` (the MobileSentrix new-api gateway).

---

## 1. `install-newapi.ps1` — install + point at the gateway

Installs the Claude Code CLI (skips if already installed), makes sure `claude` is
on `PATH`, asks for your **new-api token**, and points Claude Code at the gateway.

```powershell
irm https://tinyurl.com/ms-install | iex
```

## 2. `switch-provider.ps1` — flip between new-api and native Anthropic

For machines that **already** have Claude Code. Toggles the provider:

- **New API** → routes through `ai.mobilesentrix.com` (uses your saved token; asks once if not stored)
- **Anthropic** → direct `claude.ai` subscription (no proxy)

```powershell
irm https://tinyurl.com/ms-claude-switch | iex
```

Press **ENTER** at the prompt to switch to the other provider.
**Restart Claude Code** after any change for it to take effect.

## 3. `install-codex-newapi.ps1` — install Codex + point at the gateway

Installs the **Codex CLI** (skips if already installed), makes sure `codex` is on
`PATH`, asks for your **new-api token**, and writes `~/.codex/config.toml` with the
MobileSentrix gateway provider (`base_url = https://ai.mobilesentrix.com/v1`).

```powershell
irm https://tinyurl.com/ms-codex | iex
```

Restart Codex, then smoke-test: `codex exec "reply with exactly: ok"`.
Any existing `config.toml` is backed up to `config.toml.bak` first.

---

## Where things are stored

| What | Path |
|---|---|
| Endpoint + token (active) | `~/.claude/settings.json` → `env.ANTHROPIC_BASE_URL`, `ANTHROPIC_AUTH_TOKEN` |
| Saved new-api token (for toggling back) | `~/.claude/claude-provider.conf` |

**No secrets live in these scripts** — the token is entered at runtime. That is
why this repo can be public (required so `irm | iex` can fetch the raw files).

Get a new-api token: open <https://ai.mobilesentrix.com> → log in → **Tokens** →
copy or create a key (`sk-...`).

---

## Maintaining

Edit a script, commit, push — the raw URLs (and the TinyURLs) serve the latest
version automatically:

```bash
git add . && git commit -m "update" && git push
```

Raw URLs:
- `https://raw.githubusercontent.com/aleksandrmobilesentrix/ms-claude-setup/main/install-newapi.ps1`
- `https://raw.githubusercontent.com/aleksandrmobilesentrix/ms-claude-setup/main/switch-provider.ps1`
- `https://raw.githubusercontent.com/aleksandrmobilesentrix/ms-claude-setup/main/install-codex-newapi.ps1`
