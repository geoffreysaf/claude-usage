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
    # Return a valid OAuth token blob with the exact structure the script expects
    printf '%s' '{"claudeAiOauth":{"accessToken":"sk-ant-fake-token-abc"}}'
    exit 0
fi
exit 1
STUB
chmod +x "$WORK/bin/security"

# Stub curl: driven by env var MOCK_HTTP (200|429|500|000) and MOCK_BODY
cat > "$WORK/bin/curl" <<'STUB'
#!/bin/bash
# Parse -o <file>, --config, and -w from argv to know where to write the body and what to output.
out=""
want_code=""
skip_next=""
while [[ $# -gt 0 ]]; do
    if [[ -n "$skip_next" ]]; then
        skip_next=""
        shift
        continue
    fi
    case "$1" in
        -o) out="$2"; skip_next=1; shift ;;
        --config) skip_next=1; shift ;;  # skip the - argument
        -w) want_code="$2"; skip_next=1; shift ;;
        *) shift ;;
    esac
done

http_code="${MOCK_HTTP:-200}"

# Write HTTP response body to the output file
if [[ -n "$out" ]]; then
    case "$http_code" in
        200)
            printf '%s' '{"five_hour":{"utilization":42,"resets_at":"2099-01-01T00:00:00Z"},"seven_day":{"utilization":17,"resets_at":"2099-01-08T00:00:00Z"}}' > "$out"
            ;;
        429)
            printf '%s' '{"error":"Rate limited"}' > "$out"
            ;;
        500)
            printf '%s' '{"error":"Internal server error"}' > "$out"
            ;;
    esac
fi

# Exit based on HTTP code
case "$http_code" in
    000) exit 6 ;;  # curl network error exit code
    *)
        # Print HTTP code to stdout if -w was used
        if [[ -n "$want_code" ]]; then
            printf '%s' "$http_code"
        fi
        exit 0
        ;;
esac
STUB
chmod +x "$WORK/bin/curl"

export HOME="$WORK/home"
mkdir -p "$HOME"

