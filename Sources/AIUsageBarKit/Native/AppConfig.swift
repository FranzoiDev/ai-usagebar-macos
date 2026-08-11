import Foundation

/// How the dropdown draws each gauge: linear bars (default) or a ring arc
/// (upstream v0.17's "Estilo do indicador").
public enum IndicatorStyle: String, Sendable, CaseIterable, Identifiable {
    case bars
    case ring

    public var id: String { rawValue }
}

/// A named Anthropic account from `[[anthropic.accounts]]` or discovered under
/// `[anthropic] accounts_dir` (one subdirectory per `CLAUDE_CONFIG_DIR`).
public struct AnthropicAccount: Sendable, Equatable {
    public var label: String
    public var credentialsPath: String

    public init(label: String, credentialsPath: String) {
        self.label = label
        self.credentialsPath = credentialsPath
    }

    /// The account's `CLAUDE_CONFIG_DIR` — the parent of its credentials file.
    /// This string (unnormalized) is what the Keychain service hash is
    /// computed from, matching Claude Code.
    public var configDir: String {
        (credentialsPath as NSString).deletingLastPathComponent
    }

    /// Labels that would collide with cache filenames or escape the cache dir.
    public static func isValidLabel(_ label: String) -> Bool {
        let reserved = ["usage.json", ".stale", ".last_error", ".fetch.lock"]
        return !label.isEmpty
            && label != "." && label != ".."
            && !label.contains("/") && !label.contains("\\")
            && !label.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
            && !reserved.contains(label)
    }
}

/// In-process equivalent of upstream `src/config.rs`: reads
/// `~/.config/ai-usagebar/config.toml` (honoring `XDG_CONFIG_HOME`) to decide
/// which vendors are enabled, which is primary, and where to find API keys.
///
/// A full TOML library would be overkill — the config is a set of `[section]`
/// tables with `key = value` scalars plus the `[[anthropic.accounts]]` array
/// of tables, so a small line parser covers it. Missing file → defaults (same
/// as upstream).
public struct AppConfig: Sendable {
    public var primary: Vendor?
    /// Draw the pace marker (upstream's "meta reference"): a tick at the
    /// elapsed-time position of each window, with overshoot past it in the
    /// warning color.
    public var uiPaceMarker = true
    public var uiIndicatorStyle: IndicatorStyle = .bars

    public var anthropicEnabled = true
    public var anthropicCredentialsPath: String?
    /// Named accounts (explicit entries win over discovered ones on a label clash).
    public var anthropicAccounts: [AnthropicAccount] = []
    /// Directory of per-account `CLAUDE_CONFIG_DIR`s to auto-discover.
    public var anthropicAccountsDir: String?
    /// Hide the default (unnamed) Claude row when named accounts exist.
    public var anthropicShowDefaultAccount = true
    /// Claude Desktop profile store (claude-acc layout); nil → ~/.claude-acc/profiles.
    public var anthropicDesktopProfilesDir: String?

    public var openaiEnabled = true
    public var codexAuthPath: String?

    public var zaiEnabled = true
    public var zaiApiKeyEnv = "ZAI_API_KEY"
    public var zaiApiKey: String?
    public var zaiPlanTier: String?

    public var openrouterEnabled = true
    public var openrouterApiKeyEnv = "OPENROUTER_API_KEY"
    public var openrouterApiKey: String?

    // The vendors below need an API key (or a local install) and default to
    // disabled, matching upstream.
    public var deepseekEnabled = false
    public var deepseekApiKeyEnv = "DEEPSEEK_API_KEY"
    public var deepseekApiKey: String?

    public var kimiEnabled = false
    public var kimiApiKeyEnv = "KIMI_API_KEY"
    public var kimiApiKey: String?

    public var minimaxEnabled = false
    public var minimaxApiKeyEnv = "MINIMAX_API_KEY"
    public var minimaxApiKey: String?
    /// "global" (api.minimax.io) or "cn" (api.minimaxi.com) — separate
    /// instances with separate keys.
    public var minimaxRegion = "global"

    public var kiloEnabled = false
    public var kiloApiKeyEnv = "KILO_API_KEY"
    public var kiloApiKey: String?
    public var kiloOrganizationId: String?

