import AVFoundation
import AudioToolbox
import Foundation

/// The installed effect plug-ins, as values.
///
/// Enumeration is a plain synchronous call rather than an actor or an `async`
/// API on purpose. It is not cheap — the component manager may have to open
/// and read every bundle in `/Library/Audio/Plug-Ins/Components`, which takes
/// the better part of a second on a machine with a large plug-in folder — and
/// the caller is in the best position to decide where that second is spent.
/// Call it off the main thread and hand the result to the UI.
public enum AUCatalog {
    /// Every `aufx` and `aumf` component the system knows about, sorted by
    /// manufacturer then name.
    ///
    /// Music effects (`aumf`) are included because plenty of them are useful
    /// on a plain audio lane; Clapboard never sends them MIDI.
    public static func effects() -> [AUComponentInfo] {
        var found = components(ofType: kAudioUnitType_Effect)
        found += components(ofType: kAudioUnitType_MusicEffect)
        return sorted(found)
    }

    /// All components of one type. Sub-type and manufacturer are left at zero,
    /// which `AVAudioUnitComponentManager` reads as "any".
    public static func components(ofType type: OSType) -> [AUComponentInfo] {
        var description = AudioComponentDescription()
        description.componentType = type
        return components(matching: description)
    }

    public static func components(matching description: AudioComponentDescription) -> [AUComponentInfo] {
        AVAudioUnitComponentManager.shared()
            .components(matching: description)
            .map(AUComponentInfo.init(component:))
    }

    /// Look one plug-in up by its identity, the way a restored session does.
    /// Returns `nil` when the plug-in is not installed on this machine.
    public static func find(
        type: OSType,
        subType: OSType,
        manufacturer: OSType
    ) -> AUComponentInfo? {
        var description = AudioComponentDescription()
        description.componentType = type
        description.componentSubType = subType
        description.componentManufacturer = manufacturer
        return components(matching: description).first
    }

    /// The same, keyed by `AUComponentInfo.id` ("aufx.dely.appl").
    public static func find(id: String) -> AUComponentInfo? {
        let parts = id.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        return find(
            type: AUComponentInfo.fourCharCode(String(parts[0])),
            subType: AUComponentInfo.fourCharCode(String(parts[1])),
            manufacturer: AUComponentInfo.fourCharCode(String(parts[2]))
        )
    }

    /// Manufacturer first, then name, both case-insensitive, so a plug-in menu
    /// groups by vendor without a second pass.
    static func sorted(_ infos: [AUComponentInfo]) -> [AUComponentInfo] {
        infos.sorted { left, right in
            let byManufacturer = left.manufacturerName.caseInsensitiveCompare(right.manufacturerName)
            if byManufacturer != .orderedSame { return byManufacturer == .orderedAscending }
            let byName = left.name.caseInsensitiveCompare(right.name)
            if byName != .orderedSame { return byName == .orderedAscending }
            return left.id < right.id
        }
    }
}

extension AUComponentInfo {
    init(component: AVAudioUnitComponent) {
        let description = component.audioComponentDescription
        self.init(
            name: component.name,
            manufacturerName: component.manufacturerName,
            versionString: component.versionString,
            componentType: description.componentType,
            componentSubType: description.componentSubType,
            componentManufacturer: description.componentManufacturer,
            componentFlags: description.componentFlags,
            componentFlagsMask: description.componentFlagsMask,
            hasCustomView: component.hasCustomView,
            isSandboxSafe: component.isSandboxSafe,
            tags: component.allTagNames,
            bundleURL: component.componentURL
        )
    }
}
