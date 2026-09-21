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

    @Test("OSC messages round trip with validated padding")
    func messageRoundTrip() throws {
        let packet: ShowControlOSCPacket = .message(.init(
            address: "/viewtiful/page",
            arguments: [.integer(23), .string("show")]
        ))

        let decoded = try ShowControlOSCCodec.decode(ShowControlOSCCodec.encode(packet))
        #expect(decoded == packet)
    }

    @Test("Bundles preserve packet order")
    func bundleOrder() throws {
        let packet: ShowControlOSCPacket = .bundle(.init(elements: [
            .message(.init(address: "/viewtiful/next")),
            .message(.init(address: "/viewtiful/last"))
        ]))

        let decoded = try ShowControlOSCCodec.decode(ShowControlOSCCodec.encode(packet))
        guard case .bundle(let bundle) = decoded else {
            Issue.record("Expected a bundle")
            return
        }
        #expect(bundle.elements.count == 2)
        #expect(bundle.elements.first == .message(.init(address: "/viewtiful/next")))
    }

    @Test("Malformed padding is rejected")
    func malformedPadding() {
        let malformed = Data([47, 0, 1, 0, 44, 0, 0, 0])
        #expect(throws: ShowControlOSCError.self) {
            try ShowControlOSCCodec.decode(malformed)
        }
    }

    @Test("Nested bundles respect the decoder depth limit")
    func nestingLimit() {
        let packet: ShowControlOSCPacket = .bundle(.init(elements: [
            .bundle(.init(elements: [.message(.init(address: "/nested"))]))
        ]))

        #expect(throws: ShowControlOSCError.self) {
            try ShowControlOSCCodec.decode(
                ShowControlOSCCodec.encode(packet),
                limits: .init(maxNestingDepth: 1)
            )
        }
    }
}
