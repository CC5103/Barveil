// Ties the pieces together: sample → stabilise → apply → tell the UI.
//
// The raw detectors can briefly disagree while a browser enters or leaves
// fullscreen, while audio has a short gap, or while the AX tree changes
// shape. `DecisionStabilizer` requires a new decision to survive a short
// asymmetric window before the menu bar is touched, which removes the
// flicker without adding a visible show delay.

import AppKit
import Combine
import Foundation

@MainActor
final class AppModel: ObservableObject {
    @MainActor static let shared = AppModel()

    let preferences: Preferences

    private let veil: VeilController
    private let engine: DetectionEngine
    private let hotkey = HotkeyMonitor()
    private let diagnostics = Diagnostics()

    @Published private(set) var isHidingNow = false
    @Published private(set) var decision: Decision = .show(.disabled)
    @Published private(set) var sample: DetectionEngine.Sample?
    @Published private(set) var recentEvents: [DiagnosticEvent] = []
    @Published private(set) var hotkeyRegistered = false
    @Published private(set) var accessibilityTrusted = AccessibilityPermission.isTrusted
    @Published private(set) var launchAtLogin = LoginItem.isEnabled
    @Published var errorMessage: String?
    @Published var isRecordingHotkey = false

    private var pin: ManualPin = .none
    private var pinnedBundleID: String?
    private var stabilizer = DecisionStabilizer(initial: .show(.disabled))
    private var forceNextDecision = true
    private var lastFrontBundleID: String?
    private var transitionGuard = FullscreenTransitionGuard()
    private let dockSpace = DockSpaceMonitor()
    private var dockState: DockFullScreenState?
    private var spaceHopLock = SpaceHopLock()
    /// Last settled decision per process, used to correct the incoming
    /// Space's menu bar before its animation ends.
    private var rememberedDecisions: [pid_t: (decision: Decision, at: Date)] = [:]
    /// Decisions remembered per *Space*: the same app can behave differently
    /// in two of its Spaces (a Safari video fullscreen hides the bar, the
    /// same Safari window in window-fullscreen shows it), so the slide path
    /// must not answer from a per-process memory.
    private var rememberedSpaceDecisions: [UInt64: (decision: Decision, at: Date)] = [:]
    private let slideWatcher = SpaceSlideWatcher()
    /// Menu bar window -> Space id, learned whenever a slide settles.
    /// Space id -> owning process, learned from Dock's fullscreen events and
    /// from every settled Space.
    private var spaceOwners: [UInt64: pid_t] = [:]
    private var activeBarWindowSpace: UInt64?
    private var currentSpaceID: UInt64?
    /// The most recent Safari window-fullscreen Space. It is the return target
    /// when the first FS↔FS pulse does not carry a slide-watcher prediction.
    private var returnSpaceID: UInt64?
    private var cancellables: Set<AnyCancellable> = []
    private var started = false
    private var appliedHotkey: (enabled: Bool, chord: HotkeyMonitor.Chord)?
    private var hasShownAccessibilityAlert = false
    private var lastFullscreenDetail: String?
    private var activationObserver: NSObjectProtocol?
    private var accessibilityNotificationObserver: NSObjectProtocol?

    #if DEBUG
    private var previewExcludedBundleID: String?
    private var previewUseAccessibility: Bool?
    @Published private var previewEnabledOverride: Bool?
    private var previewCompletedOnboarding = false
    #endif

    init(defaults: UserDefaults = .standard) {
        LegacyDefaultsMigration.migrateIfNeeded(into: defaults)
        let preferences = Preferences(defaults: defaults)
        self.preferences = preferences
        veil = VeilController(defaults: defaults)
        engine = DetectionEngine(preferences: preferences)
    }

    // MARK: - Lifecycle

