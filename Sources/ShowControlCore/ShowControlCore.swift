import Foundation

/// Shared network roles used by the companion apps. QLab and PDF/MIDI behavior
/// remains app-specific; this type only names the transport boundary.
public enum ShowControlTransport: String, Codable, Hashable, Sendable {
    case bonjour
    case tcp
    case udp
}

/// A deliberately small vocabulary for surfaces that need to describe transport
/// truth without importing either app's domain model.
public enum ShowControlStatus: String, Codable, Hashable, Sendable {
    case offline
    case starting
    case connecting
    case connected
    case degraded
    case stale
    case failed

    public var label: String {
        switch self {
        case .offline: "Not Connected"
        case .starting: "Starting"
        case .connecting: "Connecting"
        case .connected: "Connected"
        case .degraded: "Connection Degraded"
        case .stale: "Data May Be Stale"
        case .failed: "Unavailable"
        }
    }
}

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
    public static let controlCornerRadius = 10.0
}

public enum ShowControlOSCValue: Hashable, Sendable {
    case integer(Int32)
    case float(Float)
    case string(String)
    case blob(Data)
    case boolean(Bool)
    case nilValue
    case impulse
    case array([ShowControlOSCValue])
}

public struct ShowControlOSCMessage: Hashable, Sendable {
    public let address: String
    public let arguments: [ShowControlOSCValue]

    public init(address: String, arguments: [ShowControlOSCValue] = []) {
        self.address = address
        self.arguments = arguments
    }
}

public struct ShowControlOSCBundle: Hashable, Sendable {
    public let timeTag: UInt64
    public let elements: [ShowControlOSCPacket]

    public init(timeTag: UInt64 = 1, elements: [ShowControlOSCPacket]) {
        self.timeTag = timeTag
        self.elements = elements
    }
}

public indirect enum ShowControlOSCPacket: Hashable, Sendable {
    case message(ShowControlOSCMessage)
    case bundle(ShowControlOSCBundle)
}

public enum ShowControlOSCError: Error, Equatable, Sendable {
    case emptyPacket
    case packetTooLarge
    case invalidAddress
    case invalidString
    case invalidPadding
    case invalidTypeTags
    case truncated
    case invalidBlobLength
    case invalidBundle
    case nestingLimitExceeded
    case elementLimitExceeded
}

public enum ShowControlOSCCodec {
    public struct Limits: Sendable {
        public var maxPacketBytes: Int
        public var maxNestingDepth: Int
        public var maxBundleElements: Int

        public init(
            maxPacketBytes: Int = 1_048_576,
            maxNestingDepth: Int = 8,
            maxBundleElements: Int = 1_024
        ) {
            self.maxPacketBytes = maxPacketBytes
            self.maxNestingDepth = maxNestingDepth
            self.maxBundleElements = maxBundleElements
        }
    }

    public static func encode(_ packet: ShowControlOSCPacket) -> Data {
        var data = Data()
        append(packet, to: &data)
        return data
    }

    public static func decode(
        _ data: Data,
        limits: Limits = Limits()
    ) throws -> ShowControlOSCPacket {
        try decode(data, limits: limits, depth: 0)
    }

    private static func decode(
        _ data: Data,
        limits: Limits,
        depth: Int
    ) throws -> ShowControlOSCPacket {
        guard !data.isEmpty else { throw ShowControlOSCError.emptyPacket }
        guard data.count <= limits.maxPacketBytes else { throw ShowControlOSCError.packetTooLarge }
        var reader = Reader(data)
        let packet = try decodePacket(&reader, limits: limits, depth: depth)
        guard reader.isAtEnd else { throw ShowControlOSCError.truncated }
        return packet
    }

    private static func append(_ packet: ShowControlOSCPacket, to data: inout Data) {
        switch packet {
        case .message(let message):
            data.appendPaddedString(message.address)
            var tags = ","
            tags += message.arguments.map(typeTag).joined()
            data.appendPaddedString(tags)
            for argument in message.arguments { append(argument, to: &data) }
        case .bundle(let bundle):
            data.append(Data("#bundle".utf8))
            data.append(0)
            data.appendBigEndian(bundle.timeTag)
            for element in bundle.elements {
                let encoded = encode(element)
                data.appendBigEndian(UInt32(encoded.count))
                data.append(encoded)
            }
        }
    }

    private static func append(_ value: ShowControlOSCValue, to data: inout Data) {
        switch value {
        case .integer(let value): data.appendBigEndian(UInt32(bitPattern: value))
        case .float(let value): data.appendBigEndian(value.bitPattern)
        case .string(let value): data.appendPaddedString(value)
        case .blob(let value):
            data.appendBigEndian(UInt32(value.count))
            data.append(value)
            data.appendPadding(for: value.count)
        case .boolean, .nilValue, .impulse:
            break
        case .array(let values):
            for value in values { append(value, to: &data) }
        }
    }

    private static func typeTag(_ value: ShowControlOSCValue) -> String {
        switch value {
        case .integer: "i"
        case .float: "f"
        case .string: "s"
        case .blob: "b"
        case .boolean(let value): value ? "T" : "F"
        case .nilValue: "N"
        case .impulse: "I"
        case .array(let values): "[" + values.map(typeTag).joined() + "]"
        }
    }

