// A short, human-readable trail of what Barveil decided and why. The panel
// shows it, the unified log gets the same lines under
// subsystem matching the app bundle identifier.

import Foundation
import os

struct DiagnosticEvent: Identifiable, Equatable, Sendable {
    let id: UUID
    let date: Date
    let tag: String
    let detail: String

    init(id: UUID = UUID(), date: Date = Date(), tag: String, detail: String) {
        self.id = id
        self.date = date
        self.tag = tag
        self.detail = detail
    }
}

@MainActor
final class Diagnostics {
    private static let limit = 30

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "app.barveil.Barveil", category: "controller")
    private(set) var events: [DiagnosticEvent] = []

    func record(_ tag: String, _ detail: String = "") {
        events.insert(DiagnosticEvent(tag: tag, detail: detail), at: 0)
        if events.count > Self.limit {
            events.removeLast(events.count - Self.limit)
        }
        logger.debug("\(tag, privacy: .public) \(detail, privacy: .public)")
    }

    func clear() {
        events.removeAll()
    }

    var exportText: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return events
            .reversed()
            .map { "\(formatter.string(from: $0.date))  \($0.tag)  \($0.detail)" }
            .joined(separator: "\n")
    }
}
