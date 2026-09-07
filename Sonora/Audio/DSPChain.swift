//
//  DSPChain.swift
//  Sonora
//
//  Owns every effect node and keeps them in sync with AppSettings.
//
//  Signal flow:
//
//    playerA ─┐
//             ├─▶ sourceMixer ─▶ EQ ─▶ Tone ─▶ Freeverb ─▶ Reverb2 ─▶ Spatial
//    playerB ─┘   (crossfade,     (10-band   (bass/   (custom)    (Apple)    (binaural
//                  replay gain)   parametric) treble)                         widener)
//
//                                          ─▶ TimePitch ─▶ SonoraDSP ─▶ out
//                                             (rate/       (pre-amp, width,
//                                              pitch)       balance, limiter)
//
//  The two reverb nodes are mutually exclusive: whichever engine the user has
//  not selected is bypassed, so only one is ever in circuit.
//
//  Spatial sits after the reverbs so the tail gets widened along with the dry
//  signal, and before the master stage so the limiter still has the last word
//  on what leaves the app.
//

import Foundation
import AVFoundation
import Combine

final class DSPChain {

    let eq: AVAudioUnitEQ
    let tone: AVAudioUnitEQ
    let reverb: ReverbUnit
    /// Freeverb runs as a second reverb node rather than replacing the first.
    /// Both stay wired into the graph and the unused one is bypassed, so
    /// switching engines costs nothing and never needs a graph rebuild.
    let freeverb: AVAudioUnitEffect?
    /// Binaural spatialiser. Nil if the component failed to register, in which
    /// case the feature simply does not appear in the UI.
    let spatial: AVAudioUnitEffect?
    let timePitch: AVAudioUnitTimePitch
    let dsp: AVAudioUnitEffect?

    private var cancellables = Set<AnyCancellable>()
    private let settings: AppSettings

    /// Effect nodes in signal order, skipping anything that failed to load.
    var orderedNodes: [AVAudioNode] {
        var nodes: [AVAudioNode] = [eq, tone]
        if let freeverb { nodes.append(freeverb) }
        nodes.append(reverb.node)
        if let spatial { nodes.append(spatial) }
        nodes.append(timePitch)
        if let dsp { nodes.append(dsp) }
        return nodes
    }

