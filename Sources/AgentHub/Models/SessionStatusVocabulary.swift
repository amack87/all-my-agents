import Foundation

/// The session status vocabulary, shared with the web server and the web app.
///
/// The server emits five statuses — `needsInput`, `working`, `idle`, `ended`
/// and `unknown`. The canonical list lives in
/// `contract/status-vocabulary.json` so the two apps cannot drift apart; see
/// `Tests/AllMyAgentsTests/StatusVocabularyContractTests.swift` and
/// `web/test/contract.test.js`.
extension ClaudeSession.SessionStatus {
    /// The wire form the server speaks.
    var wireValue: String {
        switch self {
        case .working: return "working"
        case .needsInput: return "needsInput"
        case .idle: return "idle"
        case .ended: return "ended"
        case .unknown: return "unknown"
        }
    }

    /// Coerce a wire value into a status. Anything the server does not speak
    /// becomes `.unknown`.
    init(wire: String?) {
        switch wire {
        case "working": self = .working
        case "needsInput": self = .needsInput
        case "idle": self = .idle
        case "ended": self = .ended
        default: self = .unknown
        }
    }

    /// The human-facing label, matching the web app's wording.
    var label: String {
        switch self {
        case .needsInput: return "needs input"
        case .working: return "working"
        case .idle: return "idle"
        case .ended: return "ended"
        case .unknown: return "unknown"
        }
    }
}
