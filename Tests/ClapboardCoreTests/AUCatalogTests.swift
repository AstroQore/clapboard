import AudioToolbox
import ClapboardCore
import Foundation
import Testing

/// Identities of the two Apple effects the host tests are built on. Every Mac
/// has them, which is what makes these tests runnable anywhere.
enum AUFixtures {
    static let delay = (type: kAudioUnitType_Effect, subType: kAudioUnitSubType_Delay,
                        manufacturer: kAudioUnitManufacturer_Apple)
    static let peakLimiter = (type: kAudioUnitType_Effect, subType: kAudioUnitSubType_PeakLimiter,
                              manufacturer: kAudioUnitManufacturer_Apple)
    /// AUMatrixReverb publishes (1,2) (1,4) (1,5) (2,2) (2,4) (2,5): it will
    /// take a mono input but never produce a mono output, so a mono lane has
    /// to run through it dual-mono.
    static let matrixReverb = (type: kAudioUnitType_Effect, subType: kAudioUnitSubType_MatrixReverb,
                               manufacturer: kAudioUnitManufacturer_Apple)

    static func info(_ identity: (type: OSType, subType: OSType, manufacturer: OSType)) throws -> AUComponentInfo {
        try #require(
            AUCatalog.find(
                type: identity.type,
                subType: identity.subType,
                manufacturer: identity.manufacturer),
            "expected this Mac to have the Apple effect \(AUComponentInfo.fourCharString(identity.subType))")
    }
}

@Suite("AUCatalog")
struct AUCatalogTests {
    @Test func theCatalogContainsApplesBuiltInEffects() throws {
        let effects = AUCatalog.effects()
        #expect(!effects.isEmpty)

        let delay = try #require(effects.first { $0.id == "aufx.dely.appl" })
        #expect(delay.name == "AUDelay")
        #expect(delay.manufacturerName == "Apple")
        #expect(delay.componentType == kAudioUnitType_Effect)
        #expect(delay.componentSubType == kAudioUnitSubType_Delay)
        #expect(delay.componentManufacturer == kAudioUnitManufacturer_Apple)

        let limiter = try #require(effects.first { $0.id == "aufx.lmtr.appl" })
        #expect(limiter.name == "AUPeakLimiter")
        #expect(limiter.componentSubType == kAudioUnitSubType_PeakLimiter)
    }

    @Test func everyEntryIsAnEffectOrAMusicEffect() {
        for effect in AUCatalog.effects() {
            #expect(effect.componentType == kAudioUnitType_Effect
                || effect.componentType == kAudioUnitType_MusicEffect)
        }
    }

    @Test func entriesRoundTripThroughCodable() throws {
        let effects = AUCatalog.effects()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        for effect in effects {
            let data = try encoder.encode(effect)
            let decoded = try JSONDecoder().decode(AUComponentInfo.self, from: data)
            #expect(decoded == effect, "\(effect.displayName) did not survive a JSON round trip")
            #expect(decoded.id == effect.id)
            #expect(decoded.audioComponentDescription.componentSubType
                == effect.audioComponentDescription.componentSubType)
        }
        // The whole catalog is one blob in a session file, so encode it as one.
        let all = try encoder.encode(effects)
        #expect(try JSONDecoder().decode([AUComponentInfo].self, from: all) == effects)
    }

    @Test func entriesAreSortedByManufacturerThenName() {
        let effects = AUCatalog.effects()
        for (left, right) in zip(effects, effects.dropFirst()) {
            let byManufacturer = left.manufacturerName.caseInsensitiveCompare(right.manufacturerName)
            if byManufacturer == .orderedSame {
                #expect(left.name.caseInsensitiveCompare(right.name) != .orderedDescending,
                        "\(left.name) sorted before \(right.name)")
            } else {
                #expect(byManufacturer == .orderedAscending,
                        "\(left.manufacturerName) sorted before \(right.manufacturerName)")
            }
        }
    }

    @Test func fourCharCodesRoundTrip() {
        #expect(AUComponentInfo.fourCharString(kAudioUnitType_Effect) == "aufx")
        #expect(AUComponentInfo.fourCharString(kAudioUnitType_MusicEffect) == "aumf")
        #expect(AUComponentInfo.fourCharString(kAudioUnitManufacturer_Apple) == "appl")
        #expect(AUComponentInfo.fourCharCode("aufx") == kAudioUnitType_Effect)
        #expect(AUComponentInfo.fourCharCode("appl") == kAudioUnitManufacturer_Apple)
        // Short and empty codes pad with NULs rather than trapping.
        #expect(AUComponentInfo.fourCharCode("ab") == 0x6162_0000)
        #expect(AUComponentInfo.fourCharCode("") == 0)
    }

    @Test func lookupByIdentifierFindsTheSameEntry() throws {
        let delay = try #require(AUCatalog.find(id: "aufx.dely.appl"))
        #expect(delay.name == "AUDelay")
        #expect(AUCatalog.find(id: "aufx.zzzz.zzzz") == nil)
        #expect(AUCatalog.find(id: "nonsense") == nil)
    }

    /// Not an assertion so much as a record of what this machine has installed:
    /// the host tests only use Apple's effects, and a third-party failure has
    /// to be readable from the test log rather than guessed at.
    @Test func listTheInstalledCatalog() {
        let effects = AUCatalog.effects()
        let apple = effects.filter { $0.componentManufacturer == kAudioUnitManufacturer_Apple }
        let others = effects.filter { $0.componentManufacturer != kAudioUnitManufacturer_Apple }
        print("[catalog] \(effects.count) effects: \(apple.count) Apple, \(others.count) third-party")
        for effect in others {
            print("[catalog] third-party: \(effect.displayName) v\(effect.versionString) "
                + "(\(effect.id), AUv3=\(effect.isAUv3), customView=\(effect.hasCustomView))")
        }
        #expect(apple.count >= 10)
    }
}

