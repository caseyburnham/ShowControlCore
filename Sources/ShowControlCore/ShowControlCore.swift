import Foundation

public enum ShowControlDefaults {
    public static let qlabTCPPort = 53_000
    public static let viewtifulOSCUDPPort = 53_001
    public static let qlabBonjourService = "_qlab._tcp"
}

/// Platform-neutral values used by both apps. SwiftUI Animation values stay in
/// the app targets so each platform can apply its own native Reduce Motion policy.
public enum ShowControlMotion {
    public static let cueChangeResponse = 0.34
    public static let chromeResponse = 0.50
    public static let statusDuration = 0.45
    public static let controlsFadeDuration = 0.18
}

public enum ShowControlDesignTokens {
    public static let compactSpacing = 8.0
    public static let regularSpacing = 12.0
}
