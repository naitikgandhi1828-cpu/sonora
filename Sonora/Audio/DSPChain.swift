//
//  DSPChain.swift
//  Sonora
//
//  Owns every effect node and keeps them in sync with AppSettings.
//
//  Signal flow:
//
//    playerA ─┐
//             ├─▶ sourceMixer ─▶ EQ ─▶ Tone ─▶ Reverb ─▶ TimePitch ─▶ SonoraDSP ─▶ mainMixer ─▶ out
//    playerB ─┘   (crossfade,        (10-band  (bass/   (wet mix)   (rate/     (pre-amp,
//                  replay gain)      parametric) treble)             pitch)     width, balance,
//                                                                               limiter)
//

import Foundation
import AVFoundation
import Combine

final class DSPChain {

    let eq: AVAudioUnitEQ
    let tone: AVAudioUnitEQ
    let reverb: ReverbUnit
    let timePitch: AVAudioUnitTimePitch
    let dsp: AVAudioUnitEffect?

    private var cancellables = Set<AnyCancellable>()
    private let settings: AppSettings

    /// Effect nodes in signal order, skipping anything that failed to load.
    var orderedNodes: [AVAudioNode] {
        var nodes: [AVAudioNode] = [eq, tone, reverb.node, timePitch]
        if let dsp { nodes.append(dsp) }
        return nodes
    }

    init(settings: AppSettings) {
        self.settings = settings

        eq = AVAudioUnitEQ(numberOfBands: EQPreset.standardFrequencies.count)
        tone = AVAudioUnitEQ(numberOfBands: 2)
        reverb = ReverbUnit(preferAdvanced: settings.reverbUseAdvanced)
        timePitch = AVAudioUnitTimePitch()

        SonoraDSPUnit.registerIfNeeded()
        if AudioComponentFindNext(nil, &DSPChain.sonoraDesc) != nil {
            dsp = AVAudioUnitEffect(audioComponentDescription: SonoraDSPUnit.componentDescription)
        } else {
            print("[DSPChain] Sonora DSP unit unavailable — pre-amp/width/limiter disabled")
            dsp = nil
        }

        configureToneBands()
        applyAll()
        observeSettings()
    }

    private static var sonoraDesc = SonoraDSPUnit.componentDescription

    // MARK: - Setup

    private func configureToneBands() {
        let bass = tone.bands[0]
        bass.filterType = .lowShelf
        bass.frequency = 120
        bass.bandwidth = 0.5
        bass.gain = 0
        bass.bypass = false

        let treble = tone.bands[1]
        treble.filterType = .highShelf
        treble.frequency = 6000
        treble.bandwidth = 0.5
        treble.gain = 0
        treble.bypass = false
    }

    // MARK: - Settings binding

    private func observeSettings() {
        let s = settings

        // Equalizer
        s.$eqEnabled.sink { [weak self] on in self?.applyEQ(enabled: on) }.store(in: &cancellables)
        s.$eqBands.sink { [weak self] bands in self?.applyEQ(bands: bands) }.store(in: &cancellables)
        s.$eqPreampDB.sink { [weak self] v in
            guard let self else { return }
            self.eq.globalGain = Float(max(-24, min(24, v)))
        }.store(in: &cancellables)

        // Tone
        s.$toneEnabled.sink { [weak self] _ in self?.applyTone() }.store(in: &cancellables)
        s.$bassDB.sink { [weak self] _ in self?.applyTone() }.store(in: &cancellables)
        s.$trebleDB.sink { [weak self] _ in self?.applyTone() }.store(in: &cancellables)
        s.$bassFrequency.sink { [weak self] _ in self?.applyTone() }.store(in: &cancellables)
        s.$trebleFrequency.sink { [weak self] _ in self?.applyTone() }.store(in: &cancellables)

        // Reverb
        s.$reverbEnabled.sink { [weak self] _ in self?.applyReverb() }.store(in: &cancellables)
        s.$reverbRoom.sink { [weak self] _ in self?.applyReverb() }.store(in: &cancellables)
        s.$reverbMix.sink { [weak self] _ in self?.applyReverb() }.store(in: &cancellables)
        s.$reverbDecay.sink { [weak self] _ in self?.applyReverb() }.store(in: &cancellables)
        s.$reverbDamping.sink { [weak self] _ in self?.applyReverb() }.store(in: &cancellables)
        s.$reverbPreDelay.sink { [weak self] _ in self?.applyReverb() }.store(in: &cancellables)

        // Tempo / pitch
        s.$playbackRate.sink { [weak self] _ in self?.applyTempo() }.store(in: &cancellables)
        s.$pitchCents.sink { [weak self] _ in self?.applyTempo() }.store(in: &cancellables)
        s.$tempoPitchLinked.sink { [weak self] _ in self?.applyTempo() }.store(in: &cancellables)

        // Master DSP
        s.$masterPreampDB.sink { [weak self] _ in self?.applyMasterDSP() }.store(in: &cancellables)
        s.$stereoWidth.sink { [weak self] _ in self?.applyMasterDSP() }.store(in: &cancellables)
        s.$balance.sink { [weak self] _ in self?.applyMasterDSP() }.store(in: &cancellables)
        s.$monoDownmix.sink { [weak self] _ in self?.applyMasterDSP() }.store(in: &cancellables)
        s.$limiterEnabled.sink { [weak self] _ in self?.applyMasterDSP() }.store(in: &cancellables)
        s.$limiterThresholdDB.sink { [weak self] _ in self?.applyMasterDSP() }.store(in: &cancellables)
        s.$limiterReleaseMS.sink { [weak self] _ in self?.applyMasterDSP() }.store(in: &cancellables)
    }

