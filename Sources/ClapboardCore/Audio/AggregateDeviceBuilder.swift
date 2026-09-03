import CoreAudio
import Foundation

/// What the engine wants an aggregate device to look like.
public struct AggregateDeviceRequest: Hashable, Sendable {
    /// Lane source devices, in the order their channels should appear.
    public var inputDeviceUIDs: [String]
    /// Output devices, in priority order. The first becomes the aggregate's
    /// clock main (`kAudioAggregateDeviceMainSubDeviceKey`, and the clock
    /// device when the HAL accepts it); every one of them is a mix
    /// destination some bus may write to. Never also an input. At least one
    /// is required.
    public var outputDeviceUIDs: [String]
    public var sampleRate: Double
    public var bufferFrameSize: UInt32
    public var name: String

    public init(
        inputDeviceUIDs: [String],
        outputDeviceUIDs: [String],
        sampleRate: Double = 48_000,
        bufferFrameSize: UInt32 = 256,
        name: String = "Clapboard Mix"
    ) {
        self.inputDeviceUIDs = inputDeviceUIDs
        self.outputDeviceUIDs = outputDeviceUIDs
        self.sampleRate = sampleRate
        self.bufferFrameSize = bufferFrameSize
        self.name = name
    }
}

public enum AggregateDeviceError: Error, CustomStringConvertible, Sendable {
    case noOutputDevices
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
        case .noOutputDevices:
            return "At least one output device is required."
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
    /// Every output device the aggregate carries, in priority order. The
    /// first is the clock main (`kAudioAggregateDeviceMainSubDeviceKey`).
    public let outputDeviceUIDs: [String]
    public let sampleRate: Double
    public let bufferFrameSize: UInt32

    /// Where each sub-device's input channels land in the IOProc input list.
    public let inputLayout: AggregateInputLayout
    /// Same arithmetic for the output list. An *input* sub-device that also
    /// exposes output streams (Loopback always does) contributes buffers here
    /// ahead of every requested output device, so a bus's buffer index is
    /// always looked up by device UID — never assumed — via `outputSlot`.
    public let outputLayout: AggregateStreamLayout
    /// True when the HAL accepted `kAudioAggregateDeviceClockDeviceKey`.
    public let usedClockDeviceKey: Bool

    private var destroyed = false

    init(
        objectID: AudioObjectID,
        uid: String,
        name: String,
        inputDeviceUIDs: [String],
        outputDeviceUIDs: [String],
        sampleRate: Double,
        bufferFrameSize: UInt32,
        inputLayout: AggregateInputLayout,
        outputLayout: AggregateStreamLayout,
        usedClockDeviceKey: Bool
    ) {
        self.objectID = objectID
        self.uid = uid
        self.name = name
        self.inputDeviceUIDs = inputDeviceUIDs
        self.outputDeviceUIDs = outputDeviceUIDs
        self.sampleRate = sampleRate
        self.bufferFrameSize = bufferFrameSize
        self.inputLayout = inputLayout
        self.outputLayout = outputLayout
        self.usedClockDeviceKey = usedClockDeviceKey
    }

    /// This output device's slot in the IOProc output buffer list — the
    /// buffer index and channel count a bus targeting it needs. `nil` when
    /// `uid` is not one of this aggregate's output devices.
    ///
    /// Deliberately a lookup by UID rather than an assumed index: an input
    /// sub-device that also has output streams (Loopback) contributes output
    /// buffers ahead of the requested output devices, so the only correct
    /// source of truth is the sub-devices' actual stream configuration.
    public func outputSlot(forDeviceUID uid: String) -> AggregateStreamLayout.Slot? {
        outputLayout.slots.first { $0.deviceUID == uid }
    }

