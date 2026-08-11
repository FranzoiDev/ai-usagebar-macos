import Foundation

/// Native Kimi fetcher — ports `src/kimi/`. Weekly subscription quota plus a
/// rolling 5-hour window from the undocumented `coding/v1/usages` endpoint.
public enum KimiProvider {
    static let usageURL = URL(string: "https://api.kimi.com/coding/v1/usages")!
    static let weeklyWindow: TimeInterval = 7 * 24 * 3600
    static let sessionWindow: TimeInterval = 5 * 3600

    public static func fetch(config: AppConfig, now: Date = Date()) async -> VendorUsage {
        guard let key = AppConfig.resolveKey(env: config.kimiApiKeyEnv, inline: config.kimiApiKey) else {
            return .unavailable(.kimi)
        }
        let cache = DiskCache(vendor: "kimi")
        if let bytes = cache.freshPayload(ttl: DiskCache.defaultTTL) {
            return render(bytes, now: now)
        }
        do {
            let resp = try await HTTP.get(usageURL, headers: [
                "Authorization": "Bearer \(key)",
                "Accept": "application/json",
            ])
            guard resp.isSuccess else { throw FetchError.http(status: resp.status, body: "") }
            cache.writePayload(resp.body)
            return render(resp.body, now: now)
        } catch {
            if let bytes = cache.maybePayload() {
                var row = render(bytes, now: now)
                row.isStale = true
                return row
            }
            return .unavailable(.kimi)
        }
    }

    struct QuotaBlock {
        let limit: UInt64
        let used: UInt64
        let reset: Date?

        var pct: Int {
            guard limit > 0 else { return 0 }
            return min(Int((Double(used) / Double(limit) * 100).rounded()), 100)
        }
    }

    static func render(_ bytes: Data, now: Date) -> VendorUsage {
        guard let doc = JSON.object(bytes),
              // The top-level usage block is required — its absence is drift,
              // not a zero-usage account.
              let weekly = block(JSON.dict(doc["usage"]))
        else { return .unavailable(.kimi) }

        let plan = JSON.dict(JSON.dict(doc["user"])?["membership"])
            .flatMap { JSON.string($0["level"]) }

        // The rolling 5h window lives in `limits[]`; an empty/absent array
        // legitimately means no window.
        let window = fiveHourBlock(doc["limits"])

        let headline = "\(weekly.pct)% · \(Support.countdown(weekly.reset, now: now))"
        let compactReset = Support.shortCountdown(weekly.reset, now: now)
        var gauges = [
            UsageGauge(label: "Weekly", percent: Double(weekly.pct),
                       caption: "\(weekly.used) / \(weekly.limit) · resets \(Support.countdown(weekly.reset, now: now))",
                       elapsedFraction: Support.elapsedFraction(reset: weekly.reset, window: weeklyWindow, now: now)),
        ]
        if let window, window.limit > 0 {
            gauges.append(
                UsageGauge(label: "Rolling (5h)", percent: Double(window.pct),
                           caption: "resets \(Support.countdown(window.reset, now: now))",
                           elapsedFraction: Support.elapsedFraction(reset: window.reset, window: sessionWindow, now: now))
            )
        }

        return VendorUsage(
            vendor: .kimi,
            plan: Support.sanitizeDisplay(plan.map { "Kimi \($0)" } ?? "Kimi"),
            headline: headline,
            gauges: gauges,
            severity: Support.severity(for: max(weekly.pct, window?.pct ?? 0)),
            available: true,
            compactHeadline: "\(weekly.pct)%" + (compactReset.isEmpty ? "" : " \(compactReset)")
        )
    }

    /// Counters arrive as JSON numbers or decimal strings; `used`/`remaining`
    /// derive from each other when only one is present. No field defaults to
    /// zero — a block without `limit` or without both counters is dropped.
    static func block(_ d: [String: Any]?) -> QuotaBlock? {
        guard let d, let limit = counter(d["limit"]) else { return nil }
        let used = counter(d["used"])
        let remaining = counter(d["remaining"])
        let resolvedUsed: UInt64
        switch (used, remaining) {
        case let (u?, _):        resolvedUsed = u
        case let (nil, r?):      resolvedUsed = limit > r ? limit - r : 0
        case (nil, nil):         return nil
        }
        let reset = JSON.string(d["resetTime"] ?? d["resetAt"] ?? d["reset_at"] ?? d["reset_time"])
        return QuotaBlock(limit: limit, used: resolvedUsed, reset: Support.parseRFC3339(reset))
    }

    private static func counter(_ v: Any?) -> UInt64? {
        guard let d = JSON.double(v), d >= 0 else { return nil }
        return UInt64(d)
    }

    /// First `limits[]` entry whose window is 5 hours (300 min / 5 h).
    static func fiveHourBlock(_ raw: Any?) -> QuotaBlock? {
        for entry in (JSON.array(raw) ?? []).compactMap(JSON.dict) {
            guard let w = JSON.dict(entry["window"]) else { continue }
            let duration = JSON.int(w["duration"]) ?? 0
            let unit = (JSON.string(w["timeUnit"] ?? w["time_unit"]) ?? "").uppercased()
            let isFiveHours =
                (duration == 300 && ["TIME_UNIT_MINUTE", "MINUTE", "MINUTES"].contains(unit))
                || (duration == 5 && ["TIME_UNIT_HOUR", "HOUR", "HOURS"].contains(unit))
            guard isFiveHours, let detail = block(JSON.dict(entry["detail"])) else { continue }
            return detail
        }
        return nil
    }
}
