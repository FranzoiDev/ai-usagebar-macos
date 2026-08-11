import Foundation
import SQLite3

/// Native Cursor fetcher — ports `src/cursor/`. Reads the session token the
/// Cursor IDE already wrote to its local `state.vscdb` (read-only; the
/// headless `cursor-agent`'s `auth.json` is the fallback when the IDE database
/// does not exist), then calls the same undocumented `usage-summary` endpoint
/// the Cursor dashboard's frontend uses.
public enum CursorProvider {
    static let summaryURL = URL(string: "https://cursor.com/api/usage-summary")!
    static let tokenKey = "cursorAuth/accessToken"
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
        + "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

    static func defaultDbPath() -> String {
        FileManager.default.homeDirectoryForCurrentUser.path
            + "/Library/Application Support/Cursor/User/globalStorage/state.vscdb"
    }

    static func defaultAgentAuthPath() -> String {
        FileManager.default.homeDirectoryForCurrentUser.path
            + "/Library/Application Support/cursor/auth.json"
    }

    public static func fetch(config: AppConfig, now: Date = Date()) async -> VendorUsage {
        let dbPath = config.cursorDbPath ?? defaultDbPath()
        let agentPath = config.cursorAgentAuthPath ?? defaultAgentAuthPath()
        guard let token = resolveToken(dbPath: dbPath, agentAuthPath: agentPath),
              let userId = userId(fromJWT: token)
        else { return .unavailable(.cursor) }

        // The cache is bound to the signed-in account: Cursor can switch
        // accounts in place, and serving another login's cache would leak its
        // usage until the TTL expired.
        let target = "acct:\(Support.keyFingerprint(userId))"
        let cache = DiskCache(vendor: "cursor")

        if let bytes = cache.freshPayload(ttl: DiskCache.defaultTTL, target: target) {
            let row = render(bytes, now: now)
            // A snapshot past its recorded billing-cycle reset describes the
            // previous cycle; refuse it and fall through to a live fetch.
            if row.available { return row }
        }
        do {
            let resp = try await HTTP.get(summaryURL, headers: [
                "Cookie": "WorkosCursorSessionToken=\(userId)%3A%3A\(token)",
                "Origin": "https://cursor.com",
                "Referer": "https://cursor.com/dashboard",
                "User-Agent": userAgent,
            ])
            guard resp.isSuccess else { throw FetchError.http(status: resp.status, body: "") }
            let rendered = render(resp.body, now: now)
            guard rendered.available else { throw FetchError.schema("cursor usage-summary") }
            cache.writePayload(resp.body, target: target)
            return rendered
        } catch {
            if let bytes = cache.maybePayload(target: target) {
                var row = render(bytes, now: now)
                if row.available {
                    row.isStale = true
                    return row
                }
            }
            return .unavailable(.cursor)
        }
    }

    // MARK: - Credentials

    /// IDE database first; the agent file only when the IDE database file does
    /// not exist at all (an existing-but-broken database is not silently
    /// swapped for another login).
    static func resolveToken(dbPath: String, agentAuthPath: String) -> String? {
        if let token = readIDEToken(dbPath: dbPath) { return token }
        guard !FileManager.default.fileExists(atPath: dbPath),
              FileManager.default.fileExists(atPath: agentAuthPath)
        else { return nil }
        return readAgentToken(path: agentAuthPath)
    }

    static func readIDEToken(dbPath: String) -> String? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT value FROM ItemTable WHERE key = ?1", -1, &stmt, nil) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, tokenKey, -1, transient)
        guard sqlite3_step(stmt) == SQLITE_ROW, let c = sqlite3_column_text(stmt, 0) else { return nil }
        let value = String(cString: c).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    static func readAgentToken(path: String) -> String? {
        guard let raw = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let doc = JSON.object(raw),
              let token = JSON.string(doc["accessToken"]),
              !token.trimmingCharacters(in: .whitespaces).isEmpty
        else { return nil }
        return token
    }

