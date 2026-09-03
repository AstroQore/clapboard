import CoreAudio
import Foundation

/// Error raised by the thin Core Audio property wrappers below.
public struct CoreAudioError: Error, CustomStringConvertible, Sendable {
    public let status: OSStatus
    public let operation: String

    public init(status: OSStatus, operation: String) {
        self.status = status
        self.operation = operation
    }

    public var description: String {
        "\(operation) failed with \(fourCharCode(status)) (\(status))"
    }
}

/// Renders an OSStatus / four-char selector as `'abcd'` when printable.
public func fourCharCode(_ code: OSStatus) -> String {
    fourCharCode(UInt32(bitPattern: code))
}

public func fourCharCode(_ code: UInt32) -> String {
    let bytes = [
        UInt8((code >> 24) & 0xFF), UInt8((code >> 16) & 0xFF),
        UInt8((code >> 8) & 0xFF), UInt8(code & 0xFF)
    ]
    if bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) {
        return "'" + String(decoding: bytes, as: UTF8.self) + "'"
    }
    return String(code)
}

extension AudioObjectPropertyAddress {
    public init(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) {
        self.init(mSelector: selector, mScope: scope, mElement: element)
    }
}

/// Convenience accessors over `AudioObjectGetPropertyData` and friends.
///
/// All generic helpers require `T` to be a trivial (POD) Core Audio type;
/// strings go through `propertyString` because Core Audio hands back a
/// +1 retained `CFString`.
extension AudioObjectID {
    public static let system = AudioObjectID(kAudioObjectSystemObject)

    public func hasProperty(_ address: AudioObjectPropertyAddress) -> Bool {
        var address = address
        return AudioObjectHasProperty(self, &address)
    }

    public func propertyDataSize(_ address: AudioObjectPropertyAddress) throws -> UInt32 {
        var address = address
        var size: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(self, &address, 0, nil, &size)
        guard status == noErr else {
            throw CoreAudioError(status: status, operation: "GetPropertyDataSize \(fourCharCode(address.mSelector))")
        }
        return size
    }

    public func property<T>(_ address: AudioObjectPropertyAddress, as type: T.Type = T.self) throws -> T {
        var address = address
        var size = UInt32(MemoryLayout<T>.size)
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<T>.alignment)
        defer { raw.deallocate() }
        let status = AudioObjectGetPropertyData(self, &address, 0, nil, &size, raw)
        guard status == noErr else {
            throw CoreAudioError(status: status, operation: "GetPropertyData \(fourCharCode(address.mSelector))")
        }
        return raw.load(as: T.self)
    }

    public func propertyArray<T>(_ address: AudioObjectPropertyAddress, of type: T.Type = T.self) throws -> [T] {
        let size = try propertyDataSize(address)
        let count = Int(size) / MemoryLayout<T>.stride
        guard count > 0 else { return [] }
        var address = address
        var mutableSize = size
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<T>.alignment)
        defer { raw.deallocate() }
        let status = AudioObjectGetPropertyData(self, &address, 0, nil, &mutableSize, raw)
        guard status == noErr else {
            throw CoreAudioError(status: status, operation: "GetPropertyData \(fourCharCode(address.mSelector))")
        }
        let actualCount = Int(mutableSize) / MemoryLayout<T>.stride
        return (0..<actualCount).map { raw.load(fromByteOffset: $0 * MemoryLayout<T>.stride, as: T.self) }
    }

    public func propertyString(_ address: AudioObjectPropertyAddress) throws -> String {
        var address = address
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var value: Unmanaged<CFString>? = nil
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(self, &address, 0, nil, &size, pointer)
        }
        guard status == noErr else {
            throw CoreAudioError(status: status, operation: "GetPropertyData \(fourCharCode(address.mSelector))")
        }
        guard let value else { return "" }
        return value.takeRetainedValue() as String
    }

    public func setProperty<T>(_ address: AudioObjectPropertyAddress, value: T) throws {
        var address = address
        var value = value
        let status = withUnsafePointer(to: &value) { pointer in
            AudioObjectSetPropertyData(self, &address, 0, nil, UInt32(MemoryLayout<T>.size), pointer)
        }
        guard status == noErr else {
            throw CoreAudioError(status: status, operation: "SetPropertyData \(fourCharCode(address.mSelector))")
        }
    }

    /// Channel count of every stream in `scope`, in stream order. This is the
    /// shape the HAL uses for the `AudioBufferList` it hands an IOProc: one
    /// buffer per stream, channels interleaved inside the buffer.
    public func streamChannelCounts(scope: AudioObjectPropertyScope) throws -> [Int] {
        let address = AudioObjectPropertyAddress(kAudioDevicePropertyStreamConfiguration, scope: scope)
        guard hasProperty(address) else { return [] }
        let size = try propertyDataSize(address)
        guard size > 0 else { return [] }
        var mutableAddress = address
        var mutableSize = size
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        let status = AudioObjectGetPropertyData(self, &mutableAddress, 0, nil, &mutableSize, raw)
        guard status == noErr else {
            throw CoreAudioError(status: status, operation: "GetPropertyData StreamConfiguration")
        }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.map { Int($0.mNumberChannels) }
    }
}
