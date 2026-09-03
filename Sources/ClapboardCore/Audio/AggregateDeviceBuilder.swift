import CoreAudio
import Foundation

/// What the engine wants an aggregate device to look like.
public struct AggregateDeviceRequest: Hashable, Sendable {
    /// Lane source devices, in the order their channels should appear.
    public var inputDeviceUIDs: [String]
    /// Clock main and mix destination. Never also an input.
    public var outputDeviceUID: String
    public var sampleRate: Double
    public var bufferFrameSize: UInt32
    public var name: String

    public init(
        inputDeviceUIDs: [String],
        outputDeviceUID: String,
        sampleRate: Double = 48_000,
        bufferFrameSize: UInt32 = 256,
        name: String = "Clapboard Mix"
    ) {
        self.inputDeviceUIDs = inputDeviceUIDs
        self.outputDeviceUID = outputDeviceUID
        self.sampleRate = sampleRate
        self.bufferFrameSize = bufferFrameSize
        self.name = name
    }
}

public enum AggregateDeviceError: Error, CustomStringConvertible, Sendable {
    case deviceNotFound(uid: String)
    case deviceHasNoInput(name: String)
    case deviceHasNoOutput(name: String)
    case deviceRejected(name: String, reason: String)
    case sampleRateUnsupported(name: String, wanted: Double, available: [Double])
    case sampleRateRefused(name: String, wanted: Double, actual: Double)
    case creationFailed(status: OSStatus)
    case subDevicesInactive(missing: [String])
    case channelLayoutMismatch(scope: String, expected: [Int], actual: [Int])
    case outputStreamNotFound(uid: String)

    public var description: String {
        switch self {
        case .deviceNotFound(let uid):
            return "No audio device with UID \(uid) — it was unplugged or renamed."
        case .deviceHasNoInput(let name):
            return "\(name) has no input channels."
        case .deviceHasNoOutput(let name):
            return "\(name) has no output channels."
        case .deviceRejected(let name, let reason):
            return "\(name) cannot be used: \(reason)"
        case .sampleRateUnsupported(let name, let wanted, let available):
            let rates = available.map { String(Int($0)) }.joined(separator: ", ")
            return "\(name) does not support \(Int(wanted)) Hz (offers \(rates.isEmpty ? "nothing usable" : rates)). "
                + "Change it in Audio MIDI Setup or in the device's own app."
        case .sampleRateRefused(let name, let wanted, let actual):
            return "\(name) stayed at \(Int(actual)) Hz after being asked for \(Int(wanted)) Hz — another app is probably holding it."
        case .creationFailed(let status):
            return "AudioHardwareCreateAggregateDevice failed with \(fourCharCode(status)) (\(status))."
        case .subDevicesInactive(let missing):
            return "The aggregate device never activated: \(missing.joined(separator: ", "))."
        case .channelLayoutMismatch(let scope, let expected, let actual):
            return "Aggregate \(scope) streams are \(actual) but its sub-devices add up to \(expected); refusing to guess the channel map."
        case .outputStreamNotFound(let uid):
            return "The aggregate exposes no output stream belonging to \(uid)."
        }
    }
}

/// A private Core Audio aggregate device that owns every lane source plus the
/// chosen output device, driven by one IOProc.
///
/// Private means it never shows up in Audio MIDI Setup or in other apps'
/// device lists, and the HAL destroys it when this process exits. We still
/// destroy it explicitly on stop, rebuild and termination, because a crashed
/// process is not the only way to leave one behind.
public final class AggregateDevice {
    public let objectID: AudioObjectID
    public let uid: String
    public let name: String
    public let inputDeviceUIDs: [String]
    public let outputDeviceUID: String
    public let sampleRate: Double
    public let bufferFrameSize: UInt32

    /// Where each sub-device's input channels land in the IOProc input list.
    public let inputLayout: AggregateInputLayout
    /// Same arithmetic for the output list.
    public let outputLayout: AggregateStreamLayout
    /// Buffer in the IOProc output list that belongs to the output device.
    public let masterOutputBufferIndex: Int
    public let masterOutputChannels: Int
    /// True when the HAL accepted `kAudioAggregateDeviceClockDeviceKey`.
    public let usedClockDeviceKey: Bool

