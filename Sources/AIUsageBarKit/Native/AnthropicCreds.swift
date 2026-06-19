import Foundation

/// Anthropic OAuth credentials, ported from `src/anthropic/creds.rs` +
/// `src/anthropic/oauth.rs`. Reads `~/.claude/.credentials.json` (or the macOS
/// login Keychain when the file is absent), refreshes the access token when it
/// is within the 5-minute buffer, and writes the rotated tokens back to
/// whichever store they came from — keeping a single source of truth shared
/// with Claude Code.
public struct AnthropicCreds {
    public var accessToken: String
    public var refreshToken: String
    /// Unix epoch in milliseconds.
    public var expiresAtMs: Int64
    public var subscriptionType: String
    public var rateLimitTier: String

    public var expiresAtSecs: Int64 { expiresAtMs / 1000 }

    /// "Pro" / "Max 5x" / "Max 20x" / "Unknown" — matches upstream `plan_label`.
    public var planLabel: String {
        var name = subscriptionType.isEmpty ? "" : subscriptionType.prefix(1).uppercased() + subscriptionType.dropFirst()
        if name.isEmpty { name = "Unknown" }
        if rateLimitTier.contains("5x") { name += " 5x" }
        else if rateLimitTier.contains("20x") { name += " 20x" }
        return name
    }

    // MARK: - Paths

    public static func defaultPath(_ override: String?) -> URL {
        if let override, !override.isEmpty { return URL(fileURLWithPath: override) }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude")
            .appendingPathComponent(".credentials.json")
    }

    // MARK: - Reading

    /// Read from the file, falling back to the macOS Keychain. Throws
    /// `.credentials` when neither source yields a usable blob.
    public static func read(path: URL) throws -> AnthropicCreds {
        let raw: String
        if let fileRaw = try? String(contentsOf: path, encoding: .utf8) {
            raw = fileRaw
        } else if let kc = Keychain.readRaw() {
            raw = kc
        } else {
            throw FetchError.credentials("no Claude credentials. Run `claude` to authenticate.")
        }
        guard let creds = parse(raw) else {
            throw FetchError.credentials("could not parse Claude credentials. Run `claude` to re-authenticate.")
        }
        return creds
    }

    static func parse(_ raw: String) -> AnthropicCreds? {
        guard let doc = JSON.object(Data(raw.utf8)),
              let oauth = JSON.dict(doc["claudeAiOauth"]),
              let access = JSON.string(oauth["accessToken"]),
              let refresh = JSON.string(oauth["refreshToken"])
        else { return nil }
        return AnthropicCreds(
            accessToken: access,
            refreshToken: refresh,
            expiresAtMs: Int64(JSON.double(oauth["expiresAt"]) ?? 0),
            subscriptionType: JSON.string(oauth["subscriptionType"]) ?? "",
            rateLimitTier: JSON.string(oauth["rateLimitTier"]) ?? ""
        )
    }

    // MARK: - Writing

    /// Merge the rotated tokens back into the original document, preserving any
    /// unknown top-level fields (e.g. `mcpOAuth`), and persist to the same
    /// store (Keychain when the file is absent on macOS, else the file).
    public func writeBack(path: URL) {
        let oauthBlob: [String: Any] = [
            "accessToken": accessToken,
            "refreshToken": refreshToken,
            "expiresAt": expiresAtMs,
            "subscriptionType": subscriptionType,
            "rateLimitTier": rateLimitTier,
        ]

        let fileExists = FileManager.default.fileExists(atPath: path.path)
        if !fileExists, let existing = Keychain.readRaw() {
            var doc = JSON.object(Data(existing.utf8)) ?? [:]
            doc["claudeAiOauth"] = oauthBlob
            if let data = try? JSONSerialization.data(withJSONObject: doc),
               let json = String(data: data, encoding: .utf8) {
                Keychain.writeRaw(json)
            }
            return
        }

        var doc: [String: Any] = [:]
        if let raw = try? String(contentsOf: path, encoding: .utf8),
           let parsed = JSON.object(Data(raw.utf8)) {
            doc = parsed
        }
        doc["claudeAiOauth"] = oauthBlob
        if let data = try? JSONSerialization.data(withJSONObject: doc, options: [.prettyPrinted]) {
            try? data.write(to: path, options: .atomic)
        }
    }
}

/// OAuth token refresh, ported from `src/anthropic/oauth.rs`.
public enum AnthropicOAuth {
    public static let tokenURL = URL(string: "https://platform.claude.com/v1/oauth/token")!
    public static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    public static let betaHeader = "oauth-2025-04-20"
    public static let userAgent = "claude-cli/1.0"
    public static let refreshBufferSecs: Int64 = 300

    public static func needsRefresh(expiresAtSecs: Int64, now: Int64) -> Bool {
        expiresAtSecs < now + refreshBufferSecs
    }

    public struct Refreshed {
        public let accessToken: String
        public let refreshToken: String?
        public let expiresInSecs: Int64
    }

    public static func refresh(refreshToken: String) async throws -> Refreshed {
        let resp = try await HTTP.postJSON(
            tokenURL,
            headers: [
                "anthropic-beta": betaHeader,
                "User-Agent": userAgent,
            ],
            body: [
                "grant_type": "refresh_token",
                "client_id": clientID,
                "refresh_token": refreshToken,
            ]
        )
        guard resp.isSuccess else {
            let body = String(data: resp.body, encoding: .utf8) ?? ""
            throw FetchError.http(status: resp.status, body: parseErrorBody(body) ?? "Refresh failed")
        }
        guard let doc = JSON.object(resp.body),
              let access = JSON.string(doc["access_token"]),
              let expiresIn = JSON.double(doc["expires_in"])
        else {
            throw FetchError.schema("token refresh response")
        }
        return Refreshed(
            accessToken: access,
            refreshToken: JSON.string(doc["refresh_token"]),
            expiresInSecs: Int64(expiresIn)
        )
    }

    /// Extract a human message from a non-2xx OAuth error body, tolerating the
    /// three shapes upstream handles.
    public static func parseErrorBody(_ body: String) -> String? {
        guard let v = JSON.object(Data(body.utf8)) else { return nil }
        if let s = JSON.string(v["error_description"]) { return s }
        if let err = JSON.dict(v["error"]), let s = JSON.string(err["message"]) { return s }
        if let s = JSON.string(v["error"]) { return s }
        return nil
    }
}
