#!/bin/bash
# =============================================================================
#  MobileSentrix - Switch Claude Code between the new-api gateway and Anthropic
#  (macOS / Linux)
#
#  One script, two directions:
#    [1] New API gateway  -> Claude Code talks to ai.mobilesentrix.com (needs a new-api token)
#    [2] Anthropic        -> direct claude.ai subscription login (no proxy)
#
#  - Asks what you want to do, then (only for [1]) asks for your token.
#  - The token is remembered in ~/.claude/claude-provider.conf, so switching
#    back and forth does NOT ask for it again.
#  - Only ANTHROPIC_BASE_URL / ANTHROPIC_AUTH_TOKEN in the "env" block of
#    ~/.claude/settings.json are added/removed; everything else in that file
#    (permissions, hooks, other env vars) is left untouched.
#  - Installs the Claude Code CLI if it is missing (only when switching to [1]).
#  - Safe to re-run as many times as you like.
#
#  Run it with:   curl -fsSL https://tinyurl.com/ms-claude-switch-mac | bash
#  Restart Claude Code after switching for it to take effect.
# =============================================================================
set -eu

GATEWAY='https://ai.mobilesentrix.com'
CLAUDE_DIR="$HOME/.claude"
SETTINGS="$CLAUDE_DIR/settings.json"
CONF="$CLAUDE_DIR/claude-provider.conf"
mkdir -p "$CLAUDE_DIR"

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

