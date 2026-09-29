import Foundation

/// OSC 1.0/1.1 wire encoding with bounded, linear-time decoding.
///
/// Decoding is strict about structure (zero padding, fully consumed messages)
/// but accepts two historical forms: messages that omit the type tag string,
/// and zero-length bundle elements, which are skipped.
public enum OSCCodec {
    /// Each transport chooses its own budget: a QLab TCP reply can be
    /// megabytes of JSON, while a UDP page command is a few dozen bytes.
    public struct Limits: Sendable {
        public var maxPacketBytes: Int
        /// Combined depth of bundles and arrays below the top-level packet.
        public var maxNestingDepth: Int
        /// Messages and bundles across the whole packet.
        public var maxElements: Int
        /// Argument values across the whole packet, including array contents.
        public var maxArguments: Int

        public init(
            maxPacketBytes: Int = 1_048_576,
            maxNestingDepth: Int = 8,
            maxElements: Int = 1_024,
            maxArguments: Int = 4_096
        ) {
            self.maxPacketBytes = maxPacketBytes
            self.maxNestingDepth = maxNestingDepth
            self.maxElements = maxElements
            self.maxArguments = maxArguments
        }
    }

    static let alignment = 4

    public static func encode(_ message: OSCMessage) throws(OSCEncodingError) -> Data {
        try encode(.message(message))
    }

    public static func encode(_ packet: OSCPacket) throws(OSCEncodingError) -> Data {
        var data = Data()
        try append(packet, to: &data)
        return data
    }

    public static func decode(
        _ data: Data,
        limits: Limits = Limits()
    ) throws(OSCDecodingError) -> OSCPacket {
        guard data.count <= limits.maxPacketBytes else {
            throw .packetTooLarge(size: data.count, limit: limits.maxPacketBytes)
        }
        var decoder = Decoder(bytes: Array(data), limits: limits)
        return try decoder.decodePacket(limit: decoder.bytes.count, depth: 0)
    }

    private static func append(_ packet: OSCPacket, to data: inout Data) throws(OSCEncodingError) {
        switch packet {
        case .message(let message):
            guard message.isValidForSending else { throw .invalidAddress(message.address) }
            data.appendOSCString(message.address)
            var tags = ","
            for argument in message.arguments { appendTypeTag(argument, to: &tags) }
            data.appendOSCString(tags)
            for argument in message.arguments { append(argument, to: &data) }
        case .bundle(let bundle):
            data.appendOSCString(OSCBundle.identifier)
            data.appendBigEndian(bundle.timeTag.rawValue)
            for element in bundle.elements {
                var encoded = Data()
                try append(element, to: &encoded)
                data.appendBigEndian(UInt32(encoded.count))
                data.append(encoded)
            }
        }
    }

    private static func append(_ value: OSCValue, to data: inout Data) {
        switch value {
        case .int32(let value): data.appendBigEndian(UInt32(bitPattern: value))
        case .float32(let value): data.appendBigEndian(value.bitPattern)
        case .string(let value), .symbol(let value): data.appendOSCString(value)
        case .blob(let value): data.appendOSCBlob(value)
        case .int64(let value): data.appendBigEndian(UInt64(bitPattern: value))
        case .double(let value): data.appendBigEndian(value.bitPattern)
        case .timeTag(let value): data.appendBigEndian(value.rawValue)
        case .true, .false, .null, .impulse: break
        case .array(let values): for value in values { append(value, to: &data) }
        }
    }

    private static func appendTypeTag(_ value: OSCValue, to tags: inout String) {
        switch value {
        case .int32: tags.append("i")
        case .float32: tags.append("f")
        case .string: tags.append("s")
        case .blob: tags.append("b")
        case .int64: tags.append("h")
        case .double: tags.append("d")
        case .timeTag: tags.append("t")
        case .symbol: tags.append("S")
        case .true: tags.append("T")
        case .false: tags.append("F")
        case .null: tags.append("N")
        case .impulse: tags.append("I")
        case .array(let values):
            tags.append("[")
            for value in values { appendTypeTag(value, to: &tags) }
            tags.append("]")
        }
    }
}

/// Every read is bounded by `limit`, the end of the packet or bundle element
/// being decoded, so an element can never read into its neighbour.
private struct Decoder {
    let bytes: [UInt8]
    let limits: OSCCodec.Limits
    private var offset = 0
    private var elementCount = 0
    private var argumentCount = 0

    init(bytes: [UInt8], limits: OSCCodec.Limits) {
        self.bytes = bytes
        self.limits = limits
    }

