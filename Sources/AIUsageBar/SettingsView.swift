import SwiftUI
import AIUsageBarKit

/// Settings panel shown in its own desktop window (see
/// `SettingsWindowController`), reached via the gear in the dropdown footer.
/// Edits a local copy of `AppConfig` (loaded from `config.toml`) and, on Save,
/// writes it back and asks the store to reload so changes take effect immediately.
struct SettingsView: View {
    @ObservedObject var loginItem: LoginItemManager
    /// Called after a successful save so the store can re-read the config.
    let onSaved: () -> Void
    /// Close the window (Save closes after writing; Cancel closes without).
    let onClose: () -> Void

    /// The whole config is the editable model — binding straight to its fields
    /// preserves keys the UI doesn't surface (paths, api_key_env, plan_tier).
    @State private var cfg: AppConfig = .load()
    @State private var saveError: String?

    /// Vendors that authenticate with an inline API key get a secure field.
    private struct VendorField {
        let vendor: Vendor
        let enabled: WritableKeyPath<AppConfig, Bool>
        let apiKey: WritableKeyPath<AppConfig, String?>?
    }

    private let fields: [VendorField] = [
        .init(vendor: .anthropic, enabled: \.anthropicEnabled, apiKey: nil),
        .init(vendor: .openai, enabled: \.openaiEnabled, apiKey: nil),
        .init(vendor: .zai, enabled: \.zaiEnabled, apiKey: \.zaiApiKey),
        .init(vendor: .openrouter, enabled: \.openrouterEnabled, apiKey: \.openrouterApiKey),
        .init(vendor: .deepseek, enabled: \.deepseekEnabled, apiKey: \.deepseekApiKey),
        .init(vendor: .kimi, enabled: \.kimiEnabled, apiKey: \.kimiApiKey),
        .init(vendor: .minimax, enabled: \.minimaxEnabled, apiKey: \.minimaxApiKey),
        .init(vendor: .kilo, enabled: \.kiloEnabled, apiKey: \.kiloApiKey),
        .init(vendor: .novita, enabled: \.novitaEnabled, apiKey: \.novitaApiKey),
        .init(vendor: .moonshot, enabled: \.moonshotEnabled, apiKey: \.moonshotApiKey),
        .init(vendor: .grok, enabled: \.grokEnabled, apiKey: \.grokApiKey),
        .init(vendor: .anthropicAPI, enabled: \.anthropicAPIEnabled, apiKey: \.anthropicAPIKey),
        .init(vendor: .cursor, enabled: \.cursorEnabled, apiKey: nil),
        .init(vendor: .antigravity, enabled: \.antigravityEnabled, apiKey: nil),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    menuBarSection
                    Divider()
                    vendorsSection
                    Divider()
                    generalSection
                }
                .padding(.vertical, 2)
            }
            .frame(height: 380)

            if let saveError {
                Text(saveError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Divider()
            footer
        }
        .padding(16)
        .frame(width: 380)
    }

    private var menuBarSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("MENU BAR")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Picker("Primary vendor", selection: $cfg.primary) {
                Text("Auto").tag(Vendor?.none)
                ForEach(Vendor.allCases) { vendor in
                    Text(vendor.displayName).tag(Vendor?.some(vendor))
                }
            }
            Text("Which vendor headlines the menu bar title.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Picker("Indicator style", selection: $cfg.uiIndicatorStyle) {
                Text("Bars").tag(IndicatorStyle.bars)
                Text("Rings").tag(IndicatorStyle.ring)
            }
            Toggle("Show pace marker", isOn: boolBinding(\.uiPaceMarker))
                .toggleStyle(.checkbox)
            Text("A tick at each window's elapsed-time position; usage past it shows in the warning color.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var vendorsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("VENDORS")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(fields, id: \.vendor) { field in
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(field.vendor.displayName, isOn: boolBinding(field.enabled))
                        .toggleStyle(.checkbox)
                    if let keyPath = field.apiKey {
                        SecureField("API key (optional)", text: keyBinding(keyPath))
                            .textFieldStyle(.roundedBorder)
                            .font(.caption)
                            .disabled(!cfg[keyPath: field.enabled])
                    }
                }
            }
        }
    }

    private var generalSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("GENERAL")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Toggle(isOn: Binding(
                get: { loginItem.isEnabled },
                set: { loginItem.setEnabled($0) }
            )) {
                Text("Launch at Login")
            }
            .toggleStyle(.checkbox)
            .disabled(loginItem.isUnavailable)
            if loginItem.isUnavailable {
                Text("Unavailable — run the bundled app to enable.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear { loginItem.refresh() }
    }

    private var footer: some View {
        HStack {
            Button("Cancel", action: onClose)
            Spacer()
            Button("Save", action: save)
                .keyboardShortcut(.defaultAction)
        }
    }

    private func save() {
        do {
            try cfg.save()
            onSaved()
            onClose()
        } catch {
            saveError = "Couldn't save: \(error.localizedDescription)"
        }
    }

    // MARK: - Bindings into the AppConfig struct

    private func boolBinding(_ keyPath: WritableKeyPath<AppConfig, Bool>) -> Binding<Bool> {
        Binding(get: { cfg[keyPath: keyPath] }, set: { cfg[keyPath: keyPath] = $0 })
    }

    /// Map an optional-string config field to a non-optional text binding,
    /// collapsing empty input back to `nil` so it isn't written to the file.
    private func keyBinding(_ keyPath: WritableKeyPath<AppConfig, String?>) -> Binding<String> {
        Binding(
            get: { cfg[keyPath: keyPath] ?? "" },
            set: { cfg[keyPath: keyPath] = $0.isEmpty ? nil : $0 }
        )
    }
}