    /// The first (clock-main) output device's slot — what the render graph
    /// used before more than one output device existed, and still what a
    /// single-output engine run wants.
    public var masterOutputSlot: AggregateStreamLayout.Slot? {
        outputDeviceUIDs.first.flatMap(outputSlot(forDeviceUID:))
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
        let outputs = outputDeviceUIDs.map { uid -> String in
            guard let slot = outputSlot(forDeviceUID: uid) else { return "\(uid)[?]" }
            return "\(uid)[buf=\(slot.bufferIndex)/\(slot.channelCount)ch]"
        }.joined(separator: " ")
        return "\(name) id=\(objectID) rate=\(Int(sampleRate)) buffer=\(bufferFrameSize) "
            + "in=\(inputLayout.totalChannels)ch(\(inputLayout.bufferCount) streams) "
            + "clockKey=\(usedClockDeviceKey) | in: \(inputs) | out: \(outputs)"
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
        guard !request.outputDeviceUIDs.isEmpty else { throw AggregateDeviceError.noOutputDevices }
        var outputUIDs: [String] = []
        var seenOutputs = Set<String>()
        for uid in request.outputDeviceUIDs where !seenOutputs.contains(uid) {
            seenOutputs.insert(uid)
            let device = try lookup(uid)
            guard device.hasOutput else { throw AggregateDeviceError.deviceHasNoOutput(name: device.name) }
            outputUIDs.append(uid)
        }

        var seen = Set<String>()
        var inputUIDs: [String] = []
        for uid in request.inputDeviceUIDs where !seen.contains(uid) {
            seen.insert(uid)
            let device = try lookup(uid)
            guard !outputUIDs.contains(uid) else {
                throw AggregateDeviceError.deviceRejected(
                    name: device.name,
                    reason: "it is one of the output devices; using it as a lane source would feed the mix back into itself"
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
        let orderedUIDs = inputUIDs + outputUIDs
        for uid in orderedUIDs {
            try align(device: try lookup(uid), to: request.sampleRate)
        }
        devices = try AudioDeviceInfo.enumerateAll()

        // --- Build the description. Inputs get drift compensation; so does
        // every output device except the first, which is the clock main and
        // must not be resampled against itself.
        var subDeviceList: [[String: Any]] = inputUIDs.map {
            [kAudioSubDeviceUIDKey: $0, kAudioSubDeviceDriftCompensationKey: 1]
        }
        for (index, uid) in outputUIDs.enumerated() {
            subDeviceList.append([
                kAudioSubDeviceUIDKey: uid,
                kAudioSubDeviceDriftCompensationKey: index == 0 ? 0 : 1
            ])
        }
        let clockMainUID = outputUIDs[0]

        let aggregateUID = "com.astroqore.Clapboard.aggregate.\(UUID().uuidString)"
        var description: [String: Any] = [
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceNameKey: request.name,
            kAudioAggregateDeviceIsPrivateKey: 1,
            kAudioAggregateDeviceIsStackedKey: 0,
            kAudioAggregateDeviceSubDeviceListKey: subDeviceList,
            kAudioAggregateDeviceMainSubDeviceKey: clockMainUID
        ]

        // `kAudioAggregateDeviceClockDeviceKey` wants the UID of an
        // AudioClockDevice, not of an audio device. Ask for it anyway — some
        // drivers publish a matching clock — but fall back to plain main
        // sub-device clocking rather than shipping a device that never runs.
        var usedClockDeviceKey = true
        description[kAudioAggregateDeviceClockDeviceKey] = clockMainUID
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

        // --- Every requested output device must have produced a stream. Its
        // buffer index is whatever the actual stream configuration says, not
        // an assumed position: an *input* sub-device that also exposes output
        // streams (Loopback always does) contributes buffers ahead of every
        // output device we asked for.
        for uid in outputUIDs {
            guard outputLayout.slots.contains(where: { $0.deviceUID == uid }) else {
                throw AggregateDeviceError.outputStreamNotFound(uid: uid)
            }
        }

        created = true
        return AggregateDevice(
            objectID: objectID,
            uid: aggregateUID,
            name: request.name,
            inputDeviceUIDs: inputUIDs,
            outputDeviceUIDs: outputUIDs,
            sampleRate: actualRate,
            bufferFrameSize: actualBuffer,
            inputLayout: inputLayout,
            outputLayout: outputLayout,
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
