#!/usr/bin/env bash
# =============================================================================
#  MobileSentrix - force Claude Code tool search on (macOS / Linux)
#
#  Behind a non-Anthropic ANTHROPIC_BASE_URL (our gateway) Claude Code turns
#  tool search off and sends every MCP tool schema with every request. This
#  puts ENABLE_TOOL_SEARCH=true into the machine-wide managed settings file,
#  which outranks every user setting, so nothing in ~/.claude/settings.json
#  (or a provider switch) can turn it off again.
#
#  Only that one key is written: the gateway URL and token are NOT managed,
#  so /newapi and /anthropic keep switching providers as before. Other keys
#  already in the managed file are kept; the old file is backed up.
#
#  Run (asks for your password once, for sudo):
#     curl -fsSL https://tinyurl.com/ms-tool-search-mac | bash
#  Restart Claude Code afterwards.
# =============================================================================
set -euo pipefail

if [ -n "${MS_CC_MANAGED_DIR:-}" ]; then
  dir="$MS_CC_MANAGED_DIR"                       # testing hook
elif [ "$(uname -s)" = "Darwin" ]; then
  dir="/Library/Application Support/ClaudeCode"
else
  dir="/etc/claude-code"
fi
path="$dir/managed-settings.json"

SUDO=""
if [ "$(id -u)" -ne 0 ] && [ -z "${MS_CC_MANAGED_DIR:-}" ]; then
  SUDO="sudo"
  echo "Writing the machine-wide Claude Code settings needs your password (sudo)."
  # under 'curl | bash' stdin is the script, so let sudo ask on the terminal
  sudo -v < /dev/tty
fi

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

merge() {   # $1 = existing file or empty, writes merged JSON to $tmp
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$1" "$tmp" <<'PY'
import json, sys
src, out = sys.argv[1], sys.argv[2]
d = {}
if src:
    try:
        with open(src, encoding="utf-8-sig") as f:
            d = json.load(f)
    except ValueError as e:
        raise SystemExit("existing managed settings is not valid JSON: %s" % e)
    if not isinstance(d, dict):
        raise SystemExit("existing managed settings is not a JSON object")
env = d.get("env") if isinstance(d.get("env"), dict) else {}
env["ENABLE_TOOL_SEARCH"] = "true"
d["env"] = env
with open(out, "w", encoding="utf-8") as f:
    json.dump(d, f, indent=2)
    f.write("\n")
PY
  elif command -v node >/dev/null 2>&1; then
    node - "$1" "$tmp" <<'JS'
const fs = require("fs");
const [src, out] = process.argv.slice(2);
let d = {};
if (src) {
  try { d = JSON.parse(fs.readFileSync(src, "utf8").replace(/^\uFEFF/, "")); }
  catch (e) { console.error("existing managed settings is not valid JSON: " + e.message); process.exit(1); }
  if (!d || typeof d !== "object" || Array.isArray(d)) throw new Error("existing managed settings is not a JSON object");
}
const env = d.env && typeof d.env === "object" && !Array.isArray(d.env) ? d.env : {};
env.ENABLE_TOOL_SEARCH = "true";
d.env = env;
fs.writeFileSync(out, JSON.stringify(d, null, 2) + "\n");
JS
  elif [ -z "$1" ]; then
    printf '{\n  "env": {\n    "ENABLE_TOOL_SEARCH": "true"\n  }\n}\n' > "$tmp"
  else
    echo "Need python3 or node to merge into the existing $path - nothing changed." >&2
    exit 1
  fi
}

$SUDO mkdir -p "$dir"
if [ -f "$path" ]; then
  backup="$path.bak-$(date +%Y%m%d-%H%M%S)"
  $SUDO cp "$path" "$backup"
  cp "$path" "$tmp.src" 2>/dev/null || $SUDO cat "$path" > "$tmp.src"
  if ! merge "$tmp.src"; then
    rm -f "$tmp.src"
    echo "Existing $path could not be merged - nothing changed (backup: $backup)." >&2
    exit 1
  fi
  rm -f "$tmp.src"
else
  merge ""
fi
$SUDO install -m 0644 "$tmp" "$path"

echo
echo "Done: tool search is now forced on for Claude Code on this machine."
echo "  Managed settings: $path"
echo "  /newapi and /anthropic still switch providers as before."
echo
echo "Restart Claude Code (exit and relaunch) for it to take effect."