run_case() {
    local name="$1" http="$2" expect_substring="$3"
    rm -rf "$HOME/.cache/claude-usage" "$HOME/.config/claude-usage" "$HOME/Library" 2>/dev/null || true
    mkdir -p "$HOME/.cache" "$HOME/.config" "$HOME/Library/Mobile Documents/com~apple~CloudDocs"
    local out

    # Create a modified script that uses our mock binaries
    local script_copy="$WORK/claude-usage.sh"
    sed 's|/usr/bin/security|'"$WORK"'/bin/security|g; s|/usr/bin/curl|'"$WORK"'/bin/curl|g' "$SCRIPT" > "$script_copy"
    chmod +x "$script_copy"

    out="$(MOCK_HTTP="$http" HOME="$HOME" bash "$script_copy" 2>&1 || true)"
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

# Backoff persistence: after a 429, a subsequent call within 1800s should throttle.
rm -rf "$HOME/.cache/claude-usage" "$HOME/.config/claude-usage" "$HOME/Library" 2>/dev/null || true
mkdir -p "$HOME/.cache" "$HOME/.config" "$HOME/Library/Mobile Documents/com~apple~CloudDocs"
script_copy="$WORK/claude-usage.sh"
sed 's|/usr/bin/security|'"$WORK"'/bin/security|g; s|/usr/bin/curl|'"$WORK"'/bin/curl|g' "$SCRIPT" > "$script_copy"
chmod +x "$script_copy"
MOCK_HTTP=429 HOME="$HOME" bash "$script_copy" > /dev/null 2>&1 || true
next="$(cat "$HOME/.cache/claude-usage/next_allowed_ts" 2>/dev/null || echo 0)"
now="$(date +%s)"
delta=$(( next - now ))
if (( delta < 1700 || delta > 1801 )); then
    printf 'FAIL backoff-persistence — expected ~1800s, got %ss\n' "$delta" >&2
    exit 1
fi
# Second run should throttle — we set MOCK_HTTP=500 and expect NO error bubble
# (if throttle is working, curl is not called at all).
out="$(MOCK_HTTP=500 HOME="$HOME" bash "$script_copy" 2>&1 || true)"
if ! grep -qE "Throttled( locally|\s*\()" <<< "$out"; then
    printf 'FAIL backoff-persistence — second call did not throttle:\n%s\n' "$out" >&2
    exit 1
fi
printf 'PASS backoff-persistence\n'

# render-cache subcommand must never call curl — we detect by swapping curl
# with a fatal stub and confirming the script still renders from cache.
rm -rf "$HOME/.cache/claude-usage" "$HOME/Library" 2>/dev/null || true
mkdir -p "$HOME/.cache" "$HOME/.config" "$HOME/Library/Mobile Documents/com~apple~CloudDocs"
# Prime the cache with a 200 response first (use patched copy so stubs work)
prime_copy="$WORK/claude-usage-prime.sh"
sed 's|/usr/bin/security|'"$WORK"'/bin/security|g; s|/usr/bin/curl|'"$WORK"'/bin/curl|g' "$SCRIPT" > "$prime_copy"
chmod +x "$prime_copy"
MOCK_HTTP=200 HOME="$HOME" bash "$prime_copy" > /dev/null 2>&1
# Now build a patched copy that has a fatal curl stub in place of /usr/bin/curl
mkdir -p "$WORK/nocurl"
cp "$WORK/bin/security" "$WORK/nocurl/security"
cat > "$WORK/nocurl/curl" <<'STUB'
#!/bin/bash
echo "FATAL: curl was called during render-cache" >&2
exit 99
STUB
chmod +x "$WORK/nocurl/curl"
nocurl_copy="$WORK/claude-usage-nocurl.sh"
sed 's|/usr/bin/security|'"$WORK"'/nocurl/security|g; s|/usr/bin/curl|'"$WORK"'/nocurl/curl|g' "$SCRIPT" > "$nocurl_copy"
chmod +x "$nocurl_copy"
out="$(HOME="$HOME" bash "$nocurl_copy" render-cache 2>&1 || true)"
if grep -qF "FATAL: curl was called" <<< "$out"; then
    printf 'FAIL render-cache — invoked curl:\n%s\n' "$out" >&2
    exit 1
fi
if ! grep -qF "42%" <<< "$out"; then
    printf 'FAIL render-cache — did not render cached 42%% value:\n%s\n' "$out" >&2
    exit 1
fi
printf 'PASS render-cache does not call curl\n'

# Throttled runs must NOT invoke the keychain — wasted work on throttled ticks.
rm -rf "$HOME/.cache/claude-usage" "$HOME/.config/claude-usage" "$HOME/Library" 2>/dev/null || true
mkdir -p "$HOME/.cache" "$HOME/.config" "$HOME/Library/Mobile Documents/com~apple~CloudDocs"
# Prime a backoff by running a 429
prime429="$WORK/claude-usage-prime429.sh"
sed 's|/usr/bin/security|'"$WORK"'/bin/security|g; s|/usr/bin/curl|'"$WORK"'/bin/curl|g' "$SCRIPT" > "$prime429"
chmod +x "$prime429"
MOCK_HTTP=429 HOME="$HOME" bash "$prime429" > /dev/null 2>&1 || true
# Replace security with a fatal stub, run again — throttle should skip keychain
mkdir -p "$WORK/nosec"
cat > "$WORK/nosec/security" <<'STUB'
#!/bin/bash
echo "FATAL: security was called during throttled run" >&2
exit 99
STUB
chmod +x "$WORK/nosec/security"
cp "$WORK/bin/curl" "$WORK/nosec/curl"
nosec_copy="$WORK/claude-usage-nosec.sh"
sed 's|/usr/bin/security|'"$WORK"'/nosec/security|g; s|/usr/bin/curl|'"$WORK"'/nosec/curl|g' "$SCRIPT" > "$nosec_copy"
chmod +x "$nosec_copy"
out="$(HOME="$HOME" bash "$nosec_copy" 2>&1 || true)"
if grep -qF "FATAL: security was called" <<< "$out"; then
    printf 'FAIL throttled-no-keychain — security was invoked:\n%s\n' "$out" >&2
    exit 1
fi
printf 'PASS throttled runs skip keychain\n'

printf '\nAll smoke cases passed.\n'
