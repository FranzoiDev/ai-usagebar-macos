import Foundation

/// Native Kilo Code fetcher — ports `src/kilo/`. Credit balance only.
public enum KiloProvider {
    static let balanceURL = URL(string: "https://api.kilo.ai/api/profile/balance")!

    public static func fetch(config: AppConfig, now: Date = Date()) async -> VendorUsage {
        guard let key = AppConfig.resolveKey(env: config.kiloApiKeyEnv, inline: config.kiloApiKey) else {
            return .unavailable(.kilo)
        }
        let org = config.kiloOrganizationId?.trimmingCharacters(in: .whitespaces) ?? ""
        let target = org.isEmpty ? "personal" : "org:\(org)"
        let cache = DiskCache(vendor: "kilo")

        if let bytes = cache.freshPayload(ttl: DiskCache.defaultTTL, target: target) {
            return render(bytes)
        }
        do {
            var headers = [
                "Authorization": "Bearer \(key)",
                "Content-Type": "application/json",
            ]
            if !org.isEmpty { headers["x-kilocode-organizationid"] = org }
            let resp = try await HTTP.get(balanceURL, headers: headers)
            guard resp.isSuccess else { throw FetchError.http(status: resp.status, body: "") }
            let rendered = render(resp.body)
            // A 200 error envelope without `balance` must never cache as $0.00.
            guard rendered.available else { throw FetchError.schema("kilo response") }
            cache.writePayload(resp.body, target: target)
            return rendered
        } catch {
            if let bytes = cache.maybePayload(target: target) {
                var row = render(bytes)
                row.isStale = true
                return row
            }
            return .unavailable(.kilo)
        }
    }

    static func render(_ bytes: Data) -> VendorUsage {
        guard let doc = JSON.object(bytes),
              let balance = JSON.double(doc["balance"]), balance.isFinite
        else { return .unavailable(.kilo) }
        return VendorUsage(
            vendor: .kilo,
            plan: "Kilo",
            headline: Support.money(balance),
            gauges: [],
            severity: Support.balanceSeverity(balance),
            available: true
        )
    }
}
