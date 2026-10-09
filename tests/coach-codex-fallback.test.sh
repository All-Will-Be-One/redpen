#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/redpen-model-fallback.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT

FAKE_CODEX="$TEST_DIR/codex executable"
CALL_LOG="$TEST_DIR/calls.log"

cat > "$FAKE_CODEX" <<'EOF'
#!/usr/bin/env bash
set -u

if [[ "${1:-}" == "--version" ]]; then
  printf 'codex-cli %s\n' "${FAKE_CODEX_VERSION:-0.146.0}"
  exit 0
fi

model=""
for ((i = 1; i <= $#; i++)); do
  if [[ "${!i}" == "--model" ]]; then
    next=$((i + 1))
    model="${!next}"
    break
  fi
done

printf '%s' "$model" >> "$FAKE_CALL_LOG"
printf ' %q' "$@" >> "$FAKE_CALL_LOG"
printf '\n' >> "$FAKE_CALL_LOG"

case ",${FAKE_FAIL_MODELS:-}," in
  *,"$model",*)
    printf 'simulated failure for %s\n' "$model" >&2
    exit 7
    ;;
esac

printf '%s\n' \
  '[100] test prompt' \
  '──── Native style ────' \
  'test prompt'
EOF
chmod +x "$FAKE_CODEX"

run_coach() {
  : > "$CALL_LOG"
  printf '%s\n' '{"prompt":"test prompt"}' |
    HOME="$TEST_DIR" \
    REDPEN_CODEX_BIN="$FAKE_CODEX" \
    REDPEN_NO_TELEMETRY=1 \
    REDPEN_OUTPUT=structured \
    FAKE_CALL_LOG="$CALL_LOG" \
    FAKE_FAIL_MODELS="${1:-}" \
    bash "$ROOT/plugins/redpen-codex/shared/coach_codex.sh"
}

assert_line_count() {
  local expected="$1"
  local actual
  actual="$(wc -l < "$CALL_LOG" | tr -d ' ')"
  [[ "$actual" == "$expected" ]] || {
    printf 'expected %s calls, got %s\n' "$expected" "$actual" >&2
    exit 1
  }
}

output="$(run_coach)"
assert_line_count 1
grep -q '^gpt-5\.6-luna ' "$CALL_LOG"
grep -q 'service_tier=\\"fast\\"' "$CALL_LOG"
grep -q 'features\.fast_mode=true' "$CALL_LOG"
grep -q '"status": "ok"' <<< "$output"

output="$(run_coach 'gpt-5.6-luna')"
assert_line_count 2
sed -n '2p' "$CALL_LOG" | grep -q '^gpt-5\.6-terra '
sed -n '2p' "$CALL_LOG" | grep -q 'service_tier=\\"fast\\"'
grep -q '"status": "ok"' <<< "$output"

output="$(run_coach 'gpt-5.6-luna,gpt-5.6-terra')"
assert_line_count 3
sed -n '3p' "$CALL_LOG" | grep -q '^gpt-5\.4-mini '
if sed -n '3p' "$CALL_LOG" | grep -q 'service_tier'; then
  printf 'gpt-5.4-mini fallback must not request Fast mode\n' >&2
  exit 1
fi
grep -q '"status": "ok"' <<< "$output"

output="$(run_coach 'gpt-5.6-luna,gpt-5.6-terra,gpt-5.4-mini')"
assert_line_count 3
[[ -z "$output" ]] || {
  printf 'expected empty output when every model fails\n' >&2
  exit 1
}

hook_json="$(
  : > "$CALL_LOG"
  printf '%s\n' '{"prompt":"test prompt"}' |
    HOME="$TEST_DIR" \
    REDPEN_CODEX_BIN="$FAKE_CODEX" \
    REDPEN_NO_TELEMETRY=1 \
    FAKE_CODEX_VERSION=0.136.0 \
    FAKE_CALL_LOG="$CALL_LOG" \
    bash "$ROOT/plugins/redpen-codex/shared/coach_codex.sh"
)"
HOOK_JSON="$hook_json" /usr/bin/env python3 -c '
import json
import os
import re

message = json.loads(os.environ["HOOK_JSON"])["systemMessage"]
plain = re.sub(r"\x1b\[[0-9;]*m", "", message)
assert plain == "[100] test prompt\n──── Native style ────\ntest prompt", repr(plain)
assert "\r\x1b[2K" not in message, repr(message[:20])
'

legacy_hook_json="$(
  : > "$CALL_LOG"
  printf '%s\n' '{"prompt":"test prompt"}' |
    HOME="$TEST_DIR" \
    REDPEN_CODEX_BIN="$FAKE_CODEX" \
    REDPEN_NO_TELEMETRY=1 \
    FAKE_CODEX_VERSION=0.135.0 \
    FAKE_CALL_LOG="$CALL_LOG" \
    bash "$ROOT/plugins/redpen-codex/shared/coach_codex.sh"
)"
HOOK_JSON="$legacy_hook_json" /usr/bin/env python3 -c '
import json
import os

message = json.loads(os.environ["HOOK_JSON"])["systemMessage"]
assert message.startswith("\r\x1b[2K"), repr(message[:20])
assert "\n" not in message, repr(message)
'

# Interactive answers are harness input, not prose to send to the coach.
: > "$CALL_LOG"
reply_json="$(
  printf '%s\n' '{"prompt":"<send_user_message_question_reply>\n[{\"answer\":\"Coffee\",\"question\":\"Which drink?\"}]\n</send_user_message_question_reply>"}' |
    HOME="$TEST_DIR" \
    REDPEN_CODEX_BIN="$FAKE_CODEX" \
    REDPEN_NO_TELEMETRY=1 \
    FAKE_CALL_LOG="$CALL_LOG" \
    bash "$ROOT/plugins/redpen-codex/hooks/grammar_check.sh"
)"
assert_line_count 0
[[ -z "$reply_json" ]] || {
  printf 'expected no coaching output for an interactive answer\n' >&2
  exit 1
}

printf 'coach model fallback and hook output tests passed\n'
