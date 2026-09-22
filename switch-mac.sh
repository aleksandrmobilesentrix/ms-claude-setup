#!/bin/bash
# =============================================================================
#  MobileSentrix - Universal provider switch for Claude Code and Codex
#  (macOS; also works on Linux)
#
#  Choose Claude Code, Codex, or both, then switch the selected clients to:
#    [1] MobileSentrix new-api gateway
#    [2] Their official providers (claude.ai / ChatGPT-OpenAI)
#
#  The script preserves unrelated Claude settings and Codex TOML tables, keeps
#  separate saved tokens for the two clients, and is safe to run repeatedly.
#
#  Run it with:
#    curl -fsSL https://raw.githubusercontent.com/aleksandrmobilesentrix/ms-claude-setup/main/switch-mac.sh | bash
# =============================================================================
set -eu
umask 077

GATEWAY_ROOT='https://ai.mobilesentrix.com'
CLAUDE_GATEWAY="$GATEWAY_ROOT"
CODEX_GATEWAY="$GATEWAY_ROOT/v1"

CLAUDE_DIR="$HOME/.claude"
CLAUDE_SETTINGS="$CLAUDE_DIR/settings.json"
CLAUDE_CONF="$CLAUDE_DIR/claude-provider.conf"

CODEX_DIR="$HOME/.codex"
CODEX_CONFIG="$CODEX_DIR/config.toml"
CODEX_CONF="$CODEX_DIR/newapi-provider.conf"

mkdir -p "$CLAUDE_DIR" "$CODEX_DIR"

