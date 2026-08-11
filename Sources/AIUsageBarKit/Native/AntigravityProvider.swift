import Foundation

/// Native Google Antigravity fetcher — ports `src/antigravity/` with the
/// v0.22 macOS discovery. Quota is served by whichever Antigravity product is
/// running locally (app, IDE, or an interactive `agy` session — they share one
/// account-wide quota); the server's port is ephemeral, so it is discovered
/// via `lsof` rather than assumed. Percentages are *consumed*, inverted from
/// the API's remaining fractions.
public enum AntigravityProvider {
    static let statusRPC = "exa.language_server_pb.LanguageServerService/GetUserStatus"
    static let quotaRPC = "exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary"
    static let sessionWindow: TimeInterval = 5 * 3600
    static let weeklyWindow: TimeInterval = 7 * 24 * 3600

    public static func fetch(config: AppConfig, now: Date = Date()) async -> VendorUsage {
        let cache = DiskCache(vendor: "antigravity")

        guard let session = await openSession() else {
            // Nothing running is Antigravity's normal state: serve the last
            // snapshot (stale) as long as none of its windows has rolled over.
            if let bytes = cache.maybePayload() {
                var row = render(bytes, now: now)
                if row.available {
                    row.isStale = true
                    return row
                }
            }
            return .unavailable(.antigravity)
        }

        if let bytes = cache.freshPayload(ttl: DiskCache.defaultTTL, target: session.account) {
            let row = render(bytes, now: now)
            if row.available { return row }
        }

        do {
            let body = try await rpc(base: session.base, csrf: session.csrf, path: quotaRPC)
            guard let snapshot = snapshotJSON(body, plan: session.plan) else {
                throw FetchError.schema("antigravity quota summary")
            }
            cache.writePayload(snapshot, target: session.account)
            return render(snapshot, now: now)
        } catch {
            if let bytes = cache.maybePayload(target: session.account) {
                var row = render(bytes, now: now)
                if row.available {
                    row.isStale = true
                    return row
                }
            }
            return .unavailable(.antigravity)
        }
    }

    // MARK: - Local server discovery

    struct Session {
        let base: String
        let csrf: String?
        let plan: String
        /// Fingerprint of the signed-in Google account, so switching accounts
        /// cannot show the previous account's figures. Never the address.
        let account: String
    }

    static func candidateBases() -> [String] {
        if let override = ProcessInfo.processInfo.environment["ANTIGRAVITY_LS_ADDRESS"]?
            .trimmingCharacters(in: .whitespaces), !override.isEmpty {
            let base = override.hasPrefix("http://") || override.hasPrefix("https://")
                ? override : "http://\(override)"
            return [base]
        }
        return discoverPorts().map { "http://127.0.0.1:\($0)" }
    }

    /// `lsof -nP -iTCP -sTCP:LISTEN -F pcn`, keeping ports of listening
    /// processes that look like Antigravity. Output is parsed regardless of
    /// exit status (a partial failure still emits usable rows).
    static func discoverPorts() -> [UInt16] {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        proc.arguments = ["-nP", "-iTCP", "-sTCP:LISTEN", "-F", "pcn"]
        let stdout = Pipe()
        proc.standardOutput = stdout
        proc.standardError = Pipe()
        guard (try? proc.run()) != nil else { return [] }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return parseLsofPCN(String(data: data, encoding: .utf8) ?? "")
    }

    static func parseLsofPCN(_ output: String) -> [UInt16] {
        var ports: [UInt16] = []
        var currentMatches = false
        for line in output.split(separator: "\n") {
            guard let tag = line.first else { continue }
            let rest = String(line.dropFirst())
            switch tag {
            case "p":
                currentMatches = false
            case "c":
                currentMatches = isAntigravityProcess(rest)
            case "n" where currentMatches:
                if let colon = rest.lastIndex(of: ":"),
                   let port = UInt16(rest[rest.index(after: colon)...]),
                   !ports.contains(port) {
                    ports.append(port)
                }
            default:
                break
            }
        }
        return ports
    }

    /// Case-insensitive: the packaged macOS app's process name is capitalized.
    static func isAntigravityProcess(_ comm: String) -> Bool {
        let c = comm.trimmingCharacters(in: .whitespaces).lowercased()
        return c.contains("language_server") || c == "agy" || c == "antigravity"
    }

