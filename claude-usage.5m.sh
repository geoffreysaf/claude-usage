#!/bin/bash
# claude-usage.5m.sh — SwiftBar/xbar plugin for Claude Code plan limits.
#
# Safety properties:
#   - Only outbound network call: https://api.anthropic.com/api/oauth/usage
#   - OAuth token is never written to disk and never appears in process argv
#     (passed via curl --config on stdin heredoc).
#   - Reads token via /usr/bin/security, same path Claude Code itself uses.
#   - No telemetry, no update checks, no logs, no AppleScript.
#   - Writes only:
#       ~/.config/claude-usage/mode   (4 bytes, "pct" or "time")
#       ~/.cache/claude-usage/last.json  (last good API response + timestamp)
#     Both are 0600.
#   - Exits 0 on all error paths so SwiftBar renders cleanly.
#
# Rate-limit handling:
#   - Anthropic's /api/oauth/usage is rate-limited per account. To avoid
#     digging a hole, we record a next_allowed_ts after every response and
#     serve cached values when throttled (200→4min, 429→30min, 5xx→15min).
#
# Requires: macOS, python3 (Xcode Command Line Tools), curl.

set -u
umask 077

MODE_FILE="$HOME/.config/claude-usage/mode"
# Data cache (last good API response) — may be shared on iCloud across Macs.
ICLOUD_CACHE_DIR="$HOME/Library/Mobile Documents/com~apple~CloudDocs/claude-usage"
LOCAL_CACHE_DIR="$HOME/.cache/claude-usage"
if [[ -d "$(dirname "$ICLOUD_CACHE_DIR")" ]]; then
    CACHE_DIR="$ICLOUD_CACHE_DIR"
else
    CACHE_DIR="$LOCAL_CACHE_DIR"
fi
CACHE_FILE="$CACHE_DIR/last.json"

# Throttle state is ALWAYS local — iCloud sync latency caused races.
STATE_DIR="$LOCAL_CACHE_DIR"
NEXT_ALLOWED_FILE="$STATE_DIR/next_allowed_ts"

DEFAULT_MODE="pct"
PYTHON_BIN="/usr/bin/python3"

# Backoff windows (seconds) applied to NEXT_ALLOWED_FILE after each outcome.
BACKOFF_OK=240
BACKOFF_RATE_LIMIT=1800
BACKOFF_SERVER_ERROR=900
BACKOFF_NETWORK=600

# Cached values shown as "stale" up to this age on API failure (seconds).
CACHE_FALLBACK_MAX_AGE=3600

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

# ---- render-cache subcommand (invoked by the Refresh menu item) ------------
# Renders from cache only — never calls the API. Used to prevent menu clicks
# from burning rate budget.
# NOTE: render_from_cache + render_error_raw are defined further down;
# bash resolves function names at call time so this forward reference is fine.
if [[ "${1:-}" == "render-cache" ]]; then
    mkdir -p "$(dirname "$MODE_FILE")" "$CACHE_DIR" "$STATE_DIR"
    mode="$(tr -d '[:space:]' < "$MODE_FILE" 2>/dev/null || printf '%s' "$DEFAULT_MODE")"
    [[ "$mode" != "pct" && "$mode" != "time" ]] && mode="$DEFAULT_MODE"
    other_mode="$([[ "$mode" == "pct" ]] && printf 'time' || printf 'pct')"
    render_from_cache "Cache-only refresh (next API call on SwiftBar's 5-min tick)"
    # render_from_cache exits on success; if it returns, cache is empty.
    render_error_raw "⚠️" "No cached data yet — wait for next 5-min refresh"
fi

# ---- render mode -----------------------------------------------------------
mkdir -p "$(dirname "$MODE_FILE")" "$CACHE_DIR" "$STATE_DIR"
mode="$(tr -d '[:space:]' < "$MODE_FILE" 2>/dev/null || printf '%s' "$DEFAULT_MODE")"
[[ "$mode" != "pct" && "$mode" != "time" ]] && mode="$DEFAULT_MODE"
other_mode="$([[ "$mode" == "pct" ]] && printf 'time' || printf 'pct')"