    private static func decodePacket(
        _ reader: inout Reader,
        limits: Limits,
        depth: Int
    ) throws -> ShowControlOSCPacket {
        guard depth <= limits.maxNestingDepth else { throw ShowControlOSCError.nestingLimitExceeded }
        let start = reader.offset
        let identifier = try reader.readPaddedString()
        if identifier == "#bundle" {
            guard reader.remaining >= 8 else { throw ShowControlOSCError.invalidBundle }
            let timeTag = try reader.readUInt64()
            var elements: [ShowControlOSCPacket] = []
            while !reader.isAtEnd {
                guard elements.count < limits.maxBundleElements else {
                    throw ShowControlOSCError.elementLimitExceeded
                }
                let size = Int(try reader.readUInt32())
                guard size > 0, size <= reader.remaining else { throw ShowControlOSCError.invalidBundle }
                let elementData = try reader.readData(count: size)
                elements.append(try decode(elementData, limits: limits, depth: depth + 1))
            }
            return .bundle(ShowControlOSCBundle(timeTag: timeTag, elements: elements))
        }

        guard identifier.hasPrefix("/") else { throw ShowControlOSCError.invalidAddress }
        let tags = try reader.readPaddedString()
        guard tags.first == "," else { throw ShowControlOSCError.invalidTypeTags }
        var tagReader = Array(tags.dropFirst())
        var arguments: [ShowControlOSCValue] = []
        while !tagReader.isEmpty {
            arguments.append(try decodeValue(&reader, tags: &tagReader))
        }
        guard reader.offset > start else { throw ShowControlOSCError.truncated }
        return .message(ShowControlOSCMessage(address: identifier, arguments: arguments))
    }

    private static func decodeValue(
        _ reader: inout Reader,
        tags: inout [Character]
    ) throws -> ShowControlOSCValue {
        guard let tag = tags.first else { throw ShowControlOSCError.invalidTypeTags }
        tags.removeFirst()
        switch tag {
        case "i": return .integer(Int32(bitPattern: try reader.readUInt32()))
        case "f": return .float(Float(bitPattern: try reader.readUInt32()))
        case "s": return .string(try reader.readPaddedString())
        case "b":
            let count = Int(try reader.readUInt32())
            guard count >= 0, count <= reader.remaining else { throw ShowControlOSCError.invalidBlobLength }
            return .blob(try reader.readData(count: count, padded: true))
        case "T": return .boolean(true)
        case "F": return .boolean(false)
        case "N": return .nilValue
        case "I": return .impulse
        case "[":
            var values: [ShowControlOSCValue] = []
            while tags.first != "]" {
                guard !tags.isEmpty else { throw ShowControlOSCError.invalidTypeTags }
                values.append(try decodeValue(&reader, tags: &tags))
            }
            tags.removeFirst()
            return .array(values)
        default: throw ShowControlOSCError.invalidTypeTags
        }
    }
}

private struct Reader {
    let data: Data
    var offset = 0

    init(_ data: Data) { self.data = data }

    var remaining: Int { data.count - offset }
    var isAtEnd: Bool { offset == data.count }

    mutating func readPaddedString() throws -> String {
        guard offset < data.count else { throw ShowControlOSCError.truncated }
        guard let terminator = data[offset...].firstIndex(of: 0) else {
            throw ShowControlOSCError.invalidString
        }
        guard let value = String(data: data[offset..<terminator], encoding: .utf8) else {
            throw ShowControlOSCError.invalidString
        }
        let consumed = terminator - offset + 1
        let padded = (consumed + 3) & ~3
        guard padded <= remaining else { throw ShowControlOSCError.truncated }
        guard data[terminator..<(offset + padded)].allSatisfy({ $0 == 0 }) else {
            throw ShowControlOSCError.invalidPadding
        }
        offset += padded
        return value
    }

    mutating func readUInt32() throws -> UInt32 {
        guard remaining >= 4 else { throw ShowControlOSCError.truncated }
        let value = data[offset..<(offset + 4)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        offset += 4
        return value
    }

    mutating func readUInt64() throws -> UInt64 {
        guard remaining >= 8 else { throw ShowControlOSCError.truncated }
        let value = data[offset..<(offset + 8)].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        offset += 8
        return value
    }

    mutating func readData(count: Int, padded: Bool = false) throws -> Data {
        guard count >= 0, count <= remaining else { throw ShowControlOSCError.truncated }
        let result = Data(data[offset..<(offset + count)])
        offset += count
        if padded {
            let padding = (4 - (count % 4)) % 4
            guard padding <= remaining else { throw ShowControlOSCError.truncated }
            guard data[offset..<(offset + padding)].allSatisfy({ $0 == 0 }) else {
                throw ShowControlOSCError.invalidPadding
            }
            offset += padding
        }
        return result
    }
}

private extension Data {
    mutating func appendPaddedString(_ string: String) {
        let bytes = Array(string.utf8)
        append(contentsOf: bytes)
        append(0)
        appendPadding(for: bytes.count + 1)
    }

    mutating func appendPadding(for count: Int) {
        let padding = (4 - (count % 4)) % 4
        append(contentsOf: repeatElement(UInt8(0), count: padding))
    }

    mutating func appendBigEndian(_ value: UInt32) {
        append(contentsOf: [
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff)
        ])
    }

    mutating func appendBigEndian(_ value: UInt64) {
        append(contentsOf: [
            UInt8((value >> 56) & 0xff),
            UInt8((value >> 48) & 0xff),
            UInt8((value >> 40) & 0xff),
            UInt8((value >> 32) & 0xff),
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff)
        ])
    }
}
