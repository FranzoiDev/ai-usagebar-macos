import Foundation

/// In-process replacement for the old subprocess `UsageClient`. All data
/// collection (credentials, macOS Keychain, OAuth refresh, the undocumented
/// vendor endpoints, caching) now runs natively here — there is no longer any
/// dependency on the external `ai-usagebar` CLI.
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
        case .anthropic:  return await AnthropicProvider.fetch(config: config)
        case .openai:     return await OpenAIProvider.fetch(config: config)
        case .zai:        return await ZaiProvider.fetch(config: config)
        case .openrouter: return await OpenRouterProvider.fetch(config: config)
        case .deepseek:   return await DeepseekProvider.fetch(config: config)
        }
    }

    /// Fetch every vendor concurrently, returning rows in canonical order.
    public func fetchAll() async -> [VendorUsage] {
        await withTaskGroup(of: VendorUsage.self) { group in
            for vendor in Vendor.allCases {
                group.addTask { await fetch(vendor: vendor) }
            }
            var byVendor: [Vendor: VendorUsage] = [:]
            for await usage in group { byVendor[usage.vendor] = usage }
            return Vendor.allCases.compactMap { byVendor[$0] }
        }
    }
}
