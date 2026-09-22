#!/bin/bash
# =============================================================================
#  MobileSentrix - Switch Codex CLI between the new-api gateway and its default
#  (macOS / Linux)
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
#  Run it with:   curl -fsSL https://tinyurl.com/ms-codex-switch | bash
#  Restart Codex after switching for it to take effect.
# =============================================================================
set -eu

GATEWAY='https://ai.mobilesentrix.com/v1'
CODEX_DIR="$HOME/.codex"
CONFIG="$CODEX_DIR/config.toml"
CONF="$CODEX_DIR/newapi-provider.conf"
mkdir -p "$CODEX_DIR"

# Colours (only when talking to a terminal).
if [ -t 2 ]; then
  C_CYAN=$'\033[36m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_RED=$'\033[31m'; C_GRAY=$'\033[90m'; C_OFF=$'\033[0m'
else
  C_CYAN=''; C_GREEN=''; C_YELLOW=''; C_RED=''; C_GRAY=''; C_OFF=''
fi
say()  { printf '%s%s%s\n' "$1" "$2" "$C_OFF" >&2; }
info() { say "$C_GRAY" "$1"; }

# When run via `curl | bash`, stdin is the script itself -> read answers from the terminal.
TTY=/dev/tty
if ! ( : < "$TTY" ) 2>/dev/null; then TTY=/dev/stdin; fi
ask()        { printf '%s' "$1" >&2; IFS= read -r REPLY < "$TTY" || REPLY=''; }
ask_secret() { printf '%s' "$1" >&2; IFS= read -rs REPLY < "$TTY" || REPLY=''; printf '\n' >&2; }

# --- helpers -----------------------------------------------------------------
read_config() { if [ -f "$CONFIG" ]; then cat "$CONFIG"; fi; }

on_gateway() {
  [ -f "$CONFIG" ] || return 1
  grep -Eq '^[[:space:]]*model_provider[[:space:]]*=[[:space:]]*"newapi"' "$CONFIG" \
    || grep -Eq '^[[:space:]]*\[model_providers\.newapi\]' "$CONFIG"
}

token_from_config() {
  # Only trust a token that sits inside OUR provider table.
  [ -f "$CONFIG" ] || return 0
  awk '
    /^[[:space:]]*\[/ { inside = ($0 ~ /^[[:space:]]*\[model_providers\.newapi\][[:space:]]*$/) ; next }
    inside && /^[[:space:]]*experimental_bearer_token[[:space:]]*=/ {
      sub(/^[^"]*"/, ""); sub(/".*$/, ""); print; exit
    }' "$CONFIG"
}

saved_token() {
  [ -f "$CONF" ] || return 0
  sed -n 's/^[[:space:]]*NEWAPI_TOKEN[[:space:]]*=[[:space:]]*//p' "$CONF" | head -n1 | tr -d '[:space:]'
}

save_token() {
  printf 'NEWAPI_URL=%s\nNEWAPI_TOKEN=%s\n' "$GATEWAY" "$1" > "$CONF"
  chmod 600 "$CONF"
}

# Drop `model_provider = "newapi"` and the whole [model_providers.newapi] table; keep everything else.
strip_gateway() {
  awk '
    /^[[:space:]]*\[/ {
      skip = ($0 ~ /^[[:space:]]*\[model_providers\.newapi\][[:space:]]*$/)
      if (skip) next
    }
    skip { next }
    /^[[:space:]]*model_provider[[:space:]]*=[[:space:]]*"newapi"[[:space:]]*$/ { next }
    { print }
  ' | cat -s | sed '/./,$!d' | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}'
}

# --- Detect current state ----------------------------------------------------
if on_gateway; then ON_GATEWAY=1; else ON_GATEWAY=0; fi

# Remember a token that is already in the config (e.g. from an older setup),
# so a later round-trip (default -> gateway) does not ask for it again.
if [ "$ON_GATEWAY" = 1 ] && [ -z "$(saved_token)" ]; then
  t="$(token_from_config)"
  [ -n "$t" ] && save_token "$t"
fi

if [ "$ON_GATEWAY" = 1 ]; then CURRENT="New API gateway ($GATEWAY)"; else CURRENT='Default (ChatGPT / OpenAI login)'; fi

say '' ''
say "$C_CYAN" '=== MobileSentrix - Codex provider switch ==='
say "$C_YELLOW" "Current provider: $CURRENT"
say '' ''
say '' '  [1] New API gateway   (ai.mobilesentrix.com)'
say '' '  [2] Default           (ChatGPT / OpenAI login)'
if [ "$ON_GATEWAY" = 1 ]; then DEFAULT=2; else DEFAULT=1; fi
ask "Switch to [1/2]  (ENTER = $DEFAULT, the other one): "
CHOICE="$(printf '%s' "$REPLY" | tr -d '[:space:]')"
[ -z "$CHOICE" ] && CHOICE="$DEFAULT"

# =============================================================================
case "$CHOICE" in
1)
  # --- [1] New API gateway --------------------------------------------------

  # 1) Make sure the Codex CLI exists (install if missing).
  say '' ''
  if command -v codex >/dev/null 2>&1; then
    say "$C_GREEN" '[1/3] Codex CLI already installed - OK.'
  else
    say "$C_YELLOW" '[1/3] Codex CLI not found - installing...'
    if command -v brew >/dev/null 2>&1; then
      info '      via Homebrew: brew install --cask codex'
      brew install --cask codex >&2 || true
    fi
    if ! command -v codex >/dev/null 2>&1 && command -v npm >/dev/null 2>&1; then
      info '      via npm: npm install -g @openai/codex'
      npm install -g @openai/codex >&2 || true
    fi
    if command -v codex >/dev/null 2>&1; then
      say "$C_GREEN" '      Codex CLI installed.'
    else
      say "$C_RED" 'Could not install Codex automatically.'
      info 'Install it manually, then run this script again:'
      info '  brew install --cask codex        (Homebrew)'
      info '  npm install -g @openai/codex     (Node.js)'
      exit 1
    fi
  fi

  # 2) Token: saved one (ENTER to keep) or ask for it.
  say '' ''
  SAVED="$(saved_token)"
  if [ -n "$SAVED" ]; then
    say "$C_GREEN" '[2/3] A new-api token is already saved.'
    info '      Press ENTER to keep it, or paste a new one to replace it.'
    ask_secret '      new-api token (ENTER = keep): '
    ENTERED="$(printf '%s' "$REPLY" | tr -d '[:space:]')"
    if [ -n "$ENTERED" ]; then TOKEN="$ENTERED"; else TOKEN="$SAVED"; fi
  else
    say "$C_YELLOW" '[2/3] Enter your NEW-API token.'
    info '      Where to get it: open https://ai.mobilesentrix.com -> log in -> Tokens -> copy/create a key (sk-...)'
    info '      The token must be in the "codex" group (it has the gpt/codex models).'
    ask_secret '      new-api token: '
    TOKEN="$(printf '%s' "$REPLY" | tr -d '[:space:]')"
    if [ -z "$TOKEN" ]; then
      say "$C_RED" 'No token entered - nothing was changed. Re-run when you have it.'
      exit 1
    fi
  fi
  save_token "$TOKEN"

  # 3) Add the gateway provider to config.toml (keep everything else).
  say '' ''
  say "$C_YELLOW" '[3/3] Pointing Codex at the MobileSentrix gateway...'
  [ -f "$CONFIG" ] && cp "$CONFIG" "$CONFIG.bak"

  REST="$(read_config | strip_gateway)"

  {
    # `model_provider` is a top-level key, so it must come BEFORE any [table] -> it goes first.
    printf '%s\n' 'model_provider = "newapi"'
    if [ -n "$REST" ]; then printf '\n%s\n' "$REST"; fi
    printf '\n'
    printf '%s\n' \
      '[model_providers.newapi]' \
      '# MobileSentrix new-api gateway. Model is intentionally NOT set - Codex uses its' \
      '# own default gpt/codex model. Your token must be in the "codex" group.' \
      'name = "new-api gateway"' \
      "base_url = \"$GATEWAY\"" \
      "experimental_bearer_token = \"$TOKEN\"" \
      'wire_api = "responses"' \
      'request_max_retries = 4'
  } > "$CONFIG.tmp"
  mv "$CONFIG.tmp" "$CONFIG"

  say '' ''
  say "$C_GREEN" 'Done! Codex is set to the MobileSentrix gateway.'
  say '' "  Endpoint : $GATEWAY"
  say '' "  Config   : $CONFIG"
  [ -f "$CONFIG.bak" ] && info "  Backup   : $CONFIG.bak (previous config)"
  say '' ''
  say "$C_CYAN" 'Restart Codex, then smoke-test:'
  say '' '  codex exec "reply with exactly: ok"'
  say '' ''
  info 'If you see "No available channel for model <x> under group default" -> your'
  info 'new-api token is not in the "codex" group; ask the admin to move it there.'
  say '' ''
  ;;

2)
  # --- [2] Default (ChatGPT / OpenAI) ---------------------------------------
  say '' ''
  if [ "$ON_GATEWAY" = 0 ]; then
    say "$C_GREEN" 'Codex is already on its default provider - nothing to change.'
    say '' ''
    exit 0
  fi

  cp "$CONFIG" "$CONFIG.gateway.bak"

  REST="$(read_config | strip_gateway)"
  MEANINGFUL="$(printf '%s\n' "$REST" | grep -Ev '^[[:space:]]*(#.*)?$' || true)"
  if [ -z "$MEANINGFUL" ]; then
    rm -f "$CONFIG"
    say "$C_GREEN" 'Removed the gateway config; Codex will use its built-in defaults.'
  else
    printf '%s\n' "$REST" > "$CONFIG.tmp"
    mv "$CONFIG.tmp" "$CONFIG"
    say "$C_GREEN" 'Removed the new-api provider; everything else in config.toml was kept.'
  fi

  say '' ''
  info "  Config   : $CONFIG"
  info "  Backup   : $CONFIG.gateway.bak (the gateway config)"
  info "  Token    : kept in $CONF (re-run and pick [1] to go back - no re-entry needed)"
  say '' ''
  say "$C_CYAN" 'Restart Codex. It now uses your normal ChatGPT / OpenAI login.'
  info 'If it asks you to sign in, run:  codex login'
  say '' ''
  ;;

*)
  say "$C_RED" "Invalid choice '$CHOICE' - nothing changed."
  exit 1
  ;;
esac
