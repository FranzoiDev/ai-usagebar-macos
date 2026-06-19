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

    /// How often to re-poll. The native cache holds for 60s and the
    /// undocumented endpoints rate-limit below ~300s, so don't go lower.
    let refreshInterval: TimeInterval = 60

    private var client = NativeUsageClient()
    private var timer: Timer?

    init() {
        start()
    }

    /// Re-read `config.toml` (after Settings saves) and refresh immediately so
    /// vendor/primary/key changes take effect without restarting the app.
    func reloadConfig() {
        client = NativeUsageClient()
        Task { await refresh() }
    }

    private func start() {
        Task { await refresh() }
        timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            Task { await self?.refresh() }
        }
    }

    func refresh() async {
        isRefreshing = true
        defer { isRefreshing = false }

        let client = self.client
        let fetched = await client.fetchAll()
        let primaryVendor = client.primaryVendor()

        rows = fetched.filter { $0.available }

        if let primaryRow = fetched.first(where: { $0.vendor == primaryVendor }), primaryRow.available {
            title = "\(primaryVendor.shortCode) \(primaryRow.headline)"
        } else if let firstAvailable = rows.first {
            title = "\(firstAvailable.vendor.shortCode) \(firstAvailable.headline)"
        } else {
            title = "AI ⚠"
        }
        lastUpdated = Date()
    }
}
