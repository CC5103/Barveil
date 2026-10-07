// macOS tracks the user-facing app each process acts for. Safari's WebKit
// helpers resolve to Safari, Chrome's fullscreen window can be hosted by a
// helper, and two separate instances of the same app resolve to themselves.
// This is the same mechanism TCC uses to attribute permission prompts.
//
// The symbol is private but stable in libsystem_coreservices. It returns 0
// for untracked PIDs and the PID itself for non-delegating processes.

import Foundation

@_silgen_name("responsibility_get_pid_responsible_for_pid")
private func responsibilityPID(for pid: pid_t) -> pid_t

enum Responsibility {
    /// True when both PIDs belong to the same user-facing application.
    static func matches(_ a: pid_t, _ b: pid_t) -> Bool {
        if a == b { return true }
        let aResponsible = responsibilityPID(for: a)
        let bResponsible = responsibilityPID(for: b)
        if aResponsible > 0, aResponsible == b { return true }
        if bResponsible > 0, bResponsible == a { return true }
        if aResponsible > 0, bResponsible > 0, aResponsible == bResponsible {
            return true
        }
        return false
    }
}
