import Foundation
#if os(iOS)
import UIKit
#endif

@MainActor
public final class ScreenAwakeController {
    private let reason: String

#if os(macOS)
    private var activity: NSObjectProtocol?
#elseif os(iOS)
    private var isEnabled = false
    // UIKit's idle timer is process-wide; each controller releases only its own request.
    private static var activeRequestCount = 0
#endif

    public init(reason: String) {
        self.reason = reason
    }

    public func setEnabled(_ enabled: Bool) {
#if os(macOS)
        if enabled {
            guard activity == nil else { return }
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .idleDisplaySleepDisabled],
                reason: reason
            )
        } else {
            guard let activity else { return }
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
#elseif os(iOS)
        guard isEnabled != enabled else { return }
        isEnabled = enabled
        Self.activeRequestCount += enabled ? 1 : -1
        UIApplication.shared.isIdleTimerDisabled = Self.activeRequestCount > 0
#endif
    }

    isolated deinit {
#if os(macOS)
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
        }
#elseif os(iOS)
        if isEnabled {
            Self.activeRequestCount -= 1
            UIApplication.shared.isIdleTimerDisabled = Self.activeRequestCount > 0
        }
#endif
    }
}
