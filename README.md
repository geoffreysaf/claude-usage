# claude-usage

A tiny macOS menubar indicator for Claude Code plan limits — shows the 5-hour session and 7-day weekly utilisation, nothing else.

Single readable shell script. No compiled binary, no telemetry, no update checks, no AppleScript.

## What it shows

Two display modes, click to toggle:

- **Percentage**: `🟢 35% / 12%` (session / weekly)
- **Time until reset**: `🟢 2h15m / 5d3h`

Status colour is driven by the higher of the two values: green below 70%, amber at 70–89%, red at 90%+.

## Requirements

- macOS 12+ (anything with `/usr/bin/security`, `/usr/bin/curl`, `/usr/bin/python3`)
- [Claude Code CLI](https://claude.ai/code) installed and logged in (`claude` in Terminal)
- [SwiftBar](https://swiftbar.app) or [xbar](https://xbarapp.com)

## Install

```bash
brew install --cask swiftbar
mkdir -p ~/SwiftBar
cp claude-usage.5m.sh ~/SwiftBar/
chmod +x ~/SwiftBar/claude-usage.5m.sh
open -a SwiftBar
```

On first launch SwiftBar asks you to pick a plugin folder — choose `~/SwiftBar`.

For xbar, drop the script in `~/Library/Application Support/xbar/plugins/` instead.

The filename's `.5m.` part tells SwiftBar/xbar to refresh every 5 minutes.

## Safety properties

Designed so you can audit it in one pass.

- **One outbound domain**: `api.anthropic.com/api/oauth/usage`. Nothing else is contacted.
- **No update checks**, no GitHub API calls at runtime.
- **OAuth token is never written to disk** and never appears in any process's argv — it's passed to `curl` via stdin config heredoc.
- **No entitlements required.** Token is read via `/usr/bin/security`, which is already on the Keychain ACL for Claude Code credentials (same pattern Claude Code itself uses).
- **No AppleScript**, no Accessibility, no Screen Recording, no Full Disk Access, no login-item registration.
- **One file written**: `~/.config/claude-usage/mode` (4 bytes, mode 0600) — remembers whether you last chose percentage or time view.
- **No logs**, no analytics, no project paths read, no home-directory traversal.

## How it works

1. Reads OAuth credentials blob from macOS Keychain (`Claude Code-credentials`, falling back to `Claude Code`).
2. Extracts `claudeAiOauth.accessToken` with Python's stdlib JSON.
3. `GET https://api.anthropic.com/api/oauth/usage` with the Bearer token.
4. Renders session and weekly values, coloured by the worst bucket.
5. A click on "Toggle display" rewrites the mode file and refreshes.

## Caveats

- The usage endpoint is **undocumented** — Anthropic can change or withdraw it at any time. If that happens, the script will show `❌ API error (HTTP …)` rather than misbehave.
- Not affiliated with Anthropic.

## Licence

MIT — see [LICENSE](LICENSE).
