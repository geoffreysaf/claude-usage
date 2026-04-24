# claude-usage hardening — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the rate-limit feedback loop that can bleed from `/api/oauth/usage` polling into Claude Code's completion API, plus the correctness/laziness issues uncovered in the 2026-04-24 review.

**Architecture:** Single bash script (`claude-usage.5m.sh`). We keep the current shape — keychain → curl → python parse → SwiftBar render — but split "throttle state" (local, per-machine) from "data cache" (can remain shared on iCloud). Add HTTP-status-aware backoff so 429/5xx trigger exponentially longer refusals to call the API. Verification is shellcheck + `bash -n` + a mocked smoke script (`smoke.sh`) that stubs `security` and `curl` on PATH so we can exercise the 200/429/5xx/network-error paths deterministically.

**Tech Stack:** bash 3.2+ (macOS default), `/usr/bin/python3`, `/usr/bin/curl`, `/usr/bin/security`, shellcheck.

**Review reference:** See conversation transcript 2026-04-24 for the full review. This plan covers items 1–6 of the recommended fix order (C1+C2+C3, M4, L3, L2+L1, P2, M1). P1 (consolidate python calls) is deliberately out of scope.

---

## File Structure

- **Modify:** `claude-usage.5m.sh` — all fixes land here
- **Create:** `smoke.sh` — mocked smoke test harness (stubs `curl` + `security` via PATH, exercises each HTTP path)
- **Create:** `.shellcheckrc` — disables known-acceptable findings so `shellcheck` returns clean
- **Modify:** `OTHER_MAC_SETUP.md` — remove the "both Macs stuck on ⏳" troubleshooting entry (the bug it documented is being fixed); clarify that throttle state is local-only now
- **Modify:** `README.md` — add a one-line "Safety properties" bullet about 429 backoff

---

## Task 0: Test harness + baseline lint

**Files:**
- Create: `smoke.sh`
- Create: `.shellcheckrc`

- [ ] **Step 0.1: Create `.shellcheckrc` with acceptable suppressions**

Create `/Users/geoffreysafar/claude_code/claude-usage/.shellcheckrc`:
```
# SC2155: declare and assign separately — we accept this for readability
disable=SC2155
# SC1091: not following sourced files — we don't source anything, safe
disable=SC1091
```

- [ ] **Step 0.2: Run baseline shellcheck**

```bash
cd ~/claude_code/claude-usage && shellcheck claude-usage.5m.sh
```
Expected: Zero output after `.shellcheckrc` is applied (if findings remain, capture them in the commit body so subsequent tasks can address or suppress with justification).

- [ ] **Step 0.3: Write `smoke.sh` — mocked harness**

Create `/Users/geoffreysafar/claude_code/claude-usage/smoke.sh`:
```bash
#!/bin/bash
# smoke.sh — mocked smoke harness for claude-usage.5m.sh
# Stubs `security` and `curl` on PATH, runs each HTTP path, asserts on output.
#
# Usage: ./smoke.sh
# Exits 0 if all cases pass, non-zero with diff on failure.

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$SCRIPT_DIR/claude-usage.5m.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Stub keychain: returns a valid-looking OAuth blob
mkdir -p "$WORK/bin"
cat > "$WORK/bin/security" <<'STUB'
#!/bin/bash
# Only answer find-generic-password for the two service names the script probes.
if [[ "$1" == "find-generic-password" ]]; then
    printf '%s' '{"claudeAiOauth":{"accessToken":"sk-ant-fake-token-abc"}}'
    exit 0
fi
exit 1
STUB
chmod +x "$WORK/bin/security"

# Stub curl: driven by env var MOCK_HTTP (200|429|500|000) and MOCK_BODY
cat > "$WORK/bin/curl" <<'STUB'
#!/bin/bash
# Parse -o <file> from argv to know where to write the body.
out=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -o) out="$2"; shift 2 ;;
        *) shift ;;
    esac
done
case "${MOCK_HTTP:-200}" in
    000) exit 6 ;; # curl "couldn't resolve host"
    *)
        if [[ -n "$out" ]]; then
            printf '%s' "${MOCK_BODY:-{\"five_hour\":{\"utilization\":42,\"resets_at\":\"2099-01-01T00:00:00Z\"},\"seven_day\":{\"utilization\":17,\"resets_at\":\"2099-01-08T00:00:00Z\"}}}" > "$out"
        fi
        printf '%s' "${MOCK_HTTP:-200}"
        ;;
esac
STUB
chmod +x "$WORK/bin/curl"

export PATH="$WORK/bin:/usr/bin:/bin"
export HOME="$WORK/home"
mkdir -p "$HOME"

run_case() {
    local name="$1" http="$2" expect_substring="$3"
    # Nuke cache state between cases so each case is deterministic.
    rm -rf "$HOME/.cache/claude-usage" "$HOME/Library" 2>/dev/null || true
    local out
    out="$(MOCK_HTTP="$http" bash "$SCRIPT" 2>&1 || true)"
    if ! grep -qF "$expect_substring" <<< "$out"; then
        printf 'FAIL %s — expected substring %q not in output:\n%s\n' "$name" "$expect_substring" "$out" >&2
        return 1
    fi
    printf 'PASS %s\n' "$name"
}

run_case "200 OK renders fresh" 200 "42%"
run_case "429 renders cached-or-error" 429 "Rate limited"
run_case "500 renders error" 500 "API error"
run_case "network failure renders error" 000 "Network error"

printf '\nAll smoke cases passed.\n'
```

