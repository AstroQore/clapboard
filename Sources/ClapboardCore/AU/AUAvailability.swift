import Foundation

/// Which architectures a Mach-O file was built for.
///
/// Clapboard needs this for one question only: does this AUv2 bundle contain a
/// slice for the architecture Clapboard itself is running as? An AUv2 plug-in
/// is loaded into the host process or not at all, so an Intel-only bundle on
/// an Apple Silicon Mac cannot be hosted — macOS answers by starting a Rosetta
/// hosting service instead, and a plug-in in there never finishes allocating
/// its render resources (see `AUHostError.outOfProcessV2Unsupported`). Asking
/// the file up front is what lets the plug-in menu grey the entry with a
/// reason rather than making the user find out by clicking it.
public enum MachOArchitecture {
    public static let arm64: UInt32 = 0x0100_000C  // CPU_TYPE_ARM | CPU_ARCH_ABI64
    public static let x86_64: UInt32 = 0x0100_0007  // CPU_TYPE_X86 | CPU_ARCH_ABI64

    /// The architecture this build of Clapboard runs as.
    public static var host: UInt32 {
        #if arch(arm64)
        return arm64
        #else
        return x86_64
        #endif
    }

    /// CPU types found in `url`, or `nil` when the file could not be read or
    /// is not Mach-O. `nil` is deliberately different from `[]`: "we do not
    /// know" must never be reported to the user as "this will not work".
    public static func cpuTypes(inFileAt url: URL) -> [UInt32]? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        // Enough for a fat header with a very generous number of slices; a
        // thin file needs eight bytes.
        guard let head = try? handle.read(upToCount: 4096), head.count >= 8 else { return nil }
        return head.withUnsafeBytes { raw -> [UInt32]? in
            let magic = raw.loadUnaligned(fromByteOffset: 0, as: UInt32.self)
            switch magic {
            case 0xFEED_FACE, 0xFEED_FACF:
                // Thin, host byte order: cputype follows the magic.
                return [raw.loadUnaligned(fromByteOffset: 4, as: UInt32.self)]
            case 0xCEFA_EDFE, 0xCFFA_EDFE:
                return [raw.loadUnaligned(fromByteOffset: 4, as: UInt32.self).byteSwapped]
            case 0xBEBA_FECA, 0xBFBA_FECA:
                // Universal. The fat header is always big-endian, so on this
                // machine every field arrives byte-swapped. 0xBFBAFECA is the
                // 64-bit variant, whose entries are 32 rather than 20 bytes.
                let entrySize = magic == 0xBEBA_FECA ? 20 : 32
                let count = Int(raw.loadUnaligned(fromByteOffset: 4, as: UInt32.self).byteSwapped)
                guard count > 0, count < 64 else { return nil }
                var types: [UInt32] = []
                var offset = 8
                for _ in 0..<count {
                    guard offset + 4 <= raw.count else { break }
                    types.append(raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self).byteSwapped)
                    offset += entrySize
                }
                return types.isEmpty ? nil : types
            default:
                return nil
            }
        }
    }

    /// Does the bundle's executable contain a slice for this machine?
    /// `nil` when the answer could not be established.
    public static func bundleRunsNatively(at bundleURL: URL) -> Bool? {
        guard let executable = Bundle(url: bundleURL)?.executableURL,
              let types = cpuTypes(inFileAt: executable)
        else { return nil }
        return types.contains(host)
    }
}

/// Can Clapboard host this plug-in on this machine?
public enum AUAvailability {
    /// A one-line reason the plug-in cannot be used, or `nil` if it can.
    ///
    /// Only ever answers "no" when it is sure: a bundle it cannot read, a
    /// component with no URL, and every AUv3 are all reported as available and
    /// left to fail at instantiation with a real error.
    public static func reason(for info: AUComponentInfo) -> String? {
        // AUv3 plug-ins are app extensions. macOS can host one out of process
        // whatever it was built for, and part 1 accepts that.
        guard !info.isAUv3 else { return nil }
        guard let bundleURL = info.bundleURL else { return nil }
        guard MachOArchitecture.bundleRunsNatively(at: bundleURL) == false else { return nil }
        return "Intel-only AUv2 — an AUv2 plug-in is hosted in Clapboard's own process, "
            + "and this bundle has no Apple Silicon slice. Install a native version."
    }

    /// The reason a component that is not installed at all gets.
    public static func missingComponent(_ componentID: String) -> String {
        "\(componentID) is not installed on this Mac. Its settings are kept, "
            + "so plugging the plug-in back in restores the chain."
    }
}
