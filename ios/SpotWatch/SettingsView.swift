import SwiftUI

/// The tuning settings, as on the web app's page: typed in, checked against
/// their range, saved on Save.
struct SettingsView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var typed: [String: String] = [:]
    @State private var bad: Set<String> = []
    @FocusState private var focused: String?

    var body: some View {
        NavigationView {
            Form {
                Section(footer: Text("The hunting, alert and eco settings come with N2 and N3.")) {
                    ForEach(Settings.all, id: \.key) { def in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(def.label)
                                Spacer()
                                TextField(SettingDef.text(def.def), text: binding(def.key))
                                    .keyboardType(def.isInt ? .numberPad : .decimalPad)
                                    .multilineTextAlignment(.trailing)
                                    .frame(width: 100)
                                    .focused($focused, equals: def.key)
                            }
                            Text(bad.contains(def.key)
                                 ? "Use \(SettingDef.text(def.min))–\(SettingDef.text(def.max)). Still \(SettingDef.text(model.cfg[keyPath: def.path]))."
                                 : def.hint)
                                .font(.caption)
                                .foregroundColor(bad.contains(def.key) ? .red : .gray)
                        }
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        bad = model.applySettings(typed)
                        if bad.isEmpty { dismiss() }
                    }
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { focused = nil }
                }
            }
            .onAppear {
                for def in Settings.all { typed[def.key] = SettingDef.text(model.cfg[keyPath: def.path]) }
            }
        }
        .navigationViewStyle(.stack)
        .preferredColorScheme(.dark)
    }

    private func binding(_ key: String) -> Binding<String> {
        Binding(get: { typed[key] ?? "" }, set: { typed[key] = $0 })
    }
}