    mutating func decodePacket(limit: Int, depth: Int) throws(OSCDecodingError) -> OSCPacket {
        guard depth <= limits.maxNestingDepth else {
            throw .nestingLimitExceeded(offset: offset, limit: limits.maxNestingDepth)
        }
        elementCount += 1
        guard elementCount <= limits.maxElements else {
            throw .elementLimitExceeded(offset: offset, limit: limits.maxElements)
        }
        guard offset < limit else {
            throw .unexpectedEnd(offset: offset, needed: 1, available: 0)
        }

        switch bytes[offset] {
        case UInt8(ascii: "#"): return .bundle(try decodeBundle(limit: limit, depth: depth))
        case UInt8(ascii: "/"): return .message(try decodeMessage(limit: limit, depth: depth))
        default: throw .notAPacket(offset: offset, firstByte: bytes[offset])
        }
    }

    private mutating func decodeBundle(limit: Int, depth: Int) throws(OSCDecodingError) -> OSCBundle {
        let identifierOffset = offset
        guard try readString(limit: limit) == OSCBundle.identifier else {
            throw .invalidBundleIdentifier(offset: identifierOffset)
        }
        let timeTag = OSCTimeTag(rawValue: try readUInt64(limit: limit))

        var elements: [OSCPacket] = []
        while offset < limit {
            let sizeOffset = offset
            let declared = Int32(bitPattern: try readUInt32(limit: limit))
            guard declared >= 0 else {
                throw .negativeSize(offset: sizeOffset, declared: declared)
            }
            let remaining = limit - offset
            guard Int(declared) <= remaining else {
                throw .bundleElementOverrunsBuffer(
                    offset: sizeOffset, declared: Int(declared), remaining: remaining
                )
            }
            guard declared > 0 else { continue }
            // Messages must consume their element exactly and bundles read to
            // their limit, so the offset lands on the next size field.
            elements.append(try decodePacket(limit: offset + Int(declared), depth: depth + 1))
        }
        return OSCBundle(timeTag: timeTag, elements: elements)
    }

    private mutating func decodeMessage(limit: Int, depth: Int) throws(OSCDecodingError) -> OSCMessage {
        let address = try readString(limit: limit)
        guard offset < limit else { return OSCMessage(address) }

        let tagsOffset = offset
        let tags = try readStringBytes(limit: limit)
        guard tags.first == UInt8(ascii: ",") else {
            throw .malformedTypeTagString(offset: tagsOffset)
        }

        // A cursor over the tag bytes keeps parsing linear in the tag count.
        var cursor = tags.startIndex + 1
        let arguments = try decodeArguments(
            tags: tags, cursor: &cursor, limit: limit, depth: depth, inArray: false
        )
        guard offset == limit else {
            throw .trailingBytes(offset: offset, count: limit - offset)
        }
        return OSCMessage(address, arguments)
    }

    private mutating func decodeArguments(
        tags: ArraySlice<UInt8>,
        cursor: inout Int,
        limit: Int,
        depth: Int,
        inArray: Bool
    ) throws(OSCDecodingError) -> [OSCValue] {
        var values: [OSCValue] = []
        while cursor < tags.endIndex {
            let tagOffset = cursor
            let tag = tags[cursor]
            cursor += 1

            if tag == UInt8(ascii: "]") {
                guard inArray else { throw .unbalancedArray(offset: tagOffset) }
                return values
            }

            argumentCount += 1
            guard argumentCount <= limits.maxArguments else {
                throw .argumentLimitExceeded(offset: tagOffset, limit: limits.maxArguments)
            }

            if tag == UInt8(ascii: "[") {
                guard depth + 1 <= limits.maxNestingDepth else {
                    throw .nestingLimitExceeded(offset: tagOffset, limit: limits.maxNestingDepth)
                }
                values.append(.array(try decodeArguments(
                    tags: tags, cursor: &cursor, limit: limit, depth: depth + 1, inArray: true
                )))
            } else {
                values.append(try decodeScalar(tag: tag, tagOffset: tagOffset, limit: limit))
            }
        }
        guard !inArray else { throw .unbalancedArray(offset: cursor) }
        return values
    }

    private mutating func decodeScalar(
        tag: UInt8,
        tagOffset: Int,
        limit: Int
    ) throws(OSCDecodingError) -> OSCValue {
        switch tag {
        case UInt8(ascii: "i"): .int32(Int32(bitPattern: try readUInt32(limit: limit)))
        case UInt8(ascii: "f"): .float32(Float(bitPattern: try readUInt32(limit: limit)))
        case UInt8(ascii: "s"): .string(try readString(limit: limit))
        case UInt8(ascii: "S"): .symbol(try readString(limit: limit))
        case UInt8(ascii: "b"): .blob(try readBlob(limit: limit))
        case UInt8(ascii: "h"): .int64(Int64(bitPattern: try readUInt64(limit: limit)))
        case UInt8(ascii: "d"): .double(Double(bitPattern: try readUInt64(limit: limit)))
        case UInt8(ascii: "t"): .timeTag(OSCTimeTag(rawValue: try readUInt64(limit: limit)))
        case UInt8(ascii: "T"): .true
        case UInt8(ascii: "F"): .false
        case UInt8(ascii: "N"): .null
        case UInt8(ascii: "I"): .impulse
        default: throw .unknownTypeTag(offset: tagOffset, tag: Character(Unicode.Scalar(tag)))
        }
    }

