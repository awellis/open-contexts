import AppKit
import ApplicationServices
import Darwin
import OpenContextsCore

enum WindowSpaces {
    struct DiscoveryState: @unchecked Sendable {
        var cursor: UInt64 = 0
        var unresolved: Set<CGWindowID> = []
        var windows: [CGWindowID: AXUIElement] = [:]
        var retry = DiscoveryRetry()

        mutating func deferAttempt(for targets: Set<CGWindowID>, now: TimeInterval) {
            let newTargets = !targets.isSubset(of: unresolved)
            if newTargets { cursor = 0 }
            unresolved = targets
            retry.attempted(at: now, madeProgress: false, hasNewTargets: newTargets)
        }
    }

    struct DiscoveryRetry {
        private(set) var nextAttempt = -Double.infinity
        private var delay: TimeInterval = 1

        mutating func attempted(at now: TimeInterval, madeProgress: Bool, hasNewTargets: Bool) {
            if madeProgress || hasNewTargets { delay = 1 }
            nextAttempt = now + delay
            delay = min(delay * 2, 60)
        }
    }

    struct Snapshot: Sendable {
        let spaces: [WindowSpace]
        let membership: [CGWindowID: [WindowSpace]]
        let owners: [CGWindowID: pid_t]

        func space(for windowID: CGWindowID?) -> WindowSpace? {
            guard let windowID, let spaces = membership[windowID] else { return nil }
            return spaces.first(where: \.isCurrent) ?? spaces.first
        }

        func discoveryTargets(eligiblePIDs: Set<pid_t>, knownIDs: Set<CGWindowID>) -> [pid_t: Set<CGWindowID>] {
            var targets: [pid_t: Set<CGWindowID>] = [:]
            for (id, pid) in owners where eligiblePIDs.contains(pid) && !knownIDs.contains(id) && space(for: id)?.isCurrent == false {
                targets[pid, default: []].insert(id)
            }
            return targets
        }
    }

    private struct API {
        let connection: @convention(c) () -> Int32
        let displays: @convention(c) (Int32) -> Unmanaged<CFArray>?
        let windows: @convention(c) (Int32, UInt32, CFArray, UInt32,
                                    UnsafeMutablePointer<UInt64>, UnsafeMutablePointer<UInt64>) -> Unmanaged<CFArray>?
        let windowID: @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
        let element: @convention(c) (CFData) -> Unmanaged<AXUIElement>?
    }

    // Load the read-only private APIs at runtime so unsupported macOS versions can fall back safely.
    private static let api: API? = {
        guard let library = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
              let connection = dlsym(library, "SLSMainConnectionID"),
              let displays = dlsym(library, "SLSCopyManagedDisplaySpaces"),
              let windows = dlsym(library, "SLSCopyWindowsWithOptionsAndTags"),
              let windowID = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_AXUIElementGetWindow"),
              let element = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_AXUIElementCreateWithRemoteToken") else { return nil }
        return API(connection: unsafeBitCast(connection, to: (@convention(c) () -> Int32).self),
                   displays: unsafeBitCast(displays, to: (@convention(c) (Int32) -> Unmanaged<CFArray>?).self),
                   windows: unsafeBitCast(windows, to: (@convention(c) (Int32, UInt32, CFArray, UInt32,
                       UnsafeMutablePointer<UInt64>, UnsafeMutablePointer<UInt64>) -> Unmanaged<CFArray>?).self),
                   windowID: unsafeBitCast(windowID, to: (@convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError).self),
                   element: unsafeBitCast(element, to: (@convention(c) (CFData) -> Unmanaged<AXUIElement>?).self))
    }()

    static func windowID(of element: AXUIElement) -> CGWindowID? {
        var id: CGWindowID = 0
        guard api?.windowID(element, &id) == .success, id != 0 else { return nil }
        return id
    }

    static func query() -> Snapshot? {
        guard let api, let displays = api.displays(api.connection())?.takeRetainedValue() as? [[String: Any]],
              !displays.isEmpty else { return nil }
        var spaces: [WindowSpace] = []
        var membership: [CGWindowID: [WindowSpace]] = [:]
        for display in displays {
            let current = (display["Current Space"] as? [String: Any])?["id64"] as? NSNumber
            for raw in display["Spaces"] as? [[String: Any]] ?? [] {
                guard let id = raw["id64"] as? NSNumber else { continue }
                let space = WindowSpace(id: id.uint64Value, index: spaces.count + 1,
                                        isCurrent: id == current, isFullscreen: (raw["type"] as? Int) == 4)
                spaces.append(space)
                var setTags: UInt64 = 0, clearTags: UInt64 = 0
                let ids = api.windows(api.connection(), 0, [id] as CFArray, 7, &setTags, &clearTags)?
                    .takeRetainedValue() as? [NSNumber] ?? []
                for window in ids { membership[window.uint32Value, default: []].append(space) }
            }
        }
        guard !spaces.isEmpty else { return nil }
        var owners: [CGWindowID: pid_t] = [:]
        let windows = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        for window in windows where (window[kCGWindowLayer as String] as? Int) == 0 {
            guard let id = window[kCGWindowNumber as String] as? NSNumber,
                  let pid = window[kCGWindowOwnerPID as String] as? pid_t,
                  membership[id.uint32Value] != nil else { continue }
            owners[id.uint32Value] = pid
        }
        return Snapshot(spaces: spaces, membership: membership, owners: owners)
    }

