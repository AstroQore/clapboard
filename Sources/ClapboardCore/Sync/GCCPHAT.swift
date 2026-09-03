import Accelerate
import Foundation

/// A band-limited generalised cross correlation with phase transform.
///
/// `crossCorrelation` returns `r[m] = sum_n target[n] * reference[n - m]`,
/// whitened by `|X * conj(Y)|^-beta` and restricted to `options.bandHz`, on a
/// grid `oversample` times finer than the sample rate. Zero padding the cross
/// spectrum before the inverse transform is exact sinc interpolation, so the
/// fine grid carries real information rather than a smoothed guess, which is
/// what makes sub-sample peak picking reliable.
///
/// Not thread safe: it owns scratch buffers and two FFT setups. Create one per
/// analysis pass.
final class GCCPHAT {
    /// Linear (not circular) correlation needs the transform to be at least as
    /// long as both inputs together.
    let size: Int
    let oversample: Int

    private let forwardLog2n: vDSP_Length
    private let inverseLog2n: vDSP_Length
    private let forwardSetup: FFTSetupD
    private let inverseSetup: FFTSetupD

    private var targetReal: [Double]
    private var targetImag: [Double]
    private var referenceReal: [Double]
    private var referenceImag: [Double]
    private var crossReal: [Double]
    private var crossImag: [Double]

    /// - Parameters:
    ///   - minimumSize: rounded up to a power of two; pass at least the sum of
    ///     the two window lengths so no lag wraps around.
    ///   - oversample: power-of-two refinement of the lag grid.
    init?(minimumSize: Int, oversample: Int = 4) {
        var size = 16
        while size < minimumSize { size <<= 1 }
        guard oversample >= 1, oversample.nonzeroBitCount == 1 else { return nil }

        let fine = size * oversample
        let forwardLog2n = vDSP_Length(size.trailingZeroBitCount)
        let inverseLog2n = vDSP_Length(fine.trailingZeroBitCount)
        guard let forwardSetup = vDSP_create_fftsetupD(forwardLog2n, FFTRadix(kFFTRadix2)),
              let inverseSetup = vDSP_create_fftsetupD(inverseLog2n, FFTRadix(kFFTRadix2))
        else { return nil }

        self.size = size
        self.oversample = oversample
        self.forwardLog2n = forwardLog2n
        self.inverseLog2n = inverseLog2n
        self.forwardSetup = forwardSetup
        self.inverseSetup = inverseSetup
        self.targetReal = [Double](repeating: 0, count: size)
        self.targetImag = [Double](repeating: 0, count: size)
        self.referenceReal = [Double](repeating: 0, count: size)
        self.referenceImag = [Double](repeating: 0, count: size)
        self.crossReal = [Double](repeating: 0, count: fine)
        self.crossImag = [Double](repeating: 0, count: fine)
    }

    deinit {
        vDSP_destroy_fftsetupD(forwardSetup)
        vDSP_destroy_fftsetupD(inverseSetup)
    }

    /// Number of fine-grid points; index `i` holds lag `i / oversample` for the
    /// first half and `(i - count) / oversample` for the second.
    var fineCount: Int { size * oversample }

    /// Fine-grid index of a lag expressed in whole samples.
    func index(forLag lag: Int) -> Int {
        let raw = lag * oversample
        return raw >= 0 ? raw : raw + fineCount
    }

    func crossCorrelation(
        target: [Double],
        reference: [Double],
        sampleRate: Double,
        options: SyncOptions
    ) -> [Double] {
        precondition(target.count <= size && reference.count <= size)

        for index in 0..<size {
            targetReal[index] = index < target.count ? target[index] : 0
            targetImag[index] = 0
            referenceReal[index] = index < reference.count ? reference[index] : 0
            referenceImag[index] = 0
        }
        for index in 0..<fineCount {
            crossReal[index] = 0
            crossImag[index] = 0
        }

        let nyquist = size / 2
        let binsPerHertz = Double(size) / sampleRate
        let lowBin = max(1, Int((options.bandHz.lowerBound * binsPerHertz).rounded(.up)))
        let highBin = min(
            nyquist - 1, Int((options.bandHz.upperBound * binsPerHertz).rounded(.down))
        )
        guard lowBin <= highBin else { return crossReal }
        let beta = min(max(options.phatBeta, 0), 1)
        let offset = fineCount - size

        targetReal.withUnsafeMutableBufferPointer { targetRealBuffer in
            targetImag.withUnsafeMutableBufferPointer { targetImagBuffer in
                referenceReal.withUnsafeMutableBufferPointer { referenceRealBuffer in
                    referenceImag.withUnsafeMutableBufferPointer { referenceImagBuffer in
                        var targetSpectrum = DSPDoubleSplitComplex(
                            realp: targetRealBuffer.baseAddress!,
                            imagp: targetImagBuffer.baseAddress!
                        )
                        var referenceSpectrum = DSPDoubleSplitComplex(
                            realp: referenceRealBuffer.baseAddress!,
                            imagp: referenceImagBuffer.baseAddress!
                        )
                        let forward = FFTDirection(FFT_FORWARD)
                        vDSP_fft_zipD(forwardSetup, &targetSpectrum, 1, forwardLog2n, forward)
                        vDSP_fft_zipD(forwardSetup, &referenceSpectrum, 1, forwardLog2n, forward)

                        // Keep the band, and its mirror so the result stays real.
                        for bin in lowBin...highBin {
                            for spectrumBin in [bin, size - bin] {
                                let xr = targetRealBuffer[spectrumBin]
                                let xi = targetImagBuffer[spectrumBin]
                                let yr = referenceRealBuffer[spectrumBin]
                                let yi = referenceImagBuffer[spectrumBin]
                                // target * conj(reference)
                                let real = xr * yr + xi * yi
                                let imaginary = xi * yr - xr * yi
                                let magnitude = (real * real + imaginary * imaginary).squareRoot()
                                guard magnitude > 1e-24 else { continue }
                                let weight = pow(magnitude, -beta)
                                let destination = spectrumBin <= nyquist
                                    ? spectrumBin
                                    : spectrumBin + offset
                                crossReal[destination] = real * weight
                                crossImag[destination] = imaginary * weight
                            }
                        }
                    }
                }
            }
        }

        crossReal.withUnsafeMutableBufferPointer { realBuffer in
            crossImag.withUnsafeMutableBufferPointer { imagBuffer in
                var spectrum = DSPDoubleSplitComplex(
                    realp: realBuffer.baseAddress!,
                    imagp: imagBuffer.baseAddress!
                )
                vDSP_fft_zipD(inverseSetup, &spectrum, 1, inverseLog2n, FFTDirection(FFT_INVERSE))
            }
        }
        return crossReal
    }
}
