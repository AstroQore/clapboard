import CoreAudio
import Foundation

/// How a device is attached to the machine, as reported by
/// `kAudioDevicePropertyTransportType`.
public enum AudioTransportType: Hashable, Sendable {
    case builtIn
    case usb
    case bluetooth
    case bluetoothLE
    case virtual
    case aggregate
    case autoAggregate
    case pci
    case fireWire
    case hdmi
    case displayPort
    case airPlay
    case avb
    case thunderbolt
    case continuityCaptureWired
    case continuityCaptureWireless
    case unknown(UInt32)

    public init(rawTransport: UInt32) {
        switch rawTransport {
        case kAudioDeviceTransportTypeBuiltIn: self = .builtIn
        case kAudioDeviceTransportTypeUSB: self = .usb
        case kAudioDeviceTransportTypeBluetooth: self = .bluetooth
        case kAudioDeviceTransportTypeBluetoothLE: self = .bluetoothLE
        case kAudioDeviceTransportTypeVirtual: self = .virtual
        case kAudioDeviceTransportTypeAggregate: self = .aggregate
        case kAudioDeviceTransportTypeAutoAggregate: self = .autoAggregate
        case kAudioDeviceTransportTypePCI: self = .pci
        case kAudioDeviceTransportTypeFireWire: self = .fireWire
        case kAudioDeviceTransportTypeHDMI: self = .hdmi
        case kAudioDeviceTransportTypeDisplayPort: self = .displayPort
        case kAudioDeviceTransportTypeAirPlay: self = .airPlay
        case kAudioDeviceTransportTypeAVB: self = .avb
        case kAudioDeviceTransportTypeThunderbolt: self = .thunderbolt
        case kAudioDeviceTransportTypeContinuityCaptureWired: self = .continuityCaptureWired
        case kAudioDeviceTransportTypeContinuityCaptureWireless: self = .continuityCaptureWireless
        default: self = .unknown(rawTransport)
        }
    }

    public var label: String {
        switch self {
        case .builtIn: return "Built-in"
        case .usb: return "USB"
        case .bluetooth: return "Bluetooth"
        case .bluetoothLE: return "Bluetooth LE"
        case .virtual: return "Virtual"
        case .aggregate: return "Aggregate"
        case .autoAggregate: return "Auto Aggregate"
        case .pci: return "PCI"
        case .fireWire: return "FireWire"
        case .hdmi: return "HDMI"
        case .displayPort: return "DisplayPort"
        case .airPlay: return "AirPlay"
        case .avb: return "AVB"
        case .thunderbolt: return "Thunderbolt"
        case .continuityCaptureWired: return "Continuity (wired)"
        case .continuityCaptureWireless: return "Continuity (wireless)"
        case .unknown(let raw): return "Unknown \(fourCharCode(raw))"
        }
    }

    /// Bluetooth links have variable latency and downgrade to HFP when used
    /// for input, so they are kept out of the engine's aggregate device.
    public var isBluetooth: Bool {
        self == .bluetooth || self == .bluetoothLE
    }

    /// Loopback / Audio Hijack devices and other HAL plug-ins. They cannot
    /// hear a clap, so Auto Sync excludes them by default.
    public var isVirtual: Bool {
        self == .virtual
    }

    /// Aggregates (including Clapboard's own private one) are never offered
    /// as lane sources or as sub-devices of another aggregate.
    public var isAggregate: Bool {
        self == .aggregate || self == .autoAggregate
    }
}

/// A snapshot of one Core Audio device. Immutable; `AudioDeviceRegistry`
/// rebuilds the list whenever the HAL reports a change.
public struct AudioDeviceInfo: Identifiable, Hashable, Sendable {
    /// Transient HAL object id. Changes across re-enumeration; never persist it.
    public let id: AudioObjectID
    /// Stable identifier. Persist this.
    public let uid: String
    public let name: String
    public let manufacturer: String
    public let transport: AudioTransportType
    /// Channel count of each input stream, in stream order.
    public let inputStreamChannels: [Int]
    /// Channel count of each output stream, in stream order.
    public let outputStreamChannels: [Int]
    public let nominalSampleRate: Double
    /// Supported nominal sample-rate ranges; a fixed rate appears as a range
    /// whose bounds are equal.
    public let sampleRateRanges: [ClosedRange<Double>]
    public let isAlive: Bool
    public let isHidden: Bool