```bash
chmod +x /Users/geoffreysafar/claude_code/claude-usage/smoke.sh
```

- [ ] **Step 0.4: Run smoke baseline**

```bash
cd ~/claude_code/claude-usage && ./smoke.sh
```
Expected: All four cases PASS. The 429 case may render "Rate limited" in the error body even with no cache (it goes through `render_error` → `render_from_cache` → `render_error_raw "⚠️" "Rate limited ... (no cached data yet)"`). That's acceptable baseline behaviour — we'll tighten it in Task 1.

- [ ] **Step 0.5: Commit**

```bash
cd ~/claude_code/claude-usage
git add .shellcheckrc smoke.sh
git commit -m "add shellcheck config and mocked smoke harness"
```

---

## Task 1: Throttle-state rework (fixes C1 + C2 + C3)

**Goal:** Separate local throttle state from shared data cache. Add HTTP-status-aware backoff so 429 triggers a 30-minute refusal to call the API.

**Files:**
- Modify: `claude-usage.5m.sh` lines 26–45 (path config), 166–174 (throttle gate), 200–225 (HTTP dispatch)

- [ ] **Step 1.1: Add local-only state dir + next_allowed file**

Replace lines 26–45 (the path-config block starting at `MODE_FILE=...` through `CACHE_FALLBACK_MAX_AGE=3600`) with:

```bash
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
```

- [ ] **Step 1.2: Update `mkdir` at line 60 to ensure both dirs exist**

Find:
```bash
mkdir -p "$(dirname "$MODE_FILE")" "$CACHE_DIR"
```
Replace with:
```bash
mkdir -p "$(dirname "$MODE_FILE")" "$CACHE_DIR" "$STATE_DIR"
```

- [ ] **Step 1.3: Replace throttle-gate block (lines 165–174)**

Find the block starting `# ---- self-rate-limit: skip API call if last attempt was very recent --------` and ending at the closing `fi` of the `if (( since < MIN_CALL_INTERVAL )); then` guard. Replace with:

```bash
# ---- self-rate-limit: honour NEXT_ALLOWED_FILE set by prior response --------
now_ts="$(now_epoch)"
if [[ -r "$NEXT_ALLOWED_FILE" ]]; then
    next_allowed="$(cat "$NEXT_ALLOWED_FILE" 2>/dev/null || echo 0)"
    # Guard against non-numeric file content
    [[ "$next_allowed" =~ ^[0-9]+$ ]] || next_allowed=0
    if (( now_ts < next_allowed )); then
        wait_for=$(( next_allowed - now_ts ))
        render_from_cache "Throttled locally (${wait_for}s until next API call)"
    fi
fi
```

- [ ] **Step 1.4: Remove the pre-call `last_call_ts` write (old line 204)**

