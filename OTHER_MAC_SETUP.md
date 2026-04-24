# claude-usage — setup on the second Mac

This Mac (the one you're reading this on) is the **secondary**. The primary Mac has already been migrated to a shared iCloud Drive cache so both Macs don't each burn the per-account rate limit on `/api/oauth/usage`.

## Prerequisites

- iCloud Drive signed in and syncing. Check: `~/Library/Mobile Documents/com~apple~CloudDocs/` exists.
- SwiftBar (or xbar) installed.
- Already signed into Claude Code on this Mac (`claude` run at least once so the OAuth token is in the keychain).

## Steps

### 1. Copy the script over from the primary Mac

The script lives at `~/claude_code/claude-usage/claude-usage.5m.sh` on the primary. Copy the entire `claude-usage/` folder to the same path on this Mac. AirDrop, `scp`, or a shared folder all work.

Confirm:

```sh
ls ~/claude_code/claude-usage/claude-usage.5m.sh
```

### 2. Confirm the shared iCloud cache is visible

The primary Mac has already created this directory and populated it:

```sh
ls -la ~/Library/Mobile\ Documents/com~apple~CloudDocs/claude-usage/
```

You should see `last.json` and `last_call_ts`. If iCloud hasn't synced yet, give it a minute and retry — or open Finder → iCloud Drive and let it pull.

If the directory doesn't appear at all, iCloud Drive is off or the folder hasn't synced. The script will silently fall back to a local cache in that case (no harm done, but you lose the shared-throttle benefit until iCloud comes back).

### 3. Link the plugin into SwiftBar

```sh
ln -s ~/claude_code/claude-usage/claude-usage.5m.sh \
      ~/Library/Application\ Support/SwiftBar/claude-usage.5m.sh
```

Then refresh SwiftBar (menu bar → SwiftBar icon → Refresh All).

If you use xbar, symlink into `~/Library/Application Support/xbar/plugins/` instead.

### 4. Make it executable

```sh
chmod +x ~/claude_code/claude-usage/claude-usage.5m.sh
```

### 5. Smoke-test

```sh
bash ~/claude_code/claude-usage/claude-usage.5m.sh | head -5
```

Expected: a line like `🟢 12% / 34%` followed by the dropdown content. Errors will show `⚠️` or `❌` with a diagnostic.

## How the shared cache works

- `last.json` (the data cache) lives at `~/Library/Mobile Documents/com~apple~CloudDocs/claude-usage/` if iCloud Drive is available, falling back to `~/.cache/claude-usage/`. Either Mac's fetch warms it for the other.
- Throttle state (`next_allowed_ts`) is per-Mac and always local at `~/.cache/claude-usage/`. iCloud sync latency made it unsafe to share.
- Each Mac enforces its own HTTP-status-aware backoff: 240s on success, 30min on 429, 15min on 5xx, 10min on network failure. Clicking the dropdown's "Refresh (cache-only)" item never calls the API — only SwiftBar's 5-minute filename tick does.
- The OAuth token is **never** written to the shared cache. It stays in each Mac's keychain.

## Toggling pct / time display

The display mode (`pct` vs `time`) is stored per-machine at `~/.config/claude-usage/mode` — intentional, so each Mac can show what it prefers. Click the menu bar item → "click to show …" to toggle.

## Troubleshooting

- **Both Macs stuck on ⏳ all day**: if you're getting upstream 429s, each Mac backs off for 30 minutes per incident. Either wait it out or delete `~/.cache/claude-usage/next_allowed_ts` on both Macs to retry immediately.
- **One Mac shows fresh, other shows stale**: normal for the first minute after a fetch, until iCloud syncs the data cache.
- **`❌ python3 not available`**: run `xcode-select --install`.
- **`⚪ Not signed in`**: run `claude` in Terminal on this Mac.
