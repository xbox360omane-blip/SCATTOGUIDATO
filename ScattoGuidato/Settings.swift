import SwiftUI
import Security

enum Keychain {
    private static let account = "anthropic-api-key"

    private static var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrAccount as String: account]
    }

    static func save(_ value: String) {
        SecItemDelete(baseQuery as CFDictionary)
        guard !value.isEmpty else { return }
        var add = baseQuery
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    static func load() -> String? {
        var q = baseQuery
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

struct SettingsView: View {
    @Binding var apiKey: String
    @Binding var model: String
    @Environment(\.dismiss) private var dismiss
    @State private var draftKey = ""

    private let models: [(String, String)] = [
        ("claude-sonnet-5-5", "Sonnet 5.5 · equilibrato"),
        ("claude-haiku-5-5", "Haiku 5.5 · più veloce"),
        ("claude-opus-5-5", "Opus 5.5 · più accurato")
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("sk-ant-…", text: $draftKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Chiave API Anthropic")
                } footer: {
                    Text("Crea una chiave su console.anthropic.com. Resta salvata nel Portachiavi del telefono.")
                }
                Section("Modello") {
                    Picker("Modello", selection: $model) {
                        ForEach(models, id: \.0) { m in Text(m.1).tag(m.0) }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
            }
            .navigationTitle("Impostazioni")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annulla") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Salva") {
                        let k = draftKey.trimmingCharacters(in: .whitespacesAndNewlines)
                        Keychain.save(k)
                        apiKey = k
                        dismiss()
                    }
                }
            }
            .onAppear { draftKey = apiKey }
        }
    }
}