    /// User id from the session JWT's `sub` claim, shaped `auth0|<userId>`.
    /// The signature is never verified — the dashboard JS doesn't either.
    static func userId(fromJWT token: String) -> String? {
        guard let claims = CodexCreds.jwtClaims(token),
              let sub = JSON.string(claims["sub"])
        else { return nil }
        let parts = sub.split(separator: "|", maxSplits: 1)
        guard parts.count == 2, !parts[1].isEmpty else { return nil }
        return String(parts[1])
    }

    // MARK: - Rendering

    static func render(_ bytes: Data, now: Date) -> VendorUsage {
        guard let doc = JSON.object(bytes),
              let reset = Support.parseRFC3339(JSON.string(doc["billingCycleEnd"])),
              reset > now
        else { return .unavailable(.cursor) }

        let membership = JSON.string(doc["membershipType"]) ?? ""
        var plan = membership.isEmpty ? "Cursor" : Support.capitalizeFirst(membership)
        let unlimited = JSON.bool(doc["isUnlimited"])
        let resetCaption = "resets \(Support.countdown(reset, now: now))"

        if unlimited {
            return VendorUsage(
                vendor: .cursor,
                plan: Support.sanitizeDisplay("Cursor \(plan)"),
                headline: "unlimited",
                gauges: [],
                severity: .low,
                available: true,
                footnote: resetCaption,
                compactHeadline: "unl"
            )
        }

        let autoPct: Int
        let apiPct: Int
        if let planBlock = JSON.dict(JSON.dict(doc["individualUsage"])?["plan"]) {
            guard let auto = pct(planBlock["autoPercentUsed"]),
                  let api = pct(planBlock["apiPercentUsed"])
            else { return .unavailable(.cursor) }
            autoPct = auto
            apiPct = api
        } else {
            // Team accounts: the display-message strings are the only
            // percentage source. Both must parse — one alone is drift, not
            // half a snapshot.
            guard let auto = displayMessagePct(JSON.string(doc["autoModelSelectedDisplayMessage"])),
                  let api = displayMessagePct(JSON.string(doc["namedModelSelectedDisplayMessage"]))
            else { return .unavailable(.cursor) }
            autoPct = auto
            apiPct = api
            plan += " (team)"
        }

        let onDemand = JSON.bool(JSON.dict(JSON.dict(doc["individualUsage"])?["onDemand"])?["enabled"])
            || JSON.bool(JSON.dict(JSON.dict(doc["teamUsage"])?["onDemand"])?["enabled"])

        let worst = max(autoPct, apiPct)
        let compactReset = Support.shortCountdown(reset, now: now)
        return VendorUsage(
            vendor: .cursor,
            plan: Support.sanitizeDisplay("Cursor \(plan)"),
            headline: "\(autoPct)·\(apiPct)% · \(Support.countdown(reset, now: now))",
            gauges: [
                UsageGauge(label: "Cursor Models", percent: Double(autoPct), caption: resetCaption),
                UsageGauge(label: "Other Models", percent: Double(apiPct),
                           caption: "\(resetCaption) · on-demand \(onDemand ? "on" : "off")"),
            ],
            severity: Support.severity(for: worst),
            available: true,
            compactHeadline: "\(worst)%" + (compactReset.isEmpty ? "" : " \(compactReset)")
        )
    }

    /// Percent field: must be finite; rounded; clamped low end only — over-100
    /// is real (usage past the included quota) and must survive.
    private static func pct(_ v: Any?) -> Int? {
        guard let d = JSON.double(v), d.isFinite else { return nil }
        return Int(max(d.rounded(), 0))
    }

    /// Parse "You've used 98% of your included total usage" → 98. Finds the
    /// first `%` and scans backwards over digits/dots.
    static func displayMessagePct(_ message: String?) -> Int? {
        guard let message, let pctIdx = message.firstIndex(of: "%") else { return nil }
        let prefix = message[..<pctIdx]
        let digits = prefix.reversed().prefix { $0.isNumber || $0 == "." }
        guard !digits.isEmpty, let value = Double(String(digits.reversed())), value.isFinite else {
            return nil
        }
        return Int(max(value.rounded(), 0))
    }
}
