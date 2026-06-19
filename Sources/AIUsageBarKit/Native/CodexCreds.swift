import Foundation

/// OpenAI Codex OAuth credentials, ported from `src/openai/creds.rs` +
/// `src/openai/oauth.rs`. Reads `~/.codex/auth.json`, derives the expiry and
/// plan tier from the embedded `id_token` JWT, refreshes when near expiry, and
/// writes the rotated tokens back (preserving unknown fields).
public struct CodexCreds {
    public var accessToken: String
    public var refreshToken: String
    public var idToken: String
    public var accountId: String?

    /// Expiry (Unix seconds) from the id_token `exp` claim; 0 forces refresh.
    public var expiresAtSecs: Int64 {
        Int64(Self.jwtClaims(idToken)?["exp"].flatMap(JSON.double) ?? 0)
    }

    /// Plan tier from the id_token claim
    /// `https://api.openai.com/auth.chatgpt_plan_type`.
    public var planType: String? {
        guard let claims = Self.jwtClaims(idToken),
              let auth = JSON.dict(claims["https://api.openai.com/auth"])
        else { return nil }
        return JSON.string(auth["chatgpt_plan_type"])
    }

    public static func defaultPath(_ override: String?) -> URL {
        if let override, !override.isEmpty { return URL(fileURLWithPath: override) }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex")
            .appendingPathComponent("auth.json")
    }

    public static func read(path: URL) throws -> CodexCreds {
        guard let raw = try? String(contentsOf: path, encoding: .utf8) else {
            throw FetchError.credentials("no Codex credentials. Run `codex login`.")
        }
        guard let doc = JSON.object(Data(raw.utf8)),
              let tokens = JSON.dict(doc["tokens"]),
              let access = JSON.string(tokens["access_token"]),
              let refresh = JSON.string(tokens["refresh_token"]),
              let id = JSON.string(tokens["id_token"])
        else {
            throw FetchError.credentials("could not parse Codex credentials. Run `codex login`.")
        }
        return CodexCreds(
            accessToken: access,
            refreshToken: refresh,
            idToken: id,
            accountId: JSON.string(tokens["account_id"])
        )
    }

    /// Merge the rotated tokens back into `auth.json`, preserving other fields.
    public func writeBack(path: URL) {
        var doc: [String: Any] = [:]
        if let raw = try? String(contentsOf: path, encoding: .utf8),
           let parsed = JSON.object(Data(raw.utf8)) {
            doc = parsed
        }
        var tokens = JSON.dict(doc["tokens"]) ?? [:]
        tokens["access_token"] = accessToken
        tokens["refresh_token"] = refreshToken
        tokens["id_token"] = idToken
        if let accountId { tokens["account_id"] = accountId }
        doc["tokens"] = tokens
        if let data = try? JSONSerialization.data(withJSONObject: doc, options: [.prettyPrinted]) {
            try? data.write(to: path, options: .atomic)
        }
    }

    /// Decode a JWT payload's claims (no signature verification).
    static func jwtClaims(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        guard let data = base64URLDecode(String(parts[1])) else { return nil }
        return JSON.object(data)
    }

    private static func base64URLDecode(_ s: String) -> Data? {
        var str = s.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while str.count % 4 != 0 { str.append("=") }
        return Data(base64Encoded: str)
    }
}

/// Codex OAuth token refresh, ported from `src/openai/oauth.rs`.
public enum CodexOAuth {
    public static let tokenURL = URL(string: "https://auth.openai.com/oauth/token")!
    public static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    public static let scope = "openid profile email"
    public static let refreshBufferSecs: Int64 = 300

    public static func needsRefresh(expiresAtSecs: Int64, now: Int64) -> Bool {
        expiresAtSecs < now + refreshBufferSecs
    }

    public struct Refreshed {
        public let accessToken: String
        public let refreshToken: String?
        public let idToken: String?
    }

    public static func refresh(refreshToken: String) async throws -> Refreshed {
        let resp = try await HTTP.postJSON(
            tokenURL,
            headers: [:],
            body: [
                "client_id": clientID,
                "grant_type": "refresh_token",
                "refresh_token": refreshToken,
                "scope": scope,
            ]
        )
        guard resp.isSuccess else {
            let body = String(data: resp.body, encoding: .utf8) ?? ""
            throw FetchError.http(status: resp.status, body: AnthropicOAuth.parseErrorBody(body) ?? "Refresh failed")
        }
        guard let doc = JSON.object(resp.body), let access = JSON.string(doc["access_token"]) else {
            throw FetchError.schema("openai token response")
        }
        return Refreshed(
            accessToken: access,
            refreshToken: JSON.string(doc["refresh_token"]),
            idToken: JSON.string(doc["id_token"])
        )
    }
}
