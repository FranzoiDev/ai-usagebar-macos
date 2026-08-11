import Foundation

/// The vendors AI UsageBar knows about. Each case carries a stable id
/// (`rawValue`, also used as `[ui] primary` / `[<vendor>]` in `config.toml`
/// and as the cache directory name), a display name, and the 3-letter short
/// code shown in the menu bar title.
///
/// Each vendor's fetch + render logic lives in
/// `Native/<Vendor>Provider.swift`; this enum is just the catalog.
public enum Vendor: String, CaseIterable, Sendable, Identifiable {
    case anthropic
    case openai
    case zai
    case openrouter
    case deepseek
    case kimi
    case minimax
    case kilo
    case novita
    case moonshot
    case grok
    case anthropicAPI = "anthropic_api"
    case cursor
    case antigravity

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .anthropic:    return "Claude"
        case .openai:       return "OpenAI Codex"
        case .zai:          return "Z.AI"
        case .openrouter:   return "OpenRouter"
        case .deepseek:     return "DeepSeek"
        case .kimi:         return "Kimi"
        case .minimax:      return "MiniMax"
        case .kilo:         return "Kilo"
        case .novita:       return "Novita"
        case .moonshot:     return "Moonshot"
        case .grok:         return "Grok (xAI)"
        case .anthropicAPI: return "Anthropic API"
        case .cursor:       return "Cursor"
        case .antigravity:  return "Google Antigravity"
        }
    }

    /// Short code shown next to the headline in the menu bar title (mirrors
    /// upstream `{vendor_short}`; note Moonshot is `msh`, not Kimi's `kmi`).
    public var shortCode: String {
        switch self {
        case .anthropic:    return "cld"
        case .openai:       return "gpt"
        case .zai:          return "zai"
        case .openrouter:   return "opr"
        case .deepseek:     return "dsk"
        case .kimi:         return "kmi"
        case .minimax:      return "mmx"
        case .kilo:         return "klo"
        case .novita:       return "nvt"
        case .moonshot:     return "msh"
        case .grok:         return "grk"
        case .anthropicAPI: return "aac"
        case .cursor:       return "cur"
        case .antigravity:  return "agy"
        }
    }

    public static func from(shortCode: String) -> Vendor? {
        allCases.first { $0.shortCode == shortCode }
    }
}
