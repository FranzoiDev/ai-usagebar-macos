import Foundation

/// Native Anthropic Admin API fetcher — ports `src/anthropic_api/`.
/// Month-to-date spend for the API/Console organization, separate from the
/// Claude Code OAuth account. Requires an org Admin key (`sk-ant-admin01-…`).
/// The cost API omits Priority Tier costs, and the remaining prepaid balance
/// is Console-only, so this figure is spend, not balance.
public enum AnthropicAPIProvider {
    static let costReportBase = "https://api.anthropic.com/v1/organizations/cost_report"
    static let maxPages = 12

    public static func fetch(config: AppConfig, now: Date = Date()) async -> VendorUsage {
        guard let key = AppConfig.resolveKey(env: config.anthropicAPIKeyEnv, inline: config.anthropicAPIKey) else {
            return .unavailable(.anthropicAPI)
        }
        let month = monthStartRFC3339(now)
        // The month is part of the identity: a rollover — even during an
        // outage — must refetch instead of showing last month as current. So
        // is the Admin key: a key switch to another org must not reuse spend.
        let target = "\(month)|key:\(Support.keyFingerprint(key))"
        let cache = DiskCache(vendor: "anthropic_api")
        // The `limit` always comes from the current config, never the cache,
        // so editing it takes effect without a refetch.
        let limit = config.anthropicAPIMonthlyLimit

        if let bytes = cache.freshPayload(ttl: DiskCache.defaultTTL, target: target),
           let spent = JSON.object(bytes).flatMap({ JSON.double($0["spent"]) }) {
            return render(spent: spent, limit: limit)
        }
        do {
            let spent = try await monthToDateDollars(key: key, month: month)
            if let data = try? JSONSerialization.data(withJSONObject: ["spent": spent]) {
                cache.writePayload(data, target: target)
            }
            return render(spent: spent, limit: limit)
        } catch {
            if let bytes = cache.maybePayload(target: target),
               let spent = JSON.object(bytes).flatMap({ JSON.double($0["spent"]) }) {
                var row = render(spent: spent, limit: limit)
                row.isStale = true
                return row
            }
            return .unavailable(.anthropicAPI)
        }
    }

    static func monthStartRFC3339(_ now: Date) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let c = cal.dateComponents([.year, .month], from: now)
        return String(format: "%04d-%02d-01T00:00:00Z", c.year!, c.month!)
    }

    /// Sum the month's daily buckets, following pagination. Any incomplete
    /// pagination (missing/empty/repeated cursor, page-cap hit) is an error —
    /// a partial month cached as the total is indistinguishable from lower
    /// spend.
    static func monthToDateDollars(key: String, month: String) async throws -> Double {
        var cents = 0.0
        var page: String?
        var seen = Set<String>()
        for _ in 0..<maxPages {
            var comps = URLComponents(string: costReportBase)!
            var items = [
                URLQueryItem(name: "starting_at", value: month),
                URLQueryItem(name: "bucket_width", value: "1d"),
            ]
            if let page { items.append(URLQueryItem(name: "page", value: page)) }
            comps.queryItems = items
            let resp = try await HTTP.get(comps.url!, headers: [
                "x-api-key": key,
                "anthropic-version": "2023-06-01",
            ])
            guard resp.isSuccess else { throw FetchError.http(status: resp.status, body: "") }
            let (pageCents, hasMore, next) = try parsePage(resp.body)
            cents += pageCents
            guard cents.isFinite else { throw FetchError.schema("anthropic_api total") }
            if !hasMore { return cents / 100 }
            guard let next, !next.isEmpty, !seen.contains(next) else {
                throw FetchError.schema("anthropic_api pagination")
            }
            seen.insert(next)
            page = next
        }
        throw FetchError.schema("anthropic_api pagination exceeded \(maxPages) pages")
    }

    /// One page: (cents, has_more, next_page). The envelope fields are
    /// required — `{}` or a 200 error envelope is drift, never a real $0.00.
    /// `data: []` with `has_more: false` is the legitimate zero.
    static func parsePage(_ bytes: Data) throws -> (Double, Bool, String?) {
        guard let doc = JSON.object(bytes),
              let data = JSON.array(doc["data"]),
              doc["has_more"] != nil, doc["has_more"] is Bool || doc["has_more"] is NSNumber
        else { throw FetchError.schema("anthropic_api cost_report envelope") }
        var cents = 0.0
        for bucket in data.compactMap(JSON.dict) {
            guard let results = JSON.array(bucket["results"]) else {
                throw FetchError.schema("anthropic_api cost_report bucket")
            }
            for result in results.compactMap(JSON.dict) {
                guard JSON.string(result["currency"]) == "USD",
                      let raw = JSON.string(result["amount"]),
                      let amount = Double(raw.trimmingCharacters(in: .whitespaces)),
                      amount.isFinite
                else { throw FetchError.schema("anthropic_api cost_report amount") }
                cents += amount
            }
        }
        return (cents, JSON.bool(doc["has_more"]), JSON.string(doc["next_page"]))
    }

    static func render(spent: Double, limit: Double?) -> VendorUsage {
        let headline: String
        var gauges: [UsageGauge] = []
        let severity: Severity
        if let limit, limit > 0, limit.isFinite {
            let pct = Int(min(max((spent / limit * 100).rounded(), 0), 9999))
            headline = String(format: "$%.2f / $%.0f · %d%%", spent, limit, pct)
            gauges = [UsageGauge(label: "Spend (mo)", percent: Double(pct),
                                 caption: "excludes Priority Tier · balance is Console-only")]
            severity = Support.severity(for: min(pct, 100))
        } else {
            headline = String(format: "$%.2f/mo", spent)
            // No limit ⇒ no denominator ⇒ no signal; stays calm.
            severity = .low
        }
        return VendorUsage(
            vendor: .anthropicAPI,
            plan: "Anthropic API",
            headline: headline,
            gauges: gauges,
            severity: severity,
            available: true,
            footnote: gauges.isEmpty ? "spend, not balance · excludes Priority Tier" : nil
        )
    }
}
