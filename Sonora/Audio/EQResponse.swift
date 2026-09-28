//
//  EQResponse.swift
//  Sonora
//
//  Exact magnitude response of the equalizer chain, computed from the same
//  biquad designs AVAudioUnitEQ uses (Robert Bristow-Johnson's Audio EQ
//  Cookbook). Used both to draw the response curve and to work out how much
//  headroom the automatic pre-amp needs so boosted bands cannot clip.
//
//  Band parameters are clamped exactly as DSPChain.applyEQ() clamps them
//  before handing them to the audio unit, so what is drawn is what is heard.
//

import Foundation

enum EQResponse {

    /// Normalised biquad coefficients (a0 == 1).
    struct Biquad {
        var b0: Double
        var b1: Double
        var b2: Double
        var a1: Double
        var a2: Double

        /// |H(e^jw)|^2 at angular frequency `w` (radians per sample).
        func magnitudeSquared(atOmega w: Double) -> Double {
            let c1 = cos(w), s1 = sin(w)
            let c2 = cos(2 * w), s2 = sin(2 * w)
            let nr = b0 + b1 * c1 + b2 * c2
            let ni = -(b1 * s1 + b2 * s2)
            let dr = 1 + a1 * c1 + a2 * c2
            let di = -(a1 * s1 + a2 * s2)
            let den = dr * dr + di * di
            guard den > 1e-30 else { return 1 }
            return (nr * nr + ni * ni) / den
        }
    }

    /// Floor for the response so notches don't produce -infinity.
    private static let floorDB = -120.0

    // MARK: - Public API

    /// Total magnitude response of every non-bypassed band at `hz`, in dB.
    /// Does not include the pre-amp / global gain.
    static func magnitudeDB(at hz: Double, bands: [EQBand], sampleRate: Double = 48_000) -> Double {
        let fs = sampleRate > 0 ? sampleRate : 48_000
        let filters = bands.compactMap { biquad(for: $0, sampleRate: fs) }
        return magnitudeDB(at: hz, filters: filters, sampleRate: fs)
    }

    /// Highest positive gain of the combined response between 20 Hz and 20 kHz,
    /// in dB. Returns 0 when nothing is boosted.
    static func maxBoostDB(bands: [EQBand]) -> Double {
        maxBoostDB(bands: bands, sampleRate: 48_000)
    }

    /// Same as `maxBoostDB(bands:)` at an explicit sample rate.
    static func maxBoostDB(bands: [EQBand], sampleRate: Double) -> Double {
        let fs = sampleRate > 0 ? sampleRate : 48_000
        let filters = bands.compactMap { biquad(for: $0, sampleRate: fs) }
        guard !filters.isEmpty else { return 0 }

        let minHz = 20.0, maxHz = 20_000.0
        let steps = 200
        var peak = 0.0
        let logMin = log10(minHz), logMax = log10(maxHz)
        for i in 0..<steps {
            let t = Double(i) / Double(steps - 1)
            let hz = pow(10, logMin + t * (logMax - logMin))
            peak = max(peak, magnitudeDB(at: hz, filters: filters, sampleRate: fs))
        }
        // Peaking filters reach their maximum exactly at their centre, which
        // the log grid can straddle; sample those points too.
        for band in bands where !band.bypass {
            let hz = Double(max(20, min(Float(20_000), band.frequency)))
            peak = max(peak, magnitudeDB(at: hz, filters: filters, sampleRate: fs))
        }
        return max(0, peak)
    }

    // MARK: - Internals

    private static func magnitudeDB(at hz: Double, filters: [Biquad], sampleRate fs: Double) -> Double {
        guard !filters.isEmpty else { return 0 }
        let nyquist = fs / 2
        let f = max(1, min(hz, nyquist * 0.999))
        let w = 2 * Double.pi * f / fs
        var total = 0.0
        for filter in filters {
            let m2 = filter.magnitudeSquared(atOmega: w)
            total += m2 > 1e-12 ? 10 * log10(m2) : floorDB
        }
        return max(floorDB, total)
    }

