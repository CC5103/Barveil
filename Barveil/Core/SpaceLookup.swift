// WindowServer's private Space API.
//
// `CGWindowListCopyWindowInfo(.optionOnScreenOnly)` intentionally omits
// windows that live on another Space, which is what keeps a fullscreen video
// on a background Space from hiding the menu bar. Some players (IINA/mpv in
// particular) put their fullscreen surface into a window that is also absent
// from that list even though it is the one the user is looking at.
//
// `.optionAll` returns those windows, and SkyLight can tell which Space each
// one belongs to. Asking for one window at a time avoids the API's ambiguous
// flat result when some of the requested windows have no Space at all.
//
// The API is private, so it is used only as an additional filter: when the
// framework or a call is unavailable the detector falls back to the previous
// on-screen-only behaviour.

import CoreGraphics
import Darwin
import Foundation

final class SpaceLookup: @unchecked Sendable {
    static let shared = SpaceLookup()

    private typealias MainConnectionFunction = @convention(c) () -> Int32
    private typealias ActiveSpaceFunction = @convention(c) (Int32) -> UInt64
    private typealias SpacesForWindowsFunction = @convention(c) (Int32, UInt32, CFArray) -> CFArray?
    private typealias ManagedDisplaySpacesFunction = @convention(c) (Int32) -> CFArray?
    private typealias WindowsForSpaceFunction = @convention(c) (
        Int32, UInt32, CFArray, UInt32, UnsafeMutablePointer<UInt64>?, UnsafeMutablePointer<UInt64>?
    ) -> CFArray?

    /// `kCGSSpaceAll` — ask for the window's Space on every display/desktop.
    private static let allSpacesMask: UInt32 = 0x7

    private let handle: UnsafeMutableRawPointer?
    private let mainConnection: MainConnectionFunction?
    private let activeSpace: ActiveSpaceFunction?
    private let spacesForWindows: SpacesForWindowsFunction?
    private let windowsForSpace: WindowsForSpaceFunction?
    private let managedDisplaySpaces: ManagedDisplaySpacesFunction?

    private let lock = NSLock()
    private var cache: [CGWindowID: (onActiveSpace: Bool, at: Date)] = [:]
    private let cacheDuration: TimeInterval = 0.25

    private init() {
        let handle = dlopen(
            "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
            RTLD_NOW | RTLD_LOCAL,
        )
        self.handle = handle
        mainConnection = Self.load(handle, name: "SLSMainConnectionID")
        activeSpace = Self.load(handle, name: "SLSGetActiveSpace")
        spacesForWindows = Self.load(handle, name: "SLSCopySpacesForWindows")
        windowsForSpace = Self.load(handle, name: "SLSCopyWindowsWithOptionsAndTags")
        managedDisplaySpaces = Self.load(handle, name: "CGSCopyManagedDisplaySpaces")
    }

    deinit {
        if let handle {
            dlclose(handle)
        }
    }

    /// The active Space's ID, or `nil` when the private API is unavailable.
    func activeSpaceID() -> UInt64? {
        guard let mainConnection, let activeSpace else { return nil }
        let space = activeSpace(mainConnection())
        return space > 0 ? space : nil
    }

    /// Every Space the window belongs to. Menu bar windows are per-Space, so
    /// this is how a sliding bar window is mapped back to its Space.
    func spaceIDs(forWindow windowNumber: CGWindowID) -> [UInt64]? {
        guard windowNumber > 0,
              let mainConnection,
              let spacesForWindows
        else { return nil }
        let number = NSNumber(value: windowNumber)
        guard let spaces = spacesForWindows(
            mainConnection(),
            Self.allSpacesMask,
            [number] as CFArray,
        ) as? [NSNumber] else { return nil }
        return spaces.map(\.uint64Value)
    }

    /// The ordered Space list of the display that holds the active Space.
    /// Order is what maps a slide direction onto a destination.
    func orderedSpaces() -> [(id: UInt64, type: Int)]? {
        guard let mainConnection, let managedDisplaySpaces else { return nil }
        guard let displays = managedDisplaySpaces(mainConnection()) as? [[String: Any]] else { return nil }
        let active = activeSpaceID()
        var fallback: [(id: UInt64, type: Int)]?
        for display in displays {
            let spaces = (display["Spaces"] as? [[String: Any]]) ?? []
            let parsed: [(id: UInt64, type: Int)] = spaces.compactMap {
                guard let id = ($0["ManagedSpaceID"] as? NSNumber)?.uint64Value else { return nil }
                let type = ($0["type"] as? NSNumber)?.intValue ?? -1
                return (id, type)
            }
            guard !parsed.isEmpty else { continue }
            if let active, parsed.contains(where: { $0.id == active }) {
                return parsed
            }
            if fallback == nil { fallback = parsed }
        }
        return fallback
    }