    func applyAll() {
        applyEQ(enabled: settings.eqEnabled, bands: settings.eqBands)
        eq.globalGain = Float(settings.eqPreampDB)
        applyTone()
        applyReverb()
        applyTempo()
        applyMasterDSP()
    }

    // MARK: - Apply

    private func applyEQ(enabled: Bool? = nil, bands: [EQBand]? = nil) {
        let on = enabled ?? settings.eqEnabled
        let model = bands ?? settings.eqBands
        eq.bypass = !on
        for (i, band) in model.enumerated() where i < eq.bands.count {
            let node = eq.bands[i]
            node.filterType = band.type.avFilterType
            node.frequency = max(20, min(Float(20_000), band.frequency))
            node.bandwidth = max(0.05, min(5.0, band.bandwidth))
            node.gain = max(-24, min(24, band.gain))
            node.bypass = band.bypass || !on
        }
    }

    private func applyTone() {
        let on = settings.toneEnabled
        tone.bypass = !on
        tone.bands[0].frequency = Float(max(20, min(500, settings.bassFrequency)))
        tone.bands[0].gain = Float(max(-18, min(18, settings.bassDB)))
        tone.bands[0].bypass = !on
        tone.bands[1].frequency = Float(max(1000, min(16_000, settings.trebleFrequency)))
        tone.bands[1].gain = Float(max(-18, min(18, settings.trebleDB)))
        tone.bands[1].bypass = !on
    }

    private func applyReverb() {
        reverb.setBypassed(!settings.reverbEnabled)
        guard settings.reverbEnabled else { return }
        reverb.apply(room: settings.reverbRoom,
                     decaySeconds: settings.reverbDecay,
                     damping: settings.reverbDamping,
                     preDelay: settings.reverbPreDelay)
        reverb.setMix(settings.reverbMix)
    }

    private func applyTempo() {
        let rate = Float(max(0.25, min(4.0, settings.playbackRate)))
        timePitch.rate = rate
        if settings.tempoPitchLinked {
            // Varispeed behaviour: pitch follows tempo like a turntable.
            timePitch.pitch = 1200 * log2(rate)
        } else {
            timePitch.pitch = Float(max(-2400, min(2400, settings.pitchCents)))
        }
        let neutral = abs(rate - 1) < 0.001 && abs(timePitch.pitch) < 0.5
        timePitch.bypass = neutral
    }

    private func applyMasterDSP() {
        guard let dsp else { return }
        let tree = dsp.auAudioUnit.parameterTree
        func set(_ addr: SonoraDSPParam, _ value: Float) {
            tree?.parameter(withAddress: addr.rawValue)?.value = value
        }
        set(.preampDB, Float(max(-24, min(12, settings.masterPreampDB))))
        set(.stereoWidth, Float(max(0, min(2, settings.stereoWidth))))
        set(.balance, Float(max(-1, min(1, settings.balance))))
        set(.monoDownmix, settings.monoDownmix ? 1 : 0)
        set(.limiterOn, settings.limiterEnabled ? 1 : 0)
        set(.limiterCeilDB, Float(max(-12, min(0, settings.limiterThresholdDB))))
        set(.limiterRelMS, Float(max(10, min(1000, settings.limiterReleaseMS))))
    }

    /// True when any effect is doing something audible.
    var isActive: Bool {
        settings.eqEnabled || settings.toneEnabled || settings.reverbEnabled
            || abs(settings.playbackRate - 1) > 0.001
            || abs(settings.pitchCents) > 0.5
            || abs(settings.stereoWidth - 1) > 0.01
            || abs(settings.balance) > 0.01
            || settings.monoDownmix
            || abs(settings.masterPreampDB) > 0.01
    }
}