    public var inputChannels: Int { inputStreamChannels.reduce(0, +) }
    public var outputChannels: Int { outputStreamChannels.reduce(0, +) }
    public var hasInput: Bool { inputChannels > 0 }
    public var hasOutput: Bool { outputChannels > 0 }

    public func supports(sampleRate: Double) -> Bool {
        sampleRateRanges.contains { $0.contains(sampleRate) }
    }

    /// Distinct fixed rates advertised by the device, ascending.
    public var fixedSampleRates: [Double] {
        Array(Set(sampleRateRanges.filter { $0.lowerBound == $0.upperBound }.map(\.lowerBound))).sorted()
    }

    public init(
        id: AudioObjectID,
        uid: String,
        name: String,
        manufacturer: String,
        transport: AudioTransportType,
        inputStreamChannels: [Int],
        outputStreamChannels: [Int],
        nominalSampleRate: Double,
        sampleRateRanges: [ClosedRange<Double>],
        isAlive: Bool,
        isHidden: Bool
    ) {
        self.id = id
        self.uid = uid
        self.name = name
        self.manufacturer = manufacturer
        self.transport = transport
        self.inputStreamChannels = inputStreamChannels
        self.outputStreamChannels = outputStreamChannels
        self.nominalSampleRate = nominalSampleRate
        self.sampleRateRanges = sampleRateRanges
        self.isAlive = isAlive
        self.isHidden = isHidden
    }

    /// Reads every property for a device id. Throws only when the UID cannot
    /// be read (a device without a UID is unusable to us); other properties
    /// fall back to neutral values so a misbehaving driver does not hide the
    /// whole device list.
    public init(deviceID: AudioObjectID) throws {
        let uid = try deviceID.propertyString(.init(kAudioDevicePropertyDeviceUID))
        let name = (try? deviceID.propertyString(.init(kAudioObjectPropertyName))) ?? uid
        let manufacturer = (try? deviceID.propertyString(.init(kAudioObjectPropertyManufacturer))) ?? ""
        let rawTransport = (try? deviceID.property(.init(kAudioDevicePropertyTransportType), as: UInt32.self)) ?? kAudioDeviceTransportTypeUnknown
        let inputStreams = (try? deviceID.streamChannelCounts(scope: kAudioObjectPropertyScopeInput)) ?? []
        let outputStreams = (try? deviceID.streamChannelCounts(scope: kAudioObjectPropertyScopeOutput)) ?? []
        let rate = (try? deviceID.property(.init(kAudioDevicePropertyNominalSampleRate), as: Double.self)) ?? 0
        let ranges = (try? deviceID.propertyArray(.init(kAudioDevicePropertyAvailableNominalSampleRates), of: AudioValueRange.self)) ?? []
        let alive = (try? deviceID.property(.init(kAudioDevicePropertyDeviceIsAlive), as: UInt32.self)) ?? 1
        let hidden = (try? deviceID.property(.init(kAudioDevicePropertyIsHidden), as: UInt32.self)) ?? 0

        self.init(
            id: deviceID,
            uid: uid,
            name: name,
            manufacturer: manufacturer,
            transport: AudioTransportType(rawTransport: rawTransport),
            inputStreamChannels: inputStreams,
            outputStreamChannels: outputStreams,
            nominalSampleRate: rate,
            sampleRateRanges: ranges.map { min($0.mMinimum, $0.mMaximum)...max($0.mMinimum, $0.mMaximum) },
            isAlive: alive != 0,
            isHidden: hidden != 0
        )
    }

    /// Every device the HAL currently knows about, in HAL order. Devices whose
    /// UID cannot be read are skipped.
    public static func enumerateAll() throws -> [AudioDeviceInfo] {
        let ids = try AudioObjectID.system.propertyArray(.init(kAudioHardwarePropertyDevices), of: AudioObjectID.self)
        return ids.compactMap { try? AudioDeviceInfo(deviceID: $0) }
    }

    public static func defaultDeviceID(input: Bool) -> AudioObjectID? {
        let selector = input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice
        guard let id = try? AudioObjectID.system.property(.init(selector), as: AudioObjectID.self), id != kAudioObjectUnknown else {
            return nil
        }
        return id
    }
}
