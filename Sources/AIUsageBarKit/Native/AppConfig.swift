import Foundation

/// In-process equivalent of upstream `src/config.rs`: reads
/// `~/.config/ai-usagebar/config.toml` (honoring `XDG_CONFIG_HOME`) to decide
/// which vendors are enabled, which is primary, and where to find API keys.
///
/// A full TOML library would be overkill — the config is a flat set of
/// `[section]` tables with `key = value` scalars (string / bool), so a tiny
/// line parser covers it. Missing file → defaults (same as upstream).
public struct AppConfig: Sendable {
    public var primary: Vendor?

    public var anthropicEnabled = true
    public var anthropicCredentialsPath: String?

    public var openaiEnabled = true
    public var codexAuthPath: String?

    public var zaiEnabled = true
    public var zaiApiKeyEnv = "ZAI_API_KEY"
    public var zaiApiKey: String?
    public var zaiPlanTier: String?

    public var openrouterEnabled = true
    public var openrouterApiKeyEnv = "OPENROUTER_API_KEY"
    public var openrouterApiKey: String?

    // DeepSeek defaults to disabled — it has no free tier and needs a key.
    public var deepseekEnabled = false
    public var deepseekApiKeyEnv = "DEEPSEEK_API_KEY"
    public var deepseekApiKey: String?

    public init() {}

    public func isEnabled(_ vendor: Vendor) -> Bool {
        switch vendor {
        case .anthropic:  return anthropicEnabled
        case .openai:     return openaiEnabled
        case .zai:        return zaiEnabled
        case .openrouter: return openrouterEnabled
        case .deepseek:   return deepseekEnabled
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

    /// Render the config as the flat-table TOML subset `parse` understands.
    /// Comments and unknown keys from a hand-edited file are not preserved —
    /// this app owns the file once Settings writes to it. Exposed for tests.
    public func serialize() -> String {
        var out = "# Managed by AI UsageBar Settings. Hand edits may be overwritten.\n\n"

        if let primary {
            out += "[ui]\n"
            out += "primary = \(Self.quote(primary.rawValue))\n\n"
        }

        out += "[anthropic]\n"
        out += "enabled = \(anthropicEnabled)\n"
        if let p = anthropicCredentialsPath, !p.isEmpty {
            out += "credentials_path = \(Self.quote(p))\n"
        }
        out += "\n"

        out += "[openai]\n"
        out += "enabled = \(openaiEnabled)\n"
        if let p = codexAuthPath, !p.isEmpty {
            out += "codex_auth_path = \(Self.quote(p))\n"
        }
        out += "\n"

        out += "[zai]\n"
        out += "enabled = \(zaiEnabled)\n"
        out += "api_key_env = \(Self.quote(zaiApiKeyEnv))\n"
        if let k = zaiApiKey, !k.isEmpty { out += "api_key = \(Self.quote(k))\n" }
        if let t = zaiPlanTier, !t.isEmpty { out += "plan_tier = \(Self.quote(t))\n" }
        out += "\n"

        out += "[openrouter]\n"
        out += "enabled = \(openrouterEnabled)\n"
        out += "api_key_env = \(Self.quote(openrouterApiKeyEnv))\n"
        if let k = openrouterApiKey, !k.isEmpty { out += "api_key = \(Self.quote(k))\n" }
        out += "\n"

        out += "[deepseek]\n"
        out += "enabled = \(deepseekEnabled)\n"
        out += "api_key_env = \(Self.quote(deepseekApiKeyEnv))\n"
        if let k = deepseekApiKey, !k.isEmpty { out += "api_key = \(Self.quote(k))\n" }
        out += "\n"

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

    /// Parse the flat-table TOML subset this app understands. Exposed for tests.
    public static func parse(_ raw: String) -> AppConfig {
        var cfg = AppConfig()
        var section = ""

        for lineRaw in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = stripComment(String(lineRaw)).trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            if line.hasPrefix("[") && line.hasSuffix("]") {
                section = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                continue
            }

            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            let valueRaw = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            apply(section: section, key: key, value: valueRaw, into: &cfg)
        }
        return cfg
    }

    private static func apply(section: String, key: String, value: String, into cfg: inout AppConfig) {
        let str = unquote(value)
        let boolVal = (value == "true")

        switch (section, key) {
        case ("ui", "primary"):
            cfg.primary = Vendor(rawValue: str.lowercased())

        case ("anthropic", "enabled"):           cfg.anthropicEnabled = boolVal
        case ("anthropic", "credentials_path"):  cfg.anthropicCredentialsPath = str

        case ("openai", "enabled"):              cfg.openaiEnabled = boolVal
        case ("openai", "codex_auth_path"):      cfg.codexAuthPath = str

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