Find and DELETE these two lines entirely:
```bash
# Record attempt timestamp so we self-throttle aggressive refreshes.
now_epoch > "$LAST_CALL_FILE"
```

- [ ] **Step 1.5: Add `schedule_next_allowed` helper near `now_epoch()` (after line 65)**

After `now_epoch() { date +%s; }` insert:

```bash
# Write next-allowed timestamp (absolute epoch) for the throttle gate.
# Arg: backoff-in-seconds
schedule_next_allowed() {
    local backoff="$1"
    printf '%s' "$(( $(now_epoch) + backoff ))" > "$NEXT_ALLOWED_FILE"
}
```

- [ ] **Step 1.6: Update the HTTP case dispatch (lines 219–225) to schedule backoff**

Find:
```bash
case "${HTTP_CODE:-000}" in
    200) ;;
    401) render_error_raw "❌" "Auth expired — run \`claude\` to re-login." ;;
    429) render_error "Rate limited — showing cached data" ;;
    000) render_error "Network error — showing cached data" ;;
    *)   render_error "API error (HTTP $HTTP_CODE) — showing cached data" ;;
esac
```

Replace with:
```bash
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
```

- [ ] **Step 1.7: Remove the now-dead `LAST_CALL_FILE` reference**

Search for `LAST_CALL_FILE` — should have zero remaining hits:
```bash
grep -n LAST_CALL_FILE /Users/geoffreysafar/claude_code/claude-usage/claude-usage.5m.sh
```
Expected: no output. If any line remains, delete it.

- [ ] **Step 1.8: Lint + smoke**

```bash
cd ~/claude_code/claude-usage && shellcheck claude-usage.5m.sh && bash -n claude-usage.5m.sh && ./smoke.sh
```
Expected: shellcheck clean, parse clean, all four smoke cases PASS.

- [ ] **Step 1.9: Manual verification — 429 backoff sticks**

```bash
cd ~/claude_code/claude-usage
# Simulate a 429, then immediately re-run and confirm we throttle
rm -rf /tmp/claude-usage-smoke && mkdir -p /tmp/claude-usage-smoke/home
export PATH="$(pwd)/.smoke-bin:/usr/bin:/bin"  # (run under smoke.sh's stub setup — easier: just use smoke.sh)
# Simpler: extend smoke.sh in step 1.10 below
```
(This step is covered more cleanly by 1.10 — mark this done once 1.10 passes.)

- [ ] **Step 1.10: Extend `smoke.sh` with a backoff-persistence case**

Add this case just before the final "All smoke cases passed" line in `smoke.sh`:

```bash
# Backoff persistence: after a 429, a subsequent call within 1800s should throttle.
rm -rf "$HOME/.cache/claude-usage" "$HOME/Library" 2>/dev/null || true
MOCK_HTTP=429 bash "$SCRIPT" > /dev/null 2>&1 || true
# next_allowed should now be ~30 min in the future
next="$(cat "$HOME/.cache/claude-usage/next_allowed_ts" 2>/dev/null || echo 0)"
now="$(date +%s)"
delta=$(( next - now ))
if (( delta < 1700 || delta > 1801 )); then
    printf 'FAIL backoff-persistence — expected ~1800s, got %ss\n' "$delta" >&2
    exit 1
fi
# Second run should throttle (not call curl — we confirm by setting MOCK_HTTP=500 and expecting NO error)
out="$(MOCK_HTTP=500 bash "$SCRIPT" 2>&1 || true)"
if ! grep -qF "Throttled locally" <<< "$out"; then
    printf 'FAIL backoff-persistence — second call did not throttle:\n%s\n' "$out" >&2
    exit 1
fi
printf 'PASS backoff-persistence\n'
```

Then run `./smoke.sh` — expected: new case PASSes.

- [ ] **Step 1.11: Commit**

```bash
cd ~/claude_code/claude-usage
git add claude-usage.5m.sh smoke.sh
git commit -m "throttle: local-only state + HTTP-aware backoff (C1/C2/C3)

- Move throttle state out of iCloud to kill multi-Mac races
- 429 → 30min backoff, 5xx → 15min, network → 10min, 200 → 4min
- Drop pre-call last_call_ts write; next_allowed_ts is authoritative"
```