    /// The Space next to `space` in `direction` (+1 right, -1 left).
    nonisolated static func neighbour(
        of space: UInt64,
        direction: Int,
        in spaces: [(id: UInt64, type: Int)],
    ) -> (id: UInt64, type: Int)? {
        guard let index = spaces.firstIndex(where: { $0.id == space }) else { return nil }
        let next = index + (direction > 0 ? 1 : -1)
        guard spaces.indices.contains(next) else { return nil }
        return spaces[next]
    }

    /// Every window of a Space. WindowServer keeps this list for inactive
    /// Spaces too, which is what lets Barveil resolve a destination Space's
    /// owning app before that Space is on screen.
    func spaceWindows(_ space: UInt64) -> [CGWindowID]? {
        guard space > 0, let mainConnection, let windowsForSpace else { return nil }
        var setTags: UInt64 = 0
        var clearTags: UInt64 = 0
        let spaceNumber = NSNumber(value: space)
        guard let raw = windowsForSpace(
            mainConnection(),
            0,
            [spaceNumber] as CFArray,
            Self.allSpacesMask,
            &setTags,
            &clearTags,
        ) as? [NSNumber] else { return nil }
        return raw.map { CGWindowID($0.uint32Value) }
    }

    /// The menu bar window that belongs to a Space. WindowServer keeps one
    /// per Space, and several of them can be parked at x = 0 at the same
    /// time, so “the bar at the centre” is not unique — the Space's own
    /// window list is.
    func barWindowID(ofSpace space: UInt64) -> Int? {
        guard let ids = spaceWindows(space), !ids.isEmpty else { return nil }
        let wanted = Set(ids.map { Int($0) })
        let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
        for window in list {
            guard let number = window[kCGWindowNumber as String] as? Int, wanted.contains(number) else { continue }
            guard (window[kCGWindowLayer as String] as? Int ?? 0) == 24 else { continue }
            return number
        }
        return nil
    }

    /// The process that owns a Space, taken from its largest normal window.
    /// A fullscreen Space has exactly one such window, so this identifies the
    /// app without having visited the Space first.
    func ownerPID(ofSpace space: UInt64) -> pid_t? {
        guard let ids = spaceWindows(space), !ids.isEmpty else { return nil }
        let wanted = Set(ids.map { Int($0) })
        let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
        var best: (area: CGFloat, pid: pid_t)?
        for window in list {
            guard let number = window[kCGWindowNumber as String] as? Int, wanted.contains(number) else { continue }
            guard (window[kCGWindowLayer as String] as? Int ?? 0) == 0 else { continue }
            guard let raw = window[kCGWindowOwnerPID as String] as? Int, raw > 0 else { continue }
            let bounds = window[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
            let area = (bounds["Width"] ?? 0) * (bounds["Height"] ?? 0)
            if best == nil || area > best!.area {
                best = (area, pid_t(raw))
            }
        }
        return best?.pid
    }

    /// `nil` means the private API could not answer; `false` means the window
    /// is known not to be on the active Space.
    func isWindowOnActiveSpace(_ windowNumber: CGWindowID, now: Date = Date()) -> Bool? {
        guard windowNumber > 0,
              let mainConnection,
              let activeSpace,
              let spacesForWindows
        else { return nil }

        lock.lock()
        if let cached = cache[windowNumber],
           now.timeIntervalSince(cached.at) < cacheDuration
        {
            lock.unlock()
            return cached.onActiveSpace
        }
        lock.unlock()

        let connection = mainConnection()
        let active = activeSpace(connection)
        let number = NSNumber(value: windowNumber)
        guard let spaces = spacesForWindows(
            connection,
            Self.allSpacesMask,
            [number] as CFArray,
        ) as? [NSNumber] else {
            return nil
        }

        let onActiveSpace = spaces.contains { $0.uint64Value == active }
        lock.lock()
        cache[windowNumber] = (onActiveSpace, now)
        lock.unlock()
        return onActiveSpace
    }

    private static func load<T>(_ handle: UnsafeMutableRawPointer?, name: String) -> T? {
        guard let handle, let symbol = dlsym(handle, name) else { return nil }
        return unsafeBitCast(symbol, to: T.self)
    }
}