# Colours (only when output is connected to a terminal).
if [ -t 2 ]; then
  C_CYAN=$'\033[36m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_RED=$'\033[31m'; C_GRAY=$'\033[90m'; C_OFF=$'\033[0m'
else
  C_CYAN=''; C_GREEN=''; C_YELLOW=''; C_RED=''; C_GRAY=''; C_OFF=''
fi
say()  { printf '%s%s%s\n' "$1" "$2" "$C_OFF" >&2; }
info() { say "$C_GRAY" "$1"; }
die()  { say "$C_RED" "$1"; exit 1; }

# With `curl | bash`, stdin contains the script, so interactive answers must be
# read from the terminal. When there is no terminal (tests), use stdin.
TTY=/dev/tty
if ! ( : < "$TTY" ) 2>/dev/null; then TTY=/dev/stdin; fi
ask()        { printf '%s' "$1" >&2; IFS= read -r REPLY < "$TTY" || REPLY=''; }
ask_secret() { printf '%s' "$1" >&2; IFS= read -rs REPLY < "$TTY" || REPLY=''; printf '\n' >&2; }
trim_reply() { printf '%s' "$1" | tr -d '[:space:]'; }

# --- Claude settings.json helper -------------------------------------------
# Uses Python (included with current macOS developer tools) or Node. Writes are
# atomic, retain the original file mode, and fail closed on invalid JSON.
# usage: claude_json_env <get-base|get-token|set URL TOKEN|clear>
claude_json_env() {
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$CLAUDE_SETTINGS" "$@" <<'PY'
import json, os, stat, sys

path, op = sys.argv[1], sys.argv[2]
data = {}
mode = 0o600
if os.path.exists(path):
    mode = stat.S_IMODE(os.stat(path).st_mode)
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
        if not isinstance(data, dict):
            raise ValueError("top-level JSON value is not an object")
    except Exception as exc:
        sys.stderr.write(f"Cannot safely edit {path}: invalid JSON ({exc}).\n")
        sys.exit(2)

env = data.get("env")
if not isinstance(env, dict):
    env = {}

if op == "get-base":
    print(env.get("ANTHROPIC_BASE_URL", ""))
    sys.exit(0)
if op == "get-token":
    print(env.get("ANTHROPIC_AUTH_TOKEN", ""))
    sys.exit(0)
if op == "set":
    env["ANTHROPIC_BASE_URL"] = sys.argv[3]
    env["ANTHROPIC_AUTH_TOKEN"] = sys.argv[4]
    env.pop("ANTHROPIC_API_KEY", None)
    data["env"] = env
elif op == "clear":
    for key in ("ANTHROPIC_BASE_URL", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_API_KEY"):
        env.pop(key, None)
    if env:
        data["env"] = env
    else:
        data.pop("env", None)
else:
    sys.stderr.write(f"Unknown JSON operation: {op}\n")
    sys.exit(2)

tmp = path + ".tmp"
fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, mode)
with os.fdopen(fd, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
os.chmod(tmp, mode)
os.replace(tmp, path)
PY
  elif command -v node >/dev/null 2>&1; then
    node - "$CLAUDE_SETTINGS" "$@" <<'JS'
const fs = require("fs");
const [path, op, url, token] = process.argv.slice(2);
let data = {};
let mode = 0o600;
if (fs.existsSync(path)) {
  mode = fs.statSync(path).mode & 0o777;
  try {
    data = JSON.parse(fs.readFileSync(path, "utf8"));
    if (!data || typeof data !== "object" || Array.isArray(data)) throw new Error("top-level JSON value is not an object");
  } catch (error) {
    process.stderr.write(`Cannot safely edit ${path}: invalid JSON (${error.message}).\n`);
    process.exit(2);
  }
}
const env = data.env && typeof data.env === "object" && !Array.isArray(data.env) ? data.env : {};
if (op === "get-base")  { console.log(env.ANTHROPIC_BASE_URL || ""); process.exit(0); }
if (op === "get-token") { console.log(env.ANTHROPIC_AUTH_TOKEN || ""); process.exit(0); }
if (op === "set") {
  env.ANTHROPIC_BASE_URL = url;
  env.ANTHROPIC_AUTH_TOKEN = token;
  delete env.ANTHROPIC_API_KEY;
  data.env = env;
} else if (op === "clear") {
  for (const key of ["ANTHROPIC_BASE_URL", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_API_KEY"]) delete env[key];
  if (Object.keys(env).length) data.env = env; else delete data.env;
} else {
  process.stderr.write(`Unknown JSON operation: ${op}\n`);
  process.exit(2);
}
const tmp = path + ".tmp";
fs.writeFileSync(tmp, JSON.stringify(data, null, 2) + "\n", { mode });
fs.chmodSync(tmp, mode);
fs.renameSync(tmp, path);
JS
  else
    die 'Need python3 or node to safely edit ~/.claude/settings.json.'
  fi
}

claude_saved_token() {
  [ -f "$CLAUDE_CONF" ] || return 0
  sed -n 's/^[[:space:]]*NEWAPI_TOKEN[[:space:]]*=[[:space:]]*//p' "$CLAUDE_CONF" | head -n1 | tr -d '[:space:]'
}

save_claude_token() {
  printf '# Local config for the MobileSentrix new-api gateway (do NOT commit).\nNEWAPI_URL=%s\nNEWAPI_TOKEN=%s\n' "$CLAUDE_GATEWAY" "$1" > "$CLAUDE_CONF"
  chmod 600 "$CLAUDE_CONF"
}

claude_state() {
  base="$(claude_json_env get-base)"
  normalized="${base%/}"
  if [ -z "$base" ]; then
    printf '%s' 'official'
  elif [ "$normalized" = "$CLAUDE_GATEWAY" ]; then
    printf '%s' 'gateway'
  else
    printf '%s' 'custom'
  fi
}

claude_status_label() {
  case "$1" in
    gateway)  printf '%s' 'MobileSentrix gateway' ;;
    official) printf '%s' 'Anthropic / claude.ai' ;;
    custom)   printf '%s' 'custom ANTHROPIC_BASE_URL' ;;
  esac
}

# --- Codex config.toml helpers ---------------------------------------------
read_codex_config() { if [ -f "$CODEX_CONFIG" ]; then cat "$CODEX_CONFIG"; fi; }

# Read only the top-level model_provider (top-level keys must precede tables).
codex_provider() {
  [ -f "$CODEX_CONFIG" ] || return 0
  awk '
    /^[[:space:]]*\[/ { exit }
    /^[[:space:]]*model_provider[[:space:]]*=/ {
      line = $0
      sub(/^[^=]*=[[:space:]]*"/, "", line)
      sub(/"[[:space:]]*(#.*)?$/, "", line)
      print line
      exit
    }
  ' "$CODEX_CONFIG"
}

codex_token_from_config() {
  [ -f "$CODEX_CONFIG" ] || return 0
  awk '
    /^[[:space:]]*\[/ {
      inside = ($0 ~ /^[[:space:]]*\[model_providers\.newapi\][[:space:]]*$/)
      next
    }
    inside && /^[[:space:]]*experimental_bearer_token[[:space:]]*=/ {
      sub(/^[^"]*"/, ""); sub(/".*$/, ""); print; exit
    }
  ' "$CODEX_CONFIG"
}

codex_saved_token() {
  [ -f "$CODEX_CONF" ] || return 0
  sed -n 's/^[[:space:]]*NEWAPI_TOKEN[[:space:]]*=[[:space:]]*//p' "$CODEX_CONF" | head -n1 | tr -d '[:space:]'
}

save_codex_token() {
  printf 'NEWAPI_URL=%s\nNEWAPI_TOKEN=%s\n' "$CODEX_GATEWAY" "$1" > "$CODEX_CONF"
  chmod 600 "$CODEX_CONF"
}

# Drop only the MobileSentrix selector and provider table; preserve all other
# keys and tables. Output is normalized to avoid blank-line growth on repeats.
strip_codex_gateway() {
  awk '
    /^[[:space:]]*\[/ {
      skip = ($0 ~ /^[[:space:]]*\[model_providers\.newapi\][[:space:]]*$/)
      if (skip) next
    }
    skip { next }
    /^[[:space:]]*model_provider[[:space:]]*=[[:space:]]*"newapi"[[:space:]]*(#.*)?$/ { next }
    { print }
  ' | cat -s | sed '/./,$!d' | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}'
}

codex_state() {
  provider="$(codex_provider)"
  if [ "$provider" = 'newapi' ]; then
    printf '%s' 'gateway'
  elif [ -z "$provider" ]; then
    printf '%s' 'official'
  else
    printf '%s' 'custom'
  fi
}

codex_status_label() {
  case "$1" in
    gateway)  printf '%s' 'MobileSentrix gateway' ;;
    official) printf '%s' 'ChatGPT / OpenAI' ;;
    custom)   printf 'custom provider (%s)' "$(codex_provider)" ;;
  esac
}

# --- Installation checks ---------------------------------------------------
ensure_claude() {
  if command -v claude >/dev/null 2>&1; then
    say "$C_GREEN" 'Claude Code CLI is installed - OK.'
    return 0
  fi

  say "$C_YELLOW" 'Claude Code CLI not found - installing with the official installer...'
  if ! curl -fsSL https://claude.ai/install.sh | bash >&2; then
    die 'Claude Code installation failed. Try: curl -fsSL https://claude.ai/install.sh | bash'
  fi
  BIN="$HOME/.local/bin"
  case ":$PATH:" in *":$BIN:"*) ;; *) export PATH="$BIN:$PATH" ;; esac
  if [ -x "$BIN/claude" ]; then
    for rc in "$HOME/.zshrc" "$HOME/.bashrc"; do
      if [ -f "$rc" ] && ! grep -Fq '$HOME/.local/bin' "$rc"; then
        printf '\n# Claude Code CLI\nexport PATH="$HOME/.local/bin:$PATH"\n' >> "$rc"
        info "Added ~/.local/bin to PATH in $rc"
      fi
    done
  fi
  if ! command -v claude >/dev/null 2>&1; then
    die 'Claude Code was installed but is not on PATH. Open a new terminal and run this script again.'
  fi
  say "$C_GREEN" 'Claude Code CLI installed.'
}

ensure_codex() {
  if command -v codex >/dev/null 2>&1; then
    say "$C_GREEN" 'Codex CLI is installed - OK.'
    return 0
  fi

  say "$C_YELLOW" 'Codex CLI not found - installing...'
  if command -v brew >/dev/null 2>&1; then
    info 'Trying Homebrew: brew install --cask codex'
    brew install --cask codex >&2 || true
  fi
  if ! command -v codex >/dev/null 2>&1 && command -v npm >/dev/null 2>&1; then
    info 'Trying npm: npm install -g @openai/codex'
    npm install -g @openai/codex >&2 || true
  fi
  if ! command -v codex >/dev/null 2>&1; then
    die 'Could not install Codex. Install it with Homebrew or npm, then run this script again.'
  fi
  say "$C_GREEN" 'Codex CLI installed.'
}

# --- Token prompts ----------------------------------------------------------
get_claude_token() {
  saved="$(claude_saved_token)"
  if [ -n "$saved" ]; then
    say "$C_GREEN" 'A Claude Code gateway token is already saved.'
    ask_secret '  Claude token (ENTER = keep, or paste a replacement): '
    entered="$(trim_reply "$REPLY")"
    if [ -n "$entered" ]; then CLAUDE_TOKEN="$entered"; else CLAUDE_TOKEN="$saved"; fi
  else
    say "$C_YELLOW" 'Enter a new-api token with access to Claude models.'
    ask_secret '  Claude token: '
    CLAUDE_TOKEN="$(trim_reply "$REPLY")"
    [ -n "$CLAUDE_TOKEN" ] || die 'No Claude token entered; nothing was changed.'
  fi
}

get_codex_token() {
  saved="$(codex_saved_token)"
  if [ -n "$saved" ]; then
    say "$C_GREEN" 'A Codex gateway token is already saved.'
    ask_secret '  Codex token (ENTER = keep, or paste a replacement): '
    entered="$(trim_reply "$REPLY")"
    if [ -n "$entered" ]; then CODEX_TOKEN="$entered"; else CODEX_TOKEN="$saved"; fi
  else
    say "$C_YELLOW" 'Enter a new-api token in the "codex" group (gpt/codex models).'
    ask_secret '  Codex token: '
    CODEX_TOKEN="$(trim_reply "$REPLY")"
    [ -n "$CODEX_TOKEN" ] || die 'No Codex token entered; nothing was changed.'
  fi
}

# --- Apply changes ----------------------------------------------------------
apply_claude_gateway() {
  [ -f "$CLAUDE_SETTINGS" ] && cp "$CLAUDE_SETTINGS" "$CLAUDE_SETTINGS.bak"
  save_claude_token "$CLAUDE_TOKEN"
  claude_json_env set "$CLAUDE_GATEWAY" "$CLAUDE_TOKEN"
  say "$C_GREEN" 'Claude Code -> MobileSentrix gateway.'
  info "  Settings: $CLAUDE_SETTINGS"
}

apply_claude_official() {
  if [ "$CLAUDE_STATE" = 'official' ]; then
    say "$C_GREEN" 'Claude Code is already using Anthropic / claude.ai.'
    return 0
  fi
  cp "$CLAUDE_SETTINGS" "$CLAUDE_SETTINGS.gateway.bak"
  claude_json_env clear
  say "$C_GREEN" 'Claude Code -> Anthropic / claude.ai.'
  info "  Saved gateway token: $CLAUDE_CONF"
}

apply_codex_gateway() {
  [ -f "$CODEX_CONFIG" ] && cp "$CODEX_CONFIG" "$CODEX_CONFIG.bak"
  save_codex_token "$CODEX_TOKEN"
  rest="$(read_codex_config | strip_codex_gateway)"
  {
    printf '%s\n' 'model_provider = "newapi"'
    if [ -n "$rest" ]; then printf '\n%s\n' "$rest"; fi
    printf '\n%s\n' \
      '[model_providers.newapi]' \
      '# MobileSentrix gateway. Model is intentionally not hardcoded.' \
      'name = "new-api gateway"' \
      "base_url = \"$CODEX_GATEWAY\"" \
      "experimental_bearer_token = \"$CODEX_TOKEN\"" \
      'wire_api = "responses"' \
      'request_max_retries = 4'
  } > "$CODEX_CONFIG.tmp"
  mv "$CODEX_CONFIG.tmp" "$CODEX_CONFIG"
  say "$C_GREEN" 'Codex -> MobileSentrix gateway.'
  info "  Config: $CODEX_CONFIG"
}

apply_codex_official() {
  if [ "$CODEX_STATE" = 'official' ]; then
    say "$C_GREEN" 'Codex is already using ChatGPT / OpenAI.'
    return 0
  fi
  cp "$CODEX_CONFIG" "$CODEX_CONFIG.gateway.bak"
  rest="$(read_codex_config | strip_codex_gateway)"
  meaningful="$(printf '%s\n' "$rest" | grep -Ev '^[[:space:]]*(#.*)?$' || true)"
  if [ -z "$meaningful" ]; then
    rm -f "$CODEX_CONFIG"
  else
    printf '%s\n' "$rest" > "$CODEX_CONFIG.tmp"
    mv "$CODEX_CONFIG.tmp" "$CODEX_CONFIG"
  fi
  say "$C_GREEN" 'Codex -> ChatGPT / OpenAI.'
  info "  Saved gateway token: $CODEX_CONF"
}

# --- Detect state and import legacy active tokens ---------------------------
CLAUDE_STATE="$(claude_state)"
CODEX_STATE="$(codex_state)"

if [ "$CLAUDE_STATE" = 'gateway' ] && [ -z "$(claude_saved_token)" ]; then
  legacy_token="$(claude_json_env get-token)"
  [ -z "$legacy_token" ] || save_claude_token "$legacy_token"
fi
if [ "$CODEX_STATE" = 'gateway' ] && [ -z "$(codex_saved_token)" ]; then
  legacy_token="$(codex_token_from_config)"
  [ -z "$legacy_token" ] || save_codex_token "$legacy_token"
fi

# --- Menu -------------------------------------------------------------------
say '' ''
say "$C_CYAN" '=== MobileSentrix - Claude Code + Codex switcher ==='
say "$C_YELLOW" "Claude Code: $(claude_status_label "$CLAUDE_STATE")"
say "$C_YELLOW" "Codex      : $(codex_status_label "$CODEX_STATE")"
say '' ''
say '' '  [1] Claude Code'
say '' '  [2] Codex'
say '' '  [3] Both Claude Code and Codex'
say '' '  [q] Exit'
ask 'What do you want to switch? [1/2/3/q]: '
SCOPE="$(trim_reply "$REPLY")"

DO_CLAUDE=0
DO_CODEX=0
case "$SCOPE" in
  1) DO_CLAUDE=1 ;;
  2) DO_CODEX=1 ;;
  3) DO_CLAUDE=1; DO_CODEX=1 ;;
  q|Q) say '' 'Nothing changed.'; exit 0 ;;
  *) die "Invalid choice '$SCOPE'; nothing changed." ;;
esac

# ENTER chooses the opposite when all selected clients share a state. For a
# mixed/custom selection it defaults to the gateway, and the prompt says so.
DEFAULT_TARGET=1
if [ "$DO_CLAUDE" = 1 ] && [ "$DO_CODEX" = 0 ] && [ "$CLAUDE_STATE" = 'gateway' ]; then DEFAULT_TARGET=2; fi
if [ "$DO_CODEX" = 1 ] && [ "$DO_CLAUDE" = 0 ] && [ "$CODEX_STATE" = 'gateway' ]; then DEFAULT_TARGET=2; fi
if [ "$DO_CLAUDE" = 1 ] && [ "$DO_CODEX" = 1 ] && [ "$CLAUDE_STATE" = 'gateway' ] && [ "$CODEX_STATE" = 'gateway' ]; then DEFAULT_TARGET=2; fi

say '' ''
say '' '  [1] MobileSentrix gateway'
say '' '  [2] Official providers (Anthropic + ChatGPT/OpenAI)'
ask "Switch to [1/2] (ENTER = $DEFAULT_TARGET): "
TARGET="$(trim_reply "$REPLY")"
[ -n "$TARGET" ] || TARGET="$DEFAULT_TARGET"
case "$TARGET" in 1|2) ;; *) die "Invalid choice '$TARGET'; nothing changed." ;; esac