# --- JSON helper: python3 (ships with macOS) or node --------------------------
# usage: json_env <get-base|get-token|set URL TOKEN|clear>
json_env() {
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$SETTINGS" "$@" <<'PY'
import json, sys, os
path, op = sys.argv[1], sys.argv[2]
d = {}
if os.path.exists(path):
    try:
        with open(path) as f: d = json.load(f)
    except Exception:
        if op in ("get-base", "get-token"): sys.exit(0)
        sys.stderr.write("(existing settings.json was invalid JSON - starting a clean one)\n")
        d = {}
env = d.get("env") or {}
if op == "get-base":  print(env.get("ANTHROPIC_BASE_URL", "")); sys.exit(0)
if op == "get-token": print(env.get("ANTHROPIC_AUTH_TOKEN", "")); sys.exit(0)
if op == "set":
    env["ANTHROPIC_BASE_URL"] = sys.argv[3]
    env["ANTHROPIC_AUTH_TOKEN"] = sys.argv[4]
    env.pop("ANTHROPIC_API_KEY", None)
    d["env"] = env
elif op == "clear":
    for k in ("ANTHROPIC_BASE_URL", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_API_KEY"): env.pop(k, None)
    if env: d["env"] = env
    else: d.pop("env", None)
tmp = path + ".tmp"
with open(tmp, "w") as f:
    json.dump(d, f, indent=2); f.write("\n")
os.replace(tmp, path)
PY
  elif command -v node >/dev/null 2>&1; then
    node - "$SETTINGS" "$@" <<'JS'
const fs = require("fs");
const [path, op, url, tok] = process.argv.slice(2);
let d = {};
if (fs.existsSync(path)) {
  try { d = JSON.parse(fs.readFileSync(path, "utf8")); }
  catch (e) { if (op.startsWith("get-")) process.exit(0); process.stderr.write("(existing settings.json was invalid JSON - starting a clean one)\n"); d = {}; }
}
const env = d.env || {};
if (op === "get-base")  { console.log(env.ANTHROPIC_BASE_URL || "");   process.exit(0); }
if (op === "get-token") { console.log(env.ANTHROPIC_AUTH_TOKEN || ""); process.exit(0); }
if (op === "set") { env.ANTHROPIC_BASE_URL = url; env.ANTHROPIC_AUTH_TOKEN = tok; delete env.ANTHROPIC_API_KEY; d.env = env; }
else if (op === "clear") { for (const k of ["ANTHROPIC_BASE_URL","ANTHROPIC_AUTH_TOKEN","ANTHROPIC_API_KEY"]) delete env[k]; if (Object.keys(env).length) d.env = env; else delete d.env; }
fs.writeFileSync(path + ".tmp", JSON.stringify(d, null, 2) + "\n");
fs.renameSync(path + ".tmp", path);
JS
  else
    say "$C_RED" 'Need python3 or node to edit ~/.claude/settings.json - neither found.'
    info 'On macOS, run:  xcode-select --install   (gives you python3), then re-run this script.'
    exit 1
  fi
}

saved_token() {
  [ -f "$CONF" ] || return 0
  sed -n 's/^[[:space:]]*NEWAPI_TOKEN[[:space:]]*=[[:space:]]*//p' "$CONF" | head -n1 | tr -d '[:space:]'
}
save_token() {
  printf '# Local config for the MobileSentrix new-api gateway (do NOT commit).\nNEWAPI_URL=%s\nNEWAPI_TOKEN=%s\n' "$GATEWAY" "$1" > "$CONF"
  chmod 600 "$CONF"
}

# --- Detect current state ----------------------------------------------------
CUR_BASE="$(json_env get-base)"
if [ -n "$CUR_BASE" ]; then ON_GATEWAY=1; else ON_GATEWAY=0; fi

# Remember a token that is already in settings.json (e.g. from an older setup),
# so a later round-trip (Anthropic -> gateway) does not ask for it again.
if [ "$ON_GATEWAY" = 1 ] && [ -z "$(saved_token)" ]; then
  t="$(json_env get-token)"
  [ -n "$t" ] && save_token "$t"
fi

if [ "$ON_GATEWAY" = 1 ]; then CURRENT="New API gateway ($CUR_BASE)"; else CURRENT='Anthropic (claude.ai subscription)'; fi

say '' ''
say "$C_CYAN" '=== MobileSentrix - Claude Code provider switch ==='
say "$C_YELLOW" "Current provider: $CURRENT"
say '' ''
say '' '  [1] New API gateway   (ai.mobilesentrix.com)'
say '' '  [2] Anthropic         (claude.ai subscription, no proxy)'
if [ "$ON_GATEWAY" = 1 ]; then DEFAULT=2; else DEFAULT=1; fi
ask "Switch to [1/2]  (ENTER = $DEFAULT, the other one): "
CHOICE="$(printf '%s' "$REPLY" | tr -d '[:space:]')"
[ -z "$CHOICE" ] && CHOICE="$DEFAULT"

# =============================================================================
case "$CHOICE" in
1)
  # --- [1] New API gateway --------------------------------------------------

  # 1) Make sure the Claude Code CLI exists (install if missing).
  say '' ''
  if command -v claude >/dev/null 2>&1; then
    say "$C_GREEN" '[1/3] Claude Code CLI already installed - OK.'
  else
    say "$C_YELLOW" '[1/3] Claude Code CLI not found - installing (official native installer)...'
    if ! curl -fsSL https://claude.ai/install.sh | bash >&2; then
      say "$C_RED" 'Install failed.'
      info 'Try manually:  curl -fsSL https://claude.ai/install.sh | bash'
      info 'Then run this script again.'
      exit 1
    fi
    # The installer puts `claude` in ~/.local/bin; make sure it is on PATH.
    BIN="$HOME/.local/bin"
    case ":$PATH:" in *":$BIN:"*) ;; *) export PATH="$BIN:$PATH" ;; esac
    if [ -x "$BIN/claude" ]; then
      for rc in "$HOME/.zshrc" "$HOME/.bashrc"; do
        if [ -f "$rc" ] && ! grep -q '\.local/bin' "$rc"; then
          printf '\n# Claude Code CLI\nexport PATH="$HOME/.local/bin:$PATH"\n' >> "$rc"
          info "      Added ~/.local/bin to PATH in $rc"
        fi
      done
    fi
    if command -v claude >/dev/null 2>&1; then
      say "$C_GREEN" '      Claude Code CLI installed.'
    else
      say "$C_RED" 'claude not found after install. Open a NEW terminal and run this script again.'
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
    info "      Where to get it: open $GATEWAY -> log in -> Tokens -> copy/create a key (sk-...)"
    ask_secret '      new-api token: '
    TOKEN="$(printf '%s' "$REPLY" | tr -d '[:space:]')"
    if [ -z "$TOKEN" ]; then
      say "$C_RED" 'No token entered - nothing was changed. Re-run when you have it.'
      exit 1
    fi
  fi
  save_token "$TOKEN"

  # 3) Point settings.json at the gateway (keep everything else).
  say '' ''
  say "$C_YELLOW" '[3/3] Pointing Claude Code at the MobileSentrix gateway...'
  [ -f "$SETTINGS" ] && cp "$SETTINGS" "$SETTINGS.bak"
  json_env set "$GATEWAY" "$TOKEN"

  say '' ''
  say "$C_GREEN" 'Done! Claude Code is set to the MobileSentrix gateway.'
  say '' "  Endpoint : $GATEWAY"
  say '' "  Settings : $SETTINGS"
  [ -f "$SETTINGS.bak" ] && info "  Backup   : $SETTINGS.bak (previous settings)"
  say '' ''
  say "$C_CYAN" 'Restart Claude Code (close all sessions and relaunch) for it to take effect.'
  say '' ''
  ;;

2)
  # --- [2] Anthropic (claude.ai subscription) -------------------------------
  say '' ''
  if [ "$ON_GATEWAY" = 0 ]; then
    say "$C_GREEN" 'Claude Code is already on Anthropic (no proxy) - nothing to change.'
    say '' ''
    exit 0
  fi

  cp "$SETTINGS" "$SETTINGS.gateway.bak"
  json_env clear

  say "$C_GREEN" 'Removed the gateway settings; Claude Code now uses your claude.ai login.'
  say '' ''
  info "  Settings : $SETTINGS"
  info "  Backup   : $SETTINGS.gateway.bak (the gateway settings)"
  info "  Token    : kept in $CONF (re-run and pick [1] to go back - no re-entry needed)"
  say '' ''
  say "$C_CYAN" 'Restart Claude Code (close all sessions and relaunch) for it to take effect.'
  info 'If it asks you to sign in, run:  claude   and follow the login prompt.'
  say '' ''
  ;;

*)
  say "$C_RED" "Invalid choice '$CHOICE' - nothing changed."
  exit 1
  ;;
esac