now_epoch() { date +%s; }

# Write next-allowed timestamp (absolute epoch) for the throttle gate.
# Arg: backoff-in-seconds
schedule_next_allowed() {
    local backoff="$1"
    printf '%s' "$(( $(now_epoch) + backoff ))" > "$NEXT_ALLOWED_FILE"
}

# ---- helpers to format + render --------------------------------------------
# Args: title_emoji sess_pct sess_reset week_pct week_reset [footnote]
render_values() {
    local emoji="$1" sp="$2" sr="$3" wp="$4" wr="$5" note="${6:-}"
    if [[ "$mode" == "pct" ]]; then
        printf '%s %s%% / %s%%\n' "$emoji" "$sp" "$wp"
    else
        printf '%s %s / %s\n' "$emoji" "$sr" "$wr"
    fi
    printf -- '---\n'
    printf 'Session (5h): %s%%  ·  resets in %s\n' "$sp" "$sr"
    printf 'Weekly  (7d): %s%%  ·  resets in %s\n' "$wp" "$wr"
    if [[ -n "$note" ]]; then
        printf -- '---\n'
        printf '%s\n' "$note"
    fi
    printf -- '---\n'
    printf 'Showing: %s — click to show %s | bash="%s" param1=toggle terminal=false refresh=true\n' \
        "$mode" "$other_mode" "$0"
    printf 'Refresh (cache-only) | bash="%s" param1=render-cache terminal=false refresh=true\n' "$0"
    exit 0
}

# Parse cache and render. Arg: note-to-show ("" for none)
render_from_cache() {
    local note="$1"
    [[ -r "$CACHE_FILE" ]] || render_error_raw "⚠️" "$note (no cached data yet)"

    local parsed
    parsed="$("$PYTHON_BIN" - "$CACHE_FILE" <<'PY'
import json, sys, time
from datetime import datetime, timezone

with open(sys.argv[1]) as f:
    cache = json.load(f)

age = int(time.time() - cache.get("ts", 0))
d = cache.get("data") or {}

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
print(age,
      int(s.get("utilization", 0)), fmt(s.get("resets_at")),
      int(w.get("utilization", 0)), fmt(w.get("resets_at")))
PY
)"
    [[ -z "$parsed" ]] && render_error_raw "⚠️" "$note (cache unreadable)"

    local age sp sr wp wr
    read -r age sp sr wp wr <<< "$parsed"

    if (( age > CACHE_FALLBACK_MAX_AGE )); then
        render_error_raw "⚠️" "$note (cache too old: ${age}s)"
    fi

    # Always yellow tint when serving stale data, regardless of values.
    local age_min=$(( age / 60 ))
    render_values "⏳" "$sp" "$sr" "$wp" "$wr" "${note} — cached ${age_min}m ago"
}

render_error_raw() {
    local title="$1" detail="$2"
    printf '%s\n' "$title"
    printf -- '---\n'
    printf '%s\n' "$detail"
    printf -- '---\n'
    printf 'Toggle display (%s → %s) | bash="%s" param1=toggle terminal=false refresh=true\n' \
        "$mode" "$other_mode" "$0"
    printf 'Refresh (cache-only) | bash="%s" param1=render-cache terminal=false refresh=true\n' "$0"
    exit 0
}

# If an error occurs, try cache first, fall through to raw error.
render_error() {
    render_from_cache "$1"  # exits if cache is usable
    render_error_raw "⚠️" "$1"
}

# Preflight: python3 must exist.
if ! "$PYTHON_BIN" -c 'import json' >/dev/null 2>&1; then
    render_error_raw "❌" "python3 not available — run: xcode-select --install"
fi

