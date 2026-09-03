import AudioToolbox
import Foundation

/// One installed Audio Unit, as a value.
///
/// `AVAudioUnitComponent` is a reference type owned by the component manager
/// and is not `Sendable`; the catalog converts every hit into one of these
/// immediately so lane configuration, the session file and the UI can all pass
/// plug-in identities around freely.
///
/// The `AudioComponentDescription` is stored as its five `UInt32` fields
/// rather than the C struct so the type is `Codable` — a session file has to
/// survive a plug-in being uninstalled and reinstalled, and the four-char
/// codes are the only stable identity an Audio Unit has.
public struct AUComponentInfo: Identifiable, Hashable, Codable, Sendable {
    public var name: String
    public var manufacturerName: String
    public var versionString: String

    public var componentType: UInt32
    public var componentSubType: UInt32
    public var componentManufacturer: UInt32
    public var componentFlags: UInt32
    public var componentFlagsMask: UInt32

    /// Whether the plug-in ships its own view. `false` means the host has to
    /// fall back to `AUGenericView`.
    public var hasCustomView: Bool
    public var isSandboxSafe: Bool
    /// Category tags as the component manager reports them ("Effects",
    /// "Reverb"…). Empty for most third-party plug-ins.
    public var tags: [String]

    public init(
        name: String,
        manufacturerName: String,
        versionString: String,
        componentType: UInt32,
        componentSubType: UInt32,
        componentManufacturer: UInt32,
        componentFlags: UInt32 = 0,
        componentFlagsMask: UInt32 = 0,
        hasCustomView: Bool = false,
        isSandboxSafe: Bool = false,
        tags: [String] = []
    ) {
        self.name = name
        self.manufacturerName = manufacturerName
        self.versionString = versionString
        self.componentType = componentType
        self.componentSubType = componentSubType
        self.componentManufacturer = componentManufacturer
        self.componentFlags = componentFlags
        self.componentFlagsMask = componentFlagsMask
        self.hasCustomView = hasCustomView
        self.isSandboxSafe = isSandboxSafe
        self.tags = tags
    }

    /// Stable across launches and across versions of the same plug-in, which
    /// is what a session file needs: `aufx.dely.appl`.
    public var id: String {
        "\(Self.fourCharString(componentType)).\(Self.fourCharString(componentSubType))."
            + Self.fourCharString(componentManufacturer)
    }

    /// AUv3 (app-extension) plug-ins can be loaded out of process. AUv2
    /// bundles are always in-process, which is why Clapboard cannot enable the
    /// hardened runtime.
    public var isAUv3: Bool {
        componentFlags & AudioComponentFlags.isV3AudioUnit.rawValue != 0
    }

    public var isMusicEffect: Bool { componentType == kAudioUnitType_MusicEffect }

    public var audioComponentDescription: AudioComponentDescription {
        AudioComponentDescription(
            componentType: componentType,
            componentSubType: componentSubType,
            componentManufacturer: componentManufacturer,
            componentFlags: 0,
            componentFlagsMask: 0
        )
    }

    /// "Manufacturer: Name", the form a plug-in menu wants.
    public var displayName: String {
        manufacturerName.isEmpty ? name : "\(manufacturerName): \(name)"
    }

    public var typeCode: String { Self.fourCharString(componentType) }
    public var subTypeCode: String { Self.fourCharString(componentSubType) }
    public var manufacturerCode: String { Self.fourCharString(componentManufacturer) }

    /// Big-endian four-char code as text. MacRoman, not UTF-8: `kAudioUnitType_*`
    /// codes are byte quadruples and a few shipping plug-ins use bytes above
    /// 0x7F, which UTF-8 would refuse.
    public static func fourCharString(_ code: UInt32) -> String {
        let bytes: [UInt8] = [
            UInt8(truncatingIfNeeded: code >> 24),
            UInt8(truncatingIfNeeded: code >> 16),
            UInt8(truncatingIfNeeded: code >> 8),
            UInt8(truncatingIfNeeded: code)
        ]
        return String(bytes: bytes, encoding: .macOSRoman) ?? "????"
    }

    /// Inverse of `fourCharString`, for literals in code and tests.
    public static func fourCharCode(_ text: String) -> UInt32 {
        var code: UInt32 = 0
        var count = 0
        for byte in Array(text.data(using: .macOSRoman) ?? Data()).prefix(4) {
            code = (code << 8) | UInt32(byte)
            count += 1
        }
        while count < 4 {
            code <<= 8
            count += 1
        }
        return code
    }
}
