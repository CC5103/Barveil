// Subscribes to Dock's `dock-visibility` log channel as the authoritative
// source of "is the active Space a native fullscreen Space, and which PID owns
// it".
//
// This is the approach used by houdini and it solves the Space-switch flicker
// structurally: on an FS↔FS hop Dock emits only a "Skipping no-op state update"
// pulse, so we refresh the owner and re-evaluate the decision but *never write*
// `AppleMenuBarVisibleInFullscreen` or post its distributed notification. The
// menu bar therefore never re-animates during the hand-off.
//
// `/usr/bin/log stream` is a public command and needs no entitlement.

import Foundation
import os

struct DockFullScreenState: Equatable, Sendable {
    var isFullScreen: Bool
    var ownerPID: pid_t?
    var title: String?
    /// The WindowServer Space id (`space=CGSSpace(spid: N)`) when Dock
    /// reported one; used to map menu bar windows back to their Space.
    var spaceID: UInt64?

    static let initial = DockFullScreenState(
        isFullScreen: false,
        ownerPID: nil,
        title: nil,
        spaceID: nil,
    )
}

enum DockSpaceEvent: Equatable, Sendable {
    /// FS entry or exit: carries the active Space's fullscreen flag and, on
    /// entry, the owning process and window title.
    case fullScreen(DockFullScreenState)
    /// A silent FS↔FS hop. Refresh the cached owner; do not write the pref.
    case staySpaceChange
    /// FS → Desktop arrival; the bar must be restored exactly once.
    case desktopArrival
}

final class DockSpaceMonitor: @unchecked Sendable {
    var onEvent: (@Sendable (DockSpaceEvent) -> Void)?

    /// The same private-but-readable channel houdini uses. The three strings
    /// are the only Dock visibility events that matter to us.
    private static let predicate = """
    subsystem == "com.apple.dock" \
    AND category == "dock-visibility" \
    AND (eventMessage CONTAINS "Space Forces Hidden:" \
    OR eventMessage CONTAINS "Skipping no-op state update" \
    OR eventMessage CONTAINS "Will Force Update Rect")
    """

    private let logger = Logger(subsystem: "app.barveil.Barveil", category: "dock-space")
    private let lock = NSLock()
    private let restartQueue = DispatchQueue(label: "app.barveil.dock-space.restart")
    private var process: Process?
    private var buffer = Data()
    private var stopping = false

    func start() {
        lock.lock()
        guard process == nil else {
            lock.unlock()
            return
        }
        stopping = false
        lock.unlock()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        process.arguments = [
            "stream",
            "--level", "debug",
            "--style", "compact",
            "--predicate", Self.predicate,
        ]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.ingest(data)
        }

        process.terminationHandler = { [weak self] process in
            guard let self else { return }
            self.logger.debug("dock-space monitor exited status=\(process.terminationStatus)")
            self.lock.lock()
            let shouldRestart = !self.stopping
            self.process = nil
            self.buffer.removeAll()
            self.lock.unlock()
            if shouldRestart {
                self.scheduleRestart()
            }
        }

        do {
            try process.run()
            lock.lock()
            self.process = process
            lock.unlock()
            logger.debug("dock-space monitor started")
            primeFromHistory()
        } catch {
            logger.error("dock-space monitor failed: \(error.localizedDescription)")
            lock.lock()
            let shouldRestart = !stopping
            lock.unlock()
            if shouldRestart {
                scheduleRestart()
            }
        }
    }

    func stop() {
        lock.lock()
        stopping = true
        let process = self.process
        self.process = nil
        buffer.removeAll()
        lock.unlock()
        process?.terminate()
    }

    private func scheduleRestart() {
        restartQueue.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let shouldStart = !self.stopping && self.process == nil
            self.lock.unlock()
            if shouldStart {
                self.start()
            }
        }
    }

    /// Dock only emits events on transitions, so a process launched while the
    /// user is already in a fullscreen Space would otherwise stay on the
    /// "no state yet" fallback until the next swipe. Read recent history once
    /// and emit the latest state.
    private func primeFromHistory() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
            process.arguments = [
                "show",
                "--last", "10m",
                "--style", "compact",
                "--predicate", Self.predicate,
            ]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice

            do {
                try process.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let text = String(data: data, encoding: .utf8) ?? ""
                var state: DockFullScreenState?
                for line in text.split(separator: "\n") {
                    guard let event = Self.parse(String(line)) else { continue }
                    switch event {
                    case .fullScreen(let parsed):
                        state = parsed
                    case .desktopArrival:
                        state = .initial
                    case .staySpaceChange:
                        break
                    }
                }
                if let state {
                    self.onEvent?(.fullScreen(state))
                }
            } catch {
                self.logger.debug("dock-space history prime failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Parsing

    private func ingest(_ data: Data) {
        var complete: [String] = []
        lock.lock()
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[..<newline]
            buffer.removeSubrange(...newline)
            if let line = String(data: lineData, encoding: .utf8) {
                complete.append(line)
            }
        }
        lock.unlock()

        for line in complete {
            guard let event = Self.parse(line) else { continue }
            onEvent?(event)
        }
    }

    /// Pure parser, pinned by `DockSpaceMonitorTests`.
    nonisolated static func parse(_ line: String) -> DockSpaceEvent? {
        if line.contains("Skipping no-op state update") {
            return .staySpaceChange
        }
        if line.contains("Will Force Update Rect") {
            return .desktopArrival
        }

        let isFullScreen: Bool
        if line.contains("fullscreen=true") {
            isFullScreen = true
        } else if line.contains("fullscreen=false") {
            isFullScreen = false
        } else {
            return nil
        }

        var ownerPID: pid_t?
        if let match = line.range(of: #"\bpid=\d+"#, options: .regularExpression) {
            let digits = line[match].dropFirst("pid=".count)
            if let raw = pid_t(digits), raw > 0 {
                ownerPID = raw
            }
        }

        var spaceID: UInt64?
        if let match = line.range(of: #"fullscreen=(?:true|false) space=CGSSpace\(spid: \d+\)"#, options: .regularExpression) {
            let chunk = line[match]
            if let digits = chunk.range(of: #"\d+"#, options: .regularExpression),
               let raw = UInt64(chunk[digits])
            {
                spaceID = raw
            }
        }

        var title: String?
        if isFullScreen,
           let nameStart = line.range(of: " name="),
           let nameEnd = line.range(
               of: " space=CGSSpace",
               range: nameStart.upperBound ..< line.endIndex,
           )
        {
            let raw = line[nameStart.upperBound ..< nameEnd.lowerBound]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            title = raw.isEmpty ? nil : raw
        }

        return .fullScreen(DockFullScreenState(
            isFullScreen: isFullScreen,
            ownerPID: ownerPID,
            title: title,
            spaceID: spaceID,
        ))
    }
}
