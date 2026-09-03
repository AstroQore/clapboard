import Foundation

/// How a lane's channels are mapped onto a plug-in's input and output bus.
public struct AUChannelPlan: Hashable, Sendable {
    /// Channels the plug-in's busses are configured with, 1 or 2.
    public var channels: Int
    /// True when a mono lane is being run through a plug-in that refuses a
    /// mono configuration: the lane's samples are written to both input
    /// channels and only the left output channel is taken back.
    public var dualMono: Bool

    public init(channels: Int, dualMono: Bool) {
        self.channels = channels
        self.dualMono = dualMono
    }
}

/// `AUAudioUnit.channelCapabilities`, decoded.
///
/// The array is a flat list of (input, output) pairs of `NSNumber`s, and the
/// negative values are not a bitfield but four separate conventions — see
/// AUAudioUnit.h. Getting this wrong is how a host ends up asking
/// AUMatrixReverb for a mono output and getting `kAudioUnitErr_FormatNotSupported`
/// out of `setFormat`, so the decoding lives here with tests rather than
/// inline in the instantiation path.
public enum AUChannelCapabilities {
    /// Does the plug-in accept this exact input/output channel pair?
    ///
    /// An empty list means the plug-in published no constraint — most of
    /// Apple's own effects do this — and everything is assumed supported.
    public static func supports(
        inputChannels: Int,
        outputChannels: Int,
        capabilities: [Int]
    ) -> Bool {
        guard capabilities.count >= 2 else { return true }
        var index = 0
        while index + 1 < capabilities.count {
            let inSpec = capabilities[index]
            let outSpec = capabilities[index + 1]
            index += 2
            guard side(inSpec, accepts: inputChannels), side(outSpec, accepts: outputChannels) else {
                continue
            }
            // (-1, -1) is the one pair that couples the two sides: any channel
            // count, as long as input and output agree.
            if inSpec == -1, outSpec == -1, inputChannels != outputChannels { continue }
            return true
        }
        return false
    }

    /// One half of a pair.
    ///
    /// - `0`  — "not applicable", the scope has no elements; no constraint.
    /// - `>0` — exactly that many channels.
    /// - `-1`, `-2` — any number of channels (`-1` on *both* sides also means
    ///   "the same number"; that coupling is applied by the caller).
    /// - `< -2` — a total channel count across every bus in the scope, i.e. an
    ///   upper bound.
    static func side(_ spec: Int, accepts channels: Int) -> Bool {
        if spec == 0 { return true }
        if spec > 0 { return spec == channels }
        if spec == -1 || spec == -2 { return true }
        return channels <= -spec
    }

    /// Pick the bus configuration for a lane.
    ///
    /// A mono lane prefers a mono plug-in configuration: it is half the work,
    /// and a plug-in that treats its two channels differently (a stereo imager,
    /// a mid/side EQ) would otherwise be fed a fake stereo image. Only when
    /// mono is refused does the lane go dual-mono.
    public static func plan(forLaneChannels laneChannels: Int, capabilities: [Int]) -> AUChannelPlan {
        if laneChannels == 1 {
            if supports(inputChannels: 1, outputChannels: 1, capabilities: capabilities) {
                return AUChannelPlan(channels: 1, dualMono: false)
            }
            return AUChannelPlan(channels: 2, dualMono: true)
        }
        return AUChannelPlan(channels: 2, dualMono: false)
    }
}
