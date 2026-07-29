import Foundation

/// Shared notion of "content-free" capture text.
///
/// iMessage represents an attachment inside a message's text as U+FFFC OBJECT
/// REPLACEMENT CHARACTER, so an attachment-only message decodes to "\u{FFFC}" —
/// a string that is neither empty nor whitespace. Every gate that asks "is
/// there anything dictated here?" must see through that placeholder (and its
/// invisible relatives), or content-free captures leak downstream: on
/// 2026-07-25 a lone U+FFFC passed the AI tier's plain-trim emptiness guard,
/// and the model — given nothing to work from — echoed the prompt's example
/// title back as a task. Pure, table-tested.
enum CaptureText {

    /// True when `scalar` renders as nothing (or as a placeholder box) and
    /// carries no dictated content: U+FFFC and the interlinear annotation
    /// controls beside it, variation selectors, and format-category characters
    /// (ZWJ, zero-width space, BOM, directional marks).
    nonisolated static func isInvisible(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0xFFFC, 0xFFF9...0xFFFB, 0xFE00...0xFE0F:
            return true
        default:
            return scalar.properties.generalCategory == .format
        }
    }

    /// `text` with invisible scalars removed; visible content is untouched.
    /// For emptiness gates and titles/filenames — never for note bodies, which
    /// stay verbatim.
    nonisolated static func strippingInvisibles(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: isInvisible) else { return text }
        return String(String.UnicodeScalarView(text.unicodeScalars.filter { !isInvisible($0) }))
    }

    /// True when nothing dictated remains after dropping invisible scalars and
    /// trimming whitespace.
    nonisolated static func isContentFree(_ text: String) -> Bool {
        strippingInvisibles(text)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
    }
}
