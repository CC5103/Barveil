// Keeps the menu-bar decision stable while the user is moving between two
// fullscreen Spaces.
//
// A real trackpad swipe is not a single atomic Dock event: AppKit can report
// the incoming front app before Dock refreshes the owner, and the browser/AX
// picture confirmation can flip for several samples during the animation.
// Evaluating normally during that window is what produced the visible
// "three beats": the incoming fullscreen window briefly shows its menu bar,
// the old decision hides it again, and the settled decision shows it once
// more.
//
// The lock commits the first destination decision *immediately* — the
// incoming Space's menu bar has already been re-evaluated from the new
// (global) preference by the time the animation ends, so waiting for a
// stability window only guarantees that the bar is corrected late, which the
// user perceives as a spaced-out second and third beat. Afterwards the lock
// holds the decision until the destination has been stable for a short
// window, so the transient flips that happen while the Space is still
// settling cannot push a second write through. A maximum hold guarantees the
// lock always releases.

import Foundation

struct SpaceHopLock {
    let minHold: TimeInterval
    let stableWindow: TimeInterval
    let maxHold: TimeInterval

    private var startedAt: Date?
    private var deadline: Date?
    private var signature: String?
    private var stableSince: Date?
    private var initialCommitPending = false

    init(
        minHold: TimeInterval = 0.35,
        stableWindow: TimeInterval = 0.30,
        maxHold: TimeInterval = 1.5,
    ) {
        self.minHold = minHold
        self.stableWindow = stableWindow
        self.maxHold = maxHold
    }

    var isActive: Bool {
        deadline != nil
    }

    /// True while the first (destination) decision still has to be applied.
    var needsInitialCommit: Bool {
        isActive && initialCommitPending
    }

    mutating func begin(at now: Date) {
        startedAt = now
        deadline = now.addingTimeInterval(maxHold)
        signature = nil
        stableSince = now
        initialCommitPending = true
    }

    /// Starts the lock only when no hop is in flight. The fast provisional
    /// path may already have started (and pre-committed) this hop, so the
    /// later full sample must not restart the stability window.
    mutating func beginIfIdle(at now: Date) {
        guard !isActive else { return }
        begin(at: now)
    }

    /// Marks the destination decision as committed. The lock stays active so
    /// the settling window can still veto a follow-up write.
    mutating func markInitialCommitDone() {
        initialCommitPending = false
    }

    /// Feed the current destination signature. Returns true once when the
    /// lock should be released and the final decision committed.
    mutating func observe(signature newSignature: String, at now: Date) -> Bool {
        guard let startedAt, let deadline else { return false }

        if signature != newSignature {
            signature = newSignature
            stableSince = now
        }

        if now >= deadline {
            clear()
            return true
        }

        let elapsed = now.timeIntervalSince(startedAt)
        if elapsed >= minHold,
           let stableSince,
           now.timeIntervalSince(stableSince) >= stableWindow
        {
            clear()
            return true
        }

        return false
    }

    mutating func clear() {
        startedAt = nil
        deadline = nil
        signature = nil
        stableSince = nil
        initialCommitPending = false
    }
}
