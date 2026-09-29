import Foundation

/// An OSC time tag in NTP format. Raw value `1` means "immediately"; when to
/// act on any other value is the receiving app's policy.
public struct OSCTimeTag: Hashable, Sendable {
    public var rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    public static let immediate = OSCTimeTag(rawValue: 1)

    public var isImmediate: Bool { rawValue == 1 }
}

public enum OSCValue: Hashable, Sendable {
    case int32(Int32)
    case float32(Float)
    case string(String)
    case blob(Data)
    case int64(Int64)
    case double(Double)
    case timeTag(OSCTimeTag)
    case symbol(String)
    case `true`
    case `false`
    case null
    case impulse
    case array([OSCValue])

    public var stringValue: String? {
        switch self {
        case .string(let value), .symbol(let value): value
        default: nil
        }
    }
}

public struct OSCMessage: Hashable, Sendable {
    public var address: String
    public var arguments: [OSCValue]

    public init(_ address: String, _ arguments: [OSCValue] = []) {
        self.address = address
        self.arguments = arguments
    }

    public var addressComponents: [String] {
        address.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }

    /// Pattern characters stay valid because QLab accepts them in requests.
    public var isValidForSending: Bool {
        address.hasPrefix("/") && !address.unicodeScalars.contains {
            $0 == "\0" || CharacterSet.whitespacesAndNewlines.contains($0)
        }
    }
}

extension OSCMessage: CustomStringConvertible {
    public var description: String {
        guard !arguments.isEmpty else { return address }
        return "\(address) \(arguments.map(Self.render).joined(separator: " "))"
    }

    private static func render(_ value: OSCValue) -> String {
        switch value {
        case .int32(let value): String(value)
        case .int64(let value): String(value)
        case .float32(let value): String(value)
        case .double(let value): String(value)
        case .string(let value), .symbol(let value): "\"\(value)\""
        case .blob(let data): "<\(data.count) bytes>"
        case .timeTag(let tag): tag.isImmediate ? "immediate" : String(tag.rawValue)
        case .true: "true"
        case .false: "false"
        case .null: "nil"
        case .impulse: "impulse"
        case .array(let values): "[" + values.map(render).joined(separator: " ") + "]"
        }
    }
}

public struct OSCBundle: Hashable, Sendable {
    static let identifier = "#bundle"

    public var timeTag: OSCTimeTag
    public var elements: [OSCPacket]

    public init(timeTag: OSCTimeTag = .immediate, elements: [OSCPacket] = []) {
        self.timeTag = timeTag
        self.elements = elements
    }

    /// Messages in wire order, depth first. Time tags are not applied.
    public var flattenedMessages: [OSCMessage] {
        elements.flatMap(\.flattenedMessages)
    }
}

public indirect enum OSCPacket: Hashable, Sendable {
    case message(OSCMessage)
    case bundle(OSCBundle)

    public var flattenedMessages: [OSCMessage] {
        switch self {
        case .message(let message): [message]
        case .bundle(let bundle): bundle.flattenedMessages
        }
    }
}

public enum OSCEncodingError: Error, Hashable, Sendable {
    case invalidAddress(String)
}

extension OSCEncodingError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .invalidAddress(let address):
            "Cannot send an OSC message to a malformed address: \(address)"
        }
    }
}

extension OSCEncodingError: LocalizedError {
    public var errorDescription: String? { description }
}

/// Decoding failures carry the byte offset where the packet stopped making
/// sense, for diagnostics rather than operator alerts.
public enum OSCDecodingError: Error, Hashable, Sendable {
    case packetTooLarge(size: Int, limit: Int)
    case unexpectedEnd(offset: Int, needed: Int, available: Int)
    case invalidUTF8(offset: Int)
    case unterminatedString(offset: Int)
    case invalidPadding(offset: Int)
    case notAPacket(offset: Int, firstByte: UInt8)
    case malformedTypeTagString(offset: Int)
    case unknownTypeTag(offset: Int, tag: Character)
    case unbalancedArray(offset: Int)
    case invalidBundleIdentifier(offset: Int)
    case bundleElementOverrunsBuffer(offset: Int, declared: Int, remaining: Int)
    case blobOverrunsBuffer(offset: Int, declared: Int, remaining: Int)
    case negativeSize(offset: Int, declared: Int32)
    case trailingBytes(offset: Int, count: Int)
    case nestingLimitExceeded(offset: Int, limit: Int)
    case elementLimitExceeded(offset: Int, limit: Int)
    case argumentLimitExceeded(offset: Int, limit: Int)

    public var offset: Int {
        switch self {
        case .packetTooLarge:
            0
        case .unexpectedEnd(let offset, _, _),
             .invalidUTF8(let offset),
             .unterminatedString(let offset),
             .invalidPadding(let offset),
             .notAPacket(let offset, _),
             .malformedTypeTagString(let offset),
             .unknownTypeTag(let offset, _),
             .unbalancedArray(let offset),
             .invalidBundleIdentifier(let offset),
             .bundleElementOverrunsBuffer(let offset, _, _),
             .blobOverrunsBuffer(let offset, _, _),
             .negativeSize(let offset, _),
             .trailingBytes(let offset, _),
             .nestingLimitExceeded(let offset, _),
             .elementLimitExceeded(let offset, _),
             .argumentLimitExceeded(let offset, _):
            offset
        }
    }
}

extension OSCDecodingError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .packetTooLarge(let size, let limit):
            "Packet of \(size) bytes exceeds the \(limit)-byte limit."
        case .unexpectedEnd(let offset, let needed, let available):
            "Packet ended at byte \(offset): needed \(needed) bytes, had \(available)."
        case .invalidUTF8(let offset):
            "Invalid UTF-8 in string at byte \(offset)."
        case .unterminatedString(let offset):
            "Unterminated string starting at byte \(offset)."
        case .invalidPadding(let offset):
            "Non-zero or missing padding at byte \(offset)."
        case .notAPacket(let offset, let firstByte):
            "Not an OSC packet at byte \(offset): first byte is 0x\(String(firstByte, radix: 16)), expected '/' or '#'."
        case .malformedTypeTagString(let offset):
            "Type tag string at byte \(offset) does not begin with ','."
        case .unknownTypeTag(let offset, let tag):
            "Unknown OSC type tag '\(tag)' at byte \(offset)."
        case .unbalancedArray(let offset):
            "Unbalanced array brackets in the type tag string at byte \(offset)."
        case .invalidBundleIdentifier(let offset):
            "Bundle at byte \(offset) does not begin with '#bundle'."
        case .bundleElementOverrunsBuffer(let offset, let declared, let remaining):
            "Bundle element at byte \(offset) declares \(declared) bytes but only \(remaining) remain."
        case .blobOverrunsBuffer(let offset, let declared, let remaining):
            "Blob at byte \(offset) declares \(declared) bytes but only \(remaining) remain."
        case .negativeSize(let offset, let declared):
            "Negative size \(declared) declared at byte \(offset)."
        case .trailingBytes(let offset, let count):
            "\(count) unread bytes follow the message at byte \(offset)."
        case .nestingLimitExceeded(let offset, let limit):
            "Bundles or arrays nest deeper than \(limit) levels at byte \(offset)."
        case .elementLimitExceeded(let offset, let limit):
            "Packet contains more than \(limit) messages and bundles (at byte \(offset))."
        case .argumentLimitExceeded(let offset, let limit):
            "Packet contains more than \(limit) arguments (at byte \(offset))."
        }
    }
}

extension OSCDecodingError: LocalizedError {
    public var errorDescription: String? { description }
}
