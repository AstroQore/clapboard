import CoreAudio
import Darwin
import Foundation

/// Drives one device with a HAL IOProc.
///
/// `AudioDeviceCreateIOProcIDWithBlock` with a nil queue runs the block on the
/// HAL's own real-time thread and hands input and output for the same cycle in
/// one call, which is why the engine uses it instead of two AUHAL units: the
/// timestamps match by construction and there is no `EnableIO` /
/// `CurrentDevice` ordering to get wrong.
///
/// The block captures exactly one value — an `UnsafeMutablePointer<RTState>` —
/// so no class reference is ever loaded on the render thread.
public final class HALIOProc {
    public enum Event: Sendable {
        case overload
        case deviceDied
        case sampleRateChanged
        case bufferSizeChanged
    }

    public let deviceID: AudioObjectID
    public private(set) var isRunning = false

    /// Delivered on the main queue.
    public var onEvent: ((Event) -> Void)?

    private let state: UnsafeMutablePointer<RTState>
    private var procID: AudioDeviceIOProcID?
    private var listenerBlocks: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

    private static let watchedSelectors: [AudioObjectPropertySelector] = [
        kAudioDeviceProcessorOverload,
        kAudioDevicePropertyDeviceIsAlive,
        kAudioDevicePropertyNominalSampleRate,
        kAudioDevicePropertyBufferFrameSize
    ]

    public init(deviceID: AudioObjectID, state: UnsafeMutablePointer<RTState>) {
        self.deviceID = deviceID
        self.state = state
    }

    deinit { stop() }

    public func start() throws {
        guard !isRunning else { return }
        let statePointer = state

        var newProcID: AudioDeviceIOProcID?
        let createStatus = AudioDeviceCreateIOProcIDWithBlock(&newProcID, deviceID, nil) {
            inNow, inInputData, _, outOutputData, _ in
            // --- Real-time thread. Nothing below allocates, locks or logs.
            let frames = Self.frameCount(input: inInputData, output: outOutputData)
            let hostTime = inNow.pointee.mFlags.contains(.hostTimeValid)
                ? inNow.pointee.mHostTime
                : mach_absolute_time()
            statePointer.pointee.lastCallbackHostTime.store(hostTime, ordering: .relaxed)
            statePointer.pointee.callbackCount.wrappingAdd(1, ordering: .relaxed)
            render(state: statePointer, input: inInputData, output: outOutputData, frames: frames)
        }
        guard createStatus == noErr, let newProcID else {
            throw CoreAudioError(status: createStatus, operation: "AudioDeviceCreateIOProcIDWithBlock")
        }
        procID = newProcID

        addListeners()

        let startStatus = AudioDeviceStart(deviceID, newProcID)
        guard startStatus == noErr else {
            removeListeners()
            AudioDeviceDestroyIOProcID(deviceID, newProcID)
            procID = nil
            throw CoreAudioError(status: startStatus, operation: "AudioDeviceStart")
        }
        isRunning = true
    }

    /// Stops the callback and tears the IOProc down. When this returns the
    /// block is guaranteed not to be executing, which is what makes it safe
    /// for the host to free retired graph snapshots.
    public func stop() {
        removeListeners()
        guard let procID else {
            isRunning = false
            return
        }
        if isRunning {
            AudioDeviceStop(deviceID, procID)
        }
        AudioDeviceDestroyIOProcID(deviceID, procID)
        self.procID = nil
        isRunning = false
    }

    // MARK: - Listeners

    private func addListeners() {
        guard listenerBlocks.isEmpty else { return }
        let statePointer = state
        for selector in Self.watchedSelectors {
            let address = AudioObjectPropertyAddress(selector)
            let event: Event
            switch selector {
            case kAudioDeviceProcessorOverload: event = .overload
            case kAudioDevicePropertyDeviceIsAlive: event = .deviceDied
            case kAudioDevicePropertyNominalSampleRate: event = .sampleRateChanged
            default: event = .bufferSizeChanged
            }
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                if event == .overload {
                    statePointer.pointee.overloadCount.wrappingAdd(1, ordering: .relaxed)
                }
                self?.onEvent?(event)
            }
            var mutableAddress = address
            let status = AudioObjectAddPropertyListenerBlock(deviceID, &mutableAddress, DispatchQueue.main, block)
            if status == noErr {
                listenerBlocks.append((address, block))
            }
        }
    }

    private func removeListeners() {
        for (address, block) in listenerBlocks {
            var mutableAddress = address
            AudioObjectRemovePropertyListenerBlock(deviceID, &mutableAddress, DispatchQueue.main, block)
        }
        listenerBlocks.removeAll()
    }

    // MARK: - Frame count

    /// The HAL does not pass a frame count, only buffers; derive it from the
    /// first buffer that has a sane shape.
    @inline(__always)
    private static func frameCount(
        input: UnsafePointer<AudioBufferList>?,
        output: UnsafeMutablePointer<AudioBufferList>?
    ) -> Int {
        if let output {
            let list = UnsafeMutableAudioBufferListPointer(output)
            if list.count > 0 {
                let buffer = list[0]
                let channels = Int(buffer.mNumberChannels)
                if channels > 0 {
                    return Int(buffer.mDataByteSize) / (channels * MemoryLayout<Float>.size)
                }
            }
        }
        if let input {
            let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            if list.count > 0 {
                let buffer = list[0]
                let channels = Int(buffer.mNumberChannels)
                if channels > 0 {
                    return Int(buffer.mDataByteSize) / (channels * MemoryLayout<Float>.size)
                }
            }
        }
        return 0
    }
}

/// Converts mach absolute time to seconds. Used by the main-thread watchdog,
/// never on the render thread.
public enum HostClock {
    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    public static var now: UInt64 { mach_absolute_time() }

    public static func seconds(since hostTime: UInt64) -> Double {
        let current = mach_absolute_time()
        guard hostTime != 0, current > hostTime else { return 0 }
        let elapsed = current - hostTime
        let nanos = Double(elapsed) * Double(timebase.numer) / Double(timebase.denom)
        return nanos / 1_000_000_000
    }
}
