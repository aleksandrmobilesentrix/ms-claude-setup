#!/bin/bash
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/switch-mac.sh"
PASS=0

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

assert_contains() {
  grep -Fq "$2" "$1" || fail "$1 does not contain: $2"
}

assert_not_contains() {
  if grep -Fq "$2" "$1"; then fail "$1 unexpectedly contains: $2"; fi
}

assert_mode_600() {
  mode="$(stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1")"
  [ "$mode" = '600' ] || fail "$1 mode is $mode, expected 600"
}

new_home() {
  TEST_HOME="$(mktemp -d)"
  mkdir -p "$TEST_HOME/.claude" "$TEST_HOME/.codex" "$TEST_HOME/bin"
  printf '#!/bin/sh\nexit 0\n' > "$TEST_HOME/bin/claude"
  printf '#!/bin/sh\nexit 0\n' > "$TEST_HOME/bin/codex"
  chmod +x "$TEST_HOME/bin/claude" "$TEST_HOME/bin/codex"
}

cleanup() {
  for dir in ${TEST_HOMES:-}; do rm -rf "$dir"; done
}
trap cleanup EXIT
TEST_HOMES=''

# Both clients: official -> gateway -> official, preserving unrelated config.
new_home
TEST_HOMES="$TEST_HOMES $TEST_HOME"
printf '%s\n' \
  '{' \
  '  "model": "sonnet",' \
  '  "env": {"KEEP_ME": "yes", "ANTHROPIC_API_KEY": "old-official-key"},' \
  '  "permissions": {"allow": ["Read"]}' \
  '}' > "$TEST_HOME/.claude/settings.json"
chmod 600 "$TEST_HOME/.claude/settings.json"
printf '%s\n' \
  'foo = "bar"' \
  '' \
  '[mcp_servers.keep]' \
  'command = "keep-me"' > "$TEST_HOME/.codex/config.toml"

printf '3\n1\nclaude-test-token\ncodex-test-token\n' | \
  HOME="$TEST_HOME" PATH="$TEST_HOME/bin:$PATH" bash "$SCRIPT" >/dev/null 2>&1

assert_contains "$TEST_HOME/.claude/settings.json" '"KEEP_ME": "yes"'
assert_contains "$TEST_HOME/.claude/settings.json" '"model": "sonnet"'
assert_contains "$TEST_HOME/.claude/settings.json" '"ANTHROPIC_BASE_URL": "https://ai.mobilesentrix.com"'
assert_contains "$TEST_HOME/.claude/settings.json" '"ANTHROPIC_AUTH_TOKEN": "claude-test-token"'
assert_not_contains "$TEST_HOME/.claude/settings.json" 'ANTHROPIC_API_KEY'
assert_contains "$TEST_HOME/.codex/config.toml" 'model_provider = "newapi"'
assert_contains "$TEST_HOME/.codex/config.toml" '[mcp_servers.keep]'
assert_contains "$TEST_HOME/.codex/config.toml" 'command = "keep-me"'
assert_contains "$TEST_HOME/.codex/config.toml" 'experimental_bearer_token = "codex-test-token"'
assert_mode_600 "$TEST_HOME/.claude/claude-provider.conf"
assert_mode_600 "$TEST_HOME/.codex/newapi-provider.conf"

printf '3\n\n' | HOME="$TEST_HOME" PATH="$TEST_HOME/bin:$PATH" bash "$SCRIPT" >/dev/null 2>&1
assert_contains "$TEST_HOME/.claude/settings.json" '"KEEP_ME": "yes"'
assert_not_contains "$TEST_HOME/.claude/settings.json" 'ANTHROPIC_BASE_URL'
assert_not_contains "$TEST_HOME/.claude/settings.json" 'ANTHROPIC_AUTH_TOKEN'
assert_contains "$TEST_HOME/.codex/config.toml" '[mcp_servers.keep]'
assert_not_contains "$TEST_HOME/.codex/config.toml" 'model_provider = "newapi"'
assert_not_contains "$TEST_HOME/.codex/config.toml" '[model_providers.newapi]'
PASS=$((PASS + 1))

# Repeated round trips do not duplicate blocks or grow blank lines.
i=0
while [ "$i" -lt 4 ]; do
  printf '3\n1\n\n\n' | HOME="$TEST_HOME" PATH="$TEST_HOME/bin:$PATH" bash "$SCRIPT" >/dev/null 2>&1
  [ "$(grep -c '^model_provider = "newapi"$' "$TEST_HOME/.codex/config.toml")" = 1 ] || fail 'duplicate model_provider'
  [ "$(grep -c '^\[model_providers.newapi\]$' "$TEST_HOME/.codex/config.toml")" = 1 ] || fail 'duplicate provider table'
  printf '3\n2\n' | HOME="$TEST_HOME" PATH="$TEST_HOME/bin:$PATH" bash "$SCRIPT" >/dev/null 2>&1
  i=$((i + 1))
