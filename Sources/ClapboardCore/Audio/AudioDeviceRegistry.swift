import CoreAudio
import Foundation
import Observation

/// Live list of Core Audio devices. Refreshes itself when devices are plugged
/// in or removed and when the system default input/output changes.
///
/// Main-actor bound: the HAL listener is registered on the main queue, and
/// SwiftUI observes the published properties directly.
@MainActor
@Observable
public final class AudioDeviceRegistry {
    public private(set) var devices: [AudioDeviceInfo] = []
    public private(set) var defaultInputUID: String?
    public private(set) var defaultOutputUID: String?
    public private(set) var lastError: String?
    public private(set) var lastRefresh: Date?
    /// Incremented on every refresh, so callers can cheaply detect change.
    public private(set) var generation: Int = 0

    /// Called after every refresh triggered by the HAL (not by `refresh()`).
    public var onHardwareChange: (() -> Void)?

    private var listening = false
    private var listenerBlock: AudioObjectPropertyListenerBlock?
    private static let watchedSelectors: [AudioObjectPropertySelector] = [
        kAudioHardwarePropertyDevices,
        kAudioHardwarePropertyDefaultInputDevice,
        kAudioHardwarePropertyDefaultOutputDevice
    ]

    public init() {}

    public var inputDevices: [AudioDeviceInfo] {
        devices.filter { $0.hasInput && !$0.isHidden && !$0.transport.isAggregate }
    }

    public var outputDevices: [AudioDeviceInfo] {
        devices.filter { $0.hasOutput && !$0.isHidden && !$0.transport.isAggregate }
    }

    public func device(uid: String) -> AudioDeviceInfo? {
        devices.first { $0.uid == uid }
    }

    /// Reads the device list once and starts watching the HAL.
    public func start() {
        refresh()
        guard !listening else { return }
        listening = true
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.refresh()
                self.onHardwareChange?()
            }
        }
        listenerBlock = block
        for selector in Self.watchedSelectors {
            var address = AudioObjectPropertyAddress(selector)
            let status = AudioObjectAddPropertyListenerBlock(AudioObjectID.system, &address, DispatchQueue.main, block)
            if status != noErr {
                lastError = CoreAudioError(status: status, operation: "AddPropertyListenerBlock \(fourCharCode(selector))").description
            }
        }
    }

    public func stop() {
        guard listening, let block = listenerBlock else { return }
        for selector in Self.watchedSelectors {
            var address = AudioObjectPropertyAddress(selector)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID.system, &address, DispatchQueue.main, block)
        }
        listenerBlock = nil
        listening = false
    }

    public func refresh() {
        do {
            let all = try AudioDeviceInfo.enumerateAll()
            devices = all
            let inputID = AudioDeviceInfo.defaultDeviceID(input: true)
            let outputID = AudioDeviceInfo.defaultDeviceID(input: false)
            defaultInputUID = all.first { $0.id == inputID }?.uid
            defaultOutputUID = all.first { $0.id == outputID }?.uid
            lastError = nil
        } catch {
            lastError = String(describing: error)
        }
        lastRefresh = Date()
        generation += 1
    }
}
