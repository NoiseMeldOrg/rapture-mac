import Foundation
import Security

/// Seam for the app's first (and only) credential: the optional Anthropic API
/// key for the BYO-key AI engine. Tests inject `FakeCredentialStore`; the app
/// uses `KeychainStore`. The key lives in the macOS Keychain and NEVER in
/// settings.json — settings carry only the `aiTriageEnabled` toggle.
@MainActor
protocol CredentialStore: AnyObject {
    func anthropicAPIKey() -> String?
    /// nil deletes the stored key.
    func setAnthropicAPIKey(_ key: String?) throws
}

/// Generic-password item in the login keychain. An unsandboxed app reading its
/// own items prompts nothing. DEBUG builds use a separate service name, the
/// same isolation convention as the app-support container, so a Debug build
/// never reads or overwrites the installed app's key.
@MainActor
final class KeychainStore: CredentialStore {
    #if DEBUG
    nonisolated static let service = "noisemeld.RaptureMac.debug"
    #else
    nonisolated static let service = "noisemeld.RaptureMac"
    #endif
    nonisolated static let anthropicAccount = "anthropic-api-key"

    enum KeychainError: Error, LocalizedError {
        case unexpectedStatus(OSStatus)

        var errorDescription: String? {
            switch self {
            case .unexpectedStatus(let status):
                let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
                return "Keychain error: \(message)"
            }
        }
    }

    private let service: String
    /// Reads are cached so the per-capture path never does a keychain round trip;
    /// invalidated on every set.
    private var cached: String??

    /// - Parameter service: overridden only by the keychain round-trip test,
    ///   which uses a dedicated test service and cleans up after itself.
    init(service: String = KeychainStore.service) {
        self.service = service
    }

    func anthropicAPIKey() -> String? {
        if let cached { return cached }
        // Items the app wrote itself are readable without any UI. A *foreign*
        // item under this service/account (e.g. hand-planted via the `security`
        // CLI without granting this app ACL access) makes this call block on a
        // visible macOS authorization dialog until the user clicks Allow/Deny —
        // one-time, self-inflicted, and not reachable through the app's own
        // flows, so it's accepted rather than worked around (the legacy login
        // keychain has no supported non-interactive read for ACL'd items).
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: Self.anthropicAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            cached = .some(nil)
            return nil
        }
        let key = String(decoding: data, as: UTF8.self)
        cached = .some(key)
        return key
    }

    func setAnthropicAPIKey(_ key: String?) throws {
        cached = nil
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: Self.anthropicAccount
        ]
        // Delete-then-add is the simplest correct upsert; a missing item is fine.
        let deleteStatus = SecItemDelete(base as CFDictionary)
        guard deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(deleteStatus)
        }
        guard let key, !key.isEmpty else {
            cached = .some(nil)
            return
        }
        var add = base
        add[kSecValueData as String] = Data(key.utf8)
        // The app files captures while the screen is locked; the key must be
        // readable after first unlock — and must never sync off this device.
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainError.unexpectedStatus(addStatus)
        }
        cached = .some(key)
    }
}
