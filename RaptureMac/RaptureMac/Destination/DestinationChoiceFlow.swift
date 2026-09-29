import Foundation

/// The first-run "where should your notes go?" answers (onboarding M2).
/// Capture never waits on this: the default folder already exists underneath
/// as a safety net, and a note filed there before the answer moves with the
/// rest when the user picks a place.
@MainActor
enum DestinationChoiceFlow {

    /// True when the choice window should be shown now: a fresh install still
    /// owes the question, and Full Disk Access is in place (step one first).
    static func shouldPresent(appState: AppState) -> Bool {
        appState.state.state.destinationChoicePending && appState.permissionState == .ok
    }

    /// "Keep the default" is a real answer: the question is settled for good,
    /// and the default-folder nudge never appears.
    static func keepDefault(appState: AppState) {
        appState.state.update {
            $0.destinationChoicePending = false
            $0.defaultDestinationNudgeDismissed = true
        }
    }

    /// Closing the window without answering: don't ask again at every launch,
    /// but leave the question open so the menu nudge can raise it later.
    static func dismiss(appState: AppState) {
        appState.state.update { $0.destinationChoicePending = false }
    }

    /// A place was picked: containment and move consent run as in Settings.
    /// The question counts as answered only when the folder actually changed
    /// (Cancel inside the flow leaves it open).
    static func choose(
        _ url: URL,
        appState: AppState,
        prompt: DestinationChangeFlow.ContainmentPrompt = DestinationPrompts.containment,
        consent: @escaping AppState.RelocationConsent = DestinationPrompts.consent
    ) async -> Bool {
        let before = appState.settings.settings.outputFolder?.standardizedFileURL
        await DestinationChangeFlow.change(to: url, appState: appState, prompt: prompt, consent: consent)
        let after = appState.settings.settings.outputFolder?.standardizedFileURL
        guard after != before else { return false }
        appState.state.update { $0.destinationChoicePending = false }
        return true
    }
}