# A custom Codex model provider cannot be overwritten without losing user
# intent. Refuse before touching either client, especially for the "both" path.
if [ "$DO_CODEX" = 1 ] && [ "$CODEX_STATE" = 'custom' ]; then
  die "Codex uses a custom model_provider ('$(codex_provider)'). It was left untouched; remove or change it manually first."
fi

if [ "$TARGET" = 1 ]; then
  # Preflight everything before the first config write.
  say '' ''
  say "$C_CYAN" 'Checking clients and collecting credentials...'
  if [ "$DO_CLAUDE" = 1 ]; then ensure_claude; fi
  if [ "$DO_CODEX" = 1 ]; then ensure_codex; fi
  if [ "$DO_CLAUDE" = 1 ]; then get_claude_token; fi
  if [ "$DO_CODEX" = 1 ]; then get_codex_token; fi

  say '' ''
  if [ "$DO_CLAUDE" = 1 ]; then apply_claude_gateway; fi
  if [ "$DO_CODEX" = 1 ]; then apply_codex_gateway; fi
else
  say '' ''
  if [ "$DO_CLAUDE" = 1 ]; then apply_claude_official; fi
  if [ "$DO_CODEX" = 1 ]; then apply_codex_official; fi
fi

say '' ''
say "$C_GREEN" 'Done.'
say "$C_CYAN" 'Close all affected Claude Code / Codex sessions and relaunch them.'
if [ "$TARGET" = 1 ] && [ "$DO_CODEX" = 1 ]; then
  info 'Codex smoke test: codex exec "reply with exactly: ok"'
  info 'Its new-api token must be in the "codex" group.'
fi
if [ "$TARGET" = 2 ] && [ "$DO_CODEX" = 1 ]; then
  info 'If Codex asks you to sign in, run: codex login'
fi
say '' ''