done
assert_contains "$TEST_HOME/.codex/config.toml" '[mcp_servers.keep]'
assert_not_contains "$TEST_HOME/.codex/config.toml" '[model_providers.newapi]'
PASS=$((PASS + 1))

# Individual menu selections affect only the chosen client.
new_home
TEST_HOMES="$TEST_HOMES $TEST_HOME"
printf '%s\n' '{"model":"sonnet"}' > "$TEST_HOME/.claude/settings.json"
printf '1\n\nclaude-only-token\n' | HOME="$TEST_HOME" PATH="$TEST_HOME/bin:$PATH" bash "$SCRIPT" >/dev/null 2>&1
assert_contains "$TEST_HOME/.claude/settings.json" 'ANTHROPIC_BASE_URL'
[ ! -e "$TEST_HOME/.codex/config.toml" ] || fail 'Claude-only switch created a Codex config'
cp "$TEST_HOME/.claude/settings.json" "$TEST_HOME/claude-before-codex"
printf '2\n\ncodex-only-token\n' | HOME="$TEST_HOME" PATH="$TEST_HOME/bin:$PATH" bash "$SCRIPT" >/dev/null 2>&1
cmp -s "$TEST_HOME/.claude/settings.json" "$TEST_HOME/claude-before-codex" || fail 'Codex-only switch changed Claude settings'
assert_contains "$TEST_HOME/.codex/config.toml" 'model_provider = "newapi"'
printf '1\n\n' | HOME="$TEST_HOME" PATH="$TEST_HOME/bin:$PATH" bash "$SCRIPT" >/dev/null 2>&1
assert_not_contains "$TEST_HOME/.claude/settings.json" 'ANTHROPIC_BASE_URL'
assert_contains "$TEST_HOME/.codex/config.toml" 'model_provider = "newapi"'
PASS=$((PASS + 1))

# Active legacy tokens are imported and reused without asking for replacement.
new_home
TEST_HOMES="$TEST_HOMES $TEST_HOME"
printf '%s\n' \
  '{"env":{"ANTHROPIC_BASE_URL":"https://ai.mobilesentrix.com","ANTHROPIC_AUTH_TOKEN":"legacy-claude"}}' \
  > "$TEST_HOME/.claude/settings.json"
printf '%s\n' \
  'model_provider = "newapi"' \
  '' \
  '[model_providers.newapi]' \
  'base_url = "https://ai.mobilesentrix.com/v1"' \
  'experimental_bearer_token = "legacy-codex"' \
  'wire_api = "responses"' > "$TEST_HOME/.codex/config.toml"
printf '3\n2\n' | HOME="$TEST_HOME" PATH="$TEST_HOME/bin:$PATH" bash "$SCRIPT" >/dev/null 2>&1
assert_contains "$TEST_HOME/.claude/claude-provider.conf" 'NEWAPI_TOKEN=legacy-claude'
assert_contains "$TEST_HOME/.codex/newapi-provider.conf" 'NEWAPI_TOKEN=legacy-codex'
PASS=$((PASS + 1))

# Invalid Claude JSON fails closed and remains byte-for-byte unchanged.
new_home
TEST_HOMES="$TEST_HOMES $TEST_HOME"
printf '%s' '{not valid json' > "$TEST_HOME/.claude/settings.json"
cp "$TEST_HOME/.claude/settings.json" "$TEST_HOME/original-settings"
if printf '1\n1\n' | HOME="$TEST_HOME" PATH="$TEST_HOME/bin:$PATH" bash "$SCRIPT" >/dev/null 2>&1; then
  fail 'invalid JSON unexpectedly succeeded'
fi
cmp -s "$TEST_HOME/.claude/settings.json" "$TEST_HOME/original-settings" || fail 'invalid JSON was modified'
PASS=$((PASS + 1))

# A custom Codex provider aborts before changing Claude in the "both" path.
new_home
TEST_HOMES="$TEST_HOMES $TEST_HOME"
printf '%s\n' '{"model":"sonnet"}' > "$TEST_HOME/.claude/settings.json"
cp "$TEST_HOME/.claude/settings.json" "$TEST_HOME/original-settings"
printf '%s\n' 'model_provider = "company-proxy"' > "$TEST_HOME/.codex/config.toml"
if printf '3\n1\n' | HOME="$TEST_HOME" PATH="$TEST_HOME/bin:$PATH" bash "$SCRIPT" >/dev/null 2>&1; then
  fail 'custom Codex provider unexpectedly succeeded'
fi
cmp -s "$TEST_HOME/.claude/settings.json" "$TEST_HOME/original-settings" || fail 'Claude changed before Codex preflight failure'
assert_contains "$TEST_HOME/.codex/config.toml" 'model_provider = "company-proxy"'
PASS=$((PASS + 1))

printf 'PASS: %s switch-mac scenarios\n' "$PASS"
