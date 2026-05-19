import Foundation

/// Pure normalization for user-entered allowlist handles.
/// Returns `nil` when the input collapses to empty (so the UI can refuse to add it).
enum AllowlistInput {
    /// Trim whitespace, strip Apple's `E:` / `p:` prefix the same way `SelfHandleResolver.normalize` does,
    /// and drop empties. Does NOT lowercase or alter the inner value — `MessageFilter` already compares
    /// allowlist entries both raw and normalized.
    static func normalize(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let stripped: String
        if trimmed.count >= 2,
           let first = trimmed.first, first.isLetter,
           trimmed[trimmed.index(after: trimmed.startIndex)] == ":" {
            stripped = String(trimmed.dropFirst(2))
        } else {
            stripped = trimmed
        }
        return stripped.isEmpty ? nil : stripped
    }

    /// Append `value` to `existing` if (1) it normalizes to non-empty and (2) is not already a
    /// case-insensitive duplicate. Returns the updated array.
    static func appending(_ value: String, to existing: [String]) -> [String] {
        guard let cleaned = normalize(value) else { return existing }
        let lower = cleaned.lowercased()
        if existing.contains(where: { $0.lowercased() == lower }) {
            return existing
        }
        return existing + [cleaned]
    }
}