    /// Cookbook biquad for one band, or nil if the band is bypassed.
    static func biquad(for band: EQBand, sampleRate fs: Double) -> Biquad? {
        guard !band.bypass else { return nil }

        // Same clamps as DSPChain.applyEQ(); also keep f0 safely below Nyquist.
        let f0 = min(Double(max(20, min(Float(20_000), band.frequency))), fs * 0.49)
        let bw = Double(max(0.05, min(5.0, band.bandwidth)))
        let gainDB = Double(max(-24, min(24, band.gain)))

        let w0 = 2 * Double.pi * f0 / fs
        let cosW = cos(w0)
        let sinW = sin(w0)
        // Bandwidth in octaves (with the cookbook's bilinear-warp correction).
        let alphaBW = sinW * sinh(log(2.0) / 2 * bw * w0 / sinW)
        let A = pow(10, gainDB / 40)

        var b0 = 1.0, b1 = 0.0, b2 = 0.0
        var a0 = 1.0, a1 = 0.0, a2 = 0.0

        switch band.type {
        case .parametric:
            b0 = 1 + alphaBW * A
            b1 = -2 * cosW
            b2 = 1 - alphaBW * A
            a0 = 1 + alphaBW / A
            a1 = -2 * cosW
            a2 = 1 - alphaBW / A

        case .lowShelf, .resonantLowShelf:
            // Plain shelf: shelf slope S = 1 (bandwidth ignored, as in
            // AVAudioUnitEQ). Resonant shelf: bandwidth sets the Q.
            let alpha = band.type == .lowShelf ? sinW / 2 * sqrt(2.0) : alphaBW
            let twoSqrtAAlpha = 2 * sqrt(A) * alpha
            b0 = A * ((A + 1) - (A - 1) * cosW + twoSqrtAAlpha)
            b1 = 2 * A * ((A - 1) - (A + 1) * cosW)
            b2 = A * ((A + 1) - (A - 1) * cosW - twoSqrtAAlpha)
            a0 = (A + 1) + (A - 1) * cosW + twoSqrtAAlpha
            a1 = -2 * ((A - 1) + (A + 1) * cosW)
            a2 = (A + 1) + (A - 1) * cosW - twoSqrtAAlpha

        case .highShelf, .resonantHighShelf:
            let alpha = band.type == .highShelf ? sinW / 2 * sqrt(2.0) : alphaBW
            let twoSqrtAAlpha = 2 * sqrt(A) * alpha
            b0 = A * ((A + 1) + (A - 1) * cosW + twoSqrtAAlpha)
            b1 = -2 * A * ((A - 1) + (A + 1) * cosW)
            b2 = A * ((A + 1) + (A - 1) * cosW - twoSqrtAAlpha)
            a0 = (A + 1) - (A - 1) * cosW + twoSqrtAAlpha
            a1 = 2 * ((A - 1) - (A + 1) * cosW)
            a2 = (A + 1) - (A - 1) * cosW - twoSqrtAAlpha

        case .lowPass, .resonantLowPass:
            // Plain low-pass: 2nd-order Butterworth (Q = 1/sqrt 2).
            let alpha = band.type == .lowPass ? sinW / sqrt(2.0) : alphaBW
            b0 = (1 - cosW) / 2
            b1 = 1 - cosW
            b2 = (1 - cosW) / 2
            a0 = 1 + alpha
            a1 = -2 * cosW
            a2 = 1 - alpha

        case .highPass, .resonantHighPass:
            let alpha = band.type == .highPass ? sinW / sqrt(2.0) : alphaBW
            b0 = (1 + cosW) / 2
            b1 = -(1 + cosW)
            b2 = (1 + cosW) / 2
            a0 = 1 + alpha
            a1 = -2 * cosW
            a2 = 1 - alpha

        case .bandPass:
            // Constant 0 dB peak gain.
            b0 = alphaBW
            b1 = 0
            b2 = -alphaBW
            a0 = 1 + alphaBW
            a1 = -2 * cosW
            a2 = 1 - alphaBW

        case .bandStop:
            b0 = 1
            b1 = -2 * cosW
            b2 = 1
            a0 = 1 + alphaBW
            a1 = -2 * cosW
            a2 = 1 - alphaBW
        }

        guard a0.isFinite, a0 != 0 else { return nil }
        return Biquad(b0: b0 / a0, b1: b1 / a0, b2: b2 / a0,
                      a1: a1 / a0, a2: a2 / a0)
    }
}
