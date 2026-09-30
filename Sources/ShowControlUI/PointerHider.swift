#if os(macOS)
import AppKit

/// Hides the pointer over a presenting window, bringing it back as soon as the
/// mouse moves and hiding it again once it has been still for a moment. Only
/// the window's own mouse events rearm the hide, and the window's mouse-moved
/// setting is restored when hiding ends.
public final class PointerHider {
    private static let idleDelay = Duration.seconds(3)

    private var monitor: Any?
    private var rearm: Task<Void, Never>?
    private weak var window: NSWindow?
    private var windowAcceptedMouseMoved = false

    public init() {}

    public var isActive: Bool { monitor != nil }

    public func begin(in window: NSWindow) {
        guard monitor == nil else { return }

        self.window = window
        windowAcceptedMouseMoved = window.acceptsMouseMovedEvents
        window.acceptsMouseMovedEvents = true

        // Observed, not consumed, so other monitors still see the events.
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        ) { [weak self] event in
            if let self, event.window === self.window { self.scheduleHide() }
            return event
        }

        NSCursor.setHiddenUntilMouseMoves(true)
    }

    public func end() {
        rearm?.cancel()
        rearm = nil

        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }

        window?.acceptsMouseMovedEvents = windowAcceptedMouseMoved
        window = nil

        NSCursor.setHiddenUntilMouseMoves(false)
    }

    private func scheduleHide() {
        rearm?.cancel()
        rearm = Task {
            try? await Task.sleep(for: Self.idleDelay)
            guard !Task.isCancelled else { return }
            NSCursor.setHiddenUntilMouseMoves(true)
        }
    }
}
#endif
