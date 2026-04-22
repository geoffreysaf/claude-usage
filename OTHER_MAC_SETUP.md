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

- `CACHE_DIR` auto-detects iCloud Drive at `~/Library/Mobile Documents/com~apple~CloudDocs/claude-usage/` and falls back to `~/.cache/claude-usage/` if iCloud is unavailable.
- Both Macs read/write `last.json` and `last_call_ts` there.
- Self-throttle interval is 240s. If the other Mac called the API within that window, this Mac serves the shared cached values instead of calling.
- iCloud sync is not instant — expect a few seconds of lag. Occasionally both Macs will make a call within the same window; not a problem, just not perfectly deduped.
- The OAuth token is **never** written to the shared cache. It stays in each Mac's keychain.

## Toggling pct / time display

The display mode (`pct` vs `time`) is stored per-machine at `~/.config/claude-usage/mode` — intentional, so each Mac can show what it prefers. Click the menu bar item → "click to show …" to toggle.

## Troubleshooting

- **Both Macs stuck on ⏳ (cached) all day**: the iCloud `last_call_ts` is being refreshed by whichever Mac calls first, which suppresses the other. If the API itself is returning 429s, that's upstream rate-limiting — wait it out.
- **One Mac shows fresh, other shows stale**: normal for the first minute after a fetch, until iCloud syncs.
- **`❌ python3 not available`**: run `xcode-select --install`.
- **`⚪ Not signed in`**: run `claude` in Terminal on this Mac.