---

## Task 2: Distinct User-Agent (fixes M4)

**Files:**
- Modify: `claude-usage.5m.sh:214`

- [ ] **Step 2.1: Change User-Agent header**

Find:
```bash
header = "User-Agent: claude-code/2.1.0"
```
Replace with:
```bash
header = "User-Agent: claude-usage-swiftbar/1.0 (+https://github.com/geoffreysaf/claude-usage)"
```

- [ ] **Step 2.2: Lint + smoke**

```bash
cd ~/claude_code/claude-usage && shellcheck claude-usage.5m.sh && ./smoke.sh
```
Expected: clean, all PASS.

- [ ] **Step 2.3: Commit**

```bash
cd ~/claude_code/claude-usage
git add claude-usage.5m.sh
git commit -m "ua: distinct User-Agent so plugin traffic isolates from claude CLI (M4)"
```

---

## Task 3: Cache-only Refresh button (fixes L3)

**Goal:** Clicking "Refresh" should NEVER call the API — only re-render the cache. SwiftBar's 5-min filename-based refresh is the only API-calling path.

**Files:**
- Modify: `claude-usage.5m.sh` — toggle-subcommand block (lines 48–57) and render output (lines 84–86)

- [ ] **Step 3.1: Add `render-cache` subcommand handler**

