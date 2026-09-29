import Foundation
import Testing
@testable import ShowControlCore

struct ShowControlCoreTests {
    @Test("Shared defaults identify the two network roles")
    func defaults() {
        #expect(ShowControlDefaults.qlabTCPPort == 53_000)
        #expect(ShowControlDefaults.viewtifulOSCUDPPort == 53_001)
        #expect(ShowControlDefaults.qlabBonjourService == "_qlab._tcp")
    }
}

@Suite("OSC encoding")
struct OSCEncodingTests {
    @Test(
        "Round-trips every argument type",
        arguments: [
            OSCValue.int32(0),
            .int32(-1),
            .int32(.max),
            .int32(.min),
            .float32(0),
            .float32(-0.5),
            .float32(.pi),
            .string(""),
            .string("hello"),
            .string("four"),
            .string("émoji 🎭 multibyte"),
            .symbol("sym"),
            .blob(Data()),
            .blob(Data([1])),
            .blob(Data([1, 2, 3, 4])),
            .blob(Data([0xC0, 0xDB, 0x00])),
            .int64(0),
            .int64(.max),
            .int64(.min),
            .double(0),
            .double(.pi),
            .timeTag(.immediate),
            .timeTag(OSCTimeTag(rawValue: 0xDEAD_BEEF_CAFE_F00D)),
            .true,
            .false,
            .null,
            .impulse,
            .array([]),
            .array([.int32(1), .array([.string("nested")]), .true]),
        ]
    )
    func roundTripsArgument(_ argument: OSCValue) throws {
        let message = OSCMessage("/test", [argument])
        #expect(try OSCCodec.decode(OSCCodec.encode(message)) == .message(message))
    }