    /// Give untried targets priority, then try the most overdue app. One bounded batch per tick.
    static func nextDiscovery(in targets: [pid_t: Set<CGWindowID>], states: [pid_t: DiscoveryState],
                              now: TimeInterval) -> (pid: pid_t, targets: Set<CGWindowID>)? {
        targets.compactMap { pid, ids -> (pid: pid_t, targets: Set<CGWindowID>, due: TimeInterval)? in
            let state = states[pid, default: DiscoveryState()]
            let remaining = ids.subtracting(state.windows.keys)
            guard !remaining.isEmpty else { return nil }
            let due = remaining.isSubset(of: state.unresolved) ? state.retry.nextAttempt : -.infinity
            return due <= now ? (pid, remaining, due) : nil
        }.min { ($0.due, $0.pid) < ($1.due, $1.pid) }.map { ($0.pid, $0.targets) }
    }

    static func discoveryRetrySelfCheck() -> Bool {
        let pid: pid_t = 42
        let targets: [pid_t: Set<CGWindowID>] = [pid: [1]]
        var state = DiscoveryState()
        guard nextDiscovery(in: targets, states: [:], now: 0)?.pid == pid else { return false }
        state.deferAttempt(for: [1], now: 0)
        guard nextDiscovery(in: targets, states: [pid: state], now: 0.9) == nil,
              nextDiscovery(in: targets, states: [pid: state], now: 1)?.pid == pid else { return false }
        state.deferAttempt(for: [1], now: 1)
        guard nextDiscovery(in: targets, states: [pid: state], now: 2.9) == nil,
              nextDiscovery(in: [pid: [1, 2]], states: [pid: state], now: 2)?.targets == [1, 2],
              nextDiscovery(in: [11: [3], pid: [1]], states: [pid: state], now: 3)?.pid == 11 else { return false }
        for now in stride(from: 10.0, through: 510.0, by: 100) { state.deferAttempt(for: [1], now: now) }
        guard state.retry.nextAttempt == 570 else { return false }
        state.retry.attempted(at: 571, madeProgress: true, hasNewTargets: false)
        return state.retry.nextAttempt == 572
    }

    static func probe(pid: pid_t, targets: Set<CGWindowID>, state: inout DiscoveryState, now: TimeInterval) {
        let newTargets = !targets.isSubset(of: state.unresolved)
        let before = state.windows.count
        _ = discoverWindows(pid: pid, targets: targets, state: &state)
        let found = state.windows.count > before
        state.retry.attempted(at: now, madeProgress: found, hasNewTargets: newTargets)
    }

    static func discoverWindows(pid: pid_t, targets: Set<CGWindowID>, state: inout DiscoveryState) -> [AXUIElement] {
        guard let api, !targets.isEmpty else { return [] }
        let deadline = ProcessInfo.processInfo.systemUptime + 0.08
        var remaining = targets.subtracting(state.windows.keys)
        if !remaining.isSubset(of: state.unresolved) { state.cursor = 0 }
        state.unresolved = remaining
        guard !remaining.isEmpty else { return targets.compactMap { state.windows[$0] } }
        while ProcessInfo.processInfo.systemUptime < deadline {
            // shortcut: remote AX tokens use an undocumented 20-byte ABI; revisit if macOS changes it.
            var token = Data()
            for value in [UInt32(bitPattern: pid), 0, 0x636f636f] {
                var field = value.littleEndian
                withUnsafeBytes(of: &field) { token.append(contentsOf: $0) }
            }
            var field = state.cursor.littleEndian
            withUnsafeBytes(of: &field) { token.append(contentsOf: $0) }
            guard let element = api.element(token as CFData)?.takeRetainedValue() else {
                state.cursor &+= 1
                continue
            }
            AXUIElementSetMessagingTimeout(element, 0.02)
            var id: CGWindowID = 0
            let idResult = api.windowID(element, &id)
            if idResult == .cannotComplete { break }
            guard idResult == .success, remaining.contains(id) else { state.cursor &+= 1; continue }
            var role: CFTypeRef?
            let roleResult = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
            if roleResult == .cannotComplete { break }
            state.cursor &+= 1
            guard roleResult == .success,
                  role as? String == kAXWindowRole else { continue }
            state.windows[id] = element
            remaining.remove(id)
            if remaining.isEmpty { break }
        }
        state.unresolved = remaining
        return targets.compactMap { state.windows[$0] }
    }
}
