import Foundation

enum CleanupMode: String, CaseIterable, Identifiable {
    /// Insert raw STT output verbatim. Fastest path.
    case off
    /// Regex-based filler removal. ~Microseconds. Handles 80% of LLM gain.
    case fast
    /// Full LLM cleanup via Qwen3.5-4B. ~500-1500ms but smartest.
    case full

    var id: String { rawValue }

    static let storageKey = "blabla.cleanupMode"

    var label: String {
        switch self {
        case .off:  return "Off — Parakeet only"
        case .fast: return "Fast — regex"
        case .full: return "Full — LLM (Qwen3.5 4B)"
        }
    }

    var hint: String {
        switch self {
        case .off:  return "Insert raw recognition output, no cleanup. Fastest."
        case .fast: return "Strip common filler words via regex. Near-zero overhead."
        case .full: return "Deep cleanup via local 4B LLM. Adds ~1 second."
        }
    }
}
