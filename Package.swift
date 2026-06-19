// swift-tools-version: 5.9
import PackageDescription

// AIUsageBar — a native macOS menu bar app that surfaces AI plan usage. All
// data collection (reading the OAuth credentials the `claude`/`codex` CLIs
// wrote, the macOS Keychain fallback, token refresh, the undocumented vendor
// usage endpoints, caching) runs natively in-process — no external CLI. The
// data layer is a Swift port of https://github.com/akitaonrails/ai-usagebar.
//
// Two targets so the data layer stays testable without a GUI:
//   - AIUsageBarKit : pure data layer (credentials, HTTP fetchers, parsing, models)
//   - AIUsageBar    : the SwiftUI app (MenuBarExtra UI), depends on the kit
let package = Package(
    name: "AIUsageBar",
    platforms: [.macOS(.v13)], // MenuBarExtra requires macOS 13 Ventura+
    targets: [
        .target(name: "AIUsageBarKit"),
        .executableTarget(
            name: "AIUsageBar",
            dependencies: ["AIUsageBarKit"]
        ),
        .testTarget(
            name: "AIUsageBarKitTests",
            dependencies: ["AIUsageBarKit"]
        ),
    ]
)
