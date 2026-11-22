import Accelerate

/// Visualizer analysis: log-spaced spectrum bins (0...1) and a decimated waveform (-1...1).
///
/// All scratch buffers, the FFT window and the per-bin FFT ranges are allocated once and reused,
/// so a 60 FPS caller does no per-frame heap work beyond the two small result arrays. Only the
/// part a mode needs is computed (the oscilloscope skips the FFT entirely).
final class SpectrumAnalyzer {
    let fftSize: Int
    private let log2n: vDSP_Length
    private let setup: FFTSetup
    private var hann: [Float]
    private var window: [Float]
    private var real: [Float]
    private var imag: [Float]
    private var magnitudes: [Float]
    // FFT index range per output bin, cached for (bin count, sample rate).
    private var ranges: [(lo: Int, hi: Int)] = []
    private var rangesKey: (bins: Int, sr: Double) = (0, 0)

    init(log2n: Int = 10) {
        self.log2n = vDSP_Length(log2n)
        fftSize = 1 << log2n
        setup = vDSP_create_fftsetup(self.log2n, FFTRadix(kFFTRadix2))!
        hann = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&hann, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        window = [Float](repeating: 0, count: fftSize)
        real = [Float](repeating: 0, count: fftSize / 2)
        imag = [Float](repeating: 0, count: fftSize / 2)
        magnitudes = [Float](repeating: 0, count: fftSize / 2)
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    /// Copies up to `fftSize` samples starting at `start` into the analysis window.
    /// Returns the number of valid samples (the rest of the window is zero).
    @discardableResult
    func load(_ samples: UnsafeBufferPointer<Float>, start: Int) -> Int {
        let available = max(0, min(fftSize, samples.count - start))
        window.withUnsafeMutableBufferPointer { w in
            if available > 0 { w.baseAddress!.assign(from: samples.baseAddress! + start, count: available) }
            if available < fftSize { (w.baseAddress! + available).assign(repeating: 0, count: fftSize - available) }
        }
        return available
    }

    /// Waveform from the loaded window: `points` evenly spaced samples.
    func oscilloscope(points: Int, available: Int) -> [Float] {
        guard points > 0, available > 0 else { return [Float](repeating: 0, count: max(0, points)) }
        let step = max(1, available / points)
        return (0..<points).map { window[min(available - 1, $0 * step)] }
    }

    /// Spectrum of the loaded window (consumes it: the Hann window is applied in place).
    func spectrum(bins: Int, sampleRate sr: Double) -> [Float] {
        let n = fftSize
        vDSP_vmul(window, 1, hann, 1, &window, 1, vDSP_Length(n))
        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                window.withUnsafeBytes { raw in
                    vDSP_ctoz(raw.bindMemory(to: DSPComplex.self).baseAddress!, 2, &split, 1, vDSP_Length(n / 2))
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &magnitudes, 1, vDSP_Length(n / 2))
            }
        }
        if rangesKey.bins != bins || rangesKey.sr != sr {
            ranges = SpectrumAnalyzer.binRanges(bins: bins, sampleRate: sr, fftSize: n)
            rangesKey = (bins, sr)
        }
        // Normalise: magnitude² of a full-scale sine with this window ≈ (n/4)².
        let fullScale = Float(n * n / 16)
        var out = [Float](repeating: 0, count: bins)
        magnitudes.withUnsafeBufferPointer { m in
            for i in 0..<bins {
                var peak: Float = 0
                let r = ranges[i]
                vDSP_maxv(m.baseAddress! + r.lo, 1, &peak, vDSP_Length(r.hi - r.lo))
                let db = 10 * log10(max(1e-12, peak / fullScale))
                out[i] = max(0, min(1, (db + 70) / 70))
            }
        }
        return out
    }

    /// Log-spaced 20 Hz–20 kHz bands mapped to FFT bin index ranges [lo, hi).
    static func binRanges(bins: Int, sampleRate sr: Double, fftSize n: Int) -> [(lo: Int, hi: Int)] {
        let minF: Float = 20, maxF: Float = 20000
        let ratio = pow(maxF / minF, 1.0 / Float(bins))
        let binHz = Float(sr) / Float(n)
        return (0..<bins).map { i in
            let fLow = minF * pow(ratio, Float(i))
            let fHigh = minF * pow(ratio, Float(i + 1))
            let kLow = max(1, min(n / 2 - 1, Int(fLow / binHz)))
            let kHigh = max(kLow + 1, min(n / 2, Int(ceil(fHigh / binHz))))
            return (kLow, kHigh)
        }
    }
}
