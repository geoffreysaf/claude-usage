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

printf '\nAll smoke cases passed.\n'
