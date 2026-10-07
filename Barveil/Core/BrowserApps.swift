// Which apps count as browsers.
//
// Browsers are the one kind of app where "the window is fullscreen" and "the
// picture is fullscreen" look identical from the outside — both end up as a
// window covering the whole display. Geometry therefore can never decide the
// browser case on its own; `FullscreenDetector` has to look at the window's
// Accessibility tree instead, and without the Accessibility grant a browser
// window that fills the screen is deliberately left alone.

enum BrowserApps {
    /// Bundle-id prefixes, so the channels come along for free
    /// (Chrome Beta/Canary, Firefox Developer Edition, Safari Technology
    /// Preview, …).
    private static let prefixes = [
        "com.apple.Safari",
        "com.google.Chrome",
        "org.chromium.Chromium",
        "org.mozilla.firefox",
        "com.microsoft.edgemac",
        "company.thebrowser.Browser", // Arc
        "com.brave.Browser",
        "com.operasoftware.Opera",
        "com.vivaldi.Vivaldi",
        "com.kagi.kagimacOS", // Orion
        "io.github.ungoogled_software.ungoogled_chromium",
    ]

    static func isBrowser(_ bundleID: String?) -> Bool {
        guard let bundleID, !bundleID.isEmpty else { return false }
        return prefixes.contains { bundleID.hasPrefix($0) }
    }

    /// WebKit browsers: they present a fullscreen *picture* as its own dialog
    /// window.
    static func isWebKit(_ bundleID: String?) -> Bool {
        guard let bundleID, !bundleID.isEmpty else { return false }
        return bundleID.hasPrefix("com.apple.Safari") || bundleID.hasPrefix("com.apple.WebKit")
    }

    private static let chromiumPrefixes = [
        "com.google.Chrome",
        "org.chromium.Chromium",
        "com.microsoft.edgemac",
        "company.thebrowser.Browser", // Arc
        "com.brave.Browser",
        "com.operasoftware.Opera",
        "com.vivaldi.Vivaldi",
        "io.github.ungoogled_software.ungoogled_chromium",
    ]

    /// Chromium browsers are the family whose Now Playing / media-session
    /// state is available through MediaRemote before their `Playing audio`
    /// power assertion flips on pause.
    static func isChromium(_ bundleID: String?) -> Bool {
        guard let bundleID, !bundleID.isEmpty else { return false }
        return chromiumPrefixes.contains { bundleID.hasPrefix($0) }
    }

    /// WebKit and Chromium publish power assertions that disappear as soon as
    /// media pauses, so playback detection can bypass the stale CoreAudio
    /// "running output" flag.
    static func usesMediaPlaybackAssertion(_ bundleID: String?) -> Bool {
        isWebKit(bundleID) || isChromium(bundleID)
    }
}