    public var novitaEnabled = false
    public var novitaApiKeyEnv = "NOVITA_API_KEY"
    public var novitaApiKey: String?

    public var moonshotEnabled = false
    public var moonshotApiKeyEnv = "MOONSHOT_API_KEY"
    public var moonshotApiKey: String?
    /// "global" (USD) or "cn" (CNY) — the currency is implied by the host.
    public var moonshotRegion = "global"

    public var grokEnabled = false
    public var grokApiKeyEnv = "XAI_MANAGEMENT_KEY"
    public var grokApiKey: String?
    public var grokTeamId: String?

    public var anthropicAPIEnabled = false
    public var anthropicAPIKeyEnv = "ANTHROPIC_ADMIN_KEY"
    public var anthropicAPIKey: String?
    /// Config-supplied spending cap in dollars (the API exposes no limit).
    public var anthropicAPIMonthlyLimit: Double?

    public var cursorEnabled = false
    public var cursorDbPath: String?
    public var cursorAgentAuthPath: String?

    public var antigravityEnabled = false

    public init() {}

    public func isEnabled(_ vendor: Vendor) -> Bool {
        switch vendor {
        case .anthropic:    return anthropicEnabled
        case .openai:       return openaiEnabled
        case .zai:          return zaiEnabled
        case .openrouter:   return openrouterEnabled
        case .deepseek:     return deepseekEnabled
        case .kimi:         return kimiEnabled
        case .minimax:      return minimaxEnabled
        case .kilo:         return kiloEnabled
        case .novita:       return novitaEnabled
        case .moonshot:     return moonshotEnabled
        case .grok:         return grokEnabled
        case .anthropicAPI: return anthropicAPIEnabled
        case .cursor:       return cursorEnabled
        case .antigravity:  return antigravityEnabled
        }
    }

    /// Resolve an API key: env var wins over inline config, else nil.
    public static func resolveKey(env name: String, inline: String?) -> String? {
        if !name.isEmpty, let v = ProcessInfo.processInfo.environment[name], !v.isEmpty {
            return v
        }
        if let inline, !inline.isEmpty { return inline }
        return nil
    }

    /// Expand a leading `~` or `~/` to the home directory (`~user` stays
    /// literal, matching upstream).
    public static func expandTilde(_ path: String) -> String {
        if path == "~" { return FileManager.default.homeDirectoryForCurrentUser.path }
        if path.hasPrefix("~/") {
            return FileManager.default.homeDirectoryForCurrentUser.path + String(path.dropFirst(1))
        }
        return path
    }

    /// Explicit accounts plus `accounts_dir` discoveries (explicit wins on a
    /// label clash; discovered entries are appended sorted by label). A
    /// missing or unreadable directory is ignored. Discovery does not require
    /// `.credentials.json` to exist — macOS logins live only in the Keychain.
    public func allAnthropicAccounts() -> [AnthropicAccount] {
        var out = anthropicAccounts.filter { AnthropicAccount.isValidLabel($0.label) }
        if let dirRaw = anthropicAccountsDir, !dirRaw.isEmpty {
            let dir = Self.expandTilde(dirRaw)
            let names = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
            let known = Set(out.map(\.label))
            let discovered = names.sorted().filter { name in
                var isDir: ObjCBool = false
                return AnthropicAccount.isValidLabel(name)
                    && !known.contains(name)
                    && FileManager.default.fileExists(atPath: "\(dir)/\(name)", isDirectory: &isDir)
                    && isDir.boolValue
            }
            out += discovered.map {
                AnthropicAccount(label: $0, credentialsPath: "\(dir)/\($0)/.credentials.json")
            }
        }
        return out
    }

    /// Whether the default (unnamed) Claude row shows: always when there are
    /// no named accounts; otherwise the config decides.
    public func showsDefaultAnthropicRow(hasNamedRows: Bool) -> Bool {
        hasNamedRows ? anthropicShowDefaultAccount : true
    }

    // MARK: - Loading

