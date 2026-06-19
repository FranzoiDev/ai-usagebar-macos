import Foundation

/// Native OpenRouter fetcher — ports `src/openrouter/fetch.rs` + `types.rs`.
/// Combines `/api/v1/credits` and `/api/v1/key`. The headline is balance +
/// today's spend; the single gauge tracks consumed-percentage of total credits.
public enum OpenRouterProvider {
    static let creditsURL = URL(string: "https://openrouter.ai/api/v1/credits")!
    static let keyURL = URL(string: "https://openrouter.ai/api/v1/key")!

    public static func fetch(config: AppConfig, now: Date = Date()) async -> VendorUsage {
        guard let key = AppConfig.resolveKey(env: config.openrouterApiKeyEnv, inline: config.openrouterApiKey) else {
            return .unavailable(.openrouter)
        }
        let cache = DiskCache(vendor: "openrouter")

        if let bytes = cache.freshPayload(ttl: DiskCache.defaultTTL) {
            return render(bytes)
        }

        let headers = ["Authorization": "Bearer \(key)"]
        async let creditsResp = try? HTTP.get(creditsURL, headers: headers)
        async let keyResp = try? HTTP.get(keyURL, headers: headers)
        let (credits, keyData) = await (creditsResp, keyResp)

        guard let credits, credits.isSuccess, let keyData, keyData.isSuccess,
              let creditsDoc = JSON.dict(JSON.object(credits.body)?["data"]),
              let keyDoc = JSON.dict(JSON.object(keyData.body)?["data"])
        else {
            if let bytes = cache.maybePayload() { return render(bytes) }
            return .unavailable(.openrouter)
        }

        let snapshot: [String: Any] = [
            "label": JSON.string(keyDoc["label"]) ?? "",
            "total_credits": JSON.double(creditsDoc["total_credits"]) ?? 0,
            "total_usage": JSON.double(creditsDoc["total_usage"]) ?? 0,
            "usage_daily": JSON.double(keyDoc["usage_daily"]) ?? 0,
        ]
        if let bytes = try? JSONSerialization.data(withJSONObject: snapshot) {
            cache.writePayload(bytes)
        }
        return render(snapshot)
    }

    private static func render(_ bytes: Data) -> VendorUsage {
        guard let doc = JSON.object(bytes) else { return .unavailable(.openrouter) }
        return render(doc)
    }

    private static func render(_ doc: [String: Any]) -> VendorUsage {
        let label = JSON.string(doc["label"]) ?? ""
        let plan = label.isEmpty ? "OpenRouter" : "OpenRouter — \(label)"
        let totalCredits = JSON.double(doc["total_credits"]) ?? 0
        let totalUsage = JSON.double(doc["total_usage"]) ?? 0
        let usageDaily = JSON.double(doc["usage_daily"]) ?? 0
        let balance = max(totalCredits - totalUsage, 0)
        let consumedPct: Int = totalCredits <= 0 ? 0
            : min(max(Int((totalUsage / totalCredits * 100).rounded()), 0), 100)

        let headline = "\(Support.money(balance)) · today \(Support.money(usageDaily))"
        let gauge = UsageGauge(label: "Consumed", percent: Double(consumedPct),
                               caption: "\(Support.money(balance)) left")

        return VendorUsage(
            vendor: .openrouter,
            plan: plan,
            headline: headline,
            gauges: [gauge],
            severity: Support.severity(for: consumedPct),
            available: true
        )
    }
}