    init(settings: AppSettings) {
        self.settings = settings

        eq = AVAudioUnitEQ(numberOfBands: EQPreset.standardFrequencies.count)
        tone = AVAudioUnitEQ(numberOfBands: 2)
        reverb = ReverbUnit(preferAdvanced: settings.reverbUseAdvanced)
        timePitch = AVAudioUnitTimePitch()

        FreeverbUnit.registerIfNeeded()
        if AudioComponentFindNext(nil, &DSPChain.freeverbDesc) != nil {
            freeverb = AVAudioUnitEffect(audioComponentDescription: FreeverbUnit.componentDescription)
        } else {
            print("[DSPChain] Freeverb unavailable — falling back to AUReverb2")
            freeverb = nil
        }

        SpatialUnit.registerIfNeeded()
        if AudioComponentFindNext(nil, &DSPChain.spatialDesc) != nil {
            spatial = AVAudioUnitEffect(audioComponentDescription: SpatialUnit.componentDescription)
        } else {
            print("[DSPChain] Spatial unit unavailable")
            spatial = nil
        }

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
    private static var freeverbDesc = FreeverbUnit.componentDescription
    private static var spatialDesc = SpatialUnit.componentDescription

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

    /// Subscribes to one setting and re-applies a section when it changes.
    ///
    /// The hop through the main queue is the whole point. `@Published` emits
    /// from `willSet`, so a handler that reads the value back off `AppSettings`
    /// sees the value it had *before* the change. Every handler below does
    /// exactly that - `applyReverb()` reads `settings.reverbEnabled` - so each
    /// toggle applied the state it had before you tapped it: switching the
    /// reverb off left it running, and switching it on did nothing until some
    /// later change came through. Delivering on the next main-queue turn lets
    /// the property finish assigning first.
    private func onChange<P: Publisher>(_ publisher: P,
                                        _ apply: @escaping () -> Void) where P.Failure == Never {
        publisher
            .receive(on: DispatchQueue.main)
            .sink { _ in apply() }
            .store(in: &cancellables)
    }

    private func observeSettings() {
        let s = settings

        // Equalizer
        onChange(s.$eqEnabled) { [weak self] in self?.applyEQ() }
        onChange(s.$eqBands) { [weak self] in self?.applyEQ() }
        onChange(s.$eqPreampDB) { [weak self] in self?.applyEQ() }

        // Tone
        onChange(s.$toneEnabled) { [weak self] in self?.applyTone() }
        onChange(s.$bassDB) { [weak self] in self?.applyTone() }
        onChange(s.$trebleDB) { [weak self] in self?.applyTone() }
        onChange(s.$bassFrequency) { [weak self] in self?.applyTone() }
        onChange(s.$trebleFrequency) { [weak self] in self?.applyTone() }

        // Reverb
        onChange(s.$reverbEnabled) { [weak self] in self?.applyReverb() }
        onChange(s.$reverbMix) { [weak self] in self?.applyReverb() }
        onChange(s.$reverbDamp) { [weak self] in self?.applyReverb() }
        onChange(s.$reverbFilter) { [weak self] in self?.applyReverb() }
        onChange(s.$reverbFade) { [weak self] in self?.applyReverb() }
        onChange(s.$reverbPreDelay) { [weak self] in self?.applyReverb() }
        onChange(s.$reverbPreDelayMix) { [weak self] in self?.applyReverb() }
        onChange(s.$reverbSize) { [weak self] in self?.applyReverb() }
        onChange(s.$reverbUseFreeverb) { [weak self] in self?.applyReverb() }

        // Spatial
        onChange(s.$spatialEnabled) { [weak self] in self?.applySpatial() }
        onChange(s.$spatialAmount) { [weak self] in self?.applySpatial() }
        onChange(s.$spatialWidth) { [weak self] in self?.applySpatial() }
        onChange(s.$spatialCrossfeed) { [weak self] in self?.applySpatial() }
        onChange(s.$spatialDepth) { [weak self] in self?.applySpatial() }
        onChange(s.$spatialElevation) { [weak self] in self?.applySpatial() }

        // Tempo / pitch
        onChange(s.$playbackRate) { [weak self] in self?.applyTempo() }
        onChange(s.$pitchCents) { [weak self] in self?.applyTempo() }
        onChange(s.$tempoPitchLinked) { [weak self] in self?.applyTempo() }

        // Master DSP
        onChange(s.$masterPreampDB) { [weak self] in self?.applyMasterDSP() }
        onChange(s.$stereoWidth) { [weak self] in self?.applyMasterDSP() }
        onChange(s.$balance) { [weak self] in self?.applyMasterDSP() }
        onChange(s.$monoDownmix) { [weak self] in self?.applyMasterDSP() }
        onChange(s.$limiterEnabled) { [weak self] in self?.applyMasterDSP() }
        onChange(s.$limiterThresholdDB) { [weak self] in self?.applyMasterDSP() }
        onChange(s.$limiterReleaseMS) { [weak self] in self?.applyMasterDSP() }
    }

    func applyAll() {
        applyEQ()
        applyTone()
        applyReverb()
        applySpatial()
        applyTempo()
        applyMasterDSP()
    }

    // MARK: - Apply

    /// Off has to mean off through every switch the unit exposes.
    ///
    /// `AVAudioUnitEQ` offers three independent ways to silence itself - the
    /// unit's `bypass`, each band's `bypass`, and the gains - and how faithfully
    /// `bypass` is honoured is not something to lean on. `globalGain` in
    /// particular is a unit-level property rather than a band, and it used to be
    /// written from its own subscription with no regard for whether the EQ was
    /// enabled, so the pre-amp stayed in circuit after the user switched the
    /// equalizer off. Flattening the gains as well as setting both bypasses
    /// costs nothing and leaves the EQ no route to keep colouring the sound.
    private func applyEQ() {
        let on = settings.eqEnabled
        eq.bypass = !on
        eq.globalGain = on ? Float(max(-24, min(24, settings.eqPreampDB))) : 0
        for (i, band) in settings.eqBands.enumerated() where i < eq.bands.count {
            let node = eq.bands[i]
            node.filterType = band.type.avFilterType
            node.frequency = max(20, min(Float(20_000), band.frequency))
            node.bandwidth = max(0.05, min(5.0, band.bandwidth))
            node.gain = on ? max(-24, min(24, band.gain)) : 0
            node.bypass = band.bypass || !on
        }
    }

    private func applyTone() {
        let on = settings.toneEnabled
        tone.bypass = !on
        tone.globalGain = 0
        tone.bands[0].frequency = Float(max(20, min(500, settings.bassFrequency)))
        tone.bands[0].gain = on ? Float(max(-18, min(18, settings.bassDB))) : 0
        tone.bands[0].bypass = !on
        tone.bands[1].frequency = Float(max(1000, min(16_000, settings.trebleFrequency)))
        tone.bands[1].gain = on ? Float(max(-18, min(18, settings.trebleDB))) : 0
        tone.bands[1].bypass = !on
    }

    private func applyReverb() {
        let on = settings.reverbEnabled
        let useFreeverb = settings.reverbUseFreeverb && freeverb != nil

        // Exactly one engine is ever in circuit; the other is bypassed, which
        // costs nothing and avoids stacking two reverbs in series.
        reverb.setBypassed(!on || useFreeverb)
        freeverb?.bypass = !on || !useFreeverb

        guard on else {
            // Belt and braces, for the same reason as the EQ: an effect that is
            // bypassed but still holds a wet mix will be heard the moment the
            // bypass is not honoured, and the tail already sitting in its delay
            // lines has to be wound down either way. Driving both engines fully
            // dry is what makes "off" audibly off.
            reverb.setMix(0)
            setFreeverb(.mix, 0)
            return
        }

        if useFreeverb {
            applyFreeverb()
        } else {
            // AUReverb2 has no equivalent of Filter or Pre-Delay Mix, and its
            // dimensions only come from its own preset list, so Size is
            // quantised onto the nearest room. Those two controls simply do
            // nothing on this engine, which the UI says out loud.
            reverb.apply(room: ReverbRoom.forSize(settings.reverbSize),
                         decaySeconds: 0.4 + settings.reverbFade * 7.5,
                         damping: settings.reverbDamp,
                         preDelay: settings.reverbPreDelay * 0.2)
            reverb.setMix(settings.reverbMix * 100)
        }
    }

    private func setFreeverb(_ addr: FreeverbParam, _ value: Float) {
        freeverb?.auAudioUnit.parameterTree?.parameter(withAddress: addr.rawValue)?.value = value
    }

    private func applyFreeverb() {
        guard freeverb != nil else { return }
        let set = setFreeverb
        func unit(_ v: Double) -> Float { Float(max(0, min(1, v))) }

        set(.mix, unit(settings.reverbMix))
        set(.size, unit(settings.reverbSize))
        set(.fade, unit(settings.reverbFade))
        set(.damp, unit(settings.reverbDamp))
        set(.filter, unit(settings.reverbFilter))
        set(.preDelay, unit(settings.reverbPreDelay))
        set(.preDelayMix, unit(settings.reverbPreDelayMix))
        set(.width, 1)
    }

    private func applySpatial() {
        guard let spatial else { return }
        let on = settings.spatialEnabled
        spatial.bypass = !on

        func set(_ addr: SpatialParam, _ value: Float) {
            spatial.auAudioUnit.parameterTree?.parameter(withAddress: addr.rawValue)?.value = value
        }

        // Same reasoning as the EQ and the reverbs: driving the blend to fully
        // dry means "off" is off whether or not `bypass` is honoured, and it
        // flushes the reflections already sitting in the delay lines.
        guard on else {
            set(.amount, 0)
            return
        }

        set(.amount, Float(max(0, min(100, settings.spatialAmount))))
        set(.width, Float(max(0, min(2, settings.spatialWidth))))
        set(.crossfeed, Float(max(0, min(100, settings.spatialCrossfeed))))
        set(.depth, Float(max(0, min(100, settings.spatialDepth))))
        set(.elevation, Float(max(0, min(100, settings.spatialElevation))))
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
            || settings.spatialEnabled
            || abs(settings.playbackRate - 1) > 0.001
            || abs(settings.pitchCents) > 0.5
            || abs(settings.stereoWidth - 1) > 0.01
            || abs(settings.balance) > 0.01
            || settings.monoDownmix
            || abs(settings.masterPreampDB) > 0.01
    }
}
