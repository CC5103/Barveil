// A tiny debounce/hysteresis layer between the raw decision and the menu-bar
// preference. The detectors are allowed to disagree for a sample or two while
// a browser enters/leaves fullscreen, while audio has a short gap, or while
// the AX tree briefly changes shape. Applying every raw flip is what made the
// menu bar flicker. This stabilizer only commits a new decision after it has
// survived a short, asymmetric window.

import Foundation

struct DecisionStabilizer {
    enum Update: Equatable {
        case none
        case pending(Decision)
        case cancelled(Decision)
        case applied(Decision)
    }

    /// A decision that hides the bar is allowed to take effect quickly.
    let hideStability: TimeInterval
    /// Showing again is the direction that caused most of the flicker, so it
    /// needs a slightly longer stable window. This is still much shorter than
    /// the old user-facing delay.
    let showStability: TimeInterval
    /// After any change, wait at least this long before considering another
    /// one. It prevents a hide → show → hide loop from animating repeatedly.
    let minimumDwell: TimeInterval

    private(set) var current: Decision
    private var candidate: Decision?
    private var candidateSince: Date?
    private var lastChangeAt: Date?

    init(
        initial: Decision,
        hideStability: TimeInterval = 0.15,
        showStability: TimeInterval = 0.20,
        minimumDwell: TimeInterval = 0.15,
    ) {
        current = initial
        self.hideStability = hideStability
        self.showStability = showStability
        self.minimumDwell = minimumDwell
    }

    /// Feeds one raw sample. Returns `.applied` only when the caller should
    /// actually change the system preference.
    mutating func update(proposed: Decision, at now: Date) -> Update {
        if proposed == current {
            if let candidate {
                self.candidate = nil
                candidateSince = nil
                return .cancelled(candidate)
            }
            return .none
        }

        if candidate != proposed {
            candidate = proposed
            candidateSince = now
            return .pending(proposed)
        }

        guard let candidateSince else { return .none }
        let required = proposed.shouldHide ? hideStability : showStability
        guard now.timeIntervalSince(candidateSince) >= required else { return .none }

        if let lastChangeAt, now.timeIntervalSince(lastChangeAt) < minimumDwell {
            return .none
        }

        current = proposed
        lastChangeAt = now
        candidate = nil
        self.candidateSince = nil
        return .applied(proposed)
    }

    /// Manual pins, mode changes and the first sample bypass the debounce and
    /// take effect immediately.
    @discardableResult
    mutating func force(_ decision: Decision, at now: Date) -> Decision {
        current = decision
        candidate = nil
        candidateSince = nil
        lastChangeAt = now
        return decision
    }
}
