import Foundation

/// Native DeepSeek fetcher — ports `src/deepseek/fetch.rs` + `types.rs` +
/// `vendor.rs`. Exposes a credit balance only (no rate-limit windows), so the
/// headline carries availability and there are no gauges — matching the
/// upstream `{ds_available}` default.
public enum DeepseekProvider {
    static let balanceURL = URL(string: "https://api.deepseek.com/user/balance")!

    public static func fetch(config: AppConfig, now: Date = Date()) async -> VendorUsage {
        guard let key = AppConfig.resolveKey(env: config.deepseekApiKeyEnv, inline: config.deepseekApiKey) else {
            return .unavailable(.deepseek)
        }
        let cache = DiskCache(vendor: "deepseek")

        if let bytes = cache.freshPayload(ttl: DiskCache.defaultTTL) {
            return render(bytes)
        }

        do {
            let resp = try await HTTP.get(balanceURL, headers: [
                "Authorization": "Bearer \(key)",
                "Accept": "application/json",
            ])
            guard resp.isSuccess else { throw FetchError.http(status: resp.status, body: "") }
            cache.writePayload(resp.body)
            return render(resp.body)
        } catch {
            if let bytes = cache.maybePayload() { return render(bytes) }
            return .unavailable(.deepseek)
        }
    }

    private static func render(_ bytes: Data) -> VendorUsage {
        guard let doc = JSON.object(bytes) else { return .unavailable(.deepseek) }
        let isAvailable = JSON.bool(doc["is_available"])
        let infos = (JSON.array(doc["balance_infos"]) ?? []).compactMap(JSON.dict)
        let info = infos.first { JSON.string($0["currency"]) == "USD" }
            ?? infos.first { JSON.string($0["currency"]) == "CNY" }
            ?? infos.first
        let balance = JSON.double(info?["total_balance"]) ?? 0
        let currency = JSON.string(info?["currency"]) ?? ""

        return VendorUsage(
            vendor: .deepseek,
            plan: "DeepSeek",
            headline: isAvailable ? "up" : "down",
            gauges: [],
            severity: severity(isAvailable: isAvailable, balance: balance, currency: currency),
            available: true
        )
    }

    /// Currency-scaled balance thresholds (mirrors `deepseek/vendor.rs`).
    private static func severity(isAvailable: Bool, balance: Double, currency: String) -> Severity {
        if !isAvailable { return .critical }
        let (tCritical, tHigh, tMid): (Double, Double, Double) =
            currency == "CNY" ? (7, 35, 140) : (1, 5, 20)
        if balance < tCritical { return .critical }
        if balance < tHigh { return .high }
        if balance < tMid { return .mid }
        return .low
    }
}
