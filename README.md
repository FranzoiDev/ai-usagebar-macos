# AI UsageBar

A native macOS **menu bar** app that shows your AI plan usage right next to the
battery icon — no subscription, no extra account.

Vendors: Anthropic Claude (including multiple accounts and Claude Desktop
profiles, with model-scoped weekly limits like the Fable cap), OpenAI Codex,
Z.AI, OpenRouter, DeepSeek, Kimi, MiniMax, Kilo, Novita, Moonshot, Grok (xAI),
Anthropic Admin API (Console spend), Cursor, and Google Antigravity.

It's fully self-contained. All the data collection — reading the OAuth
credentials your `claude` / `codex` CLIs already wrote, the macOS Keychain
fallback, token refresh, the undocumented usage endpoints, caching — runs
natively in-process, with no external process or CLI. The data layer is a Swift
port of [**ai-usagebar**](https://github.com/akitaonrails/ai-usagebar) by
AkitaOnRails (a Rust-based Waybar widget + TUI, itself inspired by
`claudebar`/`codexbar`), which did the original reverse-engineering of the
vendor endpoints and OAuth flows. Full attribution in [Credits](#credits) and
[`THIRD_PARTY.md`](THIRD_PARTY.md).

## Screenshot

![AI UsageBar in the macOS menu bar showing per-vendor usage with progress bars](screenshots/usagebar.png)

```
┌──────────────────────────────────────────────┐
│ AIUsageBar.app (SwiftUI)                     │   MenuBarExtra UI, refresh loop
│        │                                     │
│        ▼  NativeUsageClient (AIUsageBarKit)  │   native, in-process
│        ▼                                     │
│  ~/.claude Keychain · ~/.codex · API keys    │   credentials
│        ▼  URLSession                         │
│  Anthropic / OpenAI / Z.AI / OpenRouter / DS │   OAuth refresh, usage endpoints, caching
└──────────────────────────────────────────────┘
```

## Requirements

- macOS 13 Ventura or newer (for `MenuBarExtra`).
- Log in once with the official CLIs/apps so the credentials exist:
  - `claude` (Anthropic) — on macOS the token is read from the login Keychain.
  - `codex login` (OpenAI).
  - Cursor: sign in to the IDE (or `cursor-agent`) once; the session token is
    read locally, read-only.
  - Antigravity: no credentials — quota is served by the locally running app,
    IDE, or `agy` session.
  - The other vendors use API keys via env vars or a `config.toml`
    (see [Configuration](#configuration)).

No Rust toolchain, no CLI install — nothing beyond Swift to build and run.

## Install

```bash
brew install franzoidev/tap/ai-usagebar
ai-usagebar   # start the menu bar app
```

The formula builds from source on your machine, so the binary is signed by your
own toolchain and never quarantined — no Gatekeeper prompt, no notarization, no
`xattr` dance. It needs the Xcode toolchain to compile (Command Line Tools alone
may be missing SDK pieces).

It's a menu bar agent — no Dock icon. For a reliable **Launch at Login**, copy
it into `/Applications` first, then enable it from the app's gear ▸ Settings:

```bash
cp -R "$(brew --prefix)/opt/ai-usagebar/AIUsageBar.app" /Applications/
```

## Run it (dev)

```bash
swift run          # launch the app (shows a Dock icon in a dev build)
swift test         # unit tests for the data layer
```

## Cutting a release

Distribution is a [Homebrew formula](Formula/ai-usagebar.rb) that compiles from
a source tarball — there's no prebuilt binary to sign or upload.

1. Bump `CFBundleShortVersionString` in `Resources/Info.plist`.
2. Tag and push: `git tag v<version> && git push --tags`.
3. Get the tarball checksum:
   `curl -fsSL https://github.com/FranzoiDev/ai-usagebar-macos/archive/refs/tags/v<version>.tar.gz | shasum -a 256`
4. Update `url`, `sha256` in `Formula/ai-usagebar.rb` and push it to the
   `FranzoiDev/homebrew-tap` repo (path `Formula/ai-usagebar.rb`).

## Configuration

Optional. Mirrors upstream `ai-usagebar`'s `~/.config/ai-usagebar/config.toml`
(honoring `$XDG_CONFIG_HOME`). Every field has a sensible default, so the file
is only needed to disable a vendor, choose the primary, or inline an API key.

The common options — primary vendor, per-vendor enable, inline API keys, and
launch-at-login — can be set from the dropdown's **gear** (bottom-right), which
reads and writes this same file. Hand edits to keys the UI doesn't surface
(paths, `api_key_env`, `plan_tier`) are preserved; comments are not.

The file is watched: edits apply within a moment, no restart needed.

```toml
[ui]
primary = "anthropic"      # which vendor headlines the menu bar title
pace_marker = true         # tick at each window's elapsed-time position
indicator_style = "bars"   # or "ring"

[anthropic]
enabled = true
# accounts_dir = "~/.config/ai-usagebar/accounts"  # auto-discover CLAUDE_CONFIG_DIRs
# show_default_account = true                      # hide the unnamed login when false
# desktop_profiles_dir = "~/.claude-acc/profiles"  # Claude Desktop (claude-acc) profiles

# Extra named Claude accounts (see "Multiple Claude accounts" below):
# [[anthropic.accounts]]
# label = "work"
# credentials_path = "~/.config/ai-usagebar/accounts/work/.credentials.json"

[openai]
enabled = true

[zai]
enabled = true
api_key_env = "ZAI_API_KEY"   # env var wins over the inline key below
# api_key = "…"

[openrouter]
enabled = true
api_key_env = "OPENROUTER_API_KEY"

# Everything below is opt-in (disabled by default) and needs a key or a local
# install:

[deepseek]
enabled = false
api_key_env = "DEEPSEEK_API_KEY"

[kimi]
enabled = false
api_key_env = "KIMI_API_KEY"

[minimax]
enabled = false
api_key_env = "MINIMAX_API_KEY"
region = "global"             # or "cn" — separate instances, separate keys

[kilo]
enabled = false
api_key_env = "KILO_API_KEY"
# organization_id = "org_…"   # omit for the personal balance

[novita]
enabled = false
api_key_env = "NOVITA_API_KEY"

[moonshot]
enabled = false
api_key_env = "MOONSHOT_API_KEY"
region = "global"             # "cn" switches host AND currency (CNY)

[grok]
enabled = false
api_key_env = "XAI_MANAGEMENT_KEY"   # Management key, not the inference key
# team_id = "…"               # required for organization-scoped keys

[anthropic_api]
enabled = false
api_key_env = "ANTHROPIC_ADMIN_KEY"  # Console Admin key (sk-ant-admin01-…)
# monthly_limit = 1000        # dollars; the API exposes no limit itself

[cursor]
enabled = false               # reads the IDE's local session, read-only

[antigravity]
enabled = false               # local server discovery via lsof
```

### Multiple Claude accounts

Keep several Claude Code logins side by side with per-account
`CLAUDE_CONFIG_DIR`s (`CLAUDE_CONFIG_DIR=~/…/accounts/work claude` to sign in),
then point `accounts_dir` at the parent directory — every subdirectory becomes
its own row, with its own cache and Keychain item. Explicit
`[[anthropic.accounts]]` entries win on a label clash. Saved **Claude Desktop**
profiles (the [claude-acc](https://github.com/ohmaseclaro/claude-acc) layout)
also appear as rows, labeled `· <name> (desktop)` — read-only: this app never
rotates any credential.

## How the data flows

1. Every 60s (and on demand) `NativeUsageClient` fetches all enabled vendors
   concurrently, in-process.
2. Per vendor it reads the credentials (Anthropic from `~/.claude/.credentials.json`
   or the login Keychain — per-account Keychain items for named accounts, the
   decrypted safeStorage blob for Claude Desktop profiles; OpenAI from
   `~/.codex/auth.json`; Cursor from the IDE's `state.vscdb`; the rest from API
   keys) and `GET`s the usage endpoint via `URLSession`. HTTP redirects are
   restricted to the original origin so credential headers can't leak
   cross-origin. Responses are cached on disk (`~/.cache/ai-usagebar/<vendor>/`)
   with a 60s TTL, fingerprinted to the account/region/key they were fetched
   for, and reused (marked ⏸ stale) as a fallback when a live fetch fails —
   never past 7 days.
3. Each vendor's response is rendered into a `VendorUsage` (headline + progress
   gauges + a `low`/`mid`/`high`/`critical` severity) and the rows are drawn.
   Time-windowed gauges carry a **pace marker**: a blue tick at the window's
   elapsed-time position — fill up to it is on pace, only the overshoot past it
   is painted in the warning color.
4. The menu bar title tracks the **primary** vendor (`[ui] primary` in
   `config.toml`) with a compact reset countdown ("42% 2h"); the eye toggle on
   each row excludes it from the title.

The vendor catalog (names, short codes) lives in
`Sources/AIUsageBarKit/Vendor.swift`; each vendor's fetch + render logic lives
in `Sources/AIUsageBarKit/Native/<Vendor>Provider.swift`.

## Project layout

```
Sources/
  AIUsageBarKit/   pure, testable data layer
    Vendor.swift       vendor catalog (names, short codes)
    Models.swift       Severity / VendorUsage / UsageGauge
    Native/            the in-process data collection (port of ai-usagebar)
      NativeUsageClient.swift   orchestrator: fetch all vendors, pick primary
      AppConfig.swift           config.toml read/write + API-key resolution
      DiskCache.swift           per-vendor on-disk payload cache
      Keychain.swift            macOS login-Keychain access (security(1))
      AnthropicCreds.swift      Claude creds + OAuth token refresh
      CodexCreds.swift          Codex auth.json + JWT + OAuth token refresh
      Support.swift             countdown / severity / money / HTTP / JSON
      AnthropicProvider.swift   …and one <Vendor>Provider.swift per vendor
  AIUsageBar/      the SwiftUI app
    AIUsageBarApp.swift            @main MenuBarExtra scene
    UsageStore.swift              ObservableObject + refresh loop
    MenuContentView.swift         dropdown UI (gear opens Settings)
    SettingsView.swift            config editor (vendors, keys, login item)
    SettingsWindowController.swift hosts Settings in a desktop window
    LoginItemManager.swift        launch-at-login via SMAppService
Tests/AIUsageBarKitTests/   XCTest for the kit
Resources/Info.plist        bundle plist (LSUIElement)
Formula/ai-usagebar.rb      Homebrew formula (builds from source)
```

## Credits

This project would not exist without the upstream work it builds on:

- **[ai-usagebar](https://github.com/akitaonrails/ai-usagebar)** by
  [AkitaOnRails](https://github.com/akitaonrails) — the Rust Waybar widget + TUI
  that reverse-engineered all the data collection (credentials, macOS Keychain,
  OAuth refresh, vendor endpoints, caching). AI UsageBar's data layer
  (`Sources/AIUsageBarKit/Native/`) is a Swift port of it. _MIT._
- **[`claudebar`](https://github.com/mryll/claudebar)** and
  **[`codexbar`](https://github.com/mryll/codexbar)** by
  [mryll](https://github.com/mryll) — the original inspiration for ai-usagebar
  (the OAuth endpoint references, tooltip design, and pacing math). _MIT._

This is an independent macOS-native front-end, not affiliated with or endorsed
by the upstream authors. See [`THIRD_PARTY.md`](THIRD_PARTY.md) for details.

## License

MIT — see [`LICENSE`](LICENSE). The upstream projects are MIT-licensed too.
