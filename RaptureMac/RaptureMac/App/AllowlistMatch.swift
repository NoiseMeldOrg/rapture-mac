import Foundation

/// Phone-number-aware matching for allowlist entries. chat.db stores phone
/// handles in E.164 (`+15555550123`), but people type numbers the way they
/// read them: `(555) 555-0123`, `555.555.0123`, `+1 555 555 0123`. Before
/// 1.0.126 such an entry was saved as typed and silently never matched.
enum AllowlistMatch {
    /// Minimum digits for the trailing-digits match: a full national number.
    nonisolated static let minimumNationalDigits = 10

    /// The digits of `value` when it looks like a phone number (only digits
    /// and phone punctuation, at least 7 digits); nil for emails and anything else.
    nonisolated static func phoneDigits(_ value: String) -> String? {
        let allowed = CharacterSet(charactersIn: "0123456789+-(). \u{00A0}")
        guard !value.isEmpty, value.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        let digits = value.filter(\.isNumber)
        return digits.count >= 7 ? digits : nil
    }

    /// True when both values are phone numbers for the same line: identical
    /// digits, or one is the other plus a country code (`5555550123` vs
    /// `15555550123`) with at least a full national number in common.
    nonisolated static func phonesMatch(_ a: String, _ b: String) -> Bool {
        guard let da = phoneDigits(a), let db = phoneDigits(b) else { return false }
        if da == db { return true }
        let (short, long) = da.count < db.count ? (da, db) : (db, da)
        return short.count >= minimumNationalDigits && long.hasSuffix(short)
    }

    /// The form an entry is saved in: phone numbers lose their punctuation
    /// (keeping a leading `+`), everything else is left as typed.
    nonisolated static func canonical(_ value: String) -> String {
        guard let digits = phoneDigits(value) else { return value }
        return value.trimmingCharacters(in: .whitespaces).hasPrefix("+") ? "+" + digits : digits
    }

    /// True when `value` is a phone number or an email address, the two
    /// things an iMessage sender can be.
    nonisolated static func looksLikeHandle(_ value: String) -> Bool {
        if phoneDigits(value) != nil { return true }
        let parts = value.split(separator: "@")
        return parts.count == 2 && !parts[0].isEmpty && parts[1].contains(".") && !value.contains(" ")
    }
}
