#!/bin/bash
# claude-usage.5m.sh — SwiftBar/xbar plugin for Claude Code plan limits.
#
# Safety properties:
#   - Only outbound network call: https://api.anthropic.com/api/oauth/usage
#   - OAuth token is never written to disk and never appears in process argv
#     (passed via curl --config on stdin heredoc).
#   - Reads token via /usr/bin/security, same path Claude Code itself uses.
#   - No telemetry, no update checks, no logs, no AppleScript, no file writes
#     other than a single-line mode file at ~/.config/claude-usage/mode (0600).
#   - Exits 0 on all error paths so SwiftBar renders cleanly.
#
# Requires: macOS, python3 (ships with Xcode Command Line Tools), curl.

set -u
umask 077

MODE_FILE="$HOME/.config/claude-usage/mode"
DEFAULT_MODE="pct"
PYTHON_BIN="/usr/bin/python3"

# ---- toggle subcommand (invoked from the dropdown) --------------------------
if [[ "${1:-}" == "toggle" ]]; then
    mkdir -p "$(dirname "$MODE_FILE")"
    current="$(cat "$MODE_FILE" 2>/dev/null || printf '%s' "$DEFAULT_MODE")"
    if [[ "$current" == "pct" ]]; then
        printf 'time\n' > "$MODE_FILE"
    else
        printf 'pct\n' > "$MODE_FILE"
    fi
    exit 0
fi

# ---- render mode -----------------------------------------------------------
mkdir -p "$(dirname "$MODE_FILE")"
mode="$(tr -d '[:space:]' < "$MODE_FILE" 2>/dev/null || printf '%s' "$DEFAULT_MODE")"
[[ "$mode" != "pct" && "$mode" != "time" ]] && mode="$DEFAULT_MODE"
other_mode="$([[ "$mode" == "pct" ]] && printf 'time' || printf 'pct')"

render_error() {
    local title="$1" detail="$2"
    printf '%s\n' "$title"
    printf -- '---\n'
    printf '%s\n' "$detail"
    printf -- '---\n'
    printf 'Toggle display (%s → %s) | bash="%s" param1=toggle terminal=false refresh=true\n' \
        "$mode" "$other_mode" "$0"
    printf 'Refresh | refresh=true\n'
    exit 0
}

# Preflight: python3 must exist (ships with Xcode Command Line Tools).
if ! "$PYTHON_BIN" -c 'import json' >/dev/null 2>&1; then
    render_error "❌" "python3 not available — run: xcode-select --install"
fi

# ---- 1. pull OAuth credentials blob from keychain --------------------------
KC_BLOB="$(/usr/bin/security find-generic-password -s 'Claude Code-credentials' -w 2>/dev/null || true)"
if [[ -z "$KC_BLOB" ]]; then
    KC_BLOB="$(/usr/bin/security find-generic-password -s 'Claude Code' -w 2>/dev/null || true)"
fi
if [[ -z "$KC_BLOB" ]]; then
    render_error "⚪" "Not signed in — run \`claude\` in Terminal."
fi

ACCESS_TOKEN="$(printf '%s' "$KC_BLOB" | "$PYTHON_BIN" -c '
import json, sys
try:
    d = json.loads(sys.stdin.read())
    print(d["claudeAiOauth"]["accessToken"])
except Exception:
    pass
')"
unset KC_BLOB

if [[ -z "$ACCESS_TOKEN" ]]; then
    render_error "⚪" "No OAuth token in keychain — run \`claude\`."
fi

# ---- 2. call usage endpoint (token via stdin config, never argv) -----------
RESP_FILE="$(mktemp -t claude-usage)"
trap 'rm -f "$RESP_FILE"' EXIT INT TERM HUP

# curl --config reads key = value lines; values are literal when unquoted,
# which avoids C-escape parsing (safer for opaque tokens).
HTTP_CODE="$(
    /usr/bin/curl -sS -o "$RESP_FILE" -w '%{http_code}' \
        --max-time 10 \
        --config - <<EOF
url = https://api.anthropic.com/api/oauth/usage
header = Accept: application/json
header = anthropic-beta: oauth-2025-04-20
header = User-Agent: claude-code/2.1.0
header = Authorization: Bearer $ACCESS_TOKEN
EOF
)"
unset ACCESS_TOKEN

case "${HTTP_CODE:-000}" in
    200) ;;
    401) render_error "❌" "Auth expired — run \`claude\` to re-login." ;;
    429) render_error "⚠️"  "Rate limited — will retry at next refresh." ;;
    000) render_error "❌" "Network error." ;;
    *)   render_error "❌" "API error (HTTP $HTTP_CODE)." ;;
esac

# ---- 3. parse response ------------------------------------------------------
PARSED="$("$PYTHON_BIN" - "$RESP_FILE" <<'PY'
import json, sys
from datetime import datetime, timezone

with open(sys.argv[1]) as f:
    d = json.load(f)

def fmt(iso):
    if not iso: return "-"
    try:
        t = datetime.fromisoformat(iso.replace("Z", "+00:00"))
    except Exception:
        return "-"
    secs = int((t - datetime.now(timezone.utc)).total_seconds())
    if secs <= 0: return "soon"
    days, rem = divmod(secs, 86400)
    hours, rem = divmod(rem, 3600)
    mins = rem // 60
    if days:  return f"{days}d{hours}h"
    if hours: return f"{hours}h{mins}m"
    return f"{mins}m"

s = d.get("five_hour") or {}
w = d.get("seven_day") or {}
print(int(s.get("utilization", 0)),
      fmt(s.get("resets_at")),
      int(w.get("utilization", 0)),
      fmt(w.get("resets_at")))
PY
)"

if [[ -z "$PARSED" ]]; then
    render_error "❌" "Could not parse API response."
fi

read -r SESS_PCT SESS_RESET WEEK_PCT WEEK_RESET <<< "$PARSED"

# ---- 4. pick status colour from worst of the two --------------------------
worst="$SESS_PCT"
(( WEEK_PCT > worst )) && worst="$WEEK_PCT"
if   (( worst >= 90 )); then EMOJI="🔴"
elif (( worst >= 70 )); then EMOJI="🟡"
else                         EMOJI="🟢"
fi

# ---- 5. render -------------------------------------------------------------
if [[ "$mode" == "pct" ]]; then
    printf '%s %s%% / %s%%\n' "$EMOJI" "$SESS_PCT" "$WEEK_PCT"
else
    printf '%s %s / %s\n' "$EMOJI" "$SESS_RESET" "$WEEK_RESET"
fi
printf -- '---\n'
printf 'Session (5h): %s%%  ·  resets in %s\n' "$SESS_PCT" "$SESS_RESET"
printf 'Weekly  (7d): %s%%  ·  resets in %s\n' "$WEEK_PCT" "$WEEK_RESET"
printf -- '---\n'
printf 'Showing: %s — click to show %s | bash="%s" param1=toggle terminal=false refresh=true\n' \
    "$mode" "$other_mode" "$0"
printf 'Refresh | refresh=true\n'