    private var destroyed = false

    init(
        objectID: AudioObjectID,
        uid: String,
        name: String,
        inputDeviceUIDs: [String],
        outputDeviceUID: String,
        sampleRate: Double,
        bufferFrameSize: UInt32,
        inputLayout: AggregateInputLayout,
        outputLayout: AggregateStreamLayout,
        masterOutputBufferIndex: Int,
        masterOutputChannels: Int,
        usedClockDeviceKey: Bool
    ) {
        self.objectID = objectID
        self.uid = uid
        self.name = name
        self.inputDeviceUIDs = inputDeviceUIDs
        self.outputDeviceUID = outputDeviceUID
        self.sampleRate = sampleRate
        self.bufferFrameSize = bufferFrameSize
        self.inputLayout = inputLayout
        self.outputLayout = outputLayout
        self.masterOutputBufferIndex = masterOutputBufferIndex
        self.masterOutputChannels = masterOutputChannels
        self.usedClockDeviceKey = usedClockDeviceKey
    }

    deinit { destroy() }

    public func destroy() {
        guard !destroyed else { return }
        destroyed = true
        AudioHardwareDestroyAggregateDevice(objectID)
    }

    public var isDestroyed: Bool { destroyed }

    /// One-line description for the UI / logs.
    public var summary: String {
        let inputs = inputLayout.slots.map { "\($0.deviceUID)[\($0.channelCount)]" }.joined(separator: " ")
        return "\(name) id=\(objectID) rate=\(Int(sampleRate)) buffer=\(bufferFrameSize) "
            + "in=\(inputLayout.totalChannels)ch(\(inputLayout.bufferCount) streams) "
            + "outBuffer=\(masterOutputBufferIndex)/\(masterOutputChannels)ch "
            + "clockKey=\(usedClockDeviceKey) | \(inputs)"
    }

    // MARK: - Creation

