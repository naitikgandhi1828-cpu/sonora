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
        let clamped = Float(max(0, min(100, mix)))
        switch backend {
        case .simple(let r):
            r.wetDryMix = clamped
        case .advanced(let e):
            setParam(e, kReverb2Param_DryWetMix, clamped)
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
            let shape = room.reverb2Shape
            let minDelay = max(0.0001, Float(preDelay) * 0.35 + shape.0)
            let maxDelay = max(minDelay + 0.001, Float(preDelay) + shape.1)
            // Damping shortens the high-frequency tail relative to the low one.
            let decayLow = Float(max(0.01, decaySeconds))
            let decayHigh = max(0.01, decayLow * Float(1.0 - 0.85 * max(0, min(1, damping))))

            setParam(e, kReverb2Param_MinDelayTime, minDelay)
            setParam(e, kReverb2Param_MaxDelayTime, min(maxDelay, 1.0))
            setParam(e, kReverb2Param_DecayTimeAt0Hz, min(decayLow, 20))
            setParam(e, kReverb2Param_DecayTimeAtNyquist, min(decayHigh, 20))
            setParam(e, kReverb2Param_RandomizeReflections, 100)
            setParam(e, kReverb2Param_Gain, 0)
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
