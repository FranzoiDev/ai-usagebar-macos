import Foundation
import ServiceManagement

/// Controls whether AIUsageBar launches automatically at login.
///
/// Uses the modern `SMAppService` API (macOS 13+), which registers the main app
/// itself as a login item — no separate helper bundle, no deprecated
/// `SMLoginItemSetEnabled`. The toggle only does anything meaningful when the
/// app runs from a real `.app` bundle (i.e. the distributed build); under
/// `swift run` the registration throws and is reported as `unavailable`.
@MainActor
final class LoginItemManager: ObservableObject {
    /// Whether the app is currently registered to launch at login.
    @Published private(set) var isEnabled: Bool = false

    /// True when login-item registration can't be used in this context (e.g.
    /// running unbundled via `swift run`), so the UI can disable the toggle.
    @Published private(set) var isUnavailable: Bool = false

    init() {
        refresh()
    }

    /// Re-read the live status from the system — it can change out of band
    /// (System Settings → General → Login Items, or another launch).
    func refresh() {
        switch SMAppService.mainApp.status {
        case .enabled:
            isEnabled = true
            isUnavailable = false
        case .notRegistered, .notFound:
            isEnabled = false
            isUnavailable = false
        case .requiresApproval:
            // Registered but the user must approve it in System Settings.
            isEnabled = true
            isUnavailable = false
        @unknown default:
            isEnabled = false
            isUnavailable = false
        }
    }

    /// Register or unregister the app as a login item, then resync state.
    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                try SMAppService.mainApp.unregister()
            }
            isUnavailable = false
        } catch {
            // Most commonly hit when running unbundled (no Info.plist bundle).
            NSLog("AIUsageBar: login item toggle failed: \(error.localizedDescription)")
            isUnavailable = true
        }
        refresh()
    }
}
