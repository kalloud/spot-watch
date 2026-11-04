import SwiftUI

/// The ntfy topics and the tuning, hunting and alert settings, as on the web
/// app's page: typed in, checked, saved on Save.
struct SettingsView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var typed: [String: String] = [:]
    @State private var alertTopic = ""
    @State private var controlTopic = ""
    @State private var bad: Set<String> = []
    @FocusState private var focused: String?

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("ntfy topics"),
                        footer: Text("Subscribe to the alert topic in the ntfy app on the main phone. The control topic takes hunt on, hunt off, power low and power high. Topics are 1–64 letters, digits, - or _; anyone who knows one can read it.")) {
                    topicField("Alert topic", text: $alertTopic, key: "alertTopic")
                    topicField("Control topic", text: $controlTopic, key: "controlTopic")
                }
                Section(header: Text("Checks, spots and hunting"),
                        footer: Text("Quiet hours are decimal hours, e.g. 7.5 = 07:30; equal values turn them off.")) {
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
                        bad = model.applySettings(typed).union(model.applyTopics(alert: alertTopic, control: controlTopic))
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
                alertTopic = model.alertTopic
                controlTopic = model.controlTopic
            }
        }
        .navigationViewStyle(.stack)
        .preferredColorScheme(.dark)
    }

    private func topicField(_ label: String, text: Binding<String>, key: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
            TextField("spotwatch-…", text: text)
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)
                .font(.system(.body, design: .monospaced))
                .focused($focused, equals: key)
            if bad.contains(key) {
                Text("Use 1–64 letters, digits, - or _. Still using the previous topic.").font(.caption).foregroundColor(.red)
            }
        }
    }

    private func binding(_ key: String) -> Binding<String> {
        Binding(get: { typed[key] ?? "" }, set: { typed[key] = $0 })
    }
}