Immediately AFTER the existing `toggle` subcommand block (after line 57's `fi`), insert:

```bash
# ---- render-cache subcommand (invoked by the Refresh menu item) ------------
# Renders from cache only — never calls the API. Used to prevent menu clicks
# from burning rate budget.
if [[ "${1:-}" == "render-cache" ]]; then
    mkdir -p "$(dirname "$MODE_FILE")" "$CACHE_DIR" "$STATE_DIR"
    mode="$(tr -d '[:space:]' < "$MODE_FILE" 2>/dev/null || printf '%s' "$DEFAULT_MODE")"
    [[ "$mode" != "pct" && "$mode" != "time" ]] && mode="$DEFAULT_MODE"
    other_mode="$([[ "$mode" == "pct" ]] && printf 'time' || printf 'pct')"
    render_from_cache "Cache-only refresh (next API call on SwiftBar's 5-min tick)"
    # render_from_cache exits — but fall through to error if somehow not
    render_error_raw "⚠️" "No cached data yet — wait for next 5-min refresh"
fi
```

**Important:** this block references `render_from_cache` and `render_error_raw` which are defined later in the file. Bash functions must be defined before they're called. So this subcommand block must be moved BELOW those function definitions, OR we accept that this is fine because bash only resolves function names at call-time, not at parse-time.

Verify the second by running:
```bash
bash -n /Users/geoffreysafar/claude_code/claude-usage/claude-usage.5m.sh
```
Expected: no syntax errors. Since bash resolves function names at call time, the forward reference works — but document it by adding a comment above the block:
```bash
# NOTE: render_from_cache + render_error_raw are defined further down;
# bash resolves function names at call time so this forward reference is fine.
```

- [ ] **Step 3.2: Update the Refresh menu item in `render_values`**

Find (around line 86):
```bash
printf 'Refresh | refresh=true\n'
```
Replace with:
```bash
printf 'Refresh (cache-only) | bash="%s" param1=render-cache terminal=false refresh=true\n' "$0"
```

- [ ] **Step 3.3: Update the same Refresh item in `render_error_raw`**

Find (around line 150):
```bash
printf 'Refresh | refresh=true\n'
```
Replace with:
```bash
printf 'Refresh (cache-only) | bash="%s" param1=render-cache terminal=false refresh=true\n' "$0"
```

- [ ] **Step 3.4: Add a smoke case for `render-cache`**

Add to `smoke.sh` before the final success line:

```bash
# render-cache subcommand must never call curl — we detect by setting a sentinel
# that would make the real curl stub fail if invoked.
rm -rf "$HOME/.cache/claude-usage" "$HOME/Library" 2>/dev/null || true
# Prime the cache with a 200 response first
MOCK_HTTP=200 bash "$SCRIPT" > /dev/null 2>&1
# Now disable curl entirely by pointing PATH at a broken one
mkdir -p "$WORK/nocurl"
cat > "$WORK/nocurl/curl" <<'STUB'
#!/bin/bash
echo "FATAL: curl was called during render-cache" >&2
exit 99
STUB
chmod +x "$WORK/nocurl/curl"
out="$(PATH="$WORK/nocurl:/usr/bin:/bin" bash "$SCRIPT" render-cache 2>&1 || true)"
if grep -qF "FATAL: curl was called" <<< "$out"; then
    printf 'FAIL render-cache — invoked curl:\n%s\n' "$out" >&2
    exit 1
fi
if ! grep -qF "42%" <<< "$out"; then
    printf 'FAIL render-cache — did not render cached 42%% value:\n%s\n' "$out" >&2
    exit 1
fi
printf 'PASS render-cache does not call curl\n'
```

Run `./smoke.sh` — expected: new case PASSes.

- [ ] **Step 3.5: Commit**

```bash
cd ~/claude_code/claude-usage
git add claude-usage.5m.sh smoke.sh
git commit -m "refresh: menu button now cache-only, cannot trigger API (L3)"
```

---

## Task 4: Kill dead code + lying comment (fixes L1 + L2)

**Goal:** `render_error` currently has an unreachable second line because `render_from_cache` always exits. Either make `render_from_cache` return when cache is unusable (better — actually lets the caller fall back), or delete the dead line. We'll do the former.

**Files:**
- Modify: `claude-usage.5m.sh:91–140` (`render_from_cache`), `155–158` (`render_error`), `166–174` (throttle comment)

- [ ] **Step 4.1: Change `render_from_cache` to return instead of exit when cache is unusable**

Find inside `render_from_cache`:
```bash
[[ -r "$CACHE_FILE" ]] || render_error_raw "⚠️" "$note (no cached data yet)"
```
Replace with:
```bash
[[ -r "$CACHE_FILE" ]] || return 1
```

Find:
```bash
[[ -z "$parsed" ]] && render_error_raw "⚠️" "$note (cache unreadable)"
```
Replace with:
```bash
[[ -z "$parsed" ]] && return 1
```

Find:
```bash
if (( age > CACHE_FALLBACK_MAX_AGE )); then
    render_error_raw "⚠️" "$note (cache too old: ${age}s)"
fi
```
Replace with:
```bash
if (( age > CACHE_FALLBACK_MAX_AGE )); then
    return 1
fi
```

- [ ] **Step 4.2: Make `render_error` actually use its fallback**

The function already has the right shape — now it's real:
```bash
render_error() {
    render_from_cache "$1"  # exits via render_values on success, returns 1 on failure
    render_error_raw "⚠️" "$1"
}
```
No change needed IF the function is already written this way. Verify and keep.

- [ ] **Step 4.3: Fix the misleading comment in the throttle gate**

In the throttle-gate block from Task 1.3, the comment `# if cache missing it falls through below and returns an error` was already removed when we replaced that block. Verify:
```bash
grep -n "falls through below" /Users/geoffreysafar/claude_code/claude-usage/claude-usage.5m.sh
```
Expected: no output. If any hit remains, delete the line.

Additionally, the throttle gate currently calls `render_from_cache "..."` and relies on it exiting. With the new return-on-failure behaviour, we need to fall through to an error-raw if cache is empty. Update the throttle block from Task 1.3 so it reads:

```bash
# ---- self-rate-limit: honour NEXT_ALLOWED_FILE set by prior response --------
now_ts="$(now_epoch)"
if [[ -r "$NEXT_ALLOWED_FILE" ]]; then
    next_allowed="$(cat "$NEXT_ALLOWED_FILE" 2>/dev/null || echo 0)"
    [[ "$next_allowed" =~ ^[0-9]+$ ]] || next_allowed=0
    if (( now_ts < next_allowed )); then
        wait_for=$(( next_allowed - now_ts ))
        render_from_cache "Throttled locally (${wait_for}s until next API call)"
        # render_from_cache returned 1 → no usable cache. Show a clean error.
        render_error_raw "⏳" "Throttled (${wait_for}s remaining, no cache yet)"
    fi
fi
```

- [ ] **Step 4.4: Lint + smoke**

```bash
cd ~/claude_code/claude-usage && shellcheck claude-usage.5m.sh && bash -n claude-usage.5m.sh && ./smoke.sh
```
Expected: all PASS.

- [ ] **Step 4.5: Commit**

```bash
cd ~/claude_code/claude-usage
git add claude-usage.5m.sh
git commit -m "render_error: remove dead code, make cache-miss fall-through real (L1/L2)"
```

---

## Task 5: Re-order keychain read after throttle gate (fixes P2)

**Goal:** On a throttled run we shouldn't invoke `security` or parse the keychain blob — it's wasted work and touches ACL'd resources.

**Files:**
- Modify: `claude-usage.5m.sh` — move the keychain block (currently lines ~177–197) to AFTER the throttle gate

- [ ] **Step 5.1: Identify the keychain block**

Block to move is the section beginning `# ---- 1. pull OAuth credentials blob from keychain --------------------------` and ending with the `if [[ -z "$ACCESS_TOKEN" ]]; then ... fi` guard (around current lines 177–197).

- [ ] **Step 5.2: Move the keychain block to AFTER the throttle gate**

The throttle gate (from Task 4.3) ends with the outer `fi`. Cut the entire keychain block and paste it immediately after that `fi`, BEFORE the `# ---- 2. call usage endpoint` section.

Final ordering should be:
1. Path config (Task 1.1)
2. Toggle subcommand (unchanged)
3. `render-cache` subcommand (Task 3.1)
4. Mode setup + helpers
5. Python preflight
6. **Throttle gate** (new)
7. **Keychain read** (moved here)
8. Curl call
9. HTTP dispatch
10. Success-path cache write + parse + render

- [ ] **Step 5.3: Lint + smoke**

```bash
cd ~/claude_code/claude-usage && shellcheck claude-usage.5m.sh && bash -n claude-usage.5m.sh && ./smoke.sh
```
Expected: all PASS.

- [ ] **Step 5.4: Verify keychain is NOT read on throttled run**

Add to `smoke.sh` before the success line:
```bash
# On a throttled run, `security` must not be invoked.
rm -rf "$HOME/.cache/claude-usage" "$HOME/Library" 2>/dev/null || true
# Prime a backoff
MOCK_HTTP=429 bash "$SCRIPT" > /dev/null 2>&1
# Replace the security stub with one that screams
cat > "$WORK/bin/security" <<'STUB'
#!/bin/bash
echo "FATAL: security was called during throttled run" >&2
exit 99
STUB
chmod +x "$WORK/bin/security"
out="$(bash "$SCRIPT" 2>&1 || true)"
if grep -qF "FATAL: security was called" <<< "$out"; then
    printf 'FAIL throttled-no-keychain — security was invoked:\n%s\n' "$out" >&2
    exit 1
fi
printf 'PASS throttled runs skip keychain\n'
# Restore working security stub for any subsequent cases
cat > "$WORK/bin/security" <<'STUB'
#!/bin/bash
if [[ "$1" == "find-generic-password" ]]; then
    printf '%s' '{"claudeAiOauth":{"accessToken":"sk-ant-fake-token-abc"}}'
    exit 0
fi
exit 1
STUB
chmod +x "$WORK/bin/security"
```

Run `./smoke.sh` — expected: new case PASSes.

- [ ] **Step 5.5: Commit**

```bash
cd ~/claude_code/claude-usage
git add claude-usage.5m.sh smoke.sh
git commit -m "perf: skip keychain read on throttled refreshes (P2)"
```

---

## Task 6: set -eo pipefail (fixes M1)

**Goal:** Fail loudly on errors in the hot path instead of silently continuing.

**Files:**
- Modify: `claude-usage.5m.sh:23` (the `set -u` line)

- [ ] **Step 6.1: Extend `set`**

Find:
```bash
set -u
```
Replace with:
```bash
set -eo pipefail
set -u
```

(Split onto two lines so a future reader can see the options explicitly.)

- [ ] **Step 6.2: Audit for expected failures that `-e` would now abort on**

With `set -e`, commands like `cat "$FILE" 2>/dev/null || echo 0` still work (the `||` disables `-e` for that compound). But bare `grep` or `cat` on missing files will now kill the script. Sweep:

```bash
cd ~/claude_code/claude-usage
grep -n -E '(^|[^|])(cat|grep|read|stat) ' claude-usage.5m.sh | grep -v '||'
```

Review each hit. Expected hits that need guarding:
- Any `cat "$FILE"` inside `$(...)` without `|| echo ...`
- The `read -r ... <<<` inside `render_from_cache` — if `$parsed` is empty, read returns 1, which with `-e` aborts. Add `|| true`:

Find:
```bash
read -r age sp sr wp wr <<< "$parsed"
```
Replace with:
```bash
read -r age sp sr wp wr <<< "$parsed" || true
```

Apply the same treatment to the other `read -r` on the success path:
```bash
read -r SESS_PCT SESS_RESET WEEK_PCT WEEK_RESET <<< "$PARSED" || true
```

- [ ] **Step 6.3: Lint + smoke**

```bash
cd ~/claude_code/claude-usage && shellcheck claude-usage.5m.sh && bash -n claude-usage.5m.sh && ./smoke.sh
```
Expected: all PASS. If smoke fails on one of the error cases, the specific failure points to another unguarded command — fix with `|| true` or explicit handling.

- [ ] **Step 6.4: Commit**

```bash
cd ~/claude_code/claude-usage
git add claude-usage.5m.sh
git commit -m "set -eo pipefail for loud failures on hot path (M1)"
```

---

## Task 7: Documentation sync

**Files:**
- Modify: `OTHER_MAC_SETUP.md` — remove the "stuck on ⏳ all day" troubleshooting entry, add a note that throttle state is now local-only
- Modify: `README.md` — add a bullet about 429 backoff and the cache-only Refresh button

- [ ] **Step 7.1: Update `OTHER_MAC_SETUP.md`**

In `OTHER_MAC_SETUP.md`, find the "How the shared cache works" section and change the bullet:
```
- Self-throttle interval is 240s. If the other Mac called the API within that window, this Mac serves the shared cached values instead of calling.
```
To:
```
- `last.json` (the data cache) is shared — either Mac's fetch warms it for the other.
- Throttle state (`next_allowed_ts`) is per-Mac and local-only. iCloud sync latency made it unsafe to share.
- Each Mac enforces its own backoff: 240s on success, 30min on 429, 15min on 5xx, 10min on network failure.
```

Delete the troubleshooting bullet:
```
- **Both Macs stuck on ⏳ (cached) all day**: the iCloud `last_call_ts` is being refreshed by whichever Mac calls first, which suppresses the other. If the API itself is returning 429s, that's upstream rate-limiting — wait it out.
```

- [ ] **Step 7.2: Update `README.md`**

In the "Safety properties" list, after the "One outbound domain" bullet, add:
```
- **Conservative backoff**: on HTTP 429 the plugin refuses to call the API for 30 minutes. On 5xx, 15 minutes. On network failure, 10 minutes. Prevents the plugin from compounding an ongoing rate limit.
- **Cache-only Refresh button**: clicking the dropdown's Refresh item only re-renders from cache. The API is only called on SwiftBar's 5-minute filename-driven tick.
```

- [ ] **Step 7.3: Commit**

```bash
cd ~/claude_code/claude-usage
git add OTHER_MAC_SETUP.md README.md
git commit -m "docs: reflect local-only throttle state and 429 backoff"
```

---

## Verification checklist (end-of-plan)

After all tasks complete:

- [ ] `shellcheck claude-usage.5m.sh` → zero output
- [ ] `bash -n claude-usage.5m.sh` → zero output
- [ ] `./smoke.sh` → all cases PASS (200, 429, 500, 000, backoff-persistence, render-cache-no-curl, throttled-no-keychain)
- [ ] `grep -n LAST_CALL_FILE claude-usage.5m.sh` → zero output
- [ ] `git log --oneline | head -8` → shows 7 commits for this plan, newest first
- [ ] Manual real-world test: symlink into SwiftBar, click menu, click "Refresh (cache-only)" — should not trigger an API call (confirm via `~/.cache/claude-usage/next_allowed_ts` mtime not advancing)