# ---- self-rate-limit: honour NEXT_ALLOWED_FILE set by prior response --------
now_ts="$(now_epoch)"
if [[ -r "$NEXT_ALLOWED_FILE" ]]; then
    next_allowed="$(cat "$NEXT_ALLOWED_FILE" 2>/dev/null || echo 0)"
    [[ "$next_allowed" =~ ^[0-9]+$ ]] || next_allowed=0
    if (( now_ts < next_allowed )); then
        wait_for=$(( next_allowed - now_ts ))
        render_from_cache "Throttled locally (${wait_for}s until next API call)"
    fi
fi

# ---- 1. pull OAuth credentials blob from keychain --------------------------
KC_BLOB="$(/usr/bin/security find-generic-password -s 'Claude Code-credentials' -w 2>/dev/null || true)"
if [[ -z "$KC_BLOB" ]]; then
    KC_BLOB="$(/usr/bin/security find-generic-password -s 'Claude Code' -w 2>/dev/null || true)"
fi
if [[ -z "$KC_BLOB" ]]; then
    render_error_raw "⚪" "Not signed in — run \`claude\` in Terminal."
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
    render_error_raw "⚪" "No OAuth token in keychain — run \`claude\`."
fi

# ---- 2. call usage endpoint (token via stdin config, never argv) -----------
RESP_FILE="$(mktemp -t claude-usage)"
trap 'rm -f "$RESP_FILE"' EXIT INT TERM HUP

HTTP_CODE="$(
    /usr/bin/curl -sS -o "$RESP_FILE" -w '%{http_code}' \
        --max-time 10 \
        --config - <<EOF
url = https://api.anthropic.com/api/oauth/usage
header = "Accept: application/json"
header = "anthropic-beta: oauth-2025-04-20"
header = "User-Agent: claude-usage-swiftbar/1.0 (+https://github.com/geoffreysaf/claude-usage)"
header = "Authorization: Bearer $ACCESS_TOKEN"
EOF
)"
unset ACCESS_TOKEN

case "${HTTP_CODE:-000}" in
    200)
        schedule_next_allowed "$BACKOFF_OK"
        ;;
    401)
        # Don't schedule backoff — user needs to re-login, next run should re-check.
        render_error_raw "❌" "Auth expired — run \`claude\` to re-login."
        ;;
    429)
        schedule_next_allowed "$BACKOFF_RATE_LIMIT"
        render_error "Rate limited — backing off ${BACKOFF_RATE_LIMIT}s"
        ;;
    000)
        schedule_next_allowed "$BACKOFF_NETWORK"
        render_error "Network error — backing off ${BACKOFF_NETWORK}s"
        ;;
    *)
        schedule_next_allowed "$BACKOFF_SERVER_ERROR"
        render_error "API error (HTTP $HTTP_CODE) — backing off ${BACKOFF_SERVER_ERROR}s"
        ;;
esac

# ---- 3. on success: update cache then parse --------------------------------
"$PYTHON_BIN" - "$RESP_FILE" "$CACHE_FILE" <<'PY'
import json, sys, time, os
resp_path, cache_path = sys.argv[1], sys.argv[2]
with open(resp_path) as f:
    data = json.load(f)
tmp = cache_path + ".tmp"
with open(tmp, "w") as f:
    json.dump({"ts": int(time.time()), "data": data}, f)
os.chmod(tmp, 0o600)
os.replace(tmp, cache_path)
PY

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
    render_error "Could not parse API response"
fi

read -r SESS_PCT SESS_RESET WEEK_PCT WEEK_RESET <<< "$PARSED"

# ---- 4. colour from worst bucket -------------------------------------------
worst="$SESS_PCT"
(( WEEK_PCT > worst )) && worst="$WEEK_PCT"
if   (( worst >= 90 )); then EMOJI="🔴"
elif (( worst >= 70 )); then EMOJI="🟡"
else                         EMOJI="🟢"
fi

render_values "$EMOJI" "$SESS_PCT" "$SESS_RESET" "$WEEK_PCT" "$WEEK_RESET" ""