    private func require(_ needed: Int, limit: Int) throws(OSCDecodingError) {
        let available = limit - offset
        guard needed <= available else {
            throw .unexpectedEnd(offset: offset, needed: needed, available: max(0, available))
        }
    }

    private mutating func readUInt32(limit: Int) throws(OSCDecodingError) -> UInt32 {
        try require(4, limit: limit)
        defer { offset += 4 }
        return UInt32(bytes[offset]) << 24
            | UInt32(bytes[offset + 1]) << 16
            | UInt32(bytes[offset + 2]) << 8
            | UInt32(bytes[offset + 3])
    }

    private mutating func readUInt64(limit: Int) throws(OSCDecodingError) -> UInt64 {
        let high = try readUInt32(limit: limit)
        let low = try readUInt32(limit: limit)
        return UInt64(high) << 32 | UInt64(low)
    }

    /// Returns the string's bytes without its terminator and consumes its padding.
    private mutating func readStringBytes(limit: Int) throws(OSCDecodingError) -> ArraySlice<UInt8> {
        let start = offset
        guard let terminator = bytes[start..<max(start, limit)].firstIndex(of: 0) else {
            throw .unterminatedString(offset: start)
        }
        let paddedEnd = start + ((terminator - start) / OSCCodec.alignment + 1) * OSCCodec.alignment
        try consumePadding(from: terminator + 1, to: paddedEnd, limit: limit)
        return bytes[start..<terminator]
    }

    private mutating func readString(limit: Int) throws(OSCDecodingError) -> String {
        let start = offset
        let stringBytes = try readStringBytes(limit: limit)
        guard let string = String(validating: stringBytes, as: UTF8.self) else {
            throw .invalidUTF8(offset: start)
        }
        return string
    }

    private mutating func readBlob(limit: Int) throws(OSCDecodingError) -> Data {
        let sizeOffset = offset
        let declared = Int32(bitPattern: try readUInt32(limit: limit))
        guard declared >= 0 else {
            throw .negativeSize(offset: sizeOffset, declared: declared)
        }
        let remaining = limit - offset
        guard Int(declared) <= remaining else {
            throw .blobOverrunsBuffer(offset: sizeOffset, declared: Int(declared), remaining: remaining)
        }
        let start = offset
        let end = start + Int(declared)
        let paddedEnd = (end + OSCCodec.alignment - 1) / OSCCodec.alignment * OSCCodec.alignment
        try consumePadding(from: end, to: paddedEnd, limit: limit)
        return Data(bytes[start..<end])
    }

    /// Moves past `from..<to`, requiring the range to exist and be all zeros.
    private mutating func consumePadding(from: Int, to: Int, limit: Int) throws(OSCDecodingError) {
        guard to <= limit, bytes[from..<to].allSatisfy({ $0 == 0 }) else {
            throw .invalidPadding(offset: from)
        }
        offset = to
    }
}

extension Data {
    mutating func appendBigEndian(_ value: UInt32) {
        append(contentsOf: [
            UInt8(truncatingIfNeeded: value >> 24),
            UInt8(truncatingIfNeeded: value >> 16),
            UInt8(truncatingIfNeeded: value >> 8),
            UInt8(truncatingIfNeeded: value),
        ])
    }

    mutating func appendBigEndian(_ value: UInt64) {
        appendBigEndian(UInt32(truncatingIfNeeded: value >> 32))
        appendBigEndian(UInt32(truncatingIfNeeded: value))
    }

    /// Strings always gain at least one terminating zero, then pad to 4 bytes.
    mutating func appendOSCString(_ string: String) {
        let bytes = Array(string.utf8)
        append(contentsOf: bytes)
        append(contentsOf: repeatElement(0, count: OSCCodec.alignment - bytes.count % OSCCodec.alignment))
    }

    mutating func appendOSCBlob(_ blob: Data) {
        appendBigEndian(UInt32(blob.count))
        append(blob)
        let remainder = blob.count % OSCCodec.alignment
        if remainder != 0 {
            append(contentsOf: repeatElement(0, count: OSCCodec.alignment - remainder))
        }
    }
}