    func start() {
        guard !started else { return }
        started = true

        engine.onSample = { [weak self] sample in
            MainActor.assumeIsolated {
                self?.handle(sample: sample)
            }
        }
        engine.onFastFrontAppChange = { [weak self] app in
            MainActor.assumeIsolated {
                self?.handleFastFrontAppChange(app)
            }
        }
        engine.start()

        slideWatcher.onIncoming = { [weak self] windowID, direction in
            MainActor.assumeIsolated {
                self?.handleSlideStart(windowID: windowID, direction: direction)
            }
        }

        dockSpace.onEvent = { [weak self] event in
            Task { @MainActor in
                self?.handleDockSpace(event)
            }
        }
        dockSpace.start()

        // Permission state can be stale immediately after the user changes
        // the system switch. Refresh whenever Barveil becomes active again.
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main,
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshAccessibilityStatus()
            }
        }

        // macOS posts this when any app's Accessibility consent changes. It is
        // undocumented and can arrive before AXIsProcessTrusted reflects the
        // new value, so wait briefly; the privacy page keeps a 1s fallback poll.
        accessibilityNotificationObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.accessibility.api"),
            object: nil,
            queue: .main,
        ) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                MainActor.assumeIsolated {
                    self?.refreshAccessibilityStatus()
                }
            }
        }

        hotkey.onPress = { [weak self] in
            Task { @MainActor in
                self?.togglePinned()
            }
        }
        applyHotkeyConfiguration(force: true)

        preferences.objectWillChange
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.preferencesChanged()
                }
            }
            .store(in: &cancellables)

        diagnostics.record("start", "Barveil \(Self.version) on macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        refreshEvents()
    }

    func shutdown() {
        slideWatcher.isEnabled = false
        engine.stop()
        dockSpace.stop()
        hotkey.unregister()
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
        }
        activationObserver = nil
        if let accessibilityNotificationObserver {
            DistributedNotificationCenter.default().removeObserver(accessibilityNotificationObserver)
        }
        accessibilityNotificationObserver = nil
        veil.resetToUserSetting()
        diagnostics.record("quit", "menu bar preference restored")
        refreshEvents()
    }

    #if DEBUG
    /// Populates the panel with a deterministic state for visual regression
    /// previews. Never compiled into shipping builds.
    func configurePreview(
        bundleID: String,
        appName: String,
        fullScreen: Bool,
        playing: Bool,
        decision previewDecision: Decision,
        accessibilityTrusted trusted: Bool = true,
        excluded: Bool = false,
        useAccessibility: Bool? = nil,
    ) {
        previewExcludedBundleID = excluded ? bundleID : nil
        previewUseAccessibility = useAccessibility
        previewEnabledOverride = true
        previewCompletedOnboarding = true

        let app = FrontmostApp(pid: 0, bundleID: bundleID, name: appName, bundleURL: nil)
        sample = DetectionEngine.Sample(
            frontApp: app,
            fullscreen: FullscreenState(
                isFullScreen: fullScreen,
                scope: fullScreen ? .content : .none,
                source: trusted ? .accessibility : .geometry,
                detail: fullScreen ? "preview fullscreen" : "preview windowed",
                displayName: "Built-in Display",
            ),
            playback: PlaybackState(
                isPlaying: playing,
                producers: [],
                detail: playing ? "preview playing" : "preview silent",
                usedDeviceFallback: false,
            ),
        )
        decision = previewDecision
        accessibilityTrusted = trusted
        isHidingNow = previewDecision.shouldHide
    }

    func completePreviewOnboarding() {
        previewEnabledOverride = true
        previewCompletedOnboarding = true
    }

    /// A browser-window preview where exact detection is unavailable.
    func configurePreviewPermissionNeeded() {
        configurePreview(
            bundleID: "com.apple.Safari",
            appName: "Safari",
            fullScreen: false,
            playing: false,
            decision: .show(.notFullScreen),
            accessibilityTrusted: false,
            useAccessibility: true,
        )
        sample?.fullscreen.scope = .window
        sample?.fullscreen.source = .geometry
        sample?.fullscreen.detail = "Accessibility needed"
    }
    #endif

    // MARK: - Sampling

    private func handle(sample rawSample: DetectionEngine.Sample) {
        let rawBundleID = rawSample.frontApp?.bundleID
        let rawFrontAppChanged = lastFrontBundleID != nil && rawBundleID != lastFrontBundleID
        if rawFrontAppChanged, dockState?.isFullScreen == true {
            // A front-app change inside a native fullscreen Space is the
            // earliest reliable signal that an FS↔FS animation has started.
            // Lock before evaluating, so the incoming Space cannot make the
            // bar appear for a sample and then be hidden again. The fast
            // provisional path may already have started this hop.
            spaceHopLock.beginIfIdle(at: Date())
        }

        // During an FS↔FS hop AppKit can report the new front app one sample
        // before Dock's `Skipping no-op state update` refreshes the owner PID.
        // Adopt the new owner immediately when the incoming app is playing (or
        // is the same app as the previous owner). Without this, the transient
        // mismatch produces show → hide exactly during the hand-off.
        if let current = dockState, current.isFullScreen,
           let front = rawSample.frontApp,
           shouldAdoptDockOwner(
               front: front,
               previousOwner: current.ownerPID,
               isPlaying: rawSample.playback.isPlaying,
           )
        {
            dockState?.ownerPID = front.pid
        }

        let sample = effectiveSample(from: rawSample)
        self.sample = sample

        // The slide watcher only has to run while a native fullscreen Space
        // is on screen; that is where Space switches happen.
        // Dock's event is the usual signal, but it can be missing (a Space
        // entered without a Dock visibility event, a freshly launched app).
        // The geometry/AX verdict covers those.
        slideWatcher.isEnabled = preferences.isEnabled
            && (dockState?.isFullScreen == true || sample.fullscreen.isFullScreen)
        if let space = SpaceLookup.shared.activeSpaceID() ?? dockState?.spaceID {
            currentSpaceID = space
            if let pid = sample.frontApp?.pid {
                spaceOwners[space] = pid
            }
            if activeBarWindowSpace != space {
                activeBarWindowSpace = space
                slideWatcher.expectedParkedWindowID = SpaceLookup.shared.barWindowID(ofSpace: space)
            }
        }

        let trusted = AccessibilityPermission.isTrusted
        if accessibilityTrusted != trusted {
            accessibilityTrusted = trusted
            diagnostics.record("accessibility", trusted ? "granted" : "not granted")
            refreshEvents()
        }

        if sample.fullscreen.detail != lastFullscreenDetail {
            lastFullscreenDetail = sample.fullscreen.detail
            diagnostics.record("fullscreen", sample.fullscreen.detail)
            refreshEvents()
        }

        showAccessibilityAlertIfNeeded(sample: sample)

        let bundleID = sample.frontApp?.bundleID
        let frontAppChanged = bundleID != lastFrontBundleID
        lastFrontBundleID = bundleID

        if let pinnedBundleID, pinnedBundleID != bundleID {
            // A different app is in front now: automatic control resumes.
            pin = .none
            self.pinnedBundleID = nil
            forceNextDecision = true
        }

        let now = Date()
        let dockOwnsFront = dockState?.isFullScreen == true
            && matchesDockOwner(sample.frontApp, dockState?.ownerPID)
        transitionGuard.update(
            isFullScreen: sample.fullscreen.isFullScreen,
            // An FS↔FS hop keeps the same Dock fullscreen Space owner; it is
            // not an app/screen transition that needs the re-hide guard.
            frontAppChanged: frontAppChanged && !dockOwnsFront,
            at: now,
        )

        let input = DecisionInput(
            enabled: preferences.isEnabled,
            mode: preferences.mode,
            pin: pin,
            frontAppBundleID: bundleID,
            isFullScreen: sample.fullscreen.isFullScreen,
            isPlaying: sample.playback.isPlaying,
            isExcluded: bundleID.map { preferences.excludedBundles.contains($0) } ?? false,
            showBarWhenPaused: preferences.showBarWhenPaused,
        )
        var proposed = decide(input)
        if proposed.shouldHide,
           pin == .none,
           transitionGuard.shouldSuppressHide(at: now)
        {
            proposed = .show(.transition)
        }

        if pin == .none, spaceHopLock.isActive {
            let signature = "\(sample.frontApp?.pid ?? 0)|\(dockState?.ownerPID ?? 0)|\(sample.playback.isPlaying)|\(sample.fullscreen.isFullScreen)|\(sample.fullscreen.scope.rawValue)"
            if spaceHopLock.needsInitialCommit {
                // The incoming Space adopts whatever menu-bar preference is in
                // force when the animation ends. Holding the previous decision
                // through the whole hop therefore guarantees that the bar is
                // corrected late — the "spaced out" second and third beat.
                // Commit the destination decision on this very sample so the
                // correction lands with the arrival instead.
                spaceHopLock.markInitialCommitDone()
                forceNextDecision = false
                let committed = stabilizer.force(proposed, at: now)
                diagnostics.record("space-hop-commit", committed.diagnosticTag)
                apply(committed, sample: sample)
                return
            }
            let destinationSettled = spaceHopLock.observe(signature: signature, at: now)
            if !destinationSettled || slideWatcher.isSliding {
                // While the slide is still running the samples are still
                // describing the *outgoing* Space; releasing the lock here
                // would write its decision back over the pre-committed
                // destination. Restart the stability window instead.
                if destinationSettled {
                    spaceHopLock.begin(at: now)
                    spaceHopLock.markInitialCommitDone()
                }
                diagnostics.record("space-hop-lock", "holding \(decision.diagnosticTag)")
                return
            }
            // The destination state has been stable; commit exactly one final
            // decision on this sample.
            forceNextDecision = true
        }

        if forceNextDecision || pin != .none {
            forceNextDecision = false
            apply(stabilizer.force(proposed, at: now), sample: sample)
            return
        }

        switch stabilizer.update(proposed: proposed, at: now) {
        case .none:
            // Unchanged decision, but the sample still settles a Space: keep
            // the per-Space memory current so the next hop can pre-commit
            // without a late correction.
            rememberSettled(proposed, sample: sample)
        case .pending(let decision):
            diagnostics.record("decision-pending", decision.diagnosticTag)
            refreshEvents()
        case .cancelled(let decision):
            diagnostics.record("decision-cancelled", decision.diagnosticTag)
            rememberSettled(proposed, sample: sample)
            refreshEvents()
        case .applied(let decision):
            apply(decision, sample: sample)
        }
    }

    // MARK: - Menu bar slide (earliest Space-hop signal)

    /// The incoming Space's menu bar window is sliding toward the centre.
    /// Resolve which Space (and app) it belongs to and commit that app's
    /// remembered decision now — roughly a second before the Space switch
    /// completes, so the preference is already correct when the system
    /// renders the arriving Space.
    private func handleSlideStart(windowID: Int, direction: Int) {
        guard preferences.isEnabled, preferences.mode == .smart, pin == .none else { return }
        spaceHopLock.beginIfIdle(at: Date())

        // Direction plus the ordered Space list names the destination without
        // needing a window -> Space map (which is unreliable right after a
        // restart). The owning app is read straight from the destination
        // Space's window list, so a freshly launched Barveil predicts as well
        // as one that has already visited every Space.
        // The *active* Space is authoritative: Dock's cached state still
        // names the previous Space until its stay-change event arrives, which
        // is more than a second after the switch.
        let current = SpaceLookup.shared.activeSpaceID() ?? dockState?.spaceID
        var destination: (id: UInt64, type: Int)?
        if let current,
           let spaces = SpaceLookup.shared.orderedSpaces(),
           let neighbour = SpaceLookup.neighbour(of: current, direction: direction, in: spaces)
        {
            destination = neighbour
        }
        // The ordered-neighbour guess can fail while a brand-new Space is
        // being created. The incoming menu bar window knows its Space
        // membership, which names the destination authoritatively.
        if destination == nil || destination?.type != 4 {
            if let fromWindow = SpaceLookup.shared.spaceIDs(forWindow: CGWindowID(windowID))?
                .first(where: { $0 != current })
            {
                destination = (fromWindow, 4)
            }
        }
        guard let destination, destination.type == 4 else {
            diagnostics.record("space-slide", "unresolved dir=\(direction)")
            return
        }
        // Prefer the Space's own window list: `spaceOwners` can hold a stale
        // entry if Dock's cached Space id ever disagreed with the active one.
        let destinationOwnerPID = SpaceLookup.shared.ownerPID(ofSpace: destination.id)
            ?? spaceOwners[destination.id]
        let running: NSRunningApplication?
        if let destinationOwnerPID {
            running = NSRunningApplication(processIdentifier: destinationOwnerPID)
        } else if let front = NSWorkspace.shared.frontmostApplication,
                  BrowserApps.isWebKit(front.bundleIdentifier)
        {
            // A brand-new WebKit fullscreen Space has no windows yet, so it
            // has no owner either. The front app is the one asking for the
            // Space (Safari creating its picture surface).
            running = front
        } else {
            running = nil
        }
        guard let running else {
            diagnostics.record("space-slide", "no owner for space \(destination.id)")
            return
        }
        let pid = running.processIdentifier
        let app = FrontmostApp(
            pid: pid,
            bundleID: running.bundleIdentifier,
            name: running.localizedName ?? running.bundleIdentifier ?? "Unknown",
            bundleURL: running.bundleURL,
        )

        if let remembered = rememberedSpaceDecisions[destination.id],
           Date().timeIntervalSince(remembered.at) < 300
        {
            precommit(remembered.decision, app: app, reason: "slide")
            return
        }

        // Nothing remembered for this Space (first visit since launch):
        // evaluate the destination now — there is about a second left.
        precommit(destinationDecision(for: app, destinationSpaceID: destination.id), app: app, reason: "slide-eval")
    }

    /// The same decision table the sampler uses, but for an app that is not
    /// frontmost yet. The destination is a native fullscreen Space, so the
    /// picture policy runs with `frontOwnsDock = true`.
    private func destinationDecision(for app: FrontmostApp, destinationSpaceID: UInt64) -> Decision {
        let state = engine.destinationState(for: app, destinationSpaceID: destinationSpaceID)
        var raw = state.fullscreen
        if BrowserApps.isWebKit(app.bundleID), raw.scope == .none {
            // The incoming WebKit Space has no window on record yet. For
            // Safari that happens when a fullscreen *picture* is being
            // created — its window materialises a beat after the animation
            // starts — while a Safari window keeps its window (with the
            // toolbar) from the very beginning. Predict the picture so the
            // arriving Space renders with the bar hidden instead of being
            // corrected after the fact.
            raw = FullscreenState(
                isFullScreen: true,
                scope: .content,
                source: .geometry,
                detail: "unresolved WebKit destination predicted as picture",
                displayName: raw.displayName,
            )
        }
        let picture = PictureFullscreenPolicy.resolve(
            raw: raw,
            dockIsFullScreen: true,
            frontOwnsDock: true,
            isBrowser: BrowserApps.isBrowser(app.bundleID),
            isPlaying: state.playback.isPlaying,
        )
        return decide(DecisionInput(
            enabled: preferences.isEnabled,
            mode: preferences.mode,
            pin: pin,
            frontAppBundleID: app.bundleID,
            isFullScreen: picture.isFullScreen,
            isPlaying: state.playback.isPlaying,
            isExcluded: app.bundleID.map { preferences.excludedBundles.contains($0) } ?? false,
            showBarWhenPaused: preferences.showBarWhenPaused,
        ))
    }

    // MARK: - Fast Space-hop pre-commit

    /// Runs the moment the Accessibility fast path sees a new front app —
    /// typically while the fullscreen Space animation is still on screen.
    /// The system renders the arriving Space's menu bar from whatever
    /// preference value is in force when the animation ends, so correcting it
    /// afterwards always costs a visible beat. Writing the destination's
    /// decision here, before the arrival, removes that beat entirely.
    private func handleFastFrontAppChange(_ app: FrontmostApp) {
        guard preferences.isEnabled,
              preferences.mode == .smart,
              pin == .none
        else { return }

        let dockIsFullScreen = dockState?.isFullScreen == true
        let sameAsSample = app.pid == sample?.frontApp?.pid
        let cached = rememberedDecisions[app.pid].map { Date().timeIntervalSince($0.at) < 300 } ?? false
        if dockIsFullScreen {
            diagnostics.record(
                "space-hop-fast",
                "\(app.name) same=\(sameAsSample) cached=\(cached)",
            )
        }
        guard dockIsFullScreen, !sameAsSample else { return }

        spaceHopLock.beginIfIdle(at: Date())

        if let remembered = rememberedDecisions[app.pid],
           Date().timeIntervalSince(remembered.at) < 300
        {
            precommit(remembered.decision, app: app, reason: "remembered")
            return
        }

        // Cheap and unambiguous half of the decision: an app with no media
        // playback assertion is not playing, so the arriving Space must show
        // the bar. Hiding still waits for the full sample, which also has to
        // confirm that the picture — not browser window chrome — is
        // fullscreen.
        if preferences.showBarWhenPaused,
           engine.fastPlayingVerdict(for: app) == false
        {
            precommit(.show(.notPlaying), app: app, reason: "no playback")
        }
    }

    private func precommit(_ decision: Decision, app: FrontmostApp, reason: String) {
        spaceHopLock.markInitialCommitDone()
        forceNextDecision = false
        if preferences.isEnabled {
            veil.apply(hidden: decision.shouldHide)
        }
        isHidingNow = veil.isHiding
        self.decision = decision
        diagnostics.record(
            "space-hop-precommit",
            "\(decision.diagnosticTag) (\(reason)) \(app.name)",
        )
        refreshEvents()
    }

    private func shouldAdoptDockOwner(
        front: FrontmostApp,
        previousOwner: pid_t?,
        isPlaying: Bool,
    ) -> Bool {
        if isPlaying { return true }
        guard let previousOwner else { return false }
        if Responsibility.matches(front.pid, previousOwner) { return true }
        guard let previous = NSRunningApplication(processIdentifier: previousOwner),
              let previousBundle = previous.bundleIdentifier,
              let frontBundle = front.bundleID
        else { return false }
        return frontBundle == previousBundle
    }

    // MARK: - Dock fullscreen Space

    /// Dock's `dock-visibility` channel is authoritative for native
    /// fullscreen Spaces. Using it avoids the old geometry/AX guessing and,
    /// more importantly, lets an FS↔FS hop re-evaluate without writing the
    /// global preference again — the write (and its distributed notification)
    /// is what re-animates the menu bar and produced the "three beats".
    private func effectiveSample(
        from sample: DetectionEngine.Sample,
    ) -> DetectionEngine.Sample {
        guard let dockState else { return sample }
        var sample = sample
        sample.fullscreen = PictureFullscreenPolicy.resolve(
            raw: sample.fullscreen,
            dockIsFullScreen: dockState.isFullScreen,
            frontOwnsDock: matchesDockOwner(sample.frontApp, dockState.ownerPID),
            isBrowser: BrowserApps.isBrowser(sample.frontApp?.bundleID),
            isPlaying: sample.playback.isPlaying,
        )
        return sample
    }

    private func matchesDockOwner(_ app: FrontmostApp?, _ ownerPID: pid_t?) -> Bool {
        guard let app, let ownerPID else { return false }
        // Responsibility resolution keeps helper processes working while
        // still distinguishing two separate instances of the same app.
        return Responsibility.matches(app.pid, ownerPID)
    }

    /// Dock's first FS↔FS pulse arrives just before the active Space flips.
    /// When the slide watcher did not already commit, return to the last
    /// Safari window-fullscreen Space using its settled decision. This gives
    /// WindowServer the `show` before the incoming menu bar is rendered,
    /// instead of correcting it only after the arrival event.
    private func precommitPreviousSpaceIfReturningFromVideo() {
        guard spaceHopLock.needsInitialCommit,
              let returnSpaceID,
              returnSpaceID != currentSpaceID,
              let remembered = rememberedSpaceDecisions[returnSpaceID],
              Date().timeIntervalSince(remembered.at) < 300,
              let front = NSWorkspace.shared.frontmostApplication,
              front.bundleIdentifier != Bundle.main.bundleIdentifier
        else { return }

        let app = FrontmostApp(
            pid: front.processIdentifier,
            bundleID: front.bundleIdentifier,
            name: front.localizedName ?? front.bundleIdentifier ?? "Unknown",
            bundleURL: front.bundleURL,
        )
        diagnostics.record(
            "space-hop-stay",
            "precommit \(remembered.decision.diagnosticTag) return=\(returnSpaceID) current=\(currentSpaceID ?? 0)",
        )
        precommit(remembered.decision, app: app, reason: "stay-return")
    }

    /// Commits the incoming fullscreen Space's decision as soon as Dock
    /// names it. Only WebKit browsers need this: their fullscreen picture
    /// Space exists before its window does, so the ordinary sample path can
    /// only correct it after the animation has already rendered the bar.
    private func precommitEntryDestination(_ state: DockFullScreenState) {
        guard preferences.isEnabled,
              preferences.mode == .smart,
              pin == .none,
              let destinationID = state.spaceID,
              destinationID != currentSpaceID,
              let front = NSWorkspace.shared.frontmostApplication,
              BrowserApps.isWebKit(front.bundleIdentifier)
        else { return }
        spaceHopLock.beginIfIdle(at: Date())
        guard spaceHopLock.needsInitialCommit else { return }

        let app = FrontmostApp(
            pid: front.processIdentifier,
            bundleID: front.bundleIdentifier,
            name: front.localizedName ?? front.bundleIdentifier ?? "Unknown",
            bundleURL: front.bundleURL,
        )
        if let remembered = rememberedSpaceDecisions[destinationID],
           Date().timeIntervalSince(remembered.at) < 300
        {
            diagnostics.record(
                "space-hop-entry",
                "precommit \(remembered.decision.diagnosticTag) remembered space=\(destinationID)",
            )
            precommit(remembered.decision, app: app, reason: "entry-remembered")
            return
        }
        let decision = destinationDecision(for: app, destinationSpaceID: destinationID)
        diagnostics.record(
            "space-hop-entry",
            "precommit \(decision.diagnosticTag) evaluated space=\(destinationID)",
        )
        precommit(decision, app: app, reason: "entry-eval")
    }

    private func handleDockSpace(_ event: DockSpaceEvent) {
        switch event {
        case .fullScreen(let state):
            if let spaceID = state.spaceID, let ownerPID = state.ownerPID {
                spaceOwners[spaceID] = ownerPID
            }
            let wasFullScreen = dockState?.isFullScreen == true
            if state.isFullScreen, wasFullScreen {
                spaceHopLock.begin(at: Date())
            } else if !state.isFullScreen {
                spaceHopLock.clear()
            }
            if state.isFullScreen, !wasFullScreen {
                // Entering a brand-new fullscreen Space. Dock names the
                // incoming Space before the sample path can describe it, and
                // WindowServer renders its menu bar from whatever preference
                // is in force when the animation ends. Commit the destination
                // decision now: for a WebKit browser the picture surface may
                // not be listed yet, and waiting for the samples would apply
                // the outgoing Space's (visible) decision and cost a beat.
                precommitEntryDestination(state)
            }
            dockState = state

        case .staySpaceChange:
            spaceHopLock.beginIfIdle(at: Date())
            precommitPreviousSpaceIfReturningFromVideo()
            // FS↔FS hop: refresh the owner from the current front app, but do
            // not force a write. If the decision is still "hide", the
            // VeilController dedup below keeps the pref and WindowServer
            // completely untouched.
            guard var state = dockState, state.isFullScreen else { return }
            if let front = NSWorkspace.shared.frontmostApplication,
               front.bundleIdentifier != Bundle.main.bundleIdentifier
            {
                state.ownerPID = front.processIdentifier
            }
            dockState = state

        case .desktopArrival:
            spaceHopLock.clear()
            dockState = DockFullScreenState.initial
            if preferences.isEnabled {
                veil.apply(hidden: false)
                isHidingNow = veil.isHiding
                decision = .show(.transition)
            }
        }

        engine.sample()
    }

    /// The browser path is intentionally conservative without the grant.
    /// When the user actually hits that case, make the next step obvious
    /// instead of silently leaving the menu bar visible.
    private func showAccessibilityAlertIfNeeded(sample: DetectionEngine.Sample) {
        guard preferences.useAccessibility,
              !accessibilityTrusted,
              !hasShownAccessibilityAlert,
              let bundleID = sample.frontApp?.bundleID,
              BrowserApps.isBrowser(bundleID),
              sample.fullscreen.scope == .window,
              sample.fullscreen.detail.contains("Accessibility needed")
        else { return }

        hasShownAccessibilityAlert = true
        // The native fullscreen + playback path no longer needs Accessibility;
        // only the legacy borderless browser fallback does. Surface the state
        // in the panel/diagnostics instead of blocking the app with a modal
        // alert during normal use.
        diagnostics.record("permission-needed", "Accessibility not granted; legacy browser picture detection is conservative")
        refreshEvents()
    }

    /// Remembers what a Space settled on, whether or not the applied
    /// decision changed. The slide and stay-return pre-commit paths answer
    /// from this memory, so a Space that simply repeats the previous decision
    /// (the ordinary Safari window-fullscreen case) must still be recorded —
    /// otherwise the very first hop after launch falls back to a late
    /// correction and the menu bar visibly beats.
    private func rememberSettled(_ stable: Decision, sample: DetectionEngine.Sample) {
        guard stable != .show(.transition) else { return }
        let now = Date()
        if let pid = sample.frontApp?.pid {
            rememberedDecisions[pid] = (stable, now)
        }
        if let space = SpaceLookup.shared.activeSpaceID() ?? dockState?.spaceID {
            rememberedSpaceDecisions[space] = (stable, now)
            if stable == .show(.notFullScreen),
               BrowserApps.isWebKit(sample.frontApp?.bundleID),
               sample.fullscreen.scope == .window
            {
                returnSpaceID = space
            }
        }
        if rememberedDecisions.count > 24 || rememberedSpaceDecisions.count > 24 {
            let cutoff = now.addingTimeInterval(-300)
            rememberedDecisions = rememberedDecisions.filter { $0.value.at >= cutoff }
            rememberedSpaceDecisions = rememberedSpaceDecisions.filter { $0.value.at >= cutoff }
        }
    }

    private func apply(_ stable: Decision, sample: DetectionEngine.Sample) {
        let wasHiding = isHidingNow

        rememberSettled(stable, sample: sample)

        if preferences.isEnabled {
            veil.apply(hidden: stable.shouldHide)
        }
        isHidingNow = veil.isHiding

        if stable != decision {
            decision = stable
            diagnostics.record(stable.diagnosticTag, Self.describe(sample))
            refreshEvents()
        }
        if wasHiding != isHidingNow {
            diagnostics.record(isHidingNow ? "menu-bar-hidden" : "menu-bar-shown", Self.describe(sample))
            refreshEvents()
        }
    }

    // MARK: - User actions

    /// Hotkey / panel switch: flip the bar and pin that choice until the
    /// front app changes.
    func togglePinned() {
        let target: ManualPin = isHidingNow ? .show : .hide
        pin = target
        pinnedBundleID = sample?.frontApp?.bundleID
        forceNextDecision = true
        diagnostics.record("hotkey", target == .hide ? "pin hide" : "pin show")
        handlePinnedChange()
    }

    func clearPin() {
        pin = .none
        pinnedBundleID = nil
        forceNextDecision = true
        handlePinnedChange()
    }

    private func handlePinnedChange() {
        // Apply on the spot instead of waiting for the next tick.
        engine.sample()
    }

    func toggleExclusionForFrontApp() {
        guard let bundleID = sample?.frontApp?.bundleID else { return }
        preferences.toggleExclusion(bundleID: bundleID)
        let excluded = preferences.excludedBundles.contains(bundleID)
        diagnostics.record("exclude", "\(bundleID) \(excluded ? "added" : "removed")")
        refreshEvents()
        forceNextDecision = true
        engine.sample()
    }

    var isFrontAppExcluded: Bool {
        guard let bundleID = sample?.frontApp?.bundleID else { return false }
        #if DEBUG
        if previewExcludedBundleID == bundleID { return true }
        #endif
        return preferences.excludedBundles.contains(bundleID)
    }

    /// The preference as observed by detection and UI. Debug previews may
    /// override it without writing to the user's real defaults.
    var isAutomationEnabled: Bool {
        #if DEBUG
        if let previewEnabledOverride { return previewEnabledOverride }
        #endif
        return preferences.isEnabled
    }

    func setAutomationEnabled(_ enabled: Bool) {
        #if DEBUG
        if previewEnabledOverride != nil {
            previewEnabledOverride = enabled
            return
        }
        #endif
        preferences.isEnabled = enabled
    }

    var usesAccessibilityForDetection: Bool {
        #if DEBUG
        if let previewUseAccessibility { return previewUseAccessibility }
        #endif
        return preferences.useAccessibility
    }

    var shouldShowOnboarding: Bool {
        #if DEBUG
        if previewCompletedOnboarding { return false }
        #endif
        return !preferences.hasCompletedOnboarding
    }

    var canToggleExclusion: Bool {
        sample?.frontApp?.bundleID != nil
    }


    func restoreSystemSettingAndDisable() {
        preferences.isEnabled = false
        pin = .none
        pinnedBundleID = nil
        veil.resetToUserSetting()
        isHidingNow = veil.isHiding
        diagnostics.record("system-pref", "restored to \(veil.baseline ? "visible" : "hidden") and automation disabled")
        refreshEvents()
    }

    func refreshAccessibilityStatus() {
        let trusted = AccessibilityPermission.isTrusted
        if accessibilityTrusted != trusted {
            accessibilityTrusted = trusted
        }
    }

    /// Shows the native macOS registration prompt once. The system prompt,
    /// not the app, is responsible for offering the System Settings jump.
    func promptForAccessibilityIfNeeded() {
        guard !accessibilityTrusted,
              preferences.useAccessibility,
              !preferences.hasRequestedAccessibility
        else { return }

        preferences.hasRequestedAccessibility = true
        AccessibilityPermission.requestRegistration()
        accessibilityTrusted = AccessibilityPermission.isTrusted
    }

    /// First request: show the native registration prompt only. Later
    /// requests: the app is already registered, so open the pane directly.
    func beginAccessibilitySetup() {
        switch AccessibilityPermission.setupAction(
            isTrusted: accessibilityTrusted,
            hasRequested: preferences.hasRequestedAccessibility,
        ) {
        case .register:
            promptForAccessibilityIfNeeded()
        case .openSettings:
            openAccessibilitySettings()
        }
    }

    func openAccessibilitySettings() {
        AccessibilityPermission.openSystemSettings()
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try LoginItem.set(enabled: enabled)
            launchAtLogin = LoginItem.isEnabled
            errorMessage = nil
        } catch {
            launchAtLogin = LoginItem.isEnabled
            errorMessage = error.localizedDescription
        }
    }

    func refreshLoginItem() {
        launchAtLogin = LoginItem.isEnabled
    }

    func quit() {
        NSApp.terminate(nil)
    }

    func clearDiagnostics() {
        diagnostics.clear()
        refreshEvents()
    }

    var diagnosticsText: String {
        diagnostics.exportText
    }

    // MARK: - State exposed to the interface

    var frontAppName: String {
        sample?.frontApp?.name ?? "—"
    }

    var isFullScreen: Bool {
        sample?.fullscreen.isFullScreen ?? false
    }

    var activeDisplayName: String {
        sample?.fullscreen.displayName ?? "—"
    }

    /// A browser window fills the display, but without Accessibility there is
    /// no way to tell whether the picture itself is fullscreen — so Barveil
    /// leaves the bar alone and the panel explains why.
    var browserNeedsAccessibilityForPictureFullScreen: Bool {
        guard let sample, BrowserApps.isBrowser(sample.frontApp?.bundleID) else { return false }
        return sample.fullscreen.scope == .window && sample.fullscreen.source == .geometry
    }

    var isPlaying: Bool {
        sample?.playback.isPlaying ?? false
    }

    var detectionDetail: String {
        guard let sample else { return "—" }
        return "\(sample.fullscreen.detail) · \(sample.playback.detail)"
    }

    var version: String {
        Self.version
    }

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
    }

    static func displayName(forBundleID bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return bundleID
        }
        return FileManager.default.displayName(atPath: url.path)
    }

    // MARK: - Plumbing

    private func preferencesChanged() {
        accessibilityTrusted = AccessibilityPermission.isTrusted
        applyHotkeyConfiguration(force: false)

        if !preferences.isEnabled {
            pin = .none
            pinnedBundleID = nil
            veil.resetToUserSetting()
            isHidingNow = veil.isHiding
        }
        forceNextDecision = true
        engine.sample()
    }

    private func applyHotkeyConfiguration(force: Bool) {
        let enabled = preferences.hotkeyEnabled
        let chord = preferences.hotkeyChord
        if !force, let appliedHotkey, appliedHotkey.enabled == enabled, appliedHotkey.chord == chord {
            return
        }

        guard enabled else {
            hotkey.unregister()
            hotkeyRegistered = false
            appliedHotkey = (false, chord)
            return
        }

        hotkeyRegistered = hotkey.register(chord)
        appliedHotkey = (true, chord)
        diagnostics.record(
            "hotkey",
            hotkeyRegistered ? "registered \(chord.displayString)" : "registration failed \(chord.displayString)",
        )
        refreshEvents()
    }

    private func refreshEvents() {
        recentEvents = diagnostics.events
    }

    private static func describe(_ sample: DetectionEngine.Sample) -> String {
        let app = sample.frontApp.map { "\($0.name)[\($0.bundleID ?? "no-bundle")]" } ?? "no-app"
        let fullscreen = sample.fullscreen.isFullScreen
            ? "fullscreen(\(sample.fullscreen.source.rawValue))"
            : "windowed"
        let playback = sample.playback.isPlaying ? "playing" : "silent"
        return "\(app) \(fullscreen) \(playback) | \(sample.fullscreen.detail) | \(sample.playback.detail)"
    }
}
