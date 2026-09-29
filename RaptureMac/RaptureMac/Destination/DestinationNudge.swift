import Foundation

/// When the menu should offer to move notes off the default folder
/// (onboarding M3). Pure; the menu supplies the facts.
enum DestinationNudge {

    /// The vault to offer, or nil for no notice. Shown only when the notes go
    /// to the default folder, a reachable vault exists, and the question is
    /// neither settled (`dismissed`) nor about to be asked in the first-run
    /// window (`choicePending`).
    nonisolated static func vaultToOffer(
        outputFolder: URL?,
        defaultFolder: URL,
        detected: [DetectedDestination],
        dismissed: Bool,
        choicePending: Bool
    ) -> DetectedDestination? {
        guard !dismissed, !choicePending, isDefault(outputFolder, defaultFolder: defaultFolder) else { return nil }
        return detected.first { $0.isVault && $0.reachable }
    }

    nonisolated static func isDefault(_ folder: URL?, defaultFolder: URL) -> Bool {
        guard let folder else { return false }
        return OutputFolderMigrator.normalize(folder).path == OutputFolderMigrator.normalize(defaultFolder).path
    }
}
