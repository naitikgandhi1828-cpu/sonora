//
//  ReverbUnit.swift
//  Sonora
//
//  Wraps two reverb implementations behind one interface:
//
//    * AUReverb2 (kAudioUnitSubType_Reverb2) — exposes decay, damping and
//      pre-delay, so the UI can offer real reverb controls.
//    * AVAudioUnitReverb — the preset-only fallback, used if Reverb2 is
//      unavailable on the running system.
//

import Foundation
import AVFoundation
import AudioToolbox

final class ReverbUnit {

    enum Backend {
        case advanced(AVAudioUnitEffect)   // AUReverb2
        case simple(AVAudioUnitReverb)
    }

    let backend: Backend

    /// Typed as `AVAudioUnitEffect` so `bypass` is available — both backends
    /// are effects (`AVAudioUnitReverb` subclasses `AVAudioUnitEffect`).
    var node: AVAudioUnitEffect {
        switch backend {
        case .advanced(let e): return e
        case .simple(let r): return r
        }
    }

    var isAdvanced: Bool {
        if case .advanced = backend { return true }
        return false
    }

    init(preferAdvanced: Bool) {
        if preferAdvanced, ReverbUnit.componentExists(subType: kAudioUnitSubType_Reverb2) {
            var desc = AudioComponentDescription()
            desc.componentType = kAudioUnitType_Effect
            desc.componentSubType = kAudioUnitSubType_Reverb2
            desc.componentManufacturer = kAudioUnitManufacturer_Apple
            backend = .advanced(AVAudioUnitEffect(audioComponentDescription: desc))
        } else {
            let r = AVAudioUnitReverb()
            r.loadFactoryPreset(.mediumHall)
            backend = .simple(r)
        }
    }

    static func componentExists(subType: OSType) -> Bool {
        var desc = AudioComponentDescription()
        desc.componentType = kAudioUnitType_Effect
        desc.componentSubType = subType
        desc.componentManufacturer = kAudioUnitManufacturer_Apple
        return AudioComponentFindNext(nil, &desc) != nil
    }

    // MARK: - Controls

    /// `mix` is 0...100 percent wet.
    func setMix(_ mix: Double) {
        let pct = max(0, min(100, mix))
        switch backend {
        case .simple(let r):
            r.wetDryMix = Float(pct)
        case .advanced(let e):
            // Reverb2's DryWetMix is a linear amplitude blend, so the bottom
            // half of the slider is nearly inaudible. A square-root curve is
            // roughly equal-power: 25% on the slider becomes 50% wet, which is
            // what the ear expects from "quarter reverb".
            let norm = Float(pct / 100)
            setParam(e, kReverb2Param_DryWetMix, sqrt(norm) * 100)

            // Reverb2's wet path sits well below the dry signal at matched
            // mix. Without this lift, toggling the effect on barely changes
            // anything, which is exactly the symptom being fixed.
            setParam(e, kReverb2Param_Gain, norm * 6.0)   // 0...+6 dB
        }
    }

    func setBypassed(_ bypassed: Bool) {
        node.bypass = bypassed
    }

    /// Applies a room shape. On the simple backend this loads the matching
    /// factory preset; on the advanced backend it writes the delay/decay
    /// values and then layers the user's decay/damping/pre-delay on top.
    func apply(room: ReverbRoom,
               decaySeconds: Double,
               damping: Double,
               preDelay: Double) {
        switch backend {
        case .simple(let r):
            r.loadFactoryPreset(room.avPreset)
        case .advanced(let e):
            // shape = (minDelay, maxDelay, decayAt0Hz, decayAtNyquist)
            let shape = room.reverb2Shape

            let pre = Float(max(0, min(0.2, preDelay)))
            let minDelay = max(0.0001, shape.0 + pre)
            let maxDelay = max(minDelay + 0.005, shape.1 + pre)

            // The decay slider *scales* the room's own decay rather than
            // replacing it. Previously it overwrote both decay times, so every
            // room collapsed to the same tail and the only surviving difference
            // was a few milliseconds of pre-delay — inaudible. Rooms now keep
            // their character (a plate stays tight, a cathedral stays huge)
            // while the slider still stretches or shortens them.
            let scale = Float(max(0.1, decaySeconds)) / 2.4   // 2.4 s = slider centre
            let d = max(0, min(1, Float(damping)))

            let decayLow = min(20, max(0.05, shape.2 * scale))
            // Damping darkens the tail by shortening it at Nyquist. Clamped
            // below decayLow so the high end never outlasts the low end.
            let decayHigh = min(decayLow, max(0.05, shape.3 * scale * (1.0 - 0.7 * d)))

            setParam(e, kReverb2Param_MinDelayTime, minDelay)
            setParam(e, kReverb2Param_MaxDelayTime, min(maxDelay, 1.0))
            setParam(e, kReverb2Param_DecayTimeAt0Hz, decayLow)
            setParam(e, kReverb2Param_DecayTimeAtNyquist, decayHigh)
            // Range is 1...1000, not 0...100. At 100 the reflection pattern is
            // sparse and metallic; high values give the dense, smooth tail that
            // reads as a real space.
            setParam(e, kReverb2Param_RandomizeReflections, 800)
        }
    }

    private func setParam(_ effect: AVAudioUnitEffect, _ id: AudioUnitParameterID, _ value: Float) {
        let au = effect.audioUnit
        let status = AudioUnitSetParameter(au, id, kAudioUnitScope_Global, 0, value, 0)
        if status != noErr {
            print("[Reverb] parameter \(id) -> \(value) failed (\(status))")
        }
    }
}
