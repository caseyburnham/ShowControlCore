import SwiftUI

extension View {
    /// The companion apps' Reduce Motion policy for a whole presentation: with
    /// the setting on, no change inside it animates, whatever started the
    /// animation. Presentations and hosted AppKit or UIKit roots do not inherit
    /// it, so each window, sheet, popover and hosting-controller root applies
    /// it once.
    public func reducingMotionWhenRequested() -> some View {
        modifier(ReducedMotionTransactions())
    }
}

private struct ReducedMotionTransactions: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.transaction { transaction in
            if reduceMotion {
                transaction.animation = nil
                transaction.disablesAnimations = true
            }
        }
    }
}
