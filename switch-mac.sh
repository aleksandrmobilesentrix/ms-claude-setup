#!/bin/bash
# =============================================================================
#  MobileSentrix - Universal provider switch for Claude Code and Codex
#  (macOS; also works on Linux)
#
#  Choose Claude Code, Codex, or both, then switch the selected clients to:
#    MobileSentrix new-api gateway, or their official providers.
#  Use Up/Down + Enter. Esc or q cancels. No extra UI tools are needed.
#
#  The script preserves unrelated Claude settings and Codex TOML tables, keeps
#  separate saved tokens for the two clients, and is safe to run repeatedly.
#
#  Run it with:
#    curl -fsSL https://tinyurl.com/ms-ai-switch-mac | bash
# =============================================================================
set -eu
umask 077

PLAIN=0
case "${1:-}" in
  --plain) PLAIN=1; shift ;;
  --help|-h)
    printf '%s\n' 'Usage: bash switch-mac.sh [--plain]' \
      'Up/Down: choose; Enter: confirm; Esc/q: cancel.' \
      '--plain: numbered prompts on stdin (for basic terminals and automation).'
    exit 0 ;;
esac
[ "$#" = 0 ] || { printf '%s\n' 'Unknown argument. Use --help.' >&2; exit 1; }

GATEWAY_ROOT='https://ai.mobilesentrix.com'
CLAUDE_GATEWAY="$GATEWAY_ROOT"
CODEX_GATEWAY="$GATEWAY_ROOT/v1"

CLAUDE_DIR="$HOME/.claude"
CLAUDE_SETTINGS="$CLAUDE_DIR/settings.json"
CLAUDE_CONF="$CLAUDE_DIR/claude-provider.conf"

CODEX_DIR="$HOME/.codex"
CODEX_CONFIG="$CODEX_DIR/config.toml"
CODEX_CONF="$CODEX_DIR/newapi-provider.conf"

