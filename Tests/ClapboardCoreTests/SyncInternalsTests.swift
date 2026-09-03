@testable import ClapboardCore
import Foundation
import Testing

private typealias LaneSpec = SyncTestSignals.LaneSpec

@Suite("Sync internals")
struct SyncInternalsTests {
    let options = SyncOptions()

    @Test("the envelope detector finds the clap within a millisecond")
    func onsetDetectorLocatesTheClap() {
        var spec = LaneSpec("mic")
        spec.snrdB = 25
        let take = SyncTestSignals.makeTake([spec], seed: 4711)
        let analysis = OnsetDetector.analyze(
            samples: take.lanes[0].samples,
            sampleRate: SyncTestSignals.sampleRate,
            options: options
        )
        let onset = try! #require(analysis.onsetSample)
        let error = Double(onset) - take.clapPosition
        #expect(abs(error) <= 48, "onset off by \(error) samples")
        #expect((analysis.onsetSNRdB ?? 0) > 20)
        #expect(analysis.failure == nil)
    }

    @Test("digital silence and steady music are not transients")
    func onsetDetectorRejectsNonTransients() {
        var silent = LaneSpec("silent")
        silent.content = .silence
        var music = LaneSpec("music")
        music.content = .music
        let take = SyncTestSignals.makeTake([silent, music], seed: 99)

        let silentAnalysis = OnsetDetector.analyze(
            samples: take.lanes[0].samples, sampleRate: 48_000, options: options
        )
        #expect(silentAnalysis.onsetSample == nil)
        #expect(silentAnalysis.failure == .silent)

        let musicAnalysis = OnsetDetector.analyze(
            samples: take.lanes[1].samples, sampleRate: 48_000, options: options
        )
        #expect(musicAnalysis.onsetSample == nil)
        #expect(musicAnalysis.failure == .noTransient)
    }

    @Test("the noise floor ignores digitally silent frames")
    func noiseFloorSkipsPadding() {
        var spec = LaneSpec("mic")
        spec.snrdB = 25
        let take = SyncTestSignals.makeTake([spec], seed: 5)
        let padded = [Float](repeating: 0, count: 10_000) + take.lanes[0].samples

        let plain = OnsetDetector.analyze(
            samples: take.lanes[0].samples, sampleRate: 48_000, options: options
        )
        let shifted = OnsetDetector.analyze(samples: padded, sampleRate: 48_000, options: options)
        #expect(shifted.noiseFloor > 0)
        #expect(abs(shifted.noiseFloor / plain.noiseFloor - 1) < 0.1)
        #expect(abs((shifted.onsetSample ?? 0) - (plain.onsetSample ?? 0) - 10_000) <= 12)
    }

    @Test("GCC-PHAT recovers a known integer lag")
    func gccPhatFindsKnownLag() {
        var rng = SeededGenerator(seed: 20_250_903)
        let length = 960
        let lag = 37
        var reference = [Double](repeating: 0, count: length)
        for index in 0..<length { reference[index] = rng.gaussian() }
        var target = [Double](repeating: 0, count: length)
        for index in 0..<length {
            let source = index - lag
            target[index] = source >= 0 ? reference[source] : 0
        }

        let correlator = try! #require(GCCPHAT(minimumSize: 2 * length + 2))
        let correlation = correlator.crossCorrelation(
            target: target, reference: reference, sampleRate: 48_000, options: options
        )

        var best = 0
        var bestValue = -Double.infinity
        for index in 0..<correlator.fineCount where abs(correlation[index]) > bestValue {
            bestValue = abs(correlation[index])
            best = index
        }
        #expect(best == correlator.index(forLag: lag))
        #expect(correlation[best] > 0)
    }

    @Test("GCC-PHAT keeps only the requested band")
    func gccPhatIsBandLimited() {
        // A Hann-windowed 12 kHz tone: nothing the 500 Hz ... 8 kHz band should
        // see. Whitening is switched off so the comparison is about the mask
        // and not about how PHAT lifts near-empty bins.
        let length = 960
        var tone = [Double](repeating: 0, count: length)
        for index in 0..<length {
            let phase = 2 * Double.pi * Double(index) / Double(length - 1)
            let window = 0.5 * (1 - cos(phase))
            tone[index] = window * sin(2 * .pi * 12_000 * Double(index) / 48_000)
        }
        let correlator = try! #require(GCCPHAT(minimumSize: 2 * length + 2))

        var inBand = options
        inBand.phatBeta = 0
        var wideBand = inBand
        wideBand.bandHz = 500...20_000

        func energy(_ options: SyncOptions) -> Double {
            correlator.crossCorrelation(
                target: tone, reference: tone, sampleRate: 48_000, options: options
            ).reduce(0) { $0 + abs($1) }
        }
        let masked = energy(inBand)
        let passed = energy(wideBand)
        #expect(masked < passed * 1e-6, "masked \(masked) passed \(passed)")
    }

    @Test("the analysis window is tapered from the coarse onset")
    func windowIsTaperedFromTheOnset() {
        var spec = LaneSpec("mic")
        spec.snrdB = 30
        let take = SyncTestSignals.makeTake([spec], seed: 12_345)
        let aligner = ClapAligner()
        let preparation = aligner.prepare(take.lanes[0], sampleRate: 48_000)
        let window = try! #require(preparation.window)

        #expect(window.count == Int(0.02 * 48_000))
        #expect(preparation.anchor == Int(0.005 * 48_000))
        #expect(preparation.failureReason == nil)

        // Energy in the 5 ms after the onset must dominate the 5 ms after that.
        func energy(_ range: Range<Int>) -> Double {
            range.reduce(0) { $0 + window[$1] * window[$1] }
        }
        let early = energy(preparation.anchor..<(preparation.anchor + 240))
        let late = energy((preparation.anchor + 240)..<(preparation.anchor + 480))
        #expect(early > late * 8, "early \(early) late \(late)")
    }
}
