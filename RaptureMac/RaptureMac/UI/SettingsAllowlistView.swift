import SwiftUI

struct SettingsAllowlistView: View {
    @Environment(AppState.self) private var appState

    @State private var draftEntry: String = ""

    var body: some View {
        Form {
            Section {
                HStack {
                    TextField("Phone number or Apple ID email", text: $draftEntry)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(addDraft)
                    Button("Add", action: addDraft)
                        .disabled(AllowlistInput.normalize(draftEntry) == nil)
                }
            } header: {
                Text("Allowed Senders")
            } footer: {
                Text("Messages to yourself are always captured. Add other phone numbers (e.g. +15555550123) or Apple ID emails here to capture from them too.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Current List") {
                if appState.settings.settings.allowedHandles.isEmpty {
                    Text("No senders allowlisted yet.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(appState.settings.settings.allowedHandles, id: \.self) { handle in
                        HStack {
                            Text(handle)
                                .textSelection(.enabled)
                            Spacer()
                            Button {
                                remove(handle: handle)
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.plain)
                            .help("Remove")
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func addDraft() {
        let updated = AllowlistInput.appending(draftEntry, to: appState.settings.settings.allowedHandles)
        appState.settings.update { $0.allowedHandles = updated }
        draftEntry = ""
    }

    private func remove(handle: String) {
        appState.settings.update { $0.allowedHandles.removeAll { $0 == handle } }
    }
}