    /// First base that answers `GetUserStatus`. The Antigravity 2.0 server
    /// embeds a CSRF token in the HTML at `/` and rejects the RPC without it;
    /// the `agy` CLI 404s at `/` and answers unauthenticated — so a missing
    /// token is not an error.
    static func openSession() async -> Session? {
        for base in candidateBases() {
            let csrf = await scrapeCSRF(base: base)
            guard let body = try? await rpc(base: base, csrf: csrf, path: statusRPC),
                  let doc = JSON.object(body)
            else { continue }
            let userStatus = JSON.dict(doc["userStatus"])
            let plan = [
                JSON.string(JSON.dict(userStatus?["userTier"])?["name"]),
                JSON.string(JSON.dict(userStatus?["userTier"])?["description"]),
                JSON.string(JSON.dict(JSON.dict(userStatus?["planStatus"])?["planInfo"])?["planName"]),
            ].compactMap { $0 }.first { !$0.isEmpty } ?? "Antigravity"
            let email = JSON.string(userStatus?["email"]) ?? ""
            let account = email.isEmpty ? "acct:unknown" : "acct:\(Support.keyFingerprint(email))"
            return Session(base: base, csrf: csrf, plan: plan, account: account)
        }
        return nil
    }

    static func scrapeCSRF(base: String) async -> String? {
        guard let url = URL(string: base),
              let resp = try? await HTTP.get(url, headers: [:], timeout: 5),
              resp.isSuccess,
              let html = String(data: resp.body, encoding: .utf8)
        else { return nil }
        return scrapeCSRF(html: html)
    }

    static func scrapeCSRF(html: String) -> String? {
        let parts = html.components(separatedBy: "csrfToken\":\"")
        guard parts.count > 1, let end = parts[1].firstIndex(of: "\"") else { return nil }
        let token = String(parts[1][..<end])
        return token.isEmpty ? nil : token
    }

    static func rpc(base: String, csrf: String?, path: String) async throws -> Data {
        guard let url = URL(string: "\(base)/\(path)") else {
            throw FetchError.transport("bad base URL")
        }
        var headers = ["Content-Type": "application/json"]
        if let csrf { headers["x-codeium-csrf-token"] = csrf }
        let resp = try await HTTP.postJSON(url, headers: headers, body: [:], timeout: 5)
        guard resp.isSuccess else { throw FetchError.http(status: resp.status, body: "") }
        return resp.body
    }

    // MARK: - Quota projection

    struct Windows {
        var session: (pct: Int, reset: Date?)?
        var weekly: (pct: Int, reset: Date?)?
        var tpSession: (pct: Int, reset: Date?)?
        var tpWeekly: (pct: Int, reset: Date?)?
    }

    /// Project the RPC response into the flat snapshot this app caches. Nil on
    /// drift: a missing/invalid `remainingFraction`, a duplicate bucket, or an
    /// absent required Gemini window must refetch rather than render a
    /// confident 0%.
    static func snapshotJSON(_ body: Data, plan: String) -> Data? {
        guard let doc = JSON.object(body),
              let groups = JSON.array(JSON.dict(doc["response"])?["groups"] ?? doc["groups"]),
              let w = classify(groups),
              let session = w.session, let weekly = w.weekly
        else { return nil }

        func encode(_ win: (pct: Int, reset: Date?)?) -> [String: Any] {
            guard let win else { return [:] }
            var d: [String: Any] = ["pct": win.pct]
            if let r = win.reset { d["reset"] = r.timeIntervalSince1970 }
            return d
        }
        let payload: [String: Any] = [
            "plan": plan,
            "session": encode(session),
            "weekly": encode(weekly),
            "tp_session": encode(w.tpSession),
            "tp_weekly": encode(w.tpWeekly),
        ]
        return try? JSONSerialization.data(withJSONObject: payload)
    }

