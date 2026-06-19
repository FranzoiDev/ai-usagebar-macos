import Foundation

/// Native Z.AI / BigModel fetcher — ports `src/zai/fetch.rs` + `types.rs`.
/// Note the auth quirk: the key goes in `Authorization` WITHOUT a `Bearer`
/// prefix. Classifies limits by position: first TOKENS_LIMIT = session,
/// second = weekly, TIME_LIMIT = MCP.
public enum ZaiProvider {
    static let quotaURL = URL(string: "https://api.z.ai/api/monitor/usage/quota/limit")!

    public static func fetch(config: AppConfig, now: Date = Date()) async -> VendorUsage {
        guard let key = AppConfig.resolveKey(env: config.zaiApiKeyEnv, inline: config.zaiApiKey) else {
            return .unavailable(.zai)
        }
        let cache = DiskCache(vendor: "zai")
        let planTier = config.zaiPlanTier

        if let bytes = cache.freshPayload(ttl: DiskCache.defaultTTL) {
            return render(bytes, planTier: planTier, now: now)
        }

        do {
            let resp = try await HTTP.get(quotaURL, headers: [
                "Authorization": key, // NO `Bearer ` prefix.
                "Accept-Language": "en-US,en",
                "Content-Type": "application/json",
            ])
            guard resp.isSuccess else { throw FetchError.http(status: resp.status, body: "") }
            cache.writePayload(resp.body)
            return render(resp.body, planTier: planTier, now: now)
        } catch {
            if let bytes = cache.maybePayload() { return render(bytes, planTier: planTier, now: now) }
            return .unavailable(.zai)
        }
    }

    private static func render(_ bytes: Data, planTier: String?, now: Date) -> VendorUsage {
        guard let doc = JSON.object(bytes) else { return .unavailable(.zai) }
        let data = JSON.dict(doc["data"])
        let level = (JSON.string(data?["level"]).flatMap { $0.isEmpty ? nil : $0 })
            ?? planTier ?? "unknown"
        let plan = "GLM Coding \(Support.capitalizeFirst(level))"
        let limits = JSON.array(data?["limits"]) ?? []
        let tokenLimits = limits.compactMap(JSON.dict).filter { JSON.string($0["type"]) == "TOKENS_LIMIT" }
        let timeLimit = limits.compactMap(JSON.dict).first { JSON.string($0["type"]) == "TIME_LIMIT" }

        let session = window(tokenLimits.first)
        let weekly = window(tokenLimits.count > 1 ? tokenLimits[1] : nil)
        let mcp = window(timeLimit)

        let headline = "\(session.pct)% · \(Support.countdown(session.reset, now: now))"
        let gauges = [
            UsageGauge(label: "Session", percent: Double(session.pct),
                       caption: "resets \(Support.countdown(session.reset, now: now))"),
            UsageGauge(label: "Weekly", percent: Double(weekly.pct),
                       caption: "resets \(Support.countdown(weekly.reset, now: now))"),
        ]
        let maxPct = max(session.pct, weekly.pct, mcp.pct)

        return VendorUsage(
            vendor: .zai,
            plan: plan,
            headline: headline,
            gauges: gauges,
            severity: Support.severity(for: maxPct),
            available: true
        )
    }

    private static func window(_ l: [String: Any]?) -> Window {
        guard let l else { return Window(pct: 0, reset: nil) }
        let pct = min(max(Int((JSON.double(l["percentage"]) ?? 0).rounded()), 0), 100)
        var reset: Date?
        if let ms = JSON.int(l["nextResetTime"]), ms > 0 {
            reset = Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
        }
        return Window(pct: pct, reset: reset)
    }
}
