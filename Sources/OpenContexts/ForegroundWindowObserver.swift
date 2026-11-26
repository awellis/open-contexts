import AppKit
import ApplicationServices

/// Observe only the front app. Slow Accessibility registration stays off the UI thread.
@MainActor
final class ForegroundWindowObserver {
    private struct Registration: @unchecked Sendable {
        let observer: AXObserver
        let reportsFocus: Bool
    }

    private let queue: DispatchQueue
    private let onChange: @MainActor (Bool) -> Void
    private var processID: pid_t?
    private var registration: Registration?
    private var generation = 0

    var reportsFocus: Bool { registration?.reportsFocus == true }

    init(queue: DispatchQueue, onChange: @escaping @MainActor (Bool) -> Void) {
        self.queue = queue
        self.onChange = onChange
    }

    func watch(_ pid: pid_t?) {
        guard processID != pid else { return }
        stop()
        guard let pid else { return }
        processID = pid
        let generation = generation
        queue.async { [weak self] in
            guard let self else { return }
            var observer: AXObserver?
            guard AXObserverCreate(pid, Self.receive, &observer) == .success, let observer else { return }
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.1)
            let refcon = Unmanaged.passUnretained(self).toOpaque()
            let reportsFocus = AXObserverAddNotification(observer, app, kAXFocusedWindowChangedNotification as CFString, refcon) == .success
            AXObserverAddNotification(observer, app, kAXWindowCreatedNotification as CFString, refcon)
            let registration = Registration(observer: observer, reportsFocus: reportsFocus)
            Task { @MainActor [weak self] in
                guard let self, self.generation == generation else { return }
                self.registration = registration
                CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(registration.observer), .commonModes)
            }
        }
    }

    func stop() {
        generation &+= 1
        processID = nil
        if let registration {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(registration.observer), .commonModes)
            self.registration = nil
        }
    }

    private nonisolated static let receive: AXObserverCallback = { observer, _, notification, refcon in
        guard let refcon else { return }
        let inventoryChanged = notification as String == kAXWindowCreatedNotification
        // This callback is attached only to the main run loop.
        MainActor.assumeIsolated {
            let watcher = Unmanaged<ForegroundWindowObserver>.fromOpaque(refcon).takeUnretainedValue()
            guard let current = watcher.registration, CFEqual(observer, current.observer) else { return }
            watcher.onChange(inventoryChanged)
        }
    }
}
