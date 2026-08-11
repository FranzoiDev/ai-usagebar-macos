import Foundation
import AIUsageBarKit

/// Observable state for the menu bar. Owns the refresh loop and publishes the
/// resolved rows + the bar title. All data collection happens natively in
/// `NativeUsageClient` (credentials, Keychain, OAuth refresh, vendor endpoints,
/// caching) — there is no external process involved.
@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var rows: [VendorUsage] = []
    @Published private(set) var title: String = "AI…"
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var isRefreshing = false
    /// UI knobs re-read from `config.toml` on every reload.
    @Published private(set) var showPaceMarker = true
    @Published private(set) var indicatorStyle: IndicatorStyle = .bars
    /// Row ids the user unchecked in the dropdown: still listed (dimmed), but
    /// excluded from the menu bar title (upstream v0.19's per-provider toggle).
    @Published private(set) var hiddenRowIDs: Set<String>

    /// How often to re-poll. The native cache holds for 60s and the
    /// undocumented endpoints rate-limit below ~300s, so don't go lower.
    let refreshInterval: TimeInterval = 60

    private static let hiddenDefaultsKey = "hiddenRowIDs"

    private var client = NativeUsageClient()
    private var timer: Timer?
    private var watcher: ConfigWatcher?

    init() {
        hiddenRowIDs = Set(UserDefaults.standard.stringArray(forKey: Self.hiddenDefaultsKey) ?? [])
        applyConfig(client.config)
        start()
    }

    /// Re-read `config.toml` (after Settings saves or an external edit) and
    /// refresh immediately so vendor/primary/key changes take effect without
    /// restarting the app.
    func reloadConfig() {
        client = NativeUsageClient()
        applyConfig(client.config)
        Task { await refresh() }
    }

    func toggleHidden(_ id: String) {
        if hiddenRowIDs.contains(id) { hiddenRowIDs.remove(id) } else { hiddenRowIDs.insert(id) }
        UserDefaults.standard.set(Array(hiddenRowIDs).sorted(), forKey: Self.hiddenDefaultsKey)
        retitle()
    }

    func isHidden(_ id: String) -> Bool { hiddenRowIDs.contains(id) }

    private func applyConfig(_ config: AppConfig) {
        showPaceMarker = config.uiPaceMarker
        indicatorStyle = config.uiIndicatorStyle
    }

    private func start() {
        Task { await refresh() }
        timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            Task { await self?.refresh() }
        }
        // Live config reload (upstream v0.19): edits to config.toml apply
        // within a moment, no restart, whether made by Settings or an editor.
        watcher = ConfigWatcher(path: AppConfig.configURL()) { [weak self] in
            self?.reloadConfig()
        }
    }

    func refresh() async {
        isRefreshing = true
        defer { isRefreshing = false }

        let client = self.client
        let fetched = await client.fetchAll()

        // Keep the last good snapshot visible (marked stale) when a vendor
        // that previously had data fails with no usable cache, instead of
        // dropping its row (upstream v0.21's refresh-flicker fix).
        var next: [VendorUsage] = []
        for usage in fetched {
            if usage.available {
                next.append(usage)
            } else if var old = rows.first(where: { $0.id == usage.id }) {
                old.isStale = true
                next.append(old)
            }
        }
        // Rows from account-scoped fetches that vanished from the config are
        // intentionally not preserved: they no longer correspond to anything.
        rows = next
        retitle()
        lastUpdated = Date()
    }

    private func retitle() {
        let visible = rows.filter { !hiddenRowIDs.contains($0.id) }
        let primaryVendor = client.primaryVendor()
        let lead = visible.first { $0.vendor == primaryVendor && $0.accountLabel.isEmpty }
            ?? visible.first { $0.vendor == primaryVendor }
            ?? visible.first

        if let lead {
            let summary = lead.compactHeadline ?? lead.headline
            title = "\(lead.vendor.shortCode) \(summary)\(lead.isStale ? " ⏸" : "")"
        } else {
            title = "AI ⚠"
        }
    }
}
