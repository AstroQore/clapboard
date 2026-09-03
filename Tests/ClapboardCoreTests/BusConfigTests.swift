import ClapboardCore
import Foundation
import Testing

@Suite("Bus config")
struct BusConfigTests {
    @Test("A bus with neither a parent nor an output device is dangling")
    func danglingBus() {
        let bus = BusConfig(name: "Orphan")
        #expect(bus.isDangling)
        var withParent = bus
        withParent.destinationBus = UUID()
        #expect(!withParent.isDangling)
        var withOutput = bus
        withOutput.outputDeviceUID = "dev"
        #expect(!withOutput.isDangling)
    }

    @Test("Negative output channel offsets are clamped to zero")
    func negativeChannelOffsetClamped() {
        let bus = BusConfig(name: "Master", outputChannelOffset: -3)
        #expect(bus.outputChannelOffset == 0)
    }

    @Test("Round-trips through JSON")
    func codableRoundTrip() throws {
        let original = BusConfig(
            name: "Vocals", gainDB: -3.5, muted: true, solo: false,
            effects: [], destinationBus: UUID(), outputDeviceUID: "dev-uid", outputChannelOffset: 2
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(BusConfig.self, from: data)
        #expect(decoded == original)
    }

    @Test("Decoding tolerates missing optional keys and unknown extra keys")
    func tolerantDecoding() throws {
        let json = """
        { "id": "\(UUID().uuidString)", "name": "Master", "futureField": 42 }
        """
        let decoded = try JSONDecoder().decode(BusConfig.self, from: Data(json.utf8))
        #expect(decoded.name == "Master")
        #expect(decoded.gainDB == 0)
        #expect(decoded.muted == false)
        #expect(decoded.solo == false)
        #expect(decoded.destinationBus == nil)
        #expect(decoded.outputDeviceUID == nil)
    }
}
