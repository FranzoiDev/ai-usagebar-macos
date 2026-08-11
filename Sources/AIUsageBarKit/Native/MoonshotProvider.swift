import Foundation

/// Native Moonshot fetcher — ports `src/moonshot/`. The currency comes from
/// the region (`.ai` = USD, `.cn` = CNY), not the response, and the envelope
/// signals failure in-band (`status`/`code`) before any field is money.
public enum MoonshotProvider {
    static func balanceURL(region: String) -> (url: URL, currency: String) {
        if region.lowercased() == "cn" {
            return (URL(string: "https://api.moonshot.cn/v1/users/me/balance")!, "CNY")
        }
        return (URL(string: "https://api.moonshot.ai/v1/users/me/balance")!, "USD")
    }

    public static func fetch(config: AppConfig, now: Date = Date()) async -> VendorUsage {
        guard let key = AppConfig.resolveKey(env: config.moonshotApiKeyEnv, inline: config.moonshotApiKey) else {
            return .unavailable(.moonshot)
        }
        let (url, currency) = balanceURL(region: config.moonshotRegion)
        // A CNY figure must never be shown as USD after a region change.
        let target = "\(url.absoluteString)|\(currency)"
        let cache = DiskCache(vendor: "moonshot")

        if let bytes = cache.freshPayload(ttl: DiskCache.defaultTTL, target: target) {
            return render(bytes, currency: currency)
        }
        do {
            let resp = try await HTTP.get(url, headers: ["Authorization": "Bearer \(key)"])
            guard resp.isSuccess else { throw FetchError.http(status: resp.status, body: "") }
            let rendered = render(resp.body, currency: currency)
            guard rendered.available else { throw FetchError.schema("moonshot response") }
            cache.writePayload(resp.body, target: target)
            return rendered
        } catch {
            if let bytes = cache.maybePayload(target: target) {
                var row = render(bytes, currency: currency)
                row.isStale = true
                return row
            }
            return .unavailable(.moonshot)
        }
    }

    static func render(_ bytes: Data, currency: String) -> VendorUsage {
        guard let doc = JSON.object(bytes),
              // In-band failure check first: `status: true` with a non-zero
              // `code` is still a failure, never a zero balance.
              JSON.bool(doc["status"]), JSON.int(doc["code"]) == 0,
              let data = JSON.dict(doc["data"]),
              let available = finite(data["available_balance"]),
              let voucher = finite(data["voucher_balance"]),
              let cash = finite(data["cash_balance"])
        else { return .unavailable(.moonshot) }

        var footnote = "cash \(Support.money(cash, currency: currency)) · voucher \(Support.money(voucher, currency: currency))"
        if available <= 0 { footnote += " · out of credit, inference blocked" }

        return VendorUsage(
            vendor: .moonshot,
            plan: "Kimi (Moonshot)",
            headline: Support.money(available, currency: currency),
            gauges: [],
            severity: severity(available: available, currency: currency),
            available: true,
            footnote: footnote
        )
    }

    /// `available <= 0` blocks the inference API outright; thresholds scale
    /// with the currency (CNY ≈ 7× USD).
    static func severity(available: Double, currency: String) -> Severity {
        if available <= 0 { return .critical }
        let (tCritical, tHigh, tMid): (Double, Double, Double) =
            currency == "CNY" ? (7, 35, 140) : (1, 5, 20)
        if available < tCritical { return .critical }
        if available < tHigh { return .high }
        if available < tMid { return .mid }
        return .low
    }

    private static func finite(_ v: Any?) -> Double? {
        guard let d = JSON.double(v), d.isFinite else { return nil }
        return d
    }
}
