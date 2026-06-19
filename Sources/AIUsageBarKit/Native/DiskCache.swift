import Foundation

/// Per-vendor on-disk payload cache, ported from the relevant parts of the
/// upstream `src/cache.rs`. The macOS UI only needs the fast-path (serve a
/// fresh payload without hitting the network) and the failure fallback (reuse
/// the last good payload, marked stale) — so the inter-process flock and the
/// `.last_error` files are intentionally omitted.
///
/// Layout: `~/.cache/ai-usagebar/<vendor>/usage.json` (honoring `XDG_CACHE_HOME`).
public struct DiskCache: Sendable {
    public let dir: URL

    /// Default TTL — matches upstream `cache::DEFAULT_TTL` (60s).
    public static let defaultTTL: TimeInterval = 60
    /// Refuse to serve cached data older than this on failure (7 days).
    public static let maxStale: TimeInterval = 7 * 24 * 3600

    public init(vendor: String) {
        let env = ProcessInfo.processInfo.environment
        let base: URL
        if let xdg = env["XDG_CACHE_HOME"], !xdg.isEmpty {
            base = URL(fileURLWithPath: xdg)
        } else {
            base = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".cache")
        }
        dir = base.appendingPathComponent("ai-usagebar").appendingPathComponent(vendor)
    }

    private var payloadPath: URL { dir.appendingPathComponent("usage.json") }

    private func ensureDir() {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    /// Seconds since the payload was last written, or nil if it doesn't exist.
    public func payloadAge() -> TimeInterval? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: payloadPath.path),
              let mtime = attrs[.modificationDate] as? Date else { return nil }
        return Date().timeIntervalSince(mtime)
    }

    /// The payload if it's younger than `ttl`, else nil (forces a refresh).
    public func freshPayload(ttl: TimeInterval) -> Data? {
        guard let age = payloadAge(), age < ttl else { return nil }
        return try? Data(contentsOf: payloadPath)
    }

    /// The last good payload if it's within `maxStale` — the failure fallback.
    public func maybePayload() -> Data? {
        guard let age = payloadAge(), age < Self.maxStale else { return nil }
        return try? Data(contentsOf: payloadPath)
    }

    /// Atomically persist a fresh payload.
    public func writePayload(_ data: Data) {
        ensureDir()
        try? data.write(to: payloadPath, options: .atomic)
    }
}
