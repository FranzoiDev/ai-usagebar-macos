import Foundation

/// Native Novita fetcher — ports `src/novita/`. All four monetary fields are
/// required strings holding integers in 1/10000 USD; a partial body is drift,
/// never a $0.00 balance.
public enum NovitaProvider {
    static let balanceURL = URL(string: "https://api.novita.ai/openapi/v1/billing/balance/detail")!

    public static func fetch(config: AppConfig, now: Date = Date()) async -> VendorUsage {
        guard let key = AppConfig.resolveKey(env: config.novitaApiKeyEnv, inline: config.novitaApiKey) else {
            return .unavailable(.novita)
        }
        let cache = DiskCache(vendor: "novita")
        if let bytes = cache.freshPayload(ttl: DiskCache.defaultTTL) {
            return render(bytes)
        }
        do {
            let resp = try await HTTP.get(balanceURL, headers: [
                "Authorization": "Bearer \(key)",
                "Content-Type": "application/json",
            ])
            guard resp.isSuccess else { throw FetchError.http(status: resp.status, body: "") }
            let rendered = render(resp.body)
            guard rendered.available else { throw FetchError.schema("novita response") }
            cache.writePayload(resp.body)
            return rendered
        } catch {
            if let bytes = cache.maybePayload() {
                var row = render(bytes)
                row.isStale = true
                return row
            }
            return .unavailable(.novita)
        }
    }

    static func render(_ bytes: Data) -> VendorUsage {
        guard let doc = JSON.object(bytes),
              let available = tenThousandthsUSD(doc["availableBalance"]),
              let cash = tenThousandthsUSD(doc["cashBalance"]),
              let creditLimit = tenThousandthsUSD(doc["creditLimit"]),
              let outstanding = tenThousandthsUSD(doc["outstandingInvoices"])
        else { return .unavailable(.novita) }

        var footnote = "top-up \(Support.money(cash)) · credit limit \(Support.money(creditLimit))"
        if outstanding > 0 { footnote += " · owed \(Support.money(outstanding))" }

        return VendorUsage(
            vendor: .novita,
            plan: "Novita",
            headline: Support.money(available),
            gauges: [],
            severity: Support.balanceSeverity(available),
            available: true,
            footnote: footnote
        )
    }

    /// `"10000"` = $1.00 — the scale is 1/10000 USD, not cents.
    private static func tenThousandthsUSD(_ v: Any?) -> Double? {
        guard let s = JSON.string(v), let d = Double(s.trimmingCharacters(in: .whitespaces)),
              d.isFinite else { return nil }
        return d / 10_000
    }
}
