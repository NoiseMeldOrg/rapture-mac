import Foundation

/// The single source of truth for what both engines are asked to do — the
/// Anthropic engine sends `instructions` as its system prompt and the Apple
/// engine passes it as session instructions, so prompt tuning happens in one
/// place. Pure; input clipping is table-tested.
enum AITriagePrompt {
    /// AI sees at most this much of a capture. Way below `TriageProcessor`'s
    /// 10 MB sanity cap: a dictated note is short, and anything longer only
    /// needs its head to classify. When clipped, the validator refuses the
    /// formatted body (never "format" text the model didn't see).
    nonisolated static let maxInputChars = 6_000

    nonisolated static func clip(_ text: String) -> (text: String, truncated: Bool) {
        guard text.count > maxInputChars else { return (text, false) }
        return (String(text.prefix(maxInputChars)), true)
    }

    nonisolated static let instructions = """
    You process one dictated voice note captured by a note-taking app. Return only the requested fields.

    classification — exactly one of:
    - "task": an actionable to-do the author intends to act on (errands, calls, purchases, fixes, follow-ups). Usually imperative.
    - "idea": a product, project, content, or creative idea to explore or make ("video about…", "what if the app…").
    - "journal": an observation, feeling, reflection, gratitude, or recap of something that happened.
    - null: ambiguous, mixed, or none of the above. When unsure, use null — misfiling is worse than not classifying.

    title — 3 to 10 words. For tasks, a concise imperative ("Fix the garage door sensor"). Strip dictation filler ("um", "okay so", "note to self", "I just wanna say that"). Never invent content that is not in the note.

    formattedBody — the same words with light cleanup only: punctuation, capitalization, paragraph breaks. Never add, remove, summarize, or reorder content. If the note is already clean, return it unchanged.

    handoffs — at most one reminder and one event, and only when unambiguous:
    - reminder: the author explicitly asks to be reminded ("remind me to…", "remember to…", "don't forget…", "remind me at 5 to…"), or states a clearly dated personal errand.
    - event: the author states an appointment or meeting with an explicit day AND time.
    When in doubt, return no handoffs — the note still files either way. Each entry must carry the verbatim clause it came from, copied exactly from the note. Give date parts (year, month, day, hour, minute in the author's time zone) only when the note states them, resolved relative to the capture timestamp you are given; omit parts the note doesn't state. A reminder without a stated date is fine; an event needs the full date and time.
    """

    /// The per-capture message: the capture instant (with weekday, in the
    /// author's zone — so "tomorrow" and "Friday" resolve correctly even for a
    /// backlog note triaged days later) plus the clipped note text.
    nonisolated static func userMessage(text: String, capturedAt: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "EEEE yyyy-MM-dd HH:mm"
        let stamp = formatter.string(from: capturedAt)
        return """
        Captured: \(stamp) (\(timeZone.identifier))

        Note:
        \(text)
        """
    }
}
