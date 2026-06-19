import SwiftUI

/// Entry point. A single `MenuBarExtra` scene — no main window, no Dock icon
/// (the bundled Info.plist sets `LSUIElement`). The `.window` style lets the
/// dropdown use real SwiftUI views (colored bars, buttons) instead of a plain
/// NSMenu.
@main
struct AIUsageBarApp: App {
    @StateObject private var store = UsageStore()

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(store: store)
        } label: {
            Text(store.title)
        }
        .menuBarExtraStyle(.window)
    }
}
