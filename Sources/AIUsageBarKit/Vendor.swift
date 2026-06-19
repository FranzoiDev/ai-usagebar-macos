import Foundation

/// The vendors AI UsageBar knows about. Each case carries a stable id
/// (`rawValue`, also used as `[ui] primary` / `[<vendor>]` in `config.toml`), a
/// display name, and the 3-letter short code shown in the menu bar title.
///
/// Each vendor's fetch + render logic lives in
/// `Native/<Vendor>Provider.swift`; this enum is just the catalog.
public enum Vendor: String, CaseIterable, Sendable, Identifiable {
    case anthropic
    case openai
    case zai
    case openrouter
    case deepseek

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .anthropic:  return "Claude"
        case .openai:     return "OpenAI Codex"
        case .zai:        return "Z.AI"
        case .openrouter: return "OpenRouter"
        case .deepseek:   return "DeepSeek"
        }
    }

    /// Short code shown next to the headline in the menu bar title.
    public var shortCode: String {
        switch self {
        case .anthropic:  return "cld"
        case .openai:     return "gpt"
        case .zai:        return "zai"
        case .openrouter: return "opr"
        case .deepseek:   return "dsk"
        }
    }

    public static func from(shortCode: String) -> Vendor? {
        allCases.first { $0.shortCode == shortCode }
    }
}
