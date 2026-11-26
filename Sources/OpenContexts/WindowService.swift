import AppKit
import ApplicationServices
import Combine
import OpenContextsCore
import OSLog

@MainActor
final class WindowService: ObservableObject {
    @Published private(set) var windows: [WindowInfo] = []
    @Published private(set) var appBadges: [String: String] = [:]
    @Published private(set) var hasAccessibility = false
    @Published private(set) var fullscreenScreenIDs: Set<UInt32> = []

    @Published private(set) var focusedWindowID: String?
    private(set) var hasCompletedInitialScan = false

    private final class WeakWindow {
        weak var value: NSWindow?
        init(_ value: NSWindow) { self.value = value }
    }

    private final class ClosingCheckDelegate: NSObject, NSWindowDelegate {
        func windowShouldClose(_ sender: NSWindow) -> Bool { false }
    }

    private final class ActivationRequest: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        var isCancelled: Bool { lock.withLock { cancelled } }
        func cancel() { lock.withLock { cancelled = true } }
    }

    struct TrackedWindow: @unchecked Sendable {
        let id: String
        let element: AXUIElement
        var info: WindowInfo
        var windowID: CGWindowID? = nil
    }

    struct ApplicationSnapshot: Sendable {
        let processID: pid_t
        let appID: String
        let appName: String
    }

    struct ScanResult: @unchecked Sendable {
        let windows: [TrackedWindow]
        let focusedID: String?
        let fullscreenScreenIDs: Set<UInt32>
        let activeAppIDs: Set<String>
        let badgeReads: [String: DockBadgeRead]?
        var discoveries: [pid_t: WindowSpaces.DiscoveryState] = [:]
        var spaceSnapshot: WindowSpaces.Snapshot?
        var pendingDiscoveryPID: pid_t?
    }

    private enum FocusRead: Sendable {
        case known(String?)
        case untracked
        case failed
    }

    enum AttributeRead<Value> {
        case value(Value)
        case noValue
        case failure(AXError)
    }

    enum CapabilityProbe {
        case value(WindowTaskCapability)
        case invalidElement
    }

    private let logger = Logger(subsystem: "OpenContexts", category: "windows")
    private var tracked: [TrackedWindow] = []
    private var localWindows: [String: WeakWindow] = [:]
    private var externalFocusedID: String?
    private var timer: Timer?
    private var focusTimer: Timer?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var scanInFlight = false
    private var fullScanPending = false
    private var pendingPIDs: Set<pid_t> = []
    private var lastFullScanAt = -Double.infinity
    private var focusReadInFlight = false
    private var focusReadPending = false
    private var focusRevision = 0
    private var presentationTask: Task<Void, Never>?
    private var lastUntrackedFocusScan: (pid: pid_t, at: TimeInterval)?
    private var activationTask: Task<Void, Never>?
    private var activationRequest: ActivationRequest?
    private var includeAllSpaces = false
    private var trackSidebar = true
    private var discoveries: [pid_t: WindowSpaces.DiscoveryState] = [:]
    private var discoveryTask: Task<Void, Never>?
    private var spaceSnapshot: WindowSpaces.Snapshot?
    private var lastBadgeScanAt = -Double.infinity
    private var badgeState = DockBadgeState()
    private let scanQueue = DispatchQueue(label: "OpenContexts.WindowScan", qos: .userInitiated)
    private let focusQueue = DispatchQueue(label: "OpenContexts.WindowFocus", qos: .userInitiated)
    private lazy var foregroundObserver = ForegroundWindowObserver(queue: focusQueue) { [weak self] inventoryChanged in
        guard let self else { return }
        if inventoryChanged, let pid = self.foregroundPID {
            self.refreshApplication(pid)
        } else {
            self.refreshFocus()
        }
    }

    func start() {
        guard timer == nil else { return }
        observeWorkspace()

        let timer = Timer(timeInterval: 8, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        // Only check trust or the focused window here, never enumerate every app.
        let focusTimer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.timer != nil else { return }
                self.refreshBadges()
                if !self.hasAccessibility {
                    if AXIsProcessTrusted() { self.refresh() }
                } else if !self.foregroundObserver.reportsFocus {
                    self.refreshFocus()
                }
            }
        }
        focusTimer.tolerance = 0.2
        RunLoop.main.add(focusTimer, forMode: .common)
        self.focusTimer = focusTimer
        refresh()
    }

    func stop() {
        cancelActivation()
        timer?.invalidate()
        timer = nil
        focusTimer?.invalidate()
        focusTimer = nil
        discoveryTask?.cancel()
        discoveryTask = nil
        cancelPresentationRefresh()
        fullScanPending = false
        pendingPIDs.removeAll()
        focusReadPending = false
        foregroundObserver.stop()
        workspaceObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        workspaceObservers.removeAll()
    }

    private var foregroundPID: pid_t? {
        guard let front = NSWorkspace.shared.frontmostApplication,
              front.activationPolicy == .regular, front.processIdentifier != getpid() else { return nil }
        return front.processIdentifier
    }

    private func observeWorkspace() {
        let center = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.didHideApplicationNotification, NSWorkspace.didUnhideApplicationNotification,
            NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didWakeNotification]
        workspaceObservers = names.map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                let pid = app?.processIdentifier
                let regularApp = app?.activationPolicy == .regular
                Task { @MainActor in
                    guard let self, self.timer != nil else { return }
                    switch name {
                    case NSWorkspace.didActivateApplicationNotification:
                        self.foregroundObserver.watch(self.hasAccessibility ? self.foregroundPID : nil)
                        self.refreshFocus()
                    case NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didWakeNotification:
                        self.refresh()
                    default:
                        if let pid, regularApp || self.tracked.contains(where: { $0.info.processID == pid }) {
                            self.refreshApplication(pid)
                        }
                    }
                }
            }
        }
    }

    private func refreshFocus() {
        guard timer != nil, hasAccessibility else { return }
        guard !focusReadInFlight else { focusReadPending = true; return }
        guard let pid = foregroundPID else {
            focusRevision &+= 1
            externalFocusedID = nil
            publishWindows()
            return
        }
        let candidates = tracked.filter { $0.info.processID == pid }
        focusReadInFlight = true
        focusQueue.async { [weak self] in
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.1)
            let read: FocusRead
            switch Self.readAttribute(kAXFocusedWindowAttribute, of: app) as AttributeRead<AXUIElement> {
            case let .value(element):
                read = candidates.first { CFEqual($0.element, element) }.map { .known($0.id) } ?? .untracked
            case .noValue:
                read = .known(nil)
            case .failure:
                read = .failed
            }
            Task { @MainActor [weak self] in self?.applyFocus(read, pid: pid) }
        }
    }

    private func applyFocus(_ read: FocusRead, pid: pid_t) {
        focusReadInFlight = false
        let recheck = focusReadPending
        focusReadPending = false
        guard timer != nil, hasAccessibility else { return }
        defer { if recheck { refreshFocus() } }
        guard foregroundPID == pid else { return }
        switch read {
        case let .known(id):
            focusRevision &+= 1
            guard id == nil || tracked.contains(where: { $0.id == id }) else { return }
            guard externalFocusedID != id else { return }
            externalFocusedID = id
            publishWindows()
        case .untracked:
            let now = ProcessInfo.processInfo.systemUptime
            if let last = lastUntrackedFocusScan, last.pid == pid, now - last.at < 2 { return }
            lastUntrackedFocusScan = (pid, now)
            refreshApplication(pid)
        case .failed:
            break
        }
    }

    func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        refresh()
    }

    func refresh() {
        fullScanPending = true
        drainScans()
    }

    private func refreshApplication(_ pid: pid_t) {
        pendingPIDs.insert(pid)
        drainScans()
    }

    func refreshForPresentation() {
        // Present from cache. A quick tap should not queue a scan ahead of activation.
        guard presentationTask == nil, ProcessInfo.processInfo.systemUptime - lastFullScanAt >= 2 else { return }
        presentationTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            guard let self else { return }
            self.presentationTask = nil
            if ProcessInfo.processInfo.systemUptime - self.lastFullScanAt >= 2 { self.refresh() }
        }
    }

    func cancelPresentationRefresh() {
        presentationTask?.cancel()
        presentationTask = nil
    }

    private func drainScans() {
        guard !scanInFlight, fullScanPending || !pendingPIDs.isEmpty else { return }
        let selectedPIDs = fullScanPending ? nil : pendingPIDs
        fullScanPending = false
        pendingPIDs.removeAll()
        guard updateTrust() else { return }

        let ownPID = ProcessInfo.processInfo.processIdentifier
        let frontmostPID = foregroundPID
        if timer != nil { foregroundObserver.watch(frontmostPID) }
        let applications = NSWorkspace.shared.runningApplications.compactMap { application -> ApplicationSnapshot? in
            guard application.activationPolicy == .regular, application.processIdentifier != ownPID else { return nil }
            let appID = application.bundleIdentifier
                ?? application.bundleURL?.path
                ?? "pid:\(application.processIdentifier)"
            return ApplicationSnapshot(
                processID: application.processIdentifier,
                appID: appID,
                appName: application.localizedName ?? appID
            )
        }
        if selectedPIDs == nil { lastFullScanAt = ProcessInfo.processInfo.systemUptime }
        let scanSidebar = trackSidebar
        let previous = tracked
        let allSpaces = includeAllSpaces
        let discoveryState = discoveries
        let focusRevision = focusRevision
        let wasRunning = timer != nil
        scanInFlight = true
        scanQueue.async { [weak self] in
            let result = Self.scan(applications: applications, previous: previous,
                                   frontmostPID: frontmostPID, badgeReads: nil,
                                   allSpaces: allSpaces, discoveries: discoveryState,
                                   selectedPIDs: selectedPIDs, scanSidebar: scanSidebar)
            Task { @MainActor [weak self] in
                guard let self else { return }
                if wasRunning && self.timer == nil { self.scanInFlight = false; return }
                // A foreground notification can arrive while inventory is being read.
                let focusIsCurrent = self.foregroundPID == frontmostPID && self.focusRevision == focusRevision
                let currentFocus = focusIsCurrent ? result.focusedID : self.externalFocusedID
                self.apply(result, focusedID: currentFocus)
            }
        }
    }

    func setIncludeAllSpaces(_ enabled: Bool) {
        guard includeAllSpaces != enabled else { return }
        includeAllSpaces = enabled
        if !enabled {
            discoveryTask?.cancel()
            discoveryTask = nil
        }
        if timer != nil { refresh() }
    }

    func setTrackSidebar(_ enabled: Bool) {
        guard trackSidebar != enabled else { return }
        trackSidebar = enabled
        if enabled {
            lastBadgeScanAt = -.infinity
            if timer != nil {
                refreshBadges()
                refresh()
            }
        } else if !fullscreenScreenIDs.isEmpty {
            fullscreenScreenIDs = []
        }
    }

    private func refreshBadges() {
        let now = ProcessInfo.processInfo.systemUptime
        guard trackSidebar, hasAccessibility, !scanInFlight, now - lastBadgeScanAt >= 2,
              let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return }
        lastBadgeScanAt = now
        let pid = dock.processIdentifier
        scanQueue.async { [weak self] in
            guard let reads = Self.scanDockBadges(processID: pid) else { return }
            Task { @MainActor [weak self] in
                guard let self, self.trackSidebar, self.hasAccessibility else { return }
                self.badgeState.merge(activeAppIDs: Set(self.tracked.map(\.info.appID)), reads: reads)
                if self.appBadges != self.badgeState.badges { self.appBadges = self.badgeState.badges }
            }
        }
    }

    /// Publishes the current trust state and clears external windows when it is missing.
    private func updateTrust() -> Bool {
        let trusted = AXIsProcessTrusted()
        if hasAccessibility != trusted { hasAccessibility = trusted }
        guard !trusted else { return true }
        tracked = []
        discoveries.removeAll()
        discoveryTask?.cancel()
        discoveryTask = nil
        foregroundObserver.stop()
        externalFocusedID = nil
        if !fullscreenScreenIDs.isEmpty { fullscreenScreenIDs = [] }
        publishWindows()
        return false
    }

    private func apply(_ result: ScanResult) {
        apply(result, focusedID: result.focusedID)
    }

    private func apply(_ result: ScanResult, focusedID: String?) {
        scanInFlight = false
        guard updateTrust() else { return }

        let discoveredIDs = Set(result.windows.map(\.id))
        var orderedIDs = tracked.map(\.id).filter(discoveredIDs.contains)
        orderedIDs.append(contentsOf: result.windows.map(\.id).filter { !orderedIDs.contains($0) })

        externalFocusedID = focusedID.flatMap { discoveredIDs.contains($0) ? $0 : nil }
        discoveries = result.discoveries
        spaceSnapshot = result.spaceSnapshot
        if let externalFocusedID, let index = orderedIDs.firstIndex(of: externalFocusedID), index != 0 {
            orderedIDs.remove(at: index)
            orderedIDs.insert(externalFocusedID, at: 0)
        }

        let byID = Dictionary(uniqueKeysWithValues: result.windows.map { ($0.id, $0) })
        tracked = orderedIDs.compactMap { byID[$0] }
        if trackSidebar {
            if fullscreenScreenIDs != result.fullscreenScreenIDs { fullscreenScreenIDs = result.fullscreenScreenIDs }
            badgeState.merge(activeAppIDs: result.activeAppIDs, reads: result.badgeReads)
            if appBadges != badgeState.badges { appBadges = badgeState.badges }
        }
        hasCompletedInitialScan = true
        publishWindows()
        if discoveryTask == nil, timer != nil, includeAllSpaces, let pid = result.pendingDiscoveryPID {
            discoveryTask = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self else { return }
                self.discoveryTask = nil
                self.refreshApplication(pid)
            }
        }
        drainScans()
    }

    func activate(_ id: String) {
        cancelActivation()
        if let window = localWindows[id]?.value {
            if window.isMiniaturized { window.deminiaturize(nil) }
            NSApp.unhide(nil)
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            publishWindows()
            return
        }
        guard hasAccessibility, let window = tracked.first(where: { $0.id == id }) else { return }
        let knownWindowIDs = Set(tracked.compactMap(\.windowID))
        let request = ActivationRequest()
        activationRequest = request
        activationTask = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled else { return }
            let task = self.activationTask
            let inputMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]) { _ in
                request.cancel()
                task?.cancel()
            }
            let localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]) { event in
                request.cancel()
                task?.cancel()
                return event
            }
            defer {
                if let inputMonitor { NSEvent.removeMonitor(inputMonitor) }
                if let localMonitor { NSEvent.removeMonitor(localMonitor) }
            }
            await self.raise(window, request: request)
            guard !Task.isCancelled,
                  let application = NSRunningApplication(processIdentifier: window.info.processID) else { return }
            if application.isHidden { application.unhide() }
            application.activate(options: [.activateIgnoringOtherApps])

            // Space transitions can restore their previous front app after the initial activation.
            if window.info.space?.isCurrent == false, let windowID = window.windowID {
                let deadline = ProcessInfo.processInfo.systemUptime + 1.5
                for _ in 0..<15 {
                    do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                    guard !Task.isCancelled, !application.isTerminated else { return }
                    guard ProcessInfo.processInfo.systemUptime < deadline else { break }
                    let outcome: (current: Bool, focused: Bool) = await withCheckedContinuation { continuation in
                        self.scanQueue.async {
                            let current = WindowSpaces.query()?.space(for: windowID)?.isCurrent == true
                            let app = AXUIElementCreateApplication(window.info.processID)
                            AXUIElementSetMessagingTimeout(app, 0.2)
                            let focused: AXUIElement? = Self.attribute(kAXFocusedWindowAttribute, of: app)
                            let surfaces = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
                            let topWindowID = surfaces.compactMap {
                                ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value
                            }.first(where: knownWindowIDs.contains)
                            continuation.resume(returning: (current, focused.flatMap(WindowSpaces.windowID) == windowID && topWindowID == windowID))
                        }
                    }
                    guard !Task.isCancelled else { return }
                    guard ProcessInfo.processInfo.systemUptime < deadline else { break }
                    let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
                    guard outcome.current else { continue }
                    if frontPID == window.info.processID && outcome.focused { continue }
                    application.activate(options: [.activateIgnoringOtherApps])
                    await self.raise(window, request: request)
                }
            }
            self.refreshApplication(window.info.processID)
        }
    }

    func cancelActivation() {
        activationRequest?.cancel()
        activationTask?.cancel()
    }

    private func raise(_ window: TrackedWindow, request: ActivationRequest) async {
        let logger = logger
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            scanQueue.async {
                defer { continuation.resume() }
                guard !request.isCancelled else { return }
                let app = AXUIElementCreateApplication(window.info.processID)
                AXUIElementSetMessagingTimeout(app, 0.2)
                AXUIElementSetMessagingTimeout(window.element, 0.2)
                if Self.boolAttribute(kAXMinimizedAttribute, of: window.element) {
                    guard !request.isCancelled else { return }
                    AXUIElementSetAttributeValue(window.element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
                }
                guard !request.isCancelled else { return }
                AXUIElementSetAttributeValue(window.element, kAXMainAttribute as CFString, kCFBooleanTrue)
                guard !request.isCancelled else { return }
                AXUIElementSetAttributeValue(app, kAXFocusedWindowAttribute as CFString, window.element)
                guard !request.isCancelled else { return }
                let result = AXUIElementPerformAction(window.element, kAXRaiseAction as CFString)
                if result != .success {
                    logger.error("Failed to raise window \(window.id, privacy: .public): AX error \(result.rawValue)")
                }
            }
        }
    }

    func canClose(_ id: String) -> Bool {
        if let window = localWindows[id]?.value {
            return window.standardWindowButton(.closeButton)?.isEnabled == true
        }
        guard hasAccessibility, let window = tracked.first(where: { $0.id == id }) else { return false }
        return Self.closeButton(of: window.element) != nil
    }

    func close(_ id: String) {
        guard canClose(id) else { return }
        if let window = localWindows[id]?.value {
            window.performClose(nil)
            publishWindows()
            return
        }
        guard let window = tracked.first(where: { $0.id == id }) else { return }
        scanQueue.async { [weak self] in
            guard let button = Self.closeButton(of: window.element) else { return }
            let result = AXUIElementPerformAction(button, kAXPressAction as CFString)
            if result != .success {
                self?.logger.error("Failed to close window \(id, privacy: .public): AX error \(result.rawValue)")
            }
            Task { @MainActor [weak self] in self?.refreshApplication(window.info.processID) }
        }
    }

    nonisolated private static func closeButton(of element: AXUIElement) -> AXUIElement? {
        AXUIElementSetMessagingTimeout(element, 0.2)
        guard let button: AXUIElement = attribute(kAXCloseButtonAttribute, of: element) else { return nil }
        AXUIElementSetMessagingTimeout(button, 0.2)
        return boolAttribute(kAXEnabledAttribute, of: button) ? button : nil
    }

    func registerLocalWindow(_ window: NSWindow, id: String) {
        localWindows[id] = WeakWindow(window)
        publishWindows()
    }

    func unregisterLocalWindow(id: String) {
        localWindows.removeValue(forKey: id)
        publishWindows()
    }

    static func selfCheck() -> Bool {
        _ = NSApplication.shared
        guard orderingSelfCheck(), closingSelfCheck(), fullscreenSelfCheck() else { return false }
        let service = WindowService()
        let id = "local:self-check"
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Settings"
        service.registerLocalWindow(window, id: id)
        guard service.windows.map(\.id) == [id] else { return false }
        service.registerLocalWindow(window, id: id)
        guard service.windows.filter({ $0.id == id }).count == 1 else { return false }
        service.unregisterLocalWindow(id: id)
        service.apply(ScanResult(windows: [], focusedID: nil, fullscreenScreenIDs: [],
                                 activeAppIDs: [], badgeReads: nil))
        guard !service.windows.contains(where: { $0.id == id }) else { return false }
        service.registerLocalWindow(window, id: id)
        guard service.windows.filter({ $0.id == id }).count == 1,
              AXIsProcessTrusted(),
              let dockPID = NSRunningApplication.runningApplications(
                  withBundleIdentifier: "com.apple.dock"
              ).first?.processIdentifier,
              let reads = scanDockBadges(processID: dockPID), !reads.isEmpty else { return false }
        let readable = reads.values.filter {
            if case .value = $0 { return true }
            return false
        }.count
        let badged = reads.values.filter {
            if case let .value(raw) = $0 { return DockBadgeState.displayValue(raw) != nil }
            return false
        }.count
        FileHandle.standardError.write(Data(
            "Dock badge self-check: mapped=\(reads.count) readable=\(readable) badged=\(badged)\n".utf8
        ))
        return true
    }

    static func closingSelfCheck() -> Bool {
        _ = NSApplication.shared
        let service = WindowService()
        let windows = (0..<2).map { _ in
            NSWindow(contentRect: NSRect(x: 100, y: 100, width: 200, height: 100),
                     styleMask: [.titled, .closable], backing: .buffered, defer: false)
        }
        defer { windows.forEach { $0.close() } }
        for (index, window) in windows.enumerated() {
            window.isReleasedWhenClosed = false
            window.orderFront(nil)
            service.registerLocalWindow(window, id: "close-\(index)")
        }
        guard windows.allSatisfy(\.isVisible), service.canClose("close-0"),
              !service.canClose("missing") else { return false }
        service.close("missing")
        service.close("close-0")
        guard !windows[0].isVisible, windows[1].isVisible else { return false }
        windows[1].standardWindowButton(.closeButton)?.isEnabled = false
        service.close("close-1")
        guard !service.canClose("close-1"), windows[1].isVisible else { return false }
        windows[1].standardWindowButton(.closeButton)?.isEnabled = true
        let delegate = ClosingCheckDelegate()
        windows[1].delegate = delegate
        return withExtendedLifetime(delegate) {
            service.close("close-1")
            return windows[1].isVisible
        }
    }

    static func orderingSelfCheck() -> Bool {
        _ = NSApplication.shared
        let service = WindowService()
        var samples = ["A", "B", "C", "D"].map { id in
            TrackedWindow(id: id, element: AXUIElementCreateApplication(0),
                          info: WindowInfo(id: id, appID: "self-check", appName: "Self-check",
                                           title: id, processID: 0))
        }
        for (step, sample) in [
            ([0, 1, 2], "A", ["A", "B", "C"]),
            ([1, 0, 2], "B", ["B", "A", "C"]),
            ([0, 1, 2], "A", ["A", "B", "C"]),
            ([3, 2, 1, 0], "A", ["A", "B", "C", "D"]),
            ([3, 2, 0], "C", ["C", "A", "D"])
        ].enumerated() {
            let (ids, focus, expected) = sample
            if step == 1 {
                samples[1].info = WindowInfo(id: "B", appID: "self-check", appName: "Self-check",
                                            title: "Updated B", documentURL: "file:///B", processID: 0)
            }
            service.apply(ScanResult(windows: ids.map { samples[$0] }, focusedID: focus,
                                     fullscreenScreenIDs: [], activeAppIDs: [], badgeReads: nil))
            guard service.tracked.map(\.id) == expected,
                  service.windows.map(\.id) == expected,
                  service.focusedWindowID == focus,
                  service.windows == expected.compactMap({ id in samples.first { $0.id == id }?.info })
            else { return false }
        }
        return true
    }

    static func focusSelfCheck() -> Bool {
        _ = NSApplication.shared
        let service = WindowService()
        service.tracked = [TrackedWindow(id: "A", element: AXUIElementCreateApplication(0),
                                        info: WindowInfo(id: "A", appID: "check", appName: "Check",
                                                         title: "A", processID: 0))]
        var updates: [String?] = []
        let subscription = service.$focusedWindowID.sink { updates.append($0) }
        defer { subscription.cancel() }
        for focus in ["A", nil, "A"] {
            service.externalFocusedID = focus
            service.publishWindows()
            guard service.focusedWindowID == focus, service.windows.map(\.id) == ["A"] else { return false }
        }
        return updates == [nil, "A", nil, "A"]
    }

    static func spacesSelfCheck() -> Bool {
        guard AXIsProcessTrusted(), let topology = WindowSpaces.query() else { return false }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let applications = NSWorkspace.shared.runningApplications.compactMap { app -> ApplicationSnapshot? in
            guard app.activationPolicy == .regular, app.processIdentifier != ownPID else { return nil }
            let id = app.bundleIdentifier ?? "pid:\(app.processIdentifier)"
            return ApplicationSnapshot(processID: app.processIdentifier, appID: id, appName: app.localizedName ?? id)
        }
        var previous: [TrackedWindow] = []
        var discoveryState: [pid_t: WindowSpaces.DiscoveryState] = [:]
        for pass in 0..<30 {
            let result = scan(applications: applications, previous: previous,
                              frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier,
                              badgeReads: nil, allSpaces: true, discoveries: discoveryState, now: Double(pass))
            previous = result.windows
            discoveryState = result.discoveries
        }
        let counts = Dictionary(grouping: previous, by: { $0.info.space?.index ?? 0 }).mapValues(\.count)
        let known = Set(previous.compactMap(\.windowID))
        let missing = topology.owners.filter { id, pid in
            applications.contains { $0.processID == pid } && topology.space(for: id)?.isCurrent == false && !known.contains(id)
        }
        print("Space inventory: spaces=\(topology.spaces.count) windowsByDesktop=\(counts) unresolvedOtherSpaceSurfaces=\(missing.count)")
        if let sample = previous.first(where: { !$0.info.isOnCurrentSpace }), let id = sample.windowID {
            var state = WindowSpaces.DiscoveryState()
            var found = false
            for _ in 0..<30 where !found {
                found = !WindowSpaces.discoverWindows(pid: sample.info.processID, targets: [id], state: &state).isEmpty
            }
            print("Other-space AX lookup: resolved=\(found) cursor=\(state.cursor)")
            guard found else { return false }
            state.cursor = UInt64.max / 2
            guard !WindowSpaces.discoverWindows(pid: sample.info.processID, targets: [id], state: &state).isEmpty,
                  state.cursor == UInt64.max / 2 else { return false }
            state.windows = [:]
            state.unresolved = []
            _ = WindowSpaces.discoverWindows(pid: sample.info.processID, targets: [id], state: &state)
            guard state.cursor < UInt64.max / 2 else { return false }
        }
        return !topology.spaces.filter(\.isCurrent).isEmpty && !previous.isEmpty
    }

    static func activationSelfCheck(appID: String, simulateRestoration: Bool, simulateCancellation: Bool = false) async -> Bool {
        guard AXIsProcessTrusted(), let app = NSRunningApplication.runningApplications(withBundleIdentifier: appID).first else { return false }
        let apps = [ApplicationSnapshot(processID: app.processIdentifier, appID: appID, appName: appID)]
        let startTime = ProcessInfo.processInfo.systemUptime
        var result = scan(applications: apps, previous: [], frontmostPID: nil, badgeReads: nil, allSpaces: true, now: startTime)
        for pass in 1..<30 where result.windows.isEmpty {
            result = scan(applications: apps, previous: result.windows, frontmostPID: nil,
                          badgeReads: nil, allSpaces: true, discoveries: result.discoveries, now: startTime + Double(pass))
        }
        guard (simulateCancellation ? result.windows.count >= 2 : result.windows.count == 1), var target = result.windows.first else {
            print("Activation check requires \(simulateCancellation ? "two or more" : "exactly one") eligible windows; found \(result.windows.count)")
            return false
        }
        let service = WindowService()
        service.hasAccessibility = true
        var restorationWindow: NSWindow?
        var restorationTask: Task<Void, Never>?
        var restorationObserved = false
        defer { restorationTask?.cancel(); restorationWindow?.orderOut(nil); service.stop() }
        if simulateRestoration {
            guard let space = target.info.space, space.isCurrent else { return false }
            target.info.space = WindowSpace(id: space.id, index: space.index, isCurrent: false)
            result = ScanResult(windows: [target], focusedID: nil, fullscreenScreenIDs: [],
                                activeAppIDs: [appID], badgeReads: nil)
            let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 240, height: 120),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.title = "Activation regression check"
            restorationWindow = window
            restorationTask = Task { @MainActor in
                for _ in 0..<50 {
                    do { try await Task.sleep(for: .milliseconds(20)) } catch { return }
                    guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.info.processID else { continue }
                    try? await Task.sleep(for: .milliseconds(350))
                    NSApp.activate(ignoringOtherApps: true)
                    window.makeKeyAndOrderFront(nil)
                    for _ in 0..<10 {
                        try? await Task.sleep(for: .milliseconds(5))
                        if NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid() {
                            restorationObserved = true
                            return
                        }
                    }
                    return
                }
            }
        }
        service.apply(result)
        if simulateCancellation {
            guard let newer = result.windows.last, newer.id != target.id else { return false }
            service.activate(newer.id)
            await service.activationTask?.value
            let appElement = AXUIElementCreateApplication(newer.info.processID)
            let before: AXUIElement? = attribute(kAXFocusedWindowAttribute, of: appElement)
            guard before.flatMap(WindowSpaces.windowID) == newer.windowID,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == newer.info.processID else { return false }
            let gate = DispatchSemaphore(value: 0)
            service.scanQueue.async { gate.wait() }
            service.activate(target.id)
            try? await Task.sleep(for: .milliseconds(50))
            service.cancelActivation()
            gate.signal()
            await service.activationTask?.value
            let focused: AXUIElement? = attribute(kAXFocusedWindowAttribute, of: appElement)
            let preserved = focused.flatMap(WindowSpaces.windowID) == newer.windowID
                && NSWorkspace.shared.frontmostApplication?.processIdentifier == newer.info.processID
            print("Cancelled queued activation preserved the newer window=\(preserved)")
            return preserved
        }
        print("Activation target: pid=\(target.info.processID) wid=\(target.windowID ?? 0) crossSpace=\(!target.info.isOnCurrentSpace)")
        service.activate(target.id)
        try? await Task.sleep(for: .seconds(2))
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let focused: AXUIElement? = attribute(kAXFocusedWindowAttribute, of: AXUIElementCreateApplication(target.info.processID))
        let focusedID = focused.flatMap(WindowSpaces.windowID)
        let current = WindowSpaces.query()?.space(for: target.windowID)?.isCurrent == true
        let onScreen = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let frontWindow = onScreen.first { ($0[kCGWindowLayer as String] as? Int) == 0 }
        let frontWindowID = (frontWindow?[kCGWindowNumber as String] as? NSNumber)?.uint32Value
        let frontWindowPID = (frontWindow?[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
        print("Activation outcome: front=\(front ?? 0) focused=\(focusedID ?? 0) topWindow=\(frontWindowID ?? 0) targetDesktopCurrent=\(current)")
        if simulateRestoration { print("Simulated Space focus restoration observed=\(restorationObserved)") }
        return (!simulateRestoration || restorationObserved) && front == target.info.processID && focusedID == target.windowID && frontWindowPID == target.info.processID && current
    }

    private func publishWindows() {
        localWindows = localWindows.filter { $0.value.value != nil }
        let localInfos = localWindows.compactMap { id, reference -> WindowInfo? in
            guard let window = reference.value else { return nil }
            let appID = Bundle.main.bundleIdentifier ?? "OpenContexts"
            let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
                ?? "OpenContexts"
            return WindowInfo(id: id, appID: appID, appName: appName, title: window.title,
                              processID: ProcessInfo.processInfo.processIdentifier,
                              space: spaceSnapshot?.space(for: CGWindowID(exactly: window.windowNumber)))
        }
        let allInfos = tracked.map(\.info) + localInfos
        let byID = Dictionary(uniqueKeysWithValues: allInfos.map { ($0.id, $0) })
        var orderedIDs = windows.map(\.id).filter { byID[$0] != nil }
        orderedIDs.append(contentsOf: allInfos.map(\.id).filter { !orderedIDs.contains($0) })
        let localFocusedID = NSApp.isActive
            ? localWindows.first { $0.value.value?.isKeyWindow == true }?.key
            : nil
        let focusedID = localFocusedID ?? externalFocusedID
        if focusedWindowID != focusedID { focusedWindowID = focusedID }
        if let focusedID, let index = orderedIDs.firstIndex(of: focusedID), index != 0 {
            orderedIDs.remove(at: index)
            orderedIDs.insert(focusedID, at: 0)
        }
        let published = orderedIDs.compactMap { byID[$0] }
        if windows != published { windows = published }
    }

    nonisolated private static func scanDockBadges(processID: pid_t) -> [String: DockBadgeRead]? {
        let dock = AXUIElementCreateApplication(processID)
        AXUIElementSetMessagingTimeout(dock, 0.15)
        let rootChildren: AttributeRead<[AXUIElement]> = readAttribute(kAXChildrenAttribute, of: dock)
        guard case let .value(children) = rootChildren else { return nil }

        var pending = children.map { ($0, 0) }
        var reads: [String: DockBadgeRead] = [:]
        while let (element, depth) = pending.popLast() {
            AXUIElementSetMessagingTimeout(element, 0.15)
            let role: String? = attribute(kAXRoleAttribute, of: element)
            if role == "AXDockItem" {
                let urlRead: AttributeRead<URL> = readAttribute(kAXURLAttribute, of: element)
                guard case let .value(url) = urlRead,
                      let appID = DockBadgeState.appID(for: url) else { continue }
                let statusRead: AttributeRead<String> = readAttribute("AXStatusLabel", of: element)
                switch statusRead {
                case let .value(value): reads[appID] = .value(value)
                case .noValue: reads[appID] = .value(nil)
                case .failure: reads[appID] = .failure
                }
            } else if depth < 7 {
                let childrenRead: AttributeRead<[AXUIElement]> = readAttribute(kAXChildrenAttribute, of: element)
                if case let .value(children) = childrenRead {
                    pending.append(contentsOf: children.map { ($0, depth + 1) })
                }
            }
        }
        return reads
    }

    nonisolated static func attribute<T>(_ name: String, of element: AXUIElement) -> T? {
        let read: AttributeRead<T> = readAttribute(name, of: element)
        guard case let .value(value) = read else { return nil }
        return value
    }

    nonisolated static func readAttribute<T>(_ name: String, of element: AXUIElement) -> AttributeRead<T> {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        if result == .attributeUnsupported || result == .noValue { return .noValue }
        guard result == .success else { return .failure(result) }
        guard let value else { return .noValue }
        guard let typed = value as? T else { return .noValue }
        return .value(typed)
    }

    nonisolated private static func boolAttribute(_ name: String, of element: AXUIElement) -> Bool {
        let value: CFTypeRef? = attribute(name, of: element)
        return (value as? Bool) ?? (value as? NSNumber)?.boolValue ?? false
    }

    nonisolated static func probeTaskCapability(of element: AXUIElement) -> CapabilityProbe {
        var readFailed = false
        for attributeName in [kAXMainAttribute, kAXMinimizedAttribute] {
            var settable = DarwinBoolean(false)
            let result = AXUIElementIsAttributeSettable(element, attributeName as CFString, &settable)
            if result == .success, settable.boolValue { return .value(.supported) }
            if result == .invalidUIElement { return .invalidElement }
            if result != .success, result != .attributeUnsupported, result != .noValue { readFailed = true }
        }

        let mainRead: AttributeRead<Bool> = readAttribute(kAXMainAttribute, of: element)
        switch mainRead {
        case .value(true): return .value(.supported)
        case .failure(.invalidUIElement): return .invalidElement
        case .failure: readFailed = true
        case .value(false), .noValue: break
        }

        return .value(readFailed ? .readFailed : .unsupported)
    }

    private static func fullscreenSelfCheck() -> Bool {
        for app in NSWorkspace.shared.runningApplications where app.processIdentifier != getpid() {
            let application = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(application, 0.05)
            let elements: [AXUIElement] = attribute(kAXWindowsAttribute, of: application) ?? []
            for element in elements {
                AXUIElementSetMessagingTimeout(element, 0.05)
                var candidate = TrackedWindow(id: "fullscreen-check", element: element,
                    info: WindowInfo(id: "fullscreen-check", appID: "check", appName: "Check", title: "Check", processID: app.processIdentifier,
                                     space: WindowSpace(id: 1, index: 1, isCurrent: true)))
                guard !fullscreenDisplays(in: [candidate], isFullscreen: { _ in true }).isEmpty else { continue }
                candidate.info.space = WindowSpace(id: 2, index: 2, isCurrent: false)
                return fullscreenDisplays(in: [candidate], isFullscreen: { _ in true }).isEmpty
            }
        }
        return false
    }

    nonisolated static func fullscreenDisplays(in windows: [TrackedWindow],
        isFullscreen: (AXUIElement) -> Bool = { boolAttribute("AXFullScreen", of: $0) }) -> Set<UInt32> {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success else { return [] }
        var displays = Array(repeating: CGDirectDisplayID(), count: Int(count))
        guard CGGetActiveDisplayList(count, &displays, &count) == .success else { return [] }

        let visibleFrames = onScreenWindowFrames()
        var result: Set<UInt32> = []
        for window in windows where window.info.isOnCurrentSpace && isFullscreen(window.element) {
            guard let frame = frame(of: window.element),
                  visibleFrames[window.info.processID]?.contains(where: {
                      $0.intersection(frame).area >= frame.area * 0.9
                  }) == true else { continue }
            if let display = displays.max(by: {
                CGDisplayBounds($0).intersection(frame).area < CGDisplayBounds($1).intersection(frame).area
            }), CGDisplayBounds(display).intersection(frame).area > 0 {
                result.insert(display)
            }
        }
        return result
    }

    /// Reads from the window server only, so a hung app cannot delay the switcher.
    func frontmostWindowFrame() -> CGRect? {
        guard let processID = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return nil }
        return Self.onScreenWindowFrames()[processID]?.first { $0.width >= 50 && $0.height >= 50 }
    }

    nonisolated private static func onScreenWindowFrames() -> [pid_t: [CGRect]] {
        guard let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return [:] }
        var result: [pid_t: [CGRect]] = [:]
        for window in raw where (window[kCGWindowLayer as String] as? Int) == 0 {
            guard let owner = window[kCGWindowOwnerPID as String] as? pid_t,
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { continue }
            result[owner, default: []].append(frame)
        }
        return result
    }

    nonisolated private static func frame(of element: AXUIElement) -> CGRect? {
        guard let position: AXValue = attribute(kAXPositionAttribute, of: element),
              let size: AXValue = attribute(kAXSizeAttribute, of: element),
              AXValueGetType(position) == .cgPoint,
              AXValueGetType(size) == .cgSize else { return nil }
        var origin = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(position, .cgPoint, &origin),
              AXValueGetValue(size, .cgSize, &dimensions) else { return nil }
        return CGRect(origin: origin, size: dimensions)
    }
}

private extension CGRect {
    var area: CGFloat { width * height }
}
