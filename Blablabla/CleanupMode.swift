import Foundation

enum CleanupMode: String, CaseIterable, Identifiable {
    /// Insert raw STT output verbatim. Fastest path.
    case off
    /// Regex-based filler removal. ~Microseconds. Handles 80% of LLM gain.
    case fast
    /// Full LLM cleanup via the selected local model. ~500-1500ms but smartest.
    case full

    var id: String { rawValue }

    static let storageKey = "blabla.cleanupMode"

    var label: String {
        switch self {
        case .off:  return "Off"
        case .fast: return "Fast"
        case .full: return "Full"
        }
    }

    var hint: String {
        switch self {
        case .off:  return "Inserts Parakeet's raw transcript. Fastest."
        case .fast: return "Strips filler words with simple rules. No added delay."
        case .full: return "An on-device LLM fixes recognition errors, punctuation and fillers. Adds about a second."
        }
    }
}
