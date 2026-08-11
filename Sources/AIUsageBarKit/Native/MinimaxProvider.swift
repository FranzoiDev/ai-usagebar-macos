import Foundation

/// Native MiniMax Token Plan fetcher — ports `src/minimax/`. Four wire quirks
/// are deliberate (each mirrored from upstream): the API answers HTTP 200 even
/// on auth failures (`base_resp.status_code` is the real status); percentages
/// are what REMAINS and are inverted here; interval lengths vary per bucket
/// (5h general, 24h video) and come from each window's own start/end; and all
/// timestamps are epoch milliseconds.
public enum MinimaxProvider {
    static let globalBase = "https://api.minimax.io"
    static let cnBase = "https://api.minimaxi.com"

    static func remainsURL(region: String) -> URL {
        let base = region.lowercased() == "cn" ? cnBase : globalBase
        return URL(string: "\(base)/v1/token_plan/remains")!
    }

    public static func fetch(config: AppConfig, now: Date = Date()) async -> VendorUsage {
        guard let key = AppConfig.resolveKey(env: config.minimaxApiKeyEnv, inline: config.minimaxApiKey) else {
            return .unavailable(.minimax)
        }
        let url = remainsURL(region: config.minimaxRegion)
        // The global and CN deployments issue separate keys and reject each
        // other's, so a cache from one instance/key must never be shown for
        // the other.
        let target = "\(url.absoluteString)|key:\(Support.keyFingerprint(key))"
        let cache = DiskCache(vendor: "minimax")

        if let bytes = cache.freshPayload(ttl: DiskCache.defaultTTL, target: target) {
            return render(bytes, now: now)
        }
        do {
            let resp = try await HTTP.get(url, headers: ["Authorization": "Bearer \(key)"])
            guard resp.isSuccess else { throw FetchError.http(status: resp.status, body: "") }
            let rendered = render(resp.body, now: now)
            guard rendered.available else { throw FetchError.schema("minimax response") }
            cache.writePayload(resp.body, target: target)
            return rendered
        } catch {
            if let bytes = cache.maybePayload(target: target) {
                var row = render(bytes, now: now)
                row.isStale = true
                return row
            }
            return .unavailable(.minimax)
        }
    }

    struct Pool {
        let sessionPct: Int
        let sessionReset: Date?
        let sessionWindow: TimeInterval
        let weeklyPct: Int
        let weeklyReset: Date?
    }

    static func render(_ bytes: Data, now: Date) -> VendorUsage {
        guard let doc = JSON.object(bytes),
              let baseResp = JSON.dict(doc["base_resp"]),
              JSON.int(baseResp["status_code"]) == 0
        else { return .unavailable(.minimax) }

        let rows = (JSON.array(doc["model_remains"]) ?? []).compactMap(JSON.dict)
        guard let general = rows.first(where: { JSON.string($0["model_name"]) == "general" })
            ?? rows.first(where: { JSON.string($0["model_name"]) != "video" })
        else { return .unavailable(.minimax) }
        let video = rows.first { JSON.string($0["model_name"]) == "video" }

        guard let generalPool = pool(general, defaultInterval: 5 * 3600) else {
            return .unavailable(.minimax)
        }
        let videoPool = video.flatMap { pool($0, defaultInterval: 24 * 3600) }

        let headline = "\(generalPool.sessionPct)% · \(Support.countdown(generalPool.sessionReset, now: now))"
        let compactReset = Support.shortCountdown(generalPool.sessionReset, now: now)
        let gauges = [
            UsageGauge(label: "Session", percent: Double(generalPool.sessionPct),
                       caption: "resets \(Support.countdown(generalPool.sessionReset, now: now))",
                       elapsedFraction: Support.elapsedFraction(
                           reset: generalPool.sessionReset, window: generalPool.sessionWindow, now: now)),
            UsageGauge(label: "Weekly", percent: Double(generalPool.weeklyPct),
                       caption: "resets \(Support.countdown(generalPool.weeklyReset, now: now))",
                       elapsedFraction: Support.elapsedFraction(
                           reset: generalPool.weeklyReset, window: 7 * 24 * 3600, now: now)),
        ]

        return VendorUsage(
            vendor: .minimax,
            plan: "MiniMax Token Plan",
            headline: headline,
            gauges: gauges,
            // The video pool rides along informationally; it never drives the
            // bar's severity (mirrors upstream).
            severity: Support.severity(for: max(generalPool.sessionPct, generalPool.weeklyPct)),
            available: true,
            footnote: videoPool.map { "Video: session \($0.sessionPct)% · weekly \($0.weeklyPct)%" },
            compactHeadline: "\(generalPool.sessionPct)%" + (compactReset.isEmpty ? "" : " \(compactReset)")
        )
    }

    private static func pool(_ row: [String: Any], defaultInterval: TimeInterval) -> Pool? {
        guard let sessionRemaining = JSON.int(row["current_interval_remaining_percent"]),
              let weeklyRemaining = JSON.int(row["current_weekly_remaining_percent"])
        else { return nil }
        let start = JSON.double(row["start_time"]) ?? 0
        let end = JSON.double(row["end_time"]) ?? 0
        let window = end > start ? (end - start) / 1000 : defaultInterval
        return Pool(
            sessionPct: consumedPct(sessionRemaining),
            sessionReset: dateFromMillis(end),
            sessionWindow: window,
            weeklyPct: consumedPct(weeklyRemaining),
            weeklyReset: dateFromMillis(JSON.double(row["weekly_end_time"]) ?? 0)
        )
    }

    /// The API reports what remains; every other vendor here reports spend.
    static func consumedPct(_ remaining: Int) -> Int {
        100 - min(max(remaining, 0), 100)
    }

    private static func dateFromMillis(_ ms: Double) -> Date? {
        ms > 0 ? Date(timeIntervalSince1970: ms / 1000) : nil
    }
}
