import AppKit
import SwiftUI

/// Hosts `SettingsView` in a real desktop `NSWindow` rather than inside the menu
/// bar dropdown. A `Window` SwiftUI scene would auto-open at launch, which a
/// menu bar agent doesn't want, so the window is created on demand here.
///
/// Because the app is an accessory (`LSUIElement`), it has no Dock icon and
/// can't normally take focus. While the settings window is open we flip the
/// activation policy to `.regular` so it comes forward and its fields accept
/// input, then drop back to `.accessory` when it closes.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let loginItem: LoginItemManager
    private let onSaved: () -> Void

    init(loginItem: LoginItemManager, onSaved: @escaping () -> Void) {
        self.loginItem = loginItem
        self.onSaved = onSaved
    }

    /// Show the window, bringing an already-open one forward (preserving any
    /// in-progress edits) or building a fresh one that re-reads the config.
    func show() {
        if let window, window.isVisible {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let view = SettingsView(
            loginItem: loginItem,
            onSaved: onSaved,
            onClose: { [weak self] in self?.window?.close() }
        )
        // `NSWindow(contentViewController:)` sizes the window to the SwiftUI
        // content; building a zero-rect window and assigning the controller
        // after leaves it blank. Rebuild fresh each open so it re-reads config.
        let hosting = NSHostingController(rootView: view)
        let win = NSWindow(contentViewController: hosting)
        win.styleMask = [.titled, .closable]
        win.title = "AI UsageBar Settings"
        win.isReleasedWhenClosed = false
        win.delegate = self
        win.center()
        window = win

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        // Back to a pure menu bar agent: no Dock icon, no app-switcher entry.
        NSApp.setActivationPolicy(.accessory)
    }
}