    static func classify(_ groups: [Any]) -> Windows? {
        var w = Windows()
        for group in groups.compactMap(JSON.dict) {
            let groupName = JSON.string(group["displayName"]) ?? ""
            for bucket in (JSON.array(group["buckets"]) ?? []).compactMap(JSON.dict) {
                let id = JSON.string(bucket["bucketId"]) ?? ""
                let windowKind = JSON.string(bucket["window"]) ?? ""

                let isWeekly = id.hasSuffix("weekly") || windowKind == "weekly"
                let isSession = !isWeekly && (id.hasSuffix("5h") || windowKind == "5h")
                // An unknown cadence (e.g. a future `monthly`) is skipped,
                // never defaulted to 5h.
                guard isWeekly || isSession else { continue }

                let isGemini: Bool
                if id.hasPrefix("gemini") { isGemini = true }
                else if id.hasPrefix("3p") { isGemini = false }
                else if groupName.contains("Gemini") { isGemini = true }
                else if groupName.contains("Claude") || groupName.contains("GPT") { isGemini = false }
                else { continue }

                // Defaulting a missing fraction to 1.0 would report a
                // reassuring "0% used" for an unknown window — and cache it.
                guard let remaining = JSON.double(bucket["remainingFraction"]),
                      remaining.isFinite, (0.0...1.0).contains(remaining)
                else { return nil }
                let pct = Int(((1.0 - remaining) * 100).rounded())
                let reset = Support.parseRFC3339(JSON.string(bucket["resetTime"]))

                let slot: WritableKeyPath<Windows, (pct: Int, reset: Date?)?> =
                    isGemini ? (isWeekly ? \.weekly : \.session)
                             : (isWeekly ? \.tpWeekly : \.tpSession)
                guard w[keyPath: slot] == nil else { return nil }
                w[keyPath: slot] = (pct, reset)
            }
        }
        return w
    }

    static func render(_ bytes: Data, now: Date) -> VendorUsage {
        guard let doc = JSON.object(bytes) else { return .unavailable(.antigravity) }
        func decode(_ key: String) -> (pct: Int, reset: Date?)? {
            guard let d = JSON.dict(doc[key]), let pct = JSON.int(d["pct"]),
                  (0...100).contains(pct) else { return nil }
            let reset = JSON.double(d["reset"]).map { Date(timeIntervalSince1970: $0) }
            return (pct, reset)
        }
        guard let session = decode("session"), let weekly = decode("weekly") else {
            return .unavailable(.antigravity)
        }
        let tpSession = decode("tp_session")
        let tpWeekly = decode("tp_weekly")

        // A window past its reset is a previous period, not current usage —
        // matters here more than elsewhere, since "nothing running" is normal
        // and the snapshot may be served for days.
        for win in [session, weekly, tpSession, tpWeekly].compactMap({ $0 }) {
            if let reset = win.reset, reset <= now { return .unavailable(.antigravity) }
        }

        let plan = JSON.string(doc["plan"]) ?? "Antigravity"

        func gauge(_ label: String, _ win: (pct: Int, reset: Date?), _ window: TimeInterval) -> UsageGauge {
            UsageGauge(label: label, percent: Double(win.pct),
                       caption: "resets \(Support.countdown(win.reset, now: now))",
                       elapsedFraction: Support.elapsedFraction(reset: win.reset, window: window, now: now))
        }
        var gauges = [
            gauge("Gemini 5h", session, sessionWindow),
            gauge("Gemini Weekly", weekly, weeklyWindow),
        ]
        if let tpSession { gauges.append(gauge("Claude & GPT 5h", tpSession, sessionWindow)) }
        if let tpWeekly { gauges.append(gauge("Claude & GPT Weekly", tpWeekly, weeklyWindow)) }

        // Worst of all four: grading on Gemini alone would show a calm panel
        // while the Claude & GPT pool is exhausted.
        let worst = gauges.map { Int($0.percent) }.max() ?? 0
        let compactReset = Support.shortCountdown(session.reset, now: now)
        return VendorUsage(
            vendor: .antigravity,
            plan: Support.sanitizeDisplay(plan),
            headline: "\(session.pct)% · \(weekly.pct)%",
            gauges: gauges,
            severity: Support.severity(for: worst),
            available: true,
            compactHeadline: "\(session.pct)%" + (compactReset.isEmpty ? "" : " \(compactReset)")
        )
    }
}
