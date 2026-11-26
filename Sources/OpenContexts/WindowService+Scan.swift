import AppKit
import ApplicationServices
import OpenContextsCore

extension WindowService {
    // Keep the existing AX eligibility and error handling together during scheduling changes.
    // pi-lens-ignore: cyclomatic_complexity, function_body_length
    nonisolated static func scan(
        applications: [ApplicationSnapshot],
        previous: [TrackedWindow],
        frontmostPID: pid_t?,
        badgeReads: [String: DockBadgeRead]?,
        allSpaces: Bool = false, discoveries: [pid_t: WindowSpaces.DiscoveryState] = [:],
        selectedPIDs: Set<pid_t>? = nil, scanSidebar: Bool = true,
        now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> ScanResult {
        var discovered: [TrackedWindow] = []
        var focusedElement: AXUIElement?
        var usedIDs: Set<String> = []
        let topology = WindowSpaces.query()
        let activePIDs = Set(applications.map(\.processID))
        var discoveryState = discoveries.filter { activePIDs.contains($0.key) }
        if let topology {
            for pid in Array(discoveryState.keys) {
                guard var state = discoveryState[pid] else { continue }
                state.windows = state.windows.filter { id, _ in topology.owners[id] == pid }
                state.unresolved = state.unresolved.filter { topology.owners[$0] == pid }
                discoveryState[pid] = state
            }
        }
        let knownIDs = Set(previous.compactMap(\.windowID))
        let targets = allSpaces ? topology?.discoveryTargets(eligiblePIDs: activePIDs, knownIDs: knownIDs) ?? [:] : [:]
        let discovery = WindowSpaces.nextDiscovery(in: targets, states: discoveryState, now: now)

        for application in applications {
            let pid = application.processID
            let scanWindows = selectedPIDs?.contains(pid) != false || discovery?.pid == pid
            if !scanWindows {
                let cached = previous.filter { $0.info.processID == pid }.map { window in
                    var window = window
                    window.info.space = topology?.space(for: window.windowID) ?? window.info.space
                    return window
                }
                discovered.append(contentsOf: cached)
                usedIDs.formUnion(cached.map(\.id))
                if pid != frontmostPID { continue }
            }
            let appElement = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(appElement, 0.2)
            if pid == frontmostPID { focusedElement = attribute(kAXFocusedWindowAttribute, of: appElement) }
            guard scanWindows else { continue }
            let appWindowsRead: AttributeRead<[AXUIElement]> = readAttribute(kAXWindowsAttribute, of: appElement)
            var appWindows: [AXUIElement]
            switch appWindowsRead {
            case let .value(windows):
                appWindows = windows
            case .failure(.invalidUIElement):
                appWindows = []
            case .noValue, .failure:
                discovered.append(contentsOf: previous.filter { $0.info.processID == application.processID }.map {
                    var cached = $0
                    cached.info.space = topology?.space(for: cached.windowID) ?? cached.info.space
                    return cached
                })
                usedIDs.formUnion(previous.lazy.filter { $0.info.processID == pid }.map(\.id))
                if let discovery, discovery.pid == pid {
                    var state = discoveryState[pid, default: WindowSpaces.DiscoveryState()]
                    state.deferAttempt(for: discovery.targets, now: now)
                    discoveryState[pid] = state
                }
                continue
            }
            for key in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
                let element: AXUIElement? = key == kAXFocusedWindowAttribute && pid == frontmostPID
                    ? focusedElement : attribute(key, of: appElement)
                if let window = element,
                   !appWindows.contains(where: { CFEqual($0, window) }) { appWindows.append(window) }
            }
            for window in previous where window.info.processID == application.processID {
                guard let id = window.windowID,
                      topology?.membership[id] != nil,
                      !appWindows.contains(where: { CFEqual($0, window.element) }) else { continue }
                appWindows.append(window.element)
            }
            if let discovery, discovery.pid == pid {
                let publishedIDs = Set(appWindows.compactMap(WindowSpaces.windowID))
                let pending = discovery.targets.subtracting(publishedIDs)
                if !pending.isEmpty {
                    var state = discoveryState[pid, default: WindowSpaces.DiscoveryState()]
                    WindowSpaces.probe(pid: pid, targets: pending, state: &state, now: now)
                    discoveryState[pid] = state
                }
            }
            for element in discoveryState[application.processID]?.windows.values ?? Dictionary<CGWindowID, AXUIElement>().values {
                if !appWindows.contains(where: { CFEqual($0, element) }) { appWindows.append(element) }
            }

            for element in appWindows {
                AXUIElementSetMessagingTimeout(element, 0.2)
                guard !discovered.contains(where: { CFEqual($0.element, element) }) else { continue }

                // ponytail: linear identity matching is simpler and fast for desktop-sized window lists.
                let existing = previous.first { !usedIDs.contains($0.id) && CFEqual($0.element, element) }
                let roleState: WindowCandidateState
                let roleRead: AttributeRead<String> = readAttribute(kAXRoleAttribute, of: element)
                switch roleRead {
                case let .value(role):
                    if role == kAXWindowRole {
                        let subroleRead: AttributeRead<String> = readAttribute(kAXSubroleAttribute, of: element)
                        switch subroleRead {
                        case let .value(subrole): roleState = .attributes(role: role, subrole: subrole)
                        case .noValue: roleState = .attributes(role: role, subrole: nil)
                        case let .failure(error):
                            roleState = error == .invalidUIElement ? .notListed : .attributeReadFailed
                        }
                    } else {
                        roleState = .attributes(role: role, subrole: nil)
                    }
                case .noValue:
                    roleState = .missingRole
                case let .failure(error):
                    roleState = error == .invalidUIElement ? .notListed : .attributeReadFailed
                    if error == .invalidUIElement, var state = discoveryState[application.processID] {
                        state.windows = state.windows.filter { !CFEqual($0.value, element) }
                        discoveryState[application.processID] = state
                    }
                }

                let title: String
                let titleRead: AttributeRead<String> = readAttribute(kAXTitleAttribute, of: element)
                switch titleRead {
                case let .value(value):
                    title = value
                case .noValue:
                    title = ""
                case .failure(.invalidUIElement):
                    continue
                case .failure:
                    guard let existing else { continue }
                    title = existing.info.title
                }

                let document: String?
                let documentRead: AttributeRead<String> = readAttribute(kAXDocumentAttribute, of: element)
                switch documentRead {
                case let .value(value):
                    document = value
                case .failure(.invalidUIElement):
                    continue
                case .failure:
                    guard let existing else { continue }
                    document = existing.info.documentURL
                case .noValue:
                    let urlRead: AttributeRead<URL> = readAttribute(kAXURLAttribute, of: element)
                    switch urlRead {
                    case let .value(value):
                        document = value.absoluteString
                    case .noValue:
                        document = nil
                    case .failure(.invalidUIElement):
                        continue
                    case .failure:
                        guard let existing else { continue }
                        document = existing.info.documentURL
                    }
                }

                let hasTitle = !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                let hasDocument = document?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                let isModal: Bool
                let modalStatusUnknown: Bool
                let modalRead: AttributeRead<Bool> = readAttribute(kAXModalAttribute, of: element)
                switch modalRead {
                case let .value(value):
                    isModal = value
                    modalStatusUnknown = false
                case .noValue:
                    isModal = false
                    modalStatusUnknown = roleState == .attributes(role: "AXWindow", subrole: "AXDialog")
                        || roleState == .attributes(role: "AXWindow", subrole: "AXSystemDialog")
                case .failure(.invalidUIElement):
                    continue
                case .failure:
                    isModal = false
                    modalStatusUnknown = true
                }

                let taskCapability: WindowTaskCapability
                switch probeTaskCapability(of: element) {
                case let .value(value):
                    taskCapability = modalStatusUnknown && value == .unsupported ? .readFailed : value
                case .invalidElement:
                    continue
                }

                guard WindowEligibilityPolicy.shouldInclude(
                    roleState,
                    hasTitle: hasTitle,
                    hasDocument: hasDocument,
                    isModal: isModal,
                    modalStatusUnknown: modalStatusUnknown,
                    taskCapability: taskCapability,
                    previouslyTracked: existing != nil
                ) else { continue }

                let id = existing?.id ?? UUID().uuidString
                let windowID = existing?.windowID ?? WindowSpaces.windowID(of: element)
                usedIDs.insert(id)
                discovered.append(TrackedWindow(
                    id: id,
                    element: element,
                    info: WindowInfo(
                        id: id,
                        appID: application.appID,
                        appName: application.appName,
                        title: title,
                        documentURL: document,
                        processID: application.processID,
                        space: topology?.space(for: windowID)
                    ),
                    windowID: windowID
                ))
            }
        }

        let focusedID = focusedElement.flatMap { focused in
            discovered.first { CFEqual($0.element, focused) }?.id
        }
        let resolved = Set(discovered.compactMap(\.windowID))
        let pending = targets.mapValues { $0.subtracting(resolved) }
        return ScanResult(
            windows: discovered,
            focusedID: focusedID,
            fullscreenScreenIDs: scanSidebar ? fullscreenDisplays(in: discovered) : [],
            activeAppIDs: Set(applications.map(\.appID)),
            badgeReads: badgeReads,
            discoveries: discoveryState,
            spaceSnapshot: topology,
            pendingDiscoveryPID: discovery == nil ? nil : WindowSpaces.nextDiscovery(in: pending, states: discoveryState, now: now + 1)?.pid
        )
    }
}
