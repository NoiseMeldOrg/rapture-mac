import SwiftUI

/// Settings → Triage → "AI Triage": the one AI toggle (off by default), the
/// active-engine status with one honest privacy line per engine, and the
/// Anthropic API key row (Keychain-backed — the key is never rendered back,
/// never in a settings file). The toggle persists ON only when an engine would
/// actually run (`AITriageEnableFlow`); flipping OFF always persists.
struct AITriageSettingsSection: View {
    @Environment(AppState.self) private var appState
    @Environment(AITriageService.self) private var aiTriage

    @State private var keyDraft = ""
    /// Cleared on save/remove: a focused empty SecureField hides its placeholder
    /// on macOS, so leaving focus in the field after Save shows a blank field with
    /// a cursor instead of the "API key saved" confirmation (dogfood papercut,
    /// v1.0.98 release validation).
    @FocusState private var keyFieldFocused: Bool

    private var rawMode: Bool { appState.settings.settings.triageMode == .raw }
    private var hasStoredKey: Bool { appState.credentials.anthropicAPIKey()?.isEmpty == false }

    var body: some View {
        Section {
            if rawMode {
                Text("AI triage needs Markdown filing. Switch Filing above to “Markdown notes” to use it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Toggle("Classify and title captures with AI", isOn: toggleBinding)
                statusLine

                keyRow

                Text("Off by default. With AI on, voice notes are sorted into Tasks, Ideas, or Journal with concise titles and lightly cleaned-up text — the verbatim dictation is always kept in the note under “Raw”. If AI is ever unavailable, captures keep filing instantly without it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let error = appState.aiLastError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        } header: {
            Text("AI Triage")
        }
        .onAppear { aiTriage.refreshStatus() }
    }

    // MARK: - Status + privacy line

    @ViewBuilder
    private var statusLine: some View {
        switch appState.aiEngineStatus {
        case .off:
            if appState.settings.settings.aiTriageEnabled {
                EmptyView()
            } else {
                Text("AI triage is off. Captures file deterministically — no AI, on-device or otherwise.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .active(.apple):
            Label {
                Text("Using Apple Intelligence on this Mac. Notes are processed on-device and never leave your Mac.")
                    .font(.caption)
            } icon: {
                Image(systemName: "lock.laptopcomputer")
            }
            .foregroundStyle(.secondary)
        case .active(.anthropic):
            Label {
                Text("Using the Anthropic API with your key. Each capture's text is sent to Anthropic over HTTPS to classify and title it.")
                    .font(.caption)
            } icon: {
                Image(systemName: "network")
            }
            .foregroundStyle(.secondary)
        case .unavailable(let reason):
            Label {
                Text("\(reason) Captures keep filing without AI.")
                    .font(.caption)
            } icon: {
                Image(systemName: "exclamationmark.triangle")
            }
            .foregroundStyle(.orange)
        }
    }

    // MARK: - Anthropic key row

    @ViewBuilder
    private var keyRow: some View {
        HStack {
            SecureField(
                hasStoredKey ? "API key saved" : "Anthropic API key (optional)",
                text: $keyDraft
            )
            .textContentType(.password)
            .focused($keyFieldFocused)
            Button("Save") { saveKey() }
                .disabled(keyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
            if hasStoredKey {
                Button("Remove") { removeKey() }
            }
        }
        Text("Used only when Apple Intelligence isn't available. Stored in the macOS Keychain, never in a settings file. Get a key at console.anthropic.com — create a new key; existing ones are shown only once, at creation.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private func saveKey() {
        let key = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        do {
            try appState.credentials.setAnthropicAPIKey(key)
            keyDraft = ""
            keyFieldFocused = false
            aiTriage.noteKeySaved()
        } catch {
            appState.aiLastError = "Couldn't save the key: \(error.localizedDescription)"
        }
    }

    private func removeKey() {
        do {
            try appState.credentials.setAnthropicAPIKey(nil)
            keyDraft = ""
            keyFieldFocused = false
            aiTriage.refreshStatus()
        } catch {
            appState.aiLastError = "Couldn't remove the key: \(error.localizedDescription)"
        }
    }

    // MARK: - Toggle (persist-on-success pattern)

    private var toggleBinding: Binding<Bool> {
        Binding(
            get: { appState.settings.settings.aiTriageEnabled },
            set: { newValue in
                guard newValue else {
                    appState.settings.update { $0.aiTriageEnabled = false }
                    aiTriage.refreshStatus()
                    return
                }
                let result = AITriageEnableFlow.enable(service: aiTriage)
                if result.enabled {
                    appState.settings.update { $0.aiTriageEnabled = true }
                    appState.aiLastError = nil
                    appState.aiEngineStatus = result.status
                } else if let error = result.error {
                    appState.aiLastError = error
                    appState.aiEngineStatus = result.status
                }
            }
        )
    }
}
