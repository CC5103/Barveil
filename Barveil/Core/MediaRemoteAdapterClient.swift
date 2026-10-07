// Streams Now Playing state from the vendored mediaremote-adapter.
//
// The adapter is launched through /usr/bin/perl; that process is on Apple's
// MediaRemote allowlist, unlike an ordinary unentitled Swift binary. The perl
// script loads the bundled MediaRemoteAdapter.framework and writes one JSON
// object per line. This is the same technique houdini uses.

import Foundation
import os

struct MediaRemoteAdapterSnapshot: Equatable, Sendable {
    var playing: Bool
    var pid: pid_t?
    var bundleID: String?
    var parentBundleID: String?
    var updatedAt: Date
}

final class MediaRemoteAdapterClient: @unchecked Sendable {
    var onSnapshot: (@Sendable (MediaRemoteAdapterSnapshot) -> Void)?

    private let logger = Logger(subsystem: "app.barveil.Barveil", category: "media-remote")
    private let lock = NSLock()
    private let restartQueue = DispatchQueue(label: "app.barveil.media-remote.restart")
    private var process: Process?
    private var buffer = Data()
    private var stopping = false

    func start() {
        lock.lock()
        if process != nil {
            lock.unlock()
            return
        }
        stopping = false
        lock.unlock()

        guard let script = Bundle.main.url(
            forResource: "mediaremote-adapter",
            withExtension: "pl",
        ),
              let framework = Bundle.main.url(
                  forResource: "MediaRemoteAdapter",
                  withExtension: "framework",
              )
        else {
            logger.debug("adapter resources missing; falling back to direct MediaRemote")
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [
            script.path,
            framework.path,
            "stream",
            "--no-diff",
            "--debounce=100",
            "--no-artwork",
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
            self.logger.debug("adapter exited status=\(process.terminationStatus)")
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
            logger.debug("adapter started")
        } catch {
            logger.error("adapter failed: \(error.localizedDescription)")
            lock.lock()
            let shouldRestart = !stopping
            lock.unlock()
            if shouldRestart {
                scheduleRestart()
            }
        }
    }

    /// True while the bundled adapter stream is alive. The WebKit pause
    /// override is only trusted while a live adapter can still correct it.
    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return process != nil
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

    private func ingest(_ data: Data) {
        var lines: [String] = []
        lock.lock()
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[..<newline]
            buffer.removeSubrange(...newline)
            if let line = String(data: lineData, encoding: .utf8) {
                lines.append(line)
            }
        }
        lock.unlock()

        for line in lines {
            guard let snapshot = Self.parse(line) else { continue }
            onSnapshot?(snapshot)
        }
    }

    /// Pure JSON-line parser, pinned by `MediaRemoteAdapterClientTests`.
    nonisolated static func parse(_ line: String) -> MediaRemoteAdapterSnapshot? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["type"] as? String == "data",
              let payload = object["payload"] as? [String: Any],
              payload["playing"] != nil
        else { return nil }

        let playing = payload["playing"] as? Bool ?? false
        let pid = (payload["processIdentifier"] as? NSNumber)?.int32Value
        let bundle = payload["bundleIdentifier"] as? String
        let parent = payload["parentApplicationBundleIdentifier"] as? String
        return MediaRemoteAdapterSnapshot(
            playing: playing,
            pid: pid.map { pid_t($0) },
            bundleID: bundle,
            parentBundleID: parent,
            updatedAt: Date(),
        )
    }
}