    /// Resolved path of `config.toml` (honoring `XDG_CONFIG_HOME`). Shared by
    /// `load()` and `save()` so reads and writes can never diverge.
    public static func configURL() -> URL {
        let env = ProcessInfo.processInfo.environment
        let base: URL
        if let xdg = env["XDG_CONFIG_HOME"], !xdg.isEmpty {
            base = URL(fileURLWithPath: xdg)
        } else {
            base = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".config")
        }
        return base.appendingPathComponent("ai-usagebar").appendingPathComponent("config.toml")
    }

    public static func load() -> AppConfig {
        let path = configURL()
        guard let raw = try? String(contentsOf: path, encoding: .utf8) else {
            return AppConfig()
        }
        return parse(raw)
    }

    // MARK: - Saving

    /// Serialize to `config.toml`, creating the parent directory if needed.
    /// Writes only the fields this UI manages; round-trips through `parse`.
    public func save() throws {
        let url = AppConfig.configURL()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try serialize().write(to: url, atomically: true, encoding: .utf8)
    }

    /// Render the config as the TOML subset `parse` understands. Comments and
    /// unknown keys from a hand-edited file are not preserved — this app owns
    /// the file once Settings writes to it. Exposed for tests.
    public func serialize() -> String {
        var out = "# Managed by AI UsageBar Settings. Hand edits may be overwritten.\n\n"

        out += "[ui]\n"
        if let primary {
            out += "primary = \(Self.quote(primary.rawValue))\n"
        }
        out += "pace_marker = \(uiPaceMarker)\n"
        out += "indicator_style = \(Self.quote(uiIndicatorStyle.rawValue))\n\n"

        out += "[anthropic]\n"
        out += "enabled = \(anthropicEnabled)\n"
        if let p = anthropicCredentialsPath, !p.isEmpty {
            out += "credentials_path = \(Self.quote(p))\n"
        }
        if let d = anthropicAccountsDir, !d.isEmpty {
            out += "accounts_dir = \(Self.quote(d))\n"
        }
        out += "show_default_account = \(anthropicShowDefaultAccount)\n"
        if let d = anthropicDesktopProfilesDir, !d.isEmpty {
            out += "desktop_profiles_dir = \(Self.quote(d))\n"
        }
        out += "\n"
        for account in anthropicAccounts {
            out += "[[anthropic.accounts]]\n"
            out += "label = \(Self.quote(account.label))\n"
            out += "credentials_path = \(Self.quote(account.credentialsPath))\n\n"
        }

        out += "[openai]\n"
        out += "enabled = \(openaiEnabled)\n"
        if let p = codexAuthPath, !p.isEmpty {
            out += "codex_auth_path = \(Self.quote(p))\n"
        }
        out += "\n"

        func keySection(_ name: String, _ enabled: Bool, _ env: String, _ key: String?,
                        extra: [(String, String)] = []) -> String {
            var s = "[\(name)]\n"
            s += "enabled = \(enabled)\n"
            s += "api_key_env = \(Self.quote(env))\n"
            if let key, !key.isEmpty { s += "api_key = \(Self.quote(key))\n" }
            for (k, v) in extra where !v.isEmpty { s += "\(k) = \(v)\n" }
            s += "\n"
            return s
        }

        out += "[zai]\n"
        out += "enabled = \(zaiEnabled)\n"
        out += "api_key_env = \(Self.quote(zaiApiKeyEnv))\n"
        if let k = zaiApiKey, !k.isEmpty { out += "api_key = \(Self.quote(k))\n" }
        if let t = zaiPlanTier, !t.isEmpty { out += "plan_tier = \(Self.quote(t))\n" }
        out += "\n"

        out += keySection("openrouter", openrouterEnabled, openrouterApiKeyEnv, openrouterApiKey)
        out += keySection("deepseek", deepseekEnabled, deepseekApiKeyEnv, deepseekApiKey)
        out += keySection("kimi", kimiEnabled, kimiApiKeyEnv, kimiApiKey)
        out += keySection("minimax", minimaxEnabled, minimaxApiKeyEnv, minimaxApiKey,
                          extra: [("region", Self.quote(minimaxRegion))])
        out += keySection("kilo", kiloEnabled, kiloApiKeyEnv, kiloApiKey,
                          extra: [("organization_id", kiloOrganizationId.map(Self.quote) ?? "")])
        out += keySection("novita", novitaEnabled, novitaApiKeyEnv, novitaApiKey)
        out += keySection("moonshot", moonshotEnabled, moonshotApiKeyEnv, moonshotApiKey,
                          extra: [("region", Self.quote(moonshotRegion))])
        out += keySection("grok", grokEnabled, grokApiKeyEnv, grokApiKey,
                          extra: [("team_id", grokTeamId.map(Self.quote) ?? "")])
        out += keySection("anthropic_api", anthropicAPIEnabled, anthropicAPIKeyEnv, anthropicAPIKey,
                          extra: [("monthly_limit", anthropicAPIMonthlyLimit.map { String($0) } ?? "")])

        out += "[cursor]\n"
        out += "enabled = \(cursorEnabled)\n"
        if let p = cursorDbPath, !p.isEmpty { out += "db_path = \(Self.quote(p))\n" }
        if let p = cursorAgentAuthPath, !p.isEmpty { out += "agent_auth_path = \(Self.quote(p))\n" }
        out += "\n"

        out += "[antigravity]\n"
        out += "enabled = \(antigravityEnabled)\n\n"

        return out
    }

    /// Wrap a value in TOML basic-string quotes. Backslashes and double quotes
    /// are escaped so the value survives a `parse` round-trip; the simple line
    /// parser drops a bare `#`, so anything else stays literal.
    private static func quote(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    /// Parse the TOML subset this app understands. Exposed for tests.
    public static func parse(_ raw: String) -> AppConfig {
        var cfg = AppConfig()
        var section = ""
        var pendingAccount: (label: String?, path: String?)?

        func flushAccount() {
            if let acc = pendingAccount, let label = acc.label, let path = acc.path,
               AnthropicAccount.isValidLabel(label),
               !cfg.anthropicAccounts.contains(where: { $0.label == label }) {
                cfg.anthropicAccounts.append(
                    AnthropicAccount(label: label, credentialsPath: expandTilde(path)))
            }
            pendingAccount = nil
        }

        for lineRaw in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = stripComment(String(lineRaw)).trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            if line.hasPrefix("[[") && line.hasSuffix("]]") {
                flushAccount()
                let name = String(line.dropFirst(2).dropLast(2)).trimmingCharacters(in: .whitespaces)
                section = name
                if name == "anthropic.accounts" { pendingAccount = (nil, nil) }
                continue
            }
            if line.hasPrefix("[") && line.hasSuffix("]") {
                flushAccount()
                section = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                continue
            }

            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            let valueRaw = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)

            if section == "anthropic.accounts" {
                if key == "label" { pendingAccount?.label = unquote(valueRaw) }
                if key == "credentials_path" { pendingAccount?.path = unquote(valueRaw) }
                continue
            }
            apply(section: section, key: key, value: valueRaw, into: &cfg)
        }
        flushAccount()
        return cfg
    }

    private static func apply(section: String, key: String, value: String, into cfg: inout AppConfig) {
        let str = unquote(value)
        let boolVal = (value == "true")

        switch (section, key) {
        case ("ui", "primary"):
            cfg.primary = Vendor(rawValue: str.lowercased())
        case ("ui", "pace_marker"):
            cfg.uiPaceMarker = boolVal
        case ("ui", "indicator_style"):
            cfg.uiIndicatorStyle = IndicatorStyle(rawValue: str.lowercased()) ?? .bars

        case ("anthropic", "enabled"):              cfg.anthropicEnabled = boolVal
        case ("anthropic", "credentials_path"):     cfg.anthropicCredentialsPath = expandTilde(str)
        case ("anthropic", "accounts_dir"):         cfg.anthropicAccountsDir = str
        case ("anthropic", "show_default_account"): cfg.anthropicShowDefaultAccount = boolVal
        case ("anthropic", "desktop_profiles_dir"): cfg.anthropicDesktopProfilesDir = expandTilde(str)

        case ("openai", "enabled"):              cfg.openaiEnabled = boolVal
        case ("openai", "codex_auth_path"):      cfg.codexAuthPath = expandTilde(str)

        case ("zai", "enabled"):                 cfg.zaiEnabled = boolVal
        case ("zai", "api_key_env"):             cfg.zaiApiKeyEnv = str
        case ("zai", "api_key"):                 cfg.zaiApiKey = str
        case ("zai", "plan_tier"):               cfg.zaiPlanTier = str

        case ("openrouter", "enabled"):          cfg.openrouterEnabled = boolVal
        case ("openrouter", "api_key_env"):      cfg.openrouterApiKeyEnv = str
        case ("openrouter", "api_key"):          cfg.openrouterApiKey = str

        case ("deepseek", "enabled"):            cfg.deepseekEnabled = boolVal
        case ("deepseek", "api_key_env"):        cfg.deepseekApiKeyEnv = str
        case ("deepseek", "api_key"):            cfg.deepseekApiKey = str

        case ("kimi", "enabled"):                cfg.kimiEnabled = boolVal
        case ("kimi", "api_key_env"):            cfg.kimiApiKeyEnv = str
        case ("kimi", "api_key"):                cfg.kimiApiKey = str

        case ("minimax", "enabled"):             cfg.minimaxEnabled = boolVal
        case ("minimax", "api_key_env"):         cfg.minimaxApiKeyEnv = str
        case ("minimax", "api_key"):             cfg.minimaxApiKey = str
        case ("minimax", "region"):              cfg.minimaxRegion = str

        case ("kilo", "enabled"):                cfg.kiloEnabled = boolVal
        case ("kilo", "api_key_env"):            cfg.kiloApiKeyEnv = str
        case ("kilo", "api_key"):                cfg.kiloApiKey = str
        case ("kilo", "organization_id"):        cfg.kiloOrganizationId = str

        case ("novita", "enabled"):              cfg.novitaEnabled = boolVal
        case ("novita", "api_key_env"):          cfg.novitaApiKeyEnv = str
        case ("novita", "api_key"):              cfg.novitaApiKey = str

        case ("moonshot", "enabled"):            cfg.moonshotEnabled = boolVal
        case ("moonshot", "api_key_env"):        cfg.moonshotApiKeyEnv = str
        case ("moonshot", "api_key"):            cfg.moonshotApiKey = str
        case ("moonshot", "region"):             cfg.moonshotRegion = str

        case ("grok", "enabled"):                cfg.grokEnabled = boolVal
        case ("grok", "api_key_env"):            cfg.grokApiKeyEnv = str
        case ("grok", "api_key"):                cfg.grokApiKey = str
        case ("grok", "team_id"):                cfg.grokTeamId = str

        case ("anthropic_api", "enabled"):       cfg.anthropicAPIEnabled = boolVal
        case ("anthropic_api", "api_key_env"):   cfg.anthropicAPIKeyEnv = str
        case ("anthropic_api", "api_key"):       cfg.anthropicAPIKey = str
        case ("anthropic_api", "monthly_limit"):
            // A non-positive or non-finite cap would fabricate percentages.
            if let v = Double(str), v.isFinite, v > 0 { cfg.anthropicAPIMonthlyLimit = v }

        case ("cursor", "enabled"):              cfg.cursorEnabled = boolVal
        case ("cursor", "db_path"):              cfg.cursorDbPath = expandTilde(str)
        case ("cursor", "agent_auth_path"):      cfg.cursorAgentAuthPath = expandTilde(str)

        case ("antigravity", "enabled"):         cfg.antigravityEnabled = boolVal

        default: break
        }
    }

    /// Strip a trailing `# comment`, but not a `#` inside a quoted string.
    private static func stripComment(_ line: String) -> String {
        var inQuote = false
        var out = ""
        for ch in line {
            if ch == "\"" { inQuote.toggle() }
            if ch == "#" && !inQuote { break }
            out.append(ch)
        }
        return out
    }

    private static func unquote(_ v: String) -> String {
        guard v.count >= 2, v.hasPrefix("\""), v.hasSuffix("\"") else { return v }
        let inner = v.dropFirst().dropLast()
        // Decode the escapes `serialize`/`quote` emit: `\\` and `\"`.
        var out = ""
        var escaping = false
        for ch in inner {
            if escaping {
                out.append(ch) // `\\` -> `\`, `\"` -> `"`, others kept literal
                escaping = false
            } else if ch == "\\" {
                escaping = true
            } else {
                out.append(ch)
            }
        }
        if escaping { out.append("\\") }
        return out
    }
}
