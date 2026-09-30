#if os(macOS)
import AppKit
#else
import UIKit
#endif

public enum Pasteboard {
    /// Replaces the general pasteboard's contents with `text`.
    public static func copy(_ text: String) {
#if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
#else
        UIPasteboard.general.string = text
#endif
    }
}