    @Test("Round-trips a message with many mixed arguments")
    func roundTripsMixedArguments() throws {
        let message = OSCMessage("/workspace/ABC/cue_id/xyz/valuesForKeys", [
            .string(#"["number","name"]"#),
            .int32(42),
            .float32(0.5),
            .true,
            .null,
            .impulse,
            .false,
            .int64(9_000_000_000),
            .double(3.141592653589793),
            .blob(Data([0xC0, 0xDB, 0x00, 0x01, 0x02])),
        ])
        #expect(try OSCCodec.decode(OSCCodec.encode(message)) == .message(message))
    }

    @Test("Encodes a message as the exact OSC wire bytes")
    func encodesExactBytes() throws {
        let encoded = try OSCCodec.encode(OSCMessage("/ab", [.int32(1), .string("hi"), .true]))
        #expect(encoded == Data([
            0x2F, 0x61, 0x62, 0x00,                          // "/ab\0"
            0x2C, 0x69, 0x73, 0x54, 0x00, 0x00, 0x00, 0x00,  // ",isT" + full padding
            0x00, 0x00, 0x00, 0x01,                          // int32 1
            0x68, 0x69, 0x00, 0x00,                          // "hi\0\0"
        ]))
    }

    @Test("Encodes array tags with brackets")
    func encodesArrayTags() throws {
        let encoded = try OSCCodec.encode(OSCMessage("/a", [.array([.int32(7)])]))
        #expect(encoded == Data([
            0x2F, 0x61, 0x00, 0x00,
            0x2C, 0x5B, 0x69, 0x5D, 0x00, 0x00, 0x00, 0x00,  // ",[i]"
            0x00, 0x00, 0x00, 0x07,
        ]))
    }

    @Test("Encoded packets are always 4-byte aligned", arguments: 0...16)
    func encodedPacketsAreAligned(addressLength: Int) throws {
        let message = OSCMessage("/" + String(repeating: "a", count: addressLength), [
            .string(String(repeating: "b", count: addressLength)),
            .blob(Data(repeating: 0xFF, count: addressLength)),
        ])
        let encoded = try OSCCodec.encode(message)
        #expect(encoded.count % OSCCodec.alignment == 0)
        #expect(try OSCCodec.decode(encoded) == .message(message))
    }

    @Test("Aligned-length strings gain full padding")
    func alignedStringsGainFullPadding() {
        var data = Data()
        data.appendOSCString("four")
        #expect(data == Data([0x66, 0x6F, 0x75, 0x72, 0, 0, 0, 0]))
    }

    @Test("Empty strings encode as four null bytes")
    func emptyStringEncoding() {
        var data = Data()
        data.appendOSCString("")
        #expect(data == Data([0, 0, 0, 0]))
    }

    @Test(
        "Blob encoding pads contents to a 4-byte boundary",
        arguments: [(0, 4), (1, 8), (2, 8), (3, 8), (4, 8), (5, 12)]
    )
    func blobPadding(contentLength: Int, expectedTotal: Int) {
        var data = Data()
        data.appendOSCBlob(Data(repeating: 0xAB, count: contentLength))
        #expect(data.count == expectedTotal)
    }

    @Test("Round-trips nested bundles and flattens their messages in order")
    func roundTripsNestedBundle() throws {
        let outer = OSCPacket.bundle(OSCBundle(timeTag: OSCTimeTag(rawValue: 42), elements: [
            .message(OSCMessage("/outer", [.int32(1)])),
            .bundle(OSCBundle(elements: [.message(OSCMessage("/inner"))])),
            .message(OSCMessage("/last")),
        ]))
        let decoded = try OSCCodec.decode(OSCCodec.encode(outer))
        #expect(decoded == outer)
        #expect(decoded.flattenedMessages.map(\.address) == ["/outer", "/inner", "/last"])
    }

    @Test(
        "Validates outgoing addresses",
        arguments: [
            ("/cue/1/start", true),
            ("/cue/*/stop", true),
            ("/workspace/ABC/cueLists", true),
            ("/cue/{1,2}/start", true),
            ("no/leading/slash", false),
            ("", false),
            ("/has space", false),
            ("/has\ttab", false),
            ("/has\0nul", false),
        ]
    )
    func validatesOutgoingAddresses(address: String, expected: Bool) {
        #expect(OSCMessage(address).isValidForSending == expected)
        #expect(((try? OSCCodec.encode(OSCMessage(address))) != nil) == expected)
    }

    @Test("Refuses to encode a bundle containing a malformed address")
    func refusesMalformedAddressInBundle() {
        let bundle = OSCPacket.bundle(OSCBundle(elements: [.message(OSCMessage("bad"))]))
        #expect(throws: OSCEncodingError.invalidAddress("bad")) {
            try OSCCodec.encode(bundle)
        }
    }

    @Test("Splits addresses into components")
    func splitsAddressComponents() {
        let message = OSCMessage("/update/workspace/ABC/cueList/DEF/playbackPosition")
        #expect(message.addressComponents == [
            "update", "workspace", "ABC", "cueList", "DEF", "playbackPosition",
        ])
    }

    @Test("Reads strings from both string and symbol cases")
    func readsStrings() {
        #expect(OSCValue.string("a").stringValue == "a")
        #expect(OSCValue.symbol("b").stringValue == "b")
        #expect(OSCValue.int32(1).stringValue == nil)
    }

    @Test("Describes messages for diagnostics")
    func describesMessages() {
        let message = OSCMessage("/a", [.int32(1), .string("x"), .array([.true, .null])])
        #expect(message.description == #"/a 1 "x" [true nil]"#)
        #expect(OSCMessage("/b").description == "/b")
    }
}

@Suite("OSC decoding")
struct OSCDecodingTests {
    private func decode(_ bytes: [UInt8], limits: OSCCodec.Limits = .init()) throws(OSCDecodingError) -> OSCPacket {
        try OSCCodec.decode(Data(bytes), limits: limits)
    }

    private func message(_ address: String, tags: String, payload: [UInt8] = []) -> [UInt8] {
        var data = Data()
        data.appendOSCString(address)
        data.appendOSCString(tags)
        data.append(contentsOf: payload)
        return Array(data)
    }

    // MARK: Accepted forms

    @Test("Decodes a raw message fixture")
    func decodesRawFixture() throws {
        let packet = try decode([
            0x2F, 0x78, 0x00, 0x00,                          // "/x"
            0x2C, 0x69, 0x66, 0x00,                          // ",if"
            0xFF, 0xFF, 0xFF, 0xFE,                          // -2
            0x3F, 0x80, 0x00, 0x00,                          // 1.0
        ])
        #expect(packet == .message(OSCMessage("/x", [.int32(-2), .float32(1)])))
    }

