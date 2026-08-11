import Foundation

/// In-process replacement for the old subprocess `UsageClient`. All data
/// collection (credentials, macOS Keychain, vendor endpoints, caching) runs
/// natively here — there is no dependency on the external `ai-usagebar` CLI.
public struct NativeUsageClient: Sendable {
    public let config: AppConfig

    public init(config: AppConfig = .load()) {
        self.config = config
    }

    /// The configured primary vendor (`[ui] primary`), defaulting to Anthropic.
    public func primaryVendor() -> Vendor {
        config.primary ?? .anthropic
    }

    /// Fetch one vendor's usage. Never throws — a disabled/unauthenticated
    /// vendor or a failed fetch with no cache becomes an `available: false` row.
    public func fetch(vendor: Vendor) async -> VendorUsage {
        guard config.isEnabled(vendor) else { return .unavailable(vendor) }
        switch vendor {
        case .anthropic:    return await AnthropicProvider.fetch(config: config)
        case .openai:       return await OpenAIProvider.fetch(config: config)
        case .zai:          return await ZaiProvider.fetch(config: config)
        case .openrouter:   return await OpenRouterProvider.fetch(config: config)
        case .deepseek:     return await DeepseekProvider.fetch(config: config)
        case .kimi:         return await KimiProvider.fetch(config: config)
        case .minimax:      return await MinimaxProvider.fetch(config: config)
        case .kilo:         return await KiloProvider.fetch(config: config)
        case .novita:       return await NovitaProvider.fetch(config: config)
        case .moonshot:     return await MoonshotProvider.fetch(config: config)
        case .grok:         return await GrokProvider.fetch(config: config)
        case .anthropicAPI: return await AnthropicAPIProvider.fetch(config: config)
        case .cursor:       return await CursorProvider.fetch(config: config)
        case .antigravity:  return await AntigravityProvider.fetch(config: config)
        }
    }

    /// Fetch everything concurrently, returning rows in canonical order:
    /// the default Claude row (per `show_default_account`), one row per named
    /// Anthropic account and Claude Desktop profile, then the other vendors.
    public func fetchAll() async -> [VendorUsage] {
        let config = self.config
        var jobs: [@Sendable () async -> VendorUsage] = []

        if config.isEnabled(.anthropic) {
            let accounts = config.allAnthropicAccounts()
            let desktopProfiles = ClaudeDesktop.profiles(config: config)
            let hasNamed = !accounts.isEmpty || !desktopProfiles.isEmpty
            if config.showsDefaultAnthropicRow(hasNamedRows: hasNamed) {
                jobs.append { await AnthropicProvider.fetch(config: config) }
            }
            // Stagger the shared /api/oauth/usage endpoint: several accounts
            // fetching at once trip its rate limit (429).
            for (i, account) in accounts.enumerated() {
                jobs.append {
                    try? await Task.sleep(nanoseconds: UInt64(i) * 800_000_000)
                    return await AnthropicProvider.fetch(config: config, account: account)
                }
            }
            for (i, profile) in desktopProfiles.enumerated() {
                let offset = accounts.count + i
                jobs.append {
                    try? await Task.sleep(nanoseconds: UInt64(offset) * 800_000_000)
                    return await ClaudeDesktop.fetchUsage(profile: profile, config: config)
                }
            }
        } else {
            jobs.append { .unavailable(.anthropic) }
        }

        for vendor in Vendor.allCases where vendor != .anthropic {
            jobs.append { await self.fetch(vendor: vendor) }
        }

        return await withTaskGroup(of: (Int, VendorUsage).self) { group in
            for (i, job) in jobs.enumerated() {
                group.addTask { (i, await job()) }
            }
            var byIndex = [Int: VendorUsage]()
            for await (i, usage) in group { byIndex[i] = usage }
            return (0..<jobs.count).compactMap { byIndex[$0] }
        }
    }
}