# Colours (only when output is connected to a terminal).
if [ -t 2 ]; then
  C_CYAN=$'\033[36m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_RED=$'\033[31m'; C_GRAY=$'\033[90m'; C_OFF=$'\033[0m'
else
  C_CYAN=''; C_GREEN=''; C_YELLOW=''; C_RED=''; C_GRAY=''; C_OFF=''
fi
say()  { printf '%s%s%s\n' "$1" "$2" "$C_OFF" >&2; }
info() { say "$C_GRAY" "$1"; }
die()  { say "$C_RED" "$1"; exit 1; }

# Keep input on a separate descriptor: stdin may still contain the downloaded
# script. --plain deliberately uses stdin, even if a controlling tty exists.
INPUT_IS_TTY=0
if [ "$PLAIN" = 0 ] && ( : < /dev/tty ) 2>/dev/null; then
  exec 3</dev/tty
  INPUT_IS_TTY=1
else
  [ -n "${BASH_SOURCE[0]:-}" ] || die 'No terminal available. Download this script and run it with bash switch-mac.sh.'
  exec 3<&0
  if [ -t 3 ]; then INPUT_IS_TTY=1; fi
fi

TERMINAL_STATE=''
CURSOR_HIDDEN=0
restore_terminal() {
  if [ -n "$TERMINAL_STATE" ]; then
    stty "$TERMINAL_STATE" <&3 2>/dev/null || true
    TERMINAL_STATE=''
  fi
  if [ "$CURSOR_HIDDEN" = 1 ]; then
    printf '\033[?25h' >&2
    CURSOR_HIDDEN=0
  fi
}
trap restore_terminal EXIT
trap 'printf "\nCancelled.\n" >&2; exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

cancel_switch() { say '' 'Cancelled; provider settings were not changed.'; exit 0; }
ask() {
  printf '%s' "$1" >&2
  IFS= read -r REPLY <&3 || die 'Input closed; cancelled.'
}
ask_secret() {
  if [ "$INPUT_IS_TTY" = 1 ]; then
    TERMINAL_STATE="$(stty -g <&3)"
    stty -echo <&3
  fi
  printf '%s' "$1" >&2
  IFS= read -r REPLY <&3 || { printf '\n' >&2; die 'Input closed; cancelled.'; }
  restore_terminal
  printf '\n' >&2
}
trim_reply() { printf '%s' "$1" | tr -d '[:space:]'; }

# Bash 3.2-compatible picker. MENU_CHOICE is one-based. Each redraw occupies
# the same number of rows; clipped labels avoid wrapping in narrow terminals.
select_menu() {
  local title="$1" selected="$2" count key prefix direction i width rows dimensions
  shift 2
  local options=("$@")
  count=${#options[@]}
  MENU_CHOICE=''
  say '' "$title"
  dimensions='24 80'
  if [ "$INPUT_IS_TTY" = 1 ]; then dimensions="$(stty size <&3)"; fi
  read -r rows width <<< "$dimensions"
  if [ "$PLAIN" = 1 ] || [ "$INPUT_IS_TTY" = 0 ] || [ ! -t 2 ] || \
     [ "${TERM:-dumb}" = dumb ] || [ "$width" -lt 20 ] || [ "$rows" -lt "$((count + 3))" ]; then
    i=0
    while [ "$i" -lt "$count" ]; do
      printf '  [%s] %s\n' "$((i + 1))" "${options[$i]}" >&2
      i=$((i + 1))
    done
    ask "Choice (ENTER = $selected, q = cancel): "
    MENU_CHOICE="$(trim_reply "$REPLY")"
    [ -n "$MENU_CHOICE" ] || MENU_CHOICE="$selected"
    case "$MENU_CHOICE" in
      q|Q) cancel_switch ;;
      [1-9]) [ "$MENU_CHOICE" -le "$count" ] || die 'Invalid choice; cancelled.' ;;
      *) die 'Invalid choice; cancelled.' ;;
    esac
    return 0
  fi

  TERMINAL_STATE="$(stty -g <&3)"
  stty -echo -icanon min 1 time 0 <&3
  CURSOR_HIDDEN=1
  printf '\033[?25l' >&2
  while :; do
    i=1
    while [ "$i" -le "$count" ]; do
      printf '\r\033[2K' >&2
      if [ "$i" = "$selected" ]; then
        printf '%s> %.*s%s\n' "$C_CYAN" "$((width - 4))" "${options[$((i - 1))]}" "$C_OFF" >&2
      else
        printf '  %.*s\n' "$((width - 4))" "${options[$((i - 1))]}" >&2
      fi
      i=$((i + 1))
    done
    printf '\r\033[2K%.*s\n' "$((width - 1))" '↑/↓ choose · Enter select · Esc/q cancel' >&2
    key=''
    IFS= read -rsn1 key <&3 || die 'Input closed; cancelled.'
    case "$key" in
      ''|$'\r') MENU_CHOICE="$selected"; break ;;
      q|Q) restore_terminal; cancel_switch ;;
      $'\033')
        # A lone Escape cancels after one second. Both CSI and SS3 arrow
        # sequences occur in macOS terminals. Integer timeout works in Bash 3.2.
        prefix=''; direction=''
        if ! IFS= read -rsn1 -t 1 prefix <&3; then restore_terminal; cancel_switch; fi
        case "$prefix" in
          '['|O)
            IFS= read -rsn1 -t 1 direction <&3 || direction=''
            case "$direction" in
              A) selected=$(((selected + count - 2) % count + 1)) ;;
              B) selected=$((selected % count + 1)) ;;
            esac ;;
        esac ;;
      [1-9]) if [ "$key" -le "$count" ]; then selected="$key"; fi ;;
    esac
    printf '\033[%sA' "$((count + 1))" >&2
  done
  restore_terminal
  say "$C_GREEN" "Selected: ${options[$((MENU_CHOICE - 1))]}"
}

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
  local saved=''
  if [ -f "$CLAUDE_CONF" ]; then
    saved="$(sed -n 's/^[[:space:]]*NEWAPI_TOKEN[[:space:]]*=[[:space:]]*//p' "$CLAUDE_CONF" | head -n1 | tr -d '[:space:]')"
  fi
  if [ -n "$saved" ]; then printf '%s' "$saved"
  elif [ "$CLAUDE_STATE" = gateway ]; then claude_json_env get-token
  fi
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
  local saved=''
  if [ -f "$CODEX_CONF" ]; then
    saved="$(sed -n 's/^[[:space:]]*NEWAPI_TOKEN[[:space:]]*=[[:space:]]*//p' "$CODEX_CONF" | head -n1 | tr -d '[:space:]')"
  fi
  if [ -n "$saved" ]; then printf '%s' "$saved"
  elif [ "$CODEX_STATE" = gateway ]; then codex_token_from_config
  fi
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
    select_menu 'Claude Code gateway token' 1 'Use saved token' 'Enter a new token' 'Cancel'
    case "$MENU_CHOICE" in
      1) CLAUDE_TOKEN="$saved"; return 0 ;;
      3) cancel_switch ;;
    esac
  fi
  say "$C_YELLOW" 'Enter a new-api token with access to Claude models (input hidden).'
  ask_secret '  Claude token: '
  CLAUDE_TOKEN="$(trim_reply "$REPLY")"
  [ -n "$CLAUDE_TOKEN" ] || die 'No Claude token entered; provider settings were not changed.'
}