    @Test("Accepts an address-only message without a type tag string")
    func acceptsAddressOnlyMessage() throws {
        #expect(try decode([0x2F, 0x61, 0x62, 0x00]) == .message(OSCMessage("/ab")))
    }

    @Test("Skips zero-length bundle elements")
    func skipsZeroLengthBundleElement() throws {
        var data = Data()
        data.appendOSCString("#bundle")
        data.appendBigEndian(UInt64(1))
        data.appendBigEndian(UInt32(0))
        let element = try OSCCodec.encode(OSCMessage("/a"))
        data.appendBigEndian(UInt32(element.count))
        data.append(element)

        let packet = try OSCCodec.decode(data)
        #expect(packet == .bundle(OSCBundle(elements: [.message(OSCMessage("/a"))])))
    }

    @Test("Decodes a long run of payload-free tags quickly")
    func decodesLongTagRunLinearly() throws {
        let count = 60_000
        let bytes = message("/x", tags: "," + String(repeating: "T", count: count))
        let clock = ContinuousClock()
        var packet: OSCPacket?
        let elapsed = try clock.measure {
            packet = try decode(bytes, limits: .init(maxArguments: count))
        }
        #expect(packet?.flattenedMessages.first?.arguments.count == count)
        // Quadratic front-removal took hundreds of milliseconds here; a linear
        // cursor is orders of magnitude below this generous ceiling.
        #expect(elapsed < .milliseconds(100))
    }

    // MARK: Limits

