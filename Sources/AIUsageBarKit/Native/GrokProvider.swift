import Foundation

/// Native Grok (xAI) fetcher — ports `src/grok/`. Reads the prepaid team
/// balance via a Management key (not the inference key). The ledger is
/// inverted: a top-up is a NEGATIVE `total.val` in USD cents, so
/// `balance = -cents / 100`.
public enum GrokProvider {
    static let base = "https://management-api.x.ai"
    static let validationURL = URL(string: "\(base)/auth/management-keys/validation")!

    public static func fetch(config: AppConfig, now: Date = Date()) async -> VendorUsage {
        guard let key = AppConfig.resolveKey(env: config.grokApiKeyEnv, inline: config.grokApiKey) else {
            return .unavailable(.grok)
        }
        let configuredTeam = config.grokTeamId?.trimmingCharacters(in: .whitespaces) ?? ""
        let target = configuredTeam.isEmpty
            ? "key:\(Support.keyFingerprint(key))"
            : "team:\(configuredTeam)"
        let cache = DiskCache(vendor: "grok")

        if let bytes = cache.freshPayload(ttl: DiskCache.defaultTTL, target: target) {
            return render(bytes)
        }
        do {
            let headers = ["Authorization": "Bearer \(key)"]
            let team: String
            if configuredTeam.isEmpty {
                let resp = try await HTTP.get(validationURL, headers: headers)
                guard resp.isSuccess else { throw FetchError.http(status: resp.status, body: "") }
                guard let resolved = resolvedTeam(resp.body) else {
                    // An organization-scoped key's scopeId is an org id, not a
                    // team — configure [grok] team_id instead of guessing.
                    throw FetchError.credentials("grok: set [grok] team_id")
                }
                team = resolved
            } else {
                team = configuredTeam
            }
            let balanceURL = URL(string: "\(base)/v1/billing/teams/\(team)/prepaid/balance")!
            let resp = try await HTTP.get(balanceURL, headers: headers)
            guard resp.isSuccess else { throw FetchError.http(status: resp.status, body: "") }
            let rendered = render(resp.body)
            guard rendered.available else { throw FetchError.schema("grok response") }
            cache.writePayload(resp.body, target: target)
            return rendered
        } catch {
            if let bytes = cache.maybePayload(target: target) {
                var row = render(bytes)
                row.isStale = true
                return row
            }
            return .unavailable(.grok)
        }
    }

    /// Team from the key-validation response. Only a team-scoped (or legacy
    /// unscoped) key may adopt `scopeId`; an organization-scoped key yields
    /// nil so the caller demands an explicit `team_id`.
    static func resolvedTeam(_ bytes: Data) -> String? {
        guard let doc = JSON.object(bytes) else { return nil }
        let scope = (JSON.string(doc["scope"]) ?? "").trimmingCharacters(in: .whitespaces).uppercased()
        let scopeId = nonEmpty(JSON.string(doc["scopeId"]))
        let teamId = nonEmpty(JSON.string(doc["teamId"]))
        switch scope {
        case "SCOPE_ORGANIZATION": return teamId
        case "", "SCOPE_TEAM":     return scopeId ?? teamId
        default:                   return nil
        }
    }

    static func render(_ bytes: Data) -> VendorUsage {
        guard let doc = JSON.object(bytes),
              let total = JSON.dict(doc["total"]),
              let valRaw = JSON.string(total["val"]),
              let cents = Double(valRaw.trimmingCharacters(in: .whitespaces)), cents.isFinite
        else { return .unavailable(.grok) }
        let balance = -cents / 100

        return VendorUsage(
            vendor: .grok,
            plan: "Grok (xAI)",
            headline: Support.money(balance),
            gauges: [],
            severity: Support.balanceSeverity(balance),
            available: true,
            footnote: "prepaid balance"
        )
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        return s
    }
}