get_codex_token() {
  saved="$(codex_saved_token)"
  if [ -n "$saved" ]; then
    select_menu 'Codex gateway token' 1 'Use saved token' 'Enter a new token' 'Cancel'
    case "$MENU_CHOICE" in
      1) CODEX_TOKEN="$saved"; return 0 ;;
      3) cancel_switch ;;
    esac
  fi
  say "$C_YELLOW" 'Enter a new-api token in the "codex" group (input hidden).'
  ask_secret '  Codex token: '
  CODEX_TOKEN="$(trim_reply "$REPLY")"
  [ -n "$CODEX_TOKEN" ] || die 'No Codex token entered; provider settings were not changed.'
}

# --- Apply changes ----------------------------------------------------------
apply_claude_gateway() {
  mkdir -p "$CLAUDE_DIR"
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
  saved="$(claude_saved_token)"
  [ -z "$saved" ] || save_claude_token "$saved"
  cp "$CLAUDE_SETTINGS" "$CLAUDE_SETTINGS.gateway.bak"
  claude_json_env clear
  say "$C_GREEN" 'Claude Code -> Anthropic / claude.ai.'
  info "  Saved gateway token: $CLAUDE_CONF"
}

apply_codex_gateway() {
  mkdir -p "$CODEX_DIR"
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
  saved="$(codex_saved_token)"
  [ -z "$saved" ] || save_codex_token "$saved"
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

# --- Detect state without writing anything before a selection ---------------
CLAUDE_STATE="$(claude_state)"
CODEX_STATE="$(codex_state)"

# --- Menu -------------------------------------------------------------------
say '' ''
say "$C_CYAN" '=== MobileSentrix - Claude Code + Codex switcher ==='
say "$C_YELLOW" "Claude Code: $(claude_status_label "$CLAUDE_STATE")"
say "$C_YELLOW" "Codex      : $(codex_status_label "$CODEX_STATE")"
say '' ''
select_menu 'What do you want to switch?' 1 \
  'Claude Code' 'Codex' 'Both Claude Code and Codex' 'Exit'
SCOPE="$MENU_CHOICE"

DO_CLAUDE=0
DO_CODEX=0
case "$SCOPE" in
  1) DO_CLAUDE=1 ;;
  2) DO_CODEX=1 ;;
  3) DO_CLAUDE=1; DO_CODEX=1 ;;
  4) say '' 'Nothing changed.'; exit 0 ;;
  *) die "Invalid choice '$SCOPE'; nothing changed." ;;
esac

# ENTER chooses the opposite when all selected clients share a state. For a
# mixed/custom selection it defaults to the gateway, and the prompt says so.
DEFAULT_TARGET=1
if [ "$DO_CLAUDE" = 1 ] && [ "$DO_CODEX" = 0 ] && [ "$CLAUDE_STATE" = 'gateway' ]; then DEFAULT_TARGET=2; fi
if [ "$DO_CODEX" = 1 ] && [ "$DO_CLAUDE" = 0 ] && [ "$CODEX_STATE" = 'gateway' ]; then DEFAULT_TARGET=2; fi
if [ "$DO_CLAUDE" = 1 ] && [ "$DO_CODEX" = 1 ] && [ "$CLAUDE_STATE" = 'gateway' ] && [ "$CODEX_STATE" = 'gateway' ]; then DEFAULT_TARGET=2; fi

say '' ''
OFFICIAL_LABEL='Official providers (Anthropic + ChatGPT/OpenAI)'
if [ "$SCOPE" = 1 ]; then OFFICIAL_LABEL='Anthropic / claude.ai'; fi
if [ "$SCOPE" = 2 ]; then OFFICIAL_LABEL='ChatGPT / OpenAI'; fi
select_menu 'Switch to' "$DEFAULT_TARGET" 'MobileSentrix gateway' "$OFFICIAL_LABEL" 'Cancel'
TARGET="$MENU_CHOICE"
case "$TARGET" in 3) cancel_switch ;; esac

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