    public static func create(_ request: AggregateDeviceRequest) throws -> AggregateDevice {
        var devices = try AudioDeviceInfo.enumerateAll()

        func lookup(_ uid: String) throws -> AudioDeviceInfo {
            guard let device = devices.first(where: { $0.uid == uid }) else {
                throw AggregateDeviceError.deviceNotFound(uid: uid)
            }
            return device
        }

        // --- Validate the request before touching any hardware.
        let output = try lookup(request.outputDeviceUID)
        guard output.hasOutput else { throw AggregateDeviceError.deviceHasNoOutput(name: output.name) }

        var seen = Set<String>()
        var inputUIDs: [String] = []
        for uid in request.inputDeviceUIDs where !seen.contains(uid) {
            seen.insert(uid)
            let device = try lookup(uid)
            guard uid != request.outputDeviceUID else {
                throw AggregateDeviceError.deviceRejected(
                    name: device.name,
                    reason: "it is the output device; using it as a lane source would feed the mix back into itself"
                )
            }
            guard !device.transport.isAggregate else {
                throw AggregateDeviceError.deviceRejected(name: device.name, reason: "aggregates cannot be nested")
            }
            guard !device.transport.isBluetooth else {
                throw AggregateDeviceError.deviceRejected(name: device.name, reason: "Bluetooth latency is unstable and input forces the HFP codec")
            }
            guard device.hasInput else { throw AggregateDeviceError.deviceHasNoInput(name: device.name) }
            inputUIDs.append(uid)
        }

        // --- Put every sub-device on the same nominal rate first. An
        // aggregate whose members disagree either fails to start or resamples
        // behind our back.
        let orderedUIDs = inputUIDs + [request.outputDeviceUID]
        for uid in orderedUIDs {
            try align(device: try lookup(uid), to: request.sampleRate)
        }
        devices = try AudioDeviceInfo.enumerateAll()

        // --- Build the description. Inputs get drift compensation; the main
        // sub-device (the output) is the clock and must not be resampled.
        var subDeviceList: [[String: Any]] = inputUIDs.map {
            [kAudioSubDeviceUIDKey: $0, kAudioSubDeviceDriftCompensationKey: 1]
        }
        subDeviceList.append([
            kAudioSubDeviceUIDKey: request.outputDeviceUID,
            kAudioSubDeviceDriftCompensationKey: 0
        ])

        let aggregateUID = "com.astroqore.Clapboard.aggregate.\(UUID().uuidString)"
        var description: [String: Any] = [
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceNameKey: request.name,
            kAudioAggregateDeviceIsPrivateKey: 1,
            kAudioAggregateDeviceIsStackedKey: 0,
            kAudioAggregateDeviceSubDeviceListKey: subDeviceList,
            kAudioAggregateDeviceMainSubDeviceKey: request.outputDeviceUID
        ]

        // `kAudioAggregateDeviceClockDeviceKey` wants the UID of an
        // AudioClockDevice, not of an audio device. Ask for it anyway — some
        // drivers publish a matching clock — but fall back to plain main
        // sub-device clocking rather than shipping a device that never runs.
        var usedClockDeviceKey = true
        description[kAudioAggregateDeviceClockDeviceKey] = request.outputDeviceUID
        var objectID = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &objectID)
        if status != noErr || objectID == kAudioObjectUnknown || !hasActiveSubDevices(objectID) {
            if objectID != kAudioObjectUnknown {
                AudioHardwareDestroyAggregateDevice(objectID)
            }
            usedClockDeviceKey = false
            description.removeValue(forKey: kAudioAggregateDeviceClockDeviceKey)
            objectID = AudioObjectID(kAudioObjectUnknown)
            status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &objectID)
        }
        guard status == noErr, objectID != kAudioObjectUnknown else {
            throw AggregateDeviceError.creationFailed(status: status)
        }

        var created = false
        defer { if !created { AudioHardwareDestroyAggregateDevice(objectID) } }

        // --- Format. Both properties are best-effort: the HAL may clamp the
        // buffer size, and we read back what it actually gave us.
        try? objectID.setProperty(.init(kAudioDevicePropertyNominalSampleRate), value: request.sampleRate)
        try? objectID.setProperty(.init(kAudioDevicePropertyBufferFrameSize), value: request.bufferFrameSize)
        let actualRate = (try? objectID.property(.init(kAudioDevicePropertyNominalSampleRate), as: Double.self)) ?? request.sampleRate
        let actualBuffer = (try? objectID.property(.init(kAudioDevicePropertyBufferFrameSize), as: UInt32.self)) ?? request.bufferFrameSize

        // --- Wait for the sub-devices to come up. A freshly created aggregate
        // is briefly empty and starting an IOProc on it yields silence.
        let activeUIDs = try waitForActiveSubDevices(objectID, expecting: orderedUIDs.count)
        let missing = orderedUIDs.filter { !activeUIDs.contains($0) }
        if !missing.isEmpty && !activeUIDs.isEmpty {
            let names = missing.map { uid in devices.first { $0.uid == uid }?.name ?? uid }
            throw AggregateDeviceError.subDevicesInactive(missing: names)
        }

        // --- Channel map, from the sub-devices' *current* stream configs.
        let fresh = try AudioDeviceInfo.enumerateAll()
        func info(_ uid: String) throws -> AudioDeviceInfo {
            guard let device = fresh.first(where: { $0.uid == uid }) else {
                throw AggregateDeviceError.deviceNotFound(uid: uid)
            }
            return device
        }

        let inputSubLayouts = try orderedUIDs.map {
            SubDeviceInputLayout(deviceUID: $0, streamChannelCounts: try info($0).inputStreamChannels)
        }
        let outputSubLayouts = try orderedUIDs.map {
            SubDeviceStreamLayout(deviceUID: $0, streamChannelCounts: try info($0).outputStreamChannels)
        }
        let inputLayout = AggregateInputLayout(subDevices: inputSubLayouts)
        let outputLayout = AggregateStreamLayout(subDevices: outputSubLayouts)

        // --- Cross-check against what the aggregate itself advertises. If
        // these disagree the channel offsets we would hand the render thread
        // are fiction, and a sub-device that silently dropped out is exactly
        // the case that shifts them.
        let aggregateInput = try objectID.streamChannelCounts(scope: kAudioObjectPropertyScopeInput)
        let aggregateOutput = try objectID.streamChannelCounts(scope: kAudioObjectPropertyScopeOutput)
        guard aggregateInput == inputLayout.slots.map(\.channelCount) else {
            throw AggregateDeviceError.channelLayoutMismatch(
                scope: "input", expected: inputLayout.slots.map(\.channelCount), actual: aggregateInput
            )
        }
        guard aggregateOutput == outputLayout.slots.map(\.channelCount) else {
            throw AggregateDeviceError.channelLayoutMismatch(
                scope: "output", expected: outputLayout.slots.map(\.channelCount), actual: aggregateOutput
            )
        }

        // --- The master mix goes to the *output device's* first output
        // stream, which is not buffer 0 when an input sub-device also has
        // output streams (Loopback devices always do).
        guard let masterSlot = outputLayout.slots.first(where: { $0.deviceUID == request.outputDeviceUID }) else {
            throw AggregateDeviceError.outputStreamNotFound(uid: request.outputDeviceUID)
        }

        created = true
        return AggregateDevice(
            objectID: objectID,
            uid: aggregateUID,
            name: request.name,
            inputDeviceUIDs: inputUIDs,
            outputDeviceUID: request.outputDeviceUID,
            sampleRate: actualRate,
            bufferFrameSize: actualBuffer,
            inputLayout: inputLayout,
            outputLayout: outputLayout,
            masterOutputBufferIndex: masterSlot.bufferIndex,
            masterOutputChannels: masterSlot.channelCount,
            usedClockDeviceKey: usedClockDeviceKey
        )
    }

    // MARK: - Helpers

    /// Moves one device to `rate`, refusing devices that cannot get there.
    private static func align(device: AudioDeviceInfo, to rate: Double) throws {
        if abs(device.nominalSampleRate - rate) < 0.5 { return }
        guard device.supports(sampleRate: rate) else {
            throw AggregateDeviceError.sampleRateUnsupported(
                name: device.name, wanted: rate, available: device.fixedSampleRates
            )
        }
        try? device.id.setProperty(.init(kAudioDevicePropertyNominalSampleRate), value: rate)
        // The HAL applies a rate change asynchronously and notifies listeners
        // afterwards, so poll instead of trusting the setter's return.
        for _ in 0..<60 {
            let current = (try? device.id.property(.init(kAudioDevicePropertyNominalSampleRate), as: Double.self)) ?? 0
            if abs(current - rate) < 0.5 { return }
            usleep(25_000)
        }
        let current = (try? device.id.property(.init(kAudioDevicePropertyNominalSampleRate), as: Double.self)) ?? 0
        throw AggregateDeviceError.sampleRateRefused(name: device.name, wanted: rate, actual: current)
    }

    private static func hasActiveSubDevices(_ objectID: AudioObjectID) -> Bool {
        guard objectID != kAudioObjectUnknown else { return false }
        let ids = (try? objectID.propertyArray(
            .init(kAudioAggregateDevicePropertyActiveSubDeviceList), of: AudioObjectID.self
        )) ?? []
        return !ids.isEmpty
    }

    private static func waitForActiveSubDevices(_ objectID: AudioObjectID, expecting count: Int) throws -> Set<String> {
        var uids: Set<String> = []
        for _ in 0..<40 {
            let ids = (try? objectID.propertyArray(
                .init(kAudioAggregateDevicePropertyActiveSubDeviceList), of: AudioObjectID.self
            )) ?? []
            uids = Set(ids.compactMap { try? $0.propertyString(.init(kAudioDevicePropertyDeviceUID)) })
            if ids.count >= count { break }
            usleep(25_000)
        }
        return uids
    }
}
