# Third-party software & attribution

AI UsageBar is a macOS-native app whose data layer is derived from the projects
below. All are MIT-licensed.

## ai-usagebar (data layer ported from)

The Rust CLI that reverse-engineered all the data collection: reading the OAuth
credentials your `claude` / `codex` CLIs already wrote (including the macOS
login Keychain), refreshing tokens, calling each vendor's usage endpoint, and
caching results. AI UsageBar's data layer (`Sources/AIUsageBarKit/Native/`) is a
Swift port of it — the credential formats, OAuth flows, endpoint URLs/headers,
response shapes, severity thresholds, and caching behavior all follow it. No
binary is bundled or executed; everything runs natively in-process.

- Project: https://github.com/akitaonrails/ai-usagebar
- Author: AkitaOnRails
- License: MIT

## claudebar & codexbar (original inspiration)

ai-usagebar is a Rust port + multi-vendor extension of these two shell tools.
The undocumented OAuth endpoint references, the bordered tooltip design, the
usage-severity colors, and the pacing math originate here.

- claudebar: https://github.com/mryll/claudebar
- codexbar: https://github.com/mryll/codexbar
- Author: mryll
- License: MIT

## Relationship

AI UsageBar is an independent project, not affiliated with or endorsed by the
authors above. It is grateful to stand on their work.
