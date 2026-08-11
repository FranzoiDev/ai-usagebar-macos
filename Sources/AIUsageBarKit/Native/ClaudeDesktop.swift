import CryptoKit
import Foundation

/// Claude Desktop usage reading, ported from the read-only half of upstream
/// v0.21 (`src/anthropic/desktop_creds.rs` + `src/claude_desktop/`). Saved
/// Desktop accounts (claude-acc profile layout) report usage with no `claude`
/// CLI login: the app stores its token under the same public OAuth client as
/// Claude Code, and that token is accepted by the usage endpoint.
///
/// Strictly read-only: the ACTIVE account's credential comes from the live
/// `config.json` the app keeps fresh, and is never refreshed or written back
/// (this app never rotates any vendor's tokens). Account switching/capture is
/// intentionally not implemented.
public enum ClaudeDesktop {
    static let inferenceScope = "user:inference"
    static let configBlobKeys = ["oauth:tokenCacheV2", "oauth:tokenCache"]
    static let profileBlobFiles = ["config-tokenCacheV2", "config-tokenCache"]

    public struct Profile: Sendable {
        public let label: String
        public let accountUuid: String
        /// Whether this is the account the Desktop app is signed in as.
        public let active: Bool
    }

    static func dataDir() -> String {
        FileManager.default.homeDirectoryForCurrentUser.path + "/Library/Application Support/Claude"
    }

    static func profilesDir(config: AppConfig) -> String {
        if let dir = config.anthropicDesktopProfilesDir, !dir.isEmpty { return dir }
        return FileManager.default.homeDirectoryForCurrentUser.path + "/.claude-acc/profiles"
    }

    /// Saved profiles that carry credentials, sorted by label. Empty when the
    /// Desktop app isn't installed or no profiles were captured (claude-acc
    /// users' existing profiles work untouched).
    public static func profiles(config: AppConfig) -> [Profile] {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: dataDir(), isDirectory: &isDir), isDir.boolValue else { return [] }

        let activeUuid = activeAccountUuid()
        let root = profilesDir(config: config)
        let names = (try? fm.contentsOfDirectory(atPath: root)) ?? []
        return names.sorted().compactMap { label in
            let dir = "\(root)/\(label)"
            var sub: ObjCBool = false
            guard fm.fileExists(atPath: dir, isDirectory: &sub), sub.boolValue,
                  let metaRaw = try? Data(contentsOf: URL(fileURLWithPath: "\(dir)/meta.json")),
                  let meta = JSON.object(metaRaw),
                  let uuid = JSON.string(meta["accountUuid"]), !uuid.isEmpty,
                  // Credentials require BOTH token-cache snapshot files.
                  profileBlobFiles.allSatisfy({ fm.fileExists(atPath: "\(dir)/\($0)") })
            else { return nil }
            return Profile(label: label, accountUuid: uuid, active: uuid == activeUuid)
        }
    }

    static func activeAccountUuid() -> String? {
        guard let raw = try? Data(contentsOf: URL(fileURLWithPath: dataDir() + "/config.json")),
              let doc = JSON.object(raw),
              let uuid = JSON.string(doc["lastKnownAccountUuid"]), !uuid.isEmpty
        else { return nil }
        return uuid
    }

    public static func fetchUsage(profile: Profile, config: AppConfig, now: Date = Date()) async -> VendorUsage {
        let label = "\(profile.label) (desktop)"
        guard let creds = credentials(for: profile, config: config) else {
            return .unavailable(.anthropic, accountLabel: label)
        }
        // The account UUID — not the reusable label — owns the cache, so a
        // recycled label can never inherit another identity's usage.
        let cache = DiskCache(vendor: "anthropic-desktop/\(sha1Hex(profile.accountUuid))")
        return await AnthropicProvider.fetchWithCreds(creds, cache: cache, accountLabel: label, now: now)
    }

    /// Decrypt the profile's (or, for the active account, the live
    /// config.json's) safeStorage blob and lift the `user:inference`-scoped
    /// entry onto the existing OAuth credential shape. The refresh token is
    /// blanked at read time — this app never refreshes, and the live app owns
    /// that rotation.
    static func credentials(for profile: Profile, config: AppConfig) -> AnthropicCreds? {
        guard let key = SafeStorage.macKey(),
              let blob = blobBase64(for: profile, config: config),
              let plain = SafeStorage.decrypt(key: key, valueB64: blob),
              let map = JSON.object(plain)
        else { return nil }
        return inferenceEntry(map)
    }

    static func blobBase64(for profile: Profile, config: AppConfig) -> String? {
        if profile.active {
            guard let raw = try? Data(contentsOf: URL(fileURLWithPath: dataDir() + "/config.json")),
                  let doc = JSON.object(raw)
            else { return nil }
            for key in configBlobKeys {
                if let blob = JSON.string(doc[key]), !blob.isEmpty { return blob }
            }
            return nil
        }
        let dir = "\(profilesDir(config: config))/\(profile.label)"
        for file in profileBlobFiles {
            if let blob = try? String(contentsOf: URL(fileURLWithPath: "\(dir)/\(file)"), encoding: .utf8),
               !blob.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return blob
            }
        }
        return nil
    }

    /// First entry whose key names the inference scope (the token-cache map is
    /// keyed `<clientIdPrefix>:<org>:<aud>:<scopes>`; a `user:profile`-only
    /// entry is not usable for the usage endpoint). Keys are scanned in sorted
    /// order for determinism.
    static func inferenceEntry(_ map: [String: Any]) -> AnthropicCreds? {
        for key in map.keys.sorted() where key.contains(inferenceScope) {
            guard let entry = JSON.dict(map[key]),
                  let token = JSON.string(entry["token"]), !token.isEmpty
            else { continue }
            return AnthropicCreds(
                accessToken: token,
                refreshToken: "",
                expiresAtMs: Int64(JSON.double(entry["expiresAt"]) ?? 0),
                subscriptionType: JSON.string(entry["subscriptionType"]) ?? "",
                rateLimitTier: JSON.string(entry["rateLimitTier"]) ?? ""
            )
        }
        return nil
    }

    /// Full lowercase SHA-1 hex (40 chars) of the account UUID — matches
    /// upstream's `desktop_cache_key` so cache dirs are shared/compatible.
    static func sha1Hex(_ s: String) -> String {
        Insecure.SHA1.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