    @Test("Rejects packets larger than the configured limit")
    func rejectsOversizedPacket() {
        let bytes = message("/x", tags: ",")
        #expect(throws: OSCDecodingError.packetTooLarge(size: bytes.count, limit: bytes.count - 1)) {
            try decode(bytes, limits: .init(maxPacketBytes: bytes.count - 1))
        }
        #expect((try? decode(bytes, limits: .init(maxPacketBytes: bytes.count))) != nil)
    }

    private func nestedArrays(_ depth: Int) -> OSCMessage {
        var value = OSCValue.int32(1)
        for _ in 0..<depth { value = .array([value]) }
        return OSCMessage("/nested", [value])
    }

    @Test("Array nesting stops at the depth limit", arguments: [0, 1, 8])
    func arrayNestingLimit(limit: Int) throws {
        let atLimit = try OSCCodec.encode(nestedArrays(limit))
        #expect(try OSCCodec.decode(atLimit, limits: .init(maxNestingDepth: limit)) == .message(nestedArrays(limit)))

        let beyond = try OSCCodec.encode(nestedArrays(limit + 1))
        let error = try #require(throws: OSCDecodingError.self) {
            try OSCCodec.decode(beyond, limits: .init(maxNestingDepth: limit))
        }
        guard case .nestingLimitExceeded = error else {
            Issue.record("Expected a nesting error, got \(error)")
            return
        }
    }

    @Test("Thirty-two nested arrays are rejected by default")
    func deepArraysRejectedByDefault() throws {
        let encoded = try OSCCodec.encode(nestedArrays(32))
        #expect(throws: OSCDecodingError.self) { try OSCCodec.decode(encoded) }
    }

    private func nestedBundles(_ depth: Int) -> OSCPacket {
        var packet = OSCPacket.message(OSCMessage("/leaf"))
        for _ in 0..<depth { packet = .bundle(OSCBundle(elements: [packet])) }
        return packet
    }

    @Test("Bundle nesting stops at the depth limit", arguments: [1, 4])
    func bundleNestingLimit(limit: Int) throws {
        let atLimit = try OSCCodec.encode(nestedBundles(limit))
        #expect(try OSCCodec.decode(atLimit, limits: .init(maxNestingDepth: limit)) == nestedBundles(limit))

        let beyond = try OSCCodec.encode(nestedBundles(limit + 1))
        #expect(throws: OSCDecodingError.self) {
            try OSCCodec.decode(beyond, limits: .init(maxNestingDepth: limit))
        }
    }

    @Test("Bundles and arrays share one nesting budget")
    func mixedNestingSharesBudget() throws {
        // Bundle (depth 1 message) holding a two-level array reaches depth 3.
        let packet = OSCPacket.bundle(OSCBundle(elements: [
            .message(OSCMessage("/m", [.array([.array([.int32(1)])])])),
        ]))
        let encoded = try OSCCodec.encode(packet)
        #expect(try OSCCodec.decode(encoded, limits: .init(maxNestingDepth: 3)) == packet)
        #expect(throws: OSCDecodingError.self) {
            try OSCCodec.decode(encoded, limits: .init(maxNestingDepth: 2))
        }
    }

    @Test("The argument budget covers the whole packet, including array contents")
    func argumentBudget() throws {
        let packet = OSCPacket.bundle(OSCBundle(elements: [
            .message(OSCMessage("/a", [.int32(1), .int32(2)])),
            .message(OSCMessage("/b", [.array([.true, .false])])),
        ]))
        let encoded = try OSCCodec.encode(packet)
        // Two scalars, one array container and its two values.
        #expect(try OSCCodec.decode(encoded, limits: .init(maxArguments: 5)) == packet)
        #expect(throws: OSCDecodingError.argumentLimitExceeded(offset: 47, limit: 4)) {
            try OSCCodec.decode(encoded, limits: .init(maxArguments: 4))
        }
    }

    @Test("The element budget counts every message and bundle in the packet")
    func elementBudget() throws {
        let packet = OSCPacket.bundle(OSCBundle(elements: [
            .message(OSCMessage("/a")),
            .bundle(OSCBundle(elements: [.message(OSCMessage("/b"))])),
        ]))
        let encoded = try OSCCodec.encode(packet)
        #expect(try OSCCodec.decode(encoded, limits: .init(maxElements: 4)) == packet)
        #expect(throws: OSCDecodingError.self) {
            try OSCCodec.decode(encoded, limits: .init(maxElements: 3))
        }
    }

    // MARK: Malformed input

    @Test("Rejects non-zero string padding")
    func rejectsNonZeroPadding() {
        #expect(throws: OSCDecodingError.invalidPadding(offset: 2)) {
            try decode([0x2F, 0x00, 0x01, 0x00, 0x2C, 0x00, 0x00, 0x00])
        }
    }

    @Test("Rejects a string whose padding is cut off")
    func rejectsMissingPadding() {
        #expect(throws: OSCDecodingError.invalidPadding(offset: 3)) {
            try decode([0x2F, 0x61, 0x00])
        }
    }

    @Test("Rejects non-zero blob padding")
    func rejectsNonZeroBlobPadding() {
        let bytes = message("/b", tags: ",b", payload: [0, 0, 0, 1, 0xAA, 0, 0, 7])
        #expect(throws: OSCDecodingError.invalidPadding(offset: 13)) { try decode(bytes) }
    }

    @Test("Rejects bytes after the last declared argument")
    func rejectsTrailingBytes() {
        let bytes = message("/t", tags: ",i", payload: [0, 0, 0, 1, 0, 0, 0, 2])
        #expect(throws: OSCDecodingError.trailingBytes(offset: 12, count: 4)) { try decode(bytes) }
    }

    @Test("Rejects unbalanced array brackets", arguments: [",[i", ",i]", ",]"])
    func rejectsUnbalancedArrays(tags: String) throws {
        let bytes = message("/a", tags: tags, payload: [0, 0, 0, 1])
        let error = try #require(throws: OSCDecodingError.self) { try decode(bytes) }
        guard case .unbalancedArray = error else {
            Issue.record("Expected an array error, got \(error)")
            return
        }
    }

    @Test("Rejects a bundle whose identifier is wrong")
    func rejectsBadBundleIdentifier() {
        var data = Data()
        data.appendOSCString("#wrong")
        data.appendBigEndian(UInt64(1))
        #expect(throws: OSCDecodingError.invalidBundleIdentifier(offset: 0)) {
            try OSCCodec.decode(data)
        }
    }

    @Test("Rejects a bundle element that overruns the buffer")
    func rejectsOverrunningBundleElement() {
        var data = Data()
        data.appendOSCString(OSCBundle.identifier)
        data.appendBigEndian(UInt64(1))
        data.appendBigEndian(UInt32(9999))
        data.append(contentsOf: [0x2F, 0x61, 0x00, 0x00])
        #expect(throws: OSCDecodingError.bundleElementOverrunsBuffer(offset: 16, declared: 9999, remaining: 4)) {
            try OSCCodec.decode(data)
        }
    }

    @Test("A bundle element cannot read into its neighbour")
    func bundleElementIsBounded() {
        var data = Data()
        data.appendOSCString(OSCBundle.identifier)
        data.appendBigEndian(UInt64(1))
        data.appendBigEndian(UInt32(8))           // declares "/a" + ",i" only
        data.appendOSCString("/a")
        data.appendOSCString(",i")
        data.appendBigEndian(UInt32(1))           // the int32 lies outside the element
        #expect(throws: OSCDecodingError.self) { try OSCCodec.decode(data) }
    }

    @Test("Rejects a negative bundle element size")
    func rejectsNegativeBundleElementSize() {
        var data = Data()
        data.appendOSCString(OSCBundle.identifier)
        data.appendBigEndian(UInt64(1))
        data.appendBigEndian(UInt32(bitPattern: -8))
        #expect(throws: OSCDecodingError.negativeSize(offset: 16, declared: -8)) {
            try OSCCodec.decode(data)
        }
    }

    @Test("Rejects a packet that is neither a message nor a bundle")
    func rejectsNonPacket() {
        #expect(throws: OSCDecodingError.notAPacket(offset: 0, firstByte: 0x41)) {
            try decode([0x41, 0x42, 0x43, 0x00])
        }
    }

    @Test("Rejects empty input")
    func rejectsEmptyInput() {
        #expect(throws: OSCDecodingError.self) { try decode([]) }
    }

    @Test("Rejects an unterminated address string")
    func rejectsUnterminatedString() {
        #expect(throws: OSCDecodingError.unterminatedString(offset: 0)) {
            try decode([0x2F, 0x61, 0x62, 0x63])
        }
    }

    @Test("Rejects a type tag string that does not begin with a comma")
    func rejectsMalformedTypeTagString() {
        let bytes = message("/test", tags: "xi", payload: [0, 0, 0, 1])
        #expect(throws: OSCDecodingError.malformedTypeTagString(offset: 8)) { try decode(bytes) }
    }

    @Test("Rejects an unknown type tag")
    func rejectsUnknownTypeTag() {
        let bytes = message("/test", tags: ",Q", payload: [0, 0, 0, 1])
        #expect(throws: OSCDecodingError.unknownTypeTag(offset: 9, tag: "Q")) { try decode(bytes) }
    }

    @Test("Rejects an argument whose payload is truncated")
    func rejectsTruncatedArgument() {
        let bytes = message("/test", tags: ",i", payload: [0, 0])
        #expect(throws: OSCDecodingError.unexpectedEnd(offset: 12, needed: 4, available: 2)) {
            try decode(bytes)
        }
    }

    @Test("Rejects a blob that overruns the buffer")
    func rejectsOverrunningBlob() {
        let bytes = message("/test", tags: ",b", payload: [0, 0, 0x27, 0x0F, 1, 2, 3, 4])
        #expect(throws: OSCDecodingError.blobOverrunsBuffer(offset: 12, declared: 9999, remaining: 4)) {
            try decode(bytes)
        }
    }

    @Test("Rejects a negative blob size")
    func rejectsNegativeBlobSize() {
        let bytes = message("/test", tags: ",b", payload: [0xFF, 0xFF, 0xFF, 0xFC])
        #expect(throws: OSCDecodingError.negativeSize(offset: 12, declared: -4)) { try decode(bytes) }
    }

    @Test("Rejects invalid UTF-8 in a string")
    func rejectsInvalidUTF8() {
        let bytes = message("/test", tags: ",s", payload: [0xFF, 0xFE, 0x00, 0x00])
        #expect(throws: OSCDecodingError.invalidUTF8(offset: 12)) { try decode(bytes) }
    }

    @Test("Decoding errors describe their byte offset")
    func errorsCarryOffset() throws {
        let error = try #require(throws: OSCDecodingError.self) {
            try decode(message("/test", tags: ",i"))
        }
        #expect(error.offset == 12)
        #expect(error.description.contains("12"))
    }
}