@Suite("AUChannelCapabilities")
struct AUChannelCapabilitiesTests {
    @Test func anEmptyListMeansNoConstraint() {
        #expect(AUChannelCapabilities.supports(inputChannels: 1, outputChannels: 1, capabilities: []))
        #expect(AUChannelCapabilities.supports(inputChannels: 2, outputChannels: 2, capabilities: []))
        #expect(AUChannelCapabilities.plan(forLaneChannels: 1, capabilities: [])
            == AUChannelPlan(channels: 1, dualMono: false))
    }

    @Test func explicitPairsAreMatchedExactly() {
        let caps = [1, 2, 2, 2]
        #expect(!AUChannelCapabilities.supports(inputChannels: 1, outputChannels: 1, capabilities: caps))
        #expect(AUChannelCapabilities.supports(inputChannels: 1, outputChannels: 2, capabilities: caps))
        #expect(AUChannelCapabilities.supports(inputChannels: 2, outputChannels: 2, capabilities: caps))
        #expect(!AUChannelCapabilities.supports(inputChannels: 2, outputChannels: 1, capabilities: caps))
    }

    @Test func minusOneOnBothSidesCouplesTheChannelCounts() {
        let caps = [-1, -1]
        #expect(AUChannelCapabilities.supports(inputChannels: 1, outputChannels: 1, capabilities: caps))
        #expect(AUChannelCapabilities.supports(inputChannels: 8, outputChannels: 8, capabilities: caps))
        #expect(!AUChannelCapabilities.supports(inputChannels: 1, outputChannels: 2, capabilities: caps))
    }

    @Test func minusTwoDecouplesTheSides() {
        let caps = [-1, -2]
        #expect(AUChannelCapabilities.supports(inputChannels: 1, outputChannels: 2, capabilities: caps))
        #expect(AUChannelCapabilities.supports(inputChannels: 4, outputChannels: 1, capabilities: caps))
    }

    @Test func numbersBelowMinusTwoAreAnUpperBound() {
        let caps = [-16, 2]
        #expect(AUChannelCapabilities.supports(inputChannels: 1, outputChannels: 2, capabilities: caps))
        #expect(AUChannelCapabilities.supports(inputChannels: 16, outputChannels: 2, capabilities: caps))
        #expect(!AUChannelCapabilities.supports(inputChannels: 17, outputChannels: 2, capabilities: caps))
        #expect(!AUChannelCapabilities.supports(inputChannels: 4, outputChannels: 1, capabilities: caps))
    }

    @Test func zeroMeansTheScopeHasNoElements() {
        #expect(AUChannelCapabilities.supports(inputChannels: 2, outputChannels: 2, capabilities: [0, 2]))
    }

    @Test func aMonoRefusingPluginPlansDualMono() {
        // AUMatrixReverb's real capability list.
        let caps = [1, 2, 1, 4, 1, 5, 2, 2, 2, 4, 2, 5]
        #expect(!AUChannelCapabilities.supports(inputChannels: 1, outputChannels: 1, capabilities: caps))
        #expect(AUChannelCapabilities.plan(forLaneChannels: 1, capabilities: caps)
            == AUChannelPlan(channels: 2, dualMono: true))
        #expect(AUChannelCapabilities.plan(forLaneChannels: 2, capabilities: caps)
            == AUChannelPlan(channels: 2, dualMono: false))
    }

    @Test func aMalformedListIsIgnoredRatherThanTrapping() {
        #expect(AUChannelCapabilities.supports(inputChannels: 1, outputChannels: 1, capabilities: [1]))
        #expect(!AUChannelCapabilities.supports(inputChannels: 1, outputChannels: 1, capabilities: [2, 2, 4]))
    }
}
