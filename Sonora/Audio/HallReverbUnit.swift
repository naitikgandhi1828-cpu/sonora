//
//  HallReverbUnit.swift
//  Sonora
//
//  "Studio" reverb: an eight-line feedback delay network (FDN).
//
//  Signal flow, per sample:
//
//    in ─▶ pre-delay ─▶ low-cut / high-cut ─┬─▶ early reflections (multi-tap) ──────────┐
//                                           └─▶ 4 allpass diffusers ─▶ ┌──────────────┐  │
//                                                                      │  8 modulated │  │
//                                                          ┌──────────▶│  delay lines │  │
//                                                          │           └──────┬───────┘  │
//                                                          │     per-line two-band decay │
//                                                          │                  │          │
//                                                          └── Hadamard mix ◀─┘          │
//                                                                             │          │
//                                              stereo taps ─▶ width ─▶ + ◀────┘◀─────────┘
//                                                                      │
//                                                          equal-power wet/dry ─▶ out
//
//  Why an FDN: a lossless orthogonal feedback matrix spreads every echo into
//  every line, so echo density builds quickly and evenly, and the decay time
//  can be set per frequency band in seconds (RT60) instead of via an abstract
//  feedback knob. Slow modulation of the line lengths breaks up the metallic
//  ringing that fixed comb filters produce on sustained notes.
//
//  The design follows the published FDN literature (Stautner & Puckette 1982;
//  Jot & Chaigne 1991). All tunings — line lengths, tap patterns, preset
//  values — are Sonora's own.
//
//  Realtime contract (same as the other Sonora units): all memory is
//  allocated up front at worst-case size, the render block only touches raw
//  memory, and parameter changes rebuild derived values off the audio thread.
//  Delay lines are circular buffers read at an offset behind the write head,
//  so changing a length mid-buffer can never index out of bounds.
//

import Foundation
import AVFoundation
import AudioToolbox

// MARK: - Parameters

enum HallParam: AUParameterAddress {
    case mix          = 0   // 0...1 wet/dry (equal power)
    case decay        = 1   // seconds, 0.2...20 — mid-band RT60
    case size         = 2   // 0...1 — room dimensions (delay-line scale)
    case preDelay     = 3   // ms, 0...250
    case bassDecay    = 4   // ×, 0.5...2 — bass RT60 relative to mid
    case trebleDecay  = 5   // ×, 0.1...1 — treble RT60 relative to mid
    case lowCut       = 6   // Hz, 20...600 — high-pass on the wet signal
    case highCut      = 7   // Hz, 1000...20000 — low-pass on the wet signal
    case diffusion    = 8   // 0...1
    case modulation   = 9   // 0...1
    case early        = 10  // 0...1 — early-reflection level
    case width        = 11  // 0...1 — stereo width of the wet signal
    case freeze       = 12  // 0/1 — infinite sustain, no new input
}

// MARK: - Render state

private let hallLineCount = 8
private let hallDiffuserCount = 4   // per channel
private let hallTapCount = 8        // early-reflection taps per channel

/// Plain-old-data shared with the render thread.
private struct HallState {
    // Delay lines (8), each a ring buffer of `lineCap` floats.
    var lines: UnsafeMutablePointer<Float>          // hallLineCount * lineCap
    var lineCap: Int
    var lineLen: UnsafeMutablePointer<Float>        // current delay in samples (base)
    var lineWrite: Int = 0                          // shared write head
    var damp: UnsafeMutablePointer<Float>           // one-pole state per line
    var a0: UnsafeMutablePointer<Float>             // per-line loop filter gain
    var b1: UnsafeMutablePointer<Float>             // per-line loop filter pole

    // Input diffusers: 4 allpasses per channel, each ring of `diffCap`.
    var diff: UnsafeMutablePointer<Float>           // 2 * hallDiffuserCount * diffCap
    var diffCap: Int
    var diffLen: UnsafeMutablePointer<Int>          // hallDiffuserCount (same for L/R + offset)
    var diffWrite: Int = 0
    var diffGain: Float = 0.5

    // Early reflections: one ring per channel, taps read behind the head.
    var erL: UnsafeMutablePointer<Float>
    var erR: UnsafeMutablePointer<Float>
    var erCap: Int
    var erWrite: Int = 0
    var tapL: UnsafeMutablePointer<Int>             // hallTapCount
    var tapR: UnsafeMutablePointer<Int>
    var tapGainL: UnsafeMutablePointer<Float>
    var tapGainR: UnsafeMutablePointer<Float>
    var earlyGain: Float = 0.4

    // Pre-delay rings.
    var preL: UnsafeMutablePointer<Float>
    var preR: UnsafeMutablePointer<Float>
    var preCap: Int
    var preDelay: Int = 1
    var preWrite: Int = 0

    // Wet-input tone filters (one-pole), per channel.
    var lpCoef: Float = 1
    var hpCoef: Float = 0
    var lpL: Float = 0, lpR: Float = 0
    var hpL: Float = 0, hpR: Float = 0

    // Modulation: one quadrature LFO, fanned out across the lines.
    var lfoSin: Float = 0
    var lfoCos: Float = 1
    var lfoRotCos: Float = 1
    var lfoRotSin: Float = 0
    var modDepth: Float = 0                         // samples

    // Mix.
    var inputGain: Float = 1
    var wetGain: Float = 0.5
    var dryGain: Float = 0.85
    var widthMid: Float = 1
    var widthSide: Float = 1

    // Raw settings (kept to rebuild derived values on a rate change).
    var mix: Float = 0.3
    var decay: Float = 2.2
    var size: Float = 0.5
    var preDelayMS: Float = 20
    var bassDecay: Float = 1.2
    var trebleDecay: Float = 0.5
    var lowCut: Float = 80
    var highCut: Float = 9000
    var diffusion: Float = 0.75
    var modulation: Float = 0.35
    var early: Float = 0.4
    var width: Float = 1
    var freeze: Float = 0

    var sampleRate: Float = 48_000

    // Scratch input buffers pulled from upstream.
    var ch0: UnsafeMutableRawPointer? = nil
    var ch1: UnsafeMutableRawPointer? = nil
}

public final class HallReverbUnit: AUAudioUnit {

    // 'sohr' / 'Snra'
    public static let subType: OSType = 0x736F_6872
    public static let manufacturer: OSType = 0x536E_7261

    public static let componentDescription = AudioComponentDescription(
        componentType: kAudioUnitType_Effect,
        componentSubType: HallReverbUnit.subType,
        componentManufacturer: HallReverbUnit.manufacturer,
        componentFlags: 0,
        componentFlagsMask: 0
    )

    private static var didRegister = false

    public static func registerIfNeeded() {
        guard !didRegister else { return }
        didRegister = true
        AUAudioUnit.registerSubclass(
            HallReverbUnit.self,
            as: componentDescription,
            name: "Sonora Studio Reverb",
            version: 0x0001_0000
        )
    }

    // MARK: Tunings (samples at 48 kHz; mutually prime, Sonora's own)

    private static let lineBase: [Float] = [1031, 1327, 1523, 1789, 2053, 2311, 2647, 2957]
    private static let diffBase: [Int] = [211, 293, 409, 557]
    /// Right-channel diffusers run slightly longer so the two sides decorrelate.
    private static let diffStereoOffset = 19
    /// Early reflections, milliseconds at size 0.5, with gains. Alternating
    /// signs keep the pattern from building a comb-like colour.
    private static let tapMSL: [Float] = [7.1, 11.3, 17.9, 23.7, 31.3, 41.9, 53.1, 67.3]
    private static let tapMSR: [Float] = [8.3, 13.7, 19.1, 27.1, 35.9, 44.3, 58.7, 71.9]
    private static let tapGains: [Float] = [0.84, -0.71, 0.62, -0.53, 0.44, -0.37, 0.29, -0.22]

    private static let maxRate: Float = 192_000
    private static let minSizeFactor: Float = 0.45
    private static let maxSizeFactor: Float = 1.6
    /// Deepest modulation, as a fraction of a second (≈ 2.5 ms).
    private static let maxModSeconds: Float = 0.0025
    /// Scales the eight-line sum back to roughly unity loudness.
    private static let outputScale: Float = 0.35

    // MARK: Busses

    private var inBus: AUAudioUnitBus!
    private var outBus: AUAudioUnitBus!
    private var inBusArray: AUAudioUnitBusArray!
    private var outBusArray: AUAudioUnitBusArray!

    public override var inputBusses: AUAudioUnitBusArray { inBusArray }
    public override var outputBusses: AUAudioUnitBusArray { outBusArray }

    // MARK: Storage

    private let state = UnsafeMutablePointer<HallState>.allocate(capacity: 1)
    private let maxFrames = 4096
    private var scratchABL: UnsafeMutableAudioBufferListPointer
    private var scratchMemory: [UnsafeMutableRawPointer] = []
    private var floatAllocations: [UnsafeMutablePointer<Float>] = []
    private var intAllocations: [UnsafeMutablePointer<Int>] = []

    /// Bypass handshake with the render thread (see FreeverbUnit).
    private let bypassState: UnsafeMutablePointer<HallBypassState> = {
        let p = UnsafeMutablePointer<HallBypassState>.allocate(capacity: 1)
        p.initialize(to: HallBypassState())
        return p
    }()

    public override var shouldBypassEffect: Bool {
        get { bypassState.pointee.requested }
        set {
            bypassState.pointee.requested = newValue
            if newValue { bypassState.pointee.wasBypassed = true }
            super.shouldBypassEffect = newValue
        }
    }

    private var _parameterTree: AUParameterTree?
    public override var parameterTree: AUParameterTree? {
        get { _parameterTree }
        set { _parameterTree = newValue }
    }

    // MARK: Init

    public override init(componentDescription: AudioComponentDescription,
                         options: AudioComponentInstantiationOptions = []) throws {

        scratchABL = AudioBufferList.allocate(maximumBuffers: 2)

        func floats(_ n: Int) -> UnsafeMutablePointer<Float> {
            let p = UnsafeMutablePointer<Float>.allocate(capacity: n)
            p.initialize(repeating: 0, count: n)
            return p
        }
        func ints(_ n: Int) -> UnsafeMutablePointer<Int> {
            let p = UnsafeMutablePointer<Int>.allocate(capacity: n)
            p.initialize(repeating: 1, count: n)
            return p
        }

        let rateFactor = HallReverbUnit.maxRate / 48_000
        let longest = HallReverbUnit.lineBase.max() ?? 3000
        let lineCap = Int(longest * rateFactor * HallReverbUnit.maxSizeFactor)
            + Int(HallReverbUnit.maxModSeconds * HallReverbUnit.maxRate) * 2 + 16
        let diffCap = Int(Float((HallReverbUnit.diffBase.max() ?? 600) + HallReverbUnit.diffStereoOffset)
                          * rateFactor * HallReverbUnit.maxSizeFactor) + 16
        let longestTap = max(HallReverbUnit.tapMSL.max() ?? 80, HallReverbUnit.tapMSR.max() ?? 80)
        let erCap = Int(longestTap * 0.001 * HallReverbUnit.maxRate * 2.5) + 16
        let preCap = Int(0.25 * HallReverbUnit.maxRate) + 16

        let lines = floats(hallLineCount * lineCap)
        let lineLen = floats(hallLineCount)
        let damp = floats(hallLineCount)
        let a0 = floats(hallLineCount)
        let b1 = floats(hallLineCount)
        let diff = floats(2 * hallDiffuserCount * diffCap)
        let diffLen = ints(hallDiffuserCount)
        let erL = floats(erCap), erR = floats(erCap)
        let tapL = ints(hallTapCount), tapR = ints(hallTapCount)
        let tapGainL = floats(hallTapCount), tapGainR = floats(hallTapCount)
        let preL = floats(preCap), preR = floats(preCap)

        try super.init(componentDescription: componentDescription, options: options)

        floatAllocations = [lines, lineLen, damp, a0, b1, diff, erL, erR,
                            tapGainL, tapGainR, preL, preR]
        intAllocations = [diffLen, tapL, tapR]

        state.initialize(to: HallState(lines: lines, lineCap: lineCap, lineLen: lineLen,
                                       damp: damp, a0: a0, b1: b1,
                                       diff: diff, diffCap: diffCap, diffLen: diffLen,
                                       erL: erL, erR: erR, erCap: erCap,
                                       tapL: tapL, tapR: tapR,
                                       tapGainL: tapGainL, tapGainR: tapGainR,
                                       preL: preL, preR: preR, preCap: preCap))

        let defaultFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        inBus = try AUAudioUnitBus(format: defaultFormat)
        inBus.maximumChannelCount = 2
        outBus = try AUAudioUnitBus(format: defaultFormat)
        outBus.maximumChannelCount = 2
        inBusArray = AUAudioUnitBusArray(audioUnit: self, busType: .input, busses: [inBus])
        outBusArray = AUAudioUnitBusArray(audioUnit: self, busType: .output, busses: [outBus])

        for i in 0..<2 {
            let bytes = maxFrames * MemoryLayout<Float>.size
            let p = UnsafeMutableRawPointer.allocate(byteCount: bytes, alignment: 16)
            memset(p, 0, bytes)
            scratchMemory.append(p)
            scratchABL[i] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(bytes), mData: p)
        }
        state.pointee.ch0 = scratchMemory[0]
        state.pointee.ch1 = scratchMemory[1]

        maximumFramesToRender = AUAudioFrameCount(maxFrames)
        buildParameterTree()
        HallReverbUnit.recompute(state)
    }

    deinit {
        for p in scratchMemory { p.deallocate() }
        for p in floatAllocations { p.deallocate() }
        for p in intAllocations { p.deallocate() }
        free(scratchABL.unsafeMutablePointer)
        state.deinitialize(count: 1)
        state.deallocate()
        bypassState.deinitialize(count: 1)
        bypassState.deallocate()
    }

    // MARK: Parameter tree

    private func buildParameterTree() {
        func p(_ addr: HallParam, _ id: String, _ name: String,
               _ minV: AUValue, _ maxV: AUValue, _ def: AUValue,
               _ unit: AudioUnitParameterUnit) -> AUParameter {
            let param = AUParameterTree.createParameter(
                withIdentifier: id, name: name, address: addr.rawValue,
                min: minV, max: maxV, unit: unit, unitName: nil,
                flags: [.flag_IsReadable, .flag_IsWritable],
                valueStrings: nil, dependentParameters: nil)
            param.value = def
            return param
        }

        let params = [
            p(.mix,         "mix",        "Mix",          0,    1,     0.3,  .generic),
            p(.decay,       "decay",      "Decay",        0.2,  20,    2.2,  .seconds),
            p(.size,        "size",       "Size",         0,    1,     0.5,  .generic),
            p(.preDelay,    "predelay",   "Pre-Delay",    0,    250,   20,   .milliseconds),
            p(.bassDecay,   "bassdecay",  "Bass Decay",   0.5,  2,     1.2,  .generic),
            p(.trebleDecay, "trebdecay",  "Treble Decay", 0.1,  1,     0.5,  .generic),
            p(.lowCut,      "lowcut",     "Low Cut",      20,   600,   80,   .hertz),
            p(.highCut,     "highcut",    "High Cut",     1000, 20000, 9000, .hertz),
            p(.diffusion,   "diffusion",  "Diffusion",    0,    1,     0.75, .generic),
            p(.modulation,  "modulation", "Modulation",   0,    1,     0.35, .generic),
            p(.early,       "early",      "Early",        0,    1,     0.4,  .generic),
            p(.width,       "width",      "Width",        0,    1,     1,    .generic),
            p(.freeze,      "freeze",     "Freeze",       0,    1,     0,    .boolean)
        ]

        let tree = AUParameterTree.createTree(withChildren: params)
        _parameterTree = tree

        let st = state
        tree.implementorValueObserver = { param, value in
            HallReverbUnit.apply(param.address, value, to: st)
        }
        tree.implementorValueProvider = { param in
            HallReverbUnit.read(param.address, from: st)
        }
        tree.implementorStringFromValueCallback = { _, valuePtr in
            String(format: "%.2f", valuePtr?.pointee ?? 0)
        }

        for param in params {
            HallReverbUnit.store(param.address, param.value, in: st)
        }
    }

    private static func store(_ addr: AUParameterAddress, _ v: AUValue,
                              in st: UnsafeMutablePointer<HallState>) {
        switch HallParam(rawValue: addr) {
        case .mix:         st.pointee.mix = max(0, min(1, v))
        case .decay:       st.pointee.decay = max(0.2, min(20, v))
        case .size:        st.pointee.size = max(0, min(1, v))
        case .preDelay:    st.pointee.preDelayMS = max(0, min(250, v))
        case .bassDecay:   st.pointee.bassDecay = max(0.5, min(2, v))
        case .trebleDecay: st.pointee.trebleDecay = max(0.1, min(1, v))
        case .lowCut:      st.pointee.lowCut = max(20, min(600, v))
        case .highCut:     st.pointee.highCut = max(1000, min(20_000, v))
        case .diffusion:   st.pointee.diffusion = max(0, min(1, v))
        case .modulation:  st.pointee.modulation = max(0, min(1, v))
        case .early:       st.pointee.early = max(0, min(1, v))
        case .width:       st.pointee.width = max(0, min(1, v))
        case .freeze:      st.pointee.freeze = v > 0.5 ? 1 : 0
        case .none:        break
        }
    }

    private static func apply(_ addr: AUParameterAddress, _ v: AUValue,
                              to st: UnsafeMutablePointer<HallState>) {
        store(addr, v, in: st)
        recompute(st)
    }

    private static func read(_ addr: AUParameterAddress,
                             from st: UnsafeMutablePointer<HallState>) -> AUValue {
        switch HallParam(rawValue: addr) {
        case .mix:         return st.pointee.mix
        case .decay:       return st.pointee.decay
        case .size:        return st.pointee.size
        case .preDelay:    return st.pointee.preDelayMS
        case .bassDecay:   return st.pointee.bassDecay
        case .trebleDecay: return st.pointee.trebleDecay
        case .lowCut:      return st.pointee.lowCut
        case .highCut:     return st.pointee.highCut
        case .diffusion:   return st.pointee.diffusion
        case .modulation:  return st.pointee.modulation
        case .early:       return st.pointee.early
        case .width:       return st.pointee.width
        case .freeze:      return st.pointee.freeze
        case .none:        return 0
        }
    }

    /// Rebuilds every derived value from the raw settings. Off the audio thread.
    private static func recompute(_ st: UnsafeMutablePointer<HallState>) {
        let s = st.pointee
        let sr = max(s.sampleRate, 8_000)
        let rate = sr / 48_000
        let sizeFactor = minSizeFactor + s.size * (maxSizeFactor - minSizeFactor)
        let frozen = s.freeze > 0.5

        // Delay lines and their loop filters. Each line gets a one-pole
        // low-pass whose DC gain sets the bass decay and whose Nyquist gain
        // sets the treble decay:  g(T) = 10^(-3·L / (sr·T))  per pass.
        let maxLen = Float(s.lineCap) - maxModSeconds * sr * 2 - 8
        for i in 0..<hallLineCount {
            let len = max(64, min(maxLen, lineBase[i] * rate * sizeFactor))
            st.pointee.lineLen[i] = len
            if frozen {
                st.pointee.a0[i] = 1
                st.pointee.b1[i] = 0
            } else {
                let tBass = max(0.05, s.decay * s.bassDecay)
                let tTreble = max(0.05, s.decay * s.trebleDecay)
                let gDC = powf(10, -3 * len / (sr * tBass))
                let gNy = powf(10, -3 * len / (sr * tTreble))
                let b = (gDC - gNy) / (gDC + gNy)
                st.pointee.b1[i] = max(-0.95, min(0.95, b))
                st.pointee.a0[i] = gDC * (1 - st.pointee.b1[i])
            }
        }

        // Input diffusers.
        let diffScale = rate * (0.75 + 0.25 * sizeFactor)
        for k in 0..<hallDiffuserCount {
            let len = Int(Float(diffBase[k]) * diffScale)
            st.pointee.diffLen[k] = max(2, min(s.diffCap - diffStereoOffset * 4 - 2, len))
        }
        st.pointee.diffGain = 0.72 * s.diffusion

        // Early reflections scale with the room.
        let erScale = 0.4 + 0.8 * s.size   // 0.4 ... 1.2
        for k in 0..<hallTapCount {
            let l = Int(tapMSL[k] * 0.001 * sr * erScale)
            let r = Int(tapMSR[k] * 0.001 * sr * erScale)
            st.pointee.tapL[k] = max(1, min(s.erCap - 2, l))
            st.pointee.tapR[k] = max(1, min(s.erCap - 2, r))
            st.pointee.tapGainL[k] = tapGains[k]
            st.pointee.tapGainR[k] = tapGains[(k + 1) % hallTapCount] * -1
        }
        st.pointee.earlyGain = frozen ? 0 : s.early * 0.45

        // Pre-delay.
        st.pointee.preDelay = max(1, min(s.preCap - 2, Int(s.preDelayMS * 0.001 * sr)))

        // Wet tone filters (one-pole coefficients).
        st.pointee.lpCoef = min(1, 1 - expf(-2 * .pi * min(s.highCut, sr * 0.45) / sr))
        st.pointee.hpCoef = min(1, 1 - expf(-2 * .pi * s.lowCut / sr))

        // Modulation LFO: ~0.3 ... 1.1 Hz, deeper as the control rises.
        let lfoHz = 0.3 + 0.8 * s.modulation
        let w = 2 * Float.pi * lfoHz / sr
        st.pointee.lfoRotCos = cosf(w)
        st.pointee.lfoRotSin = sinf(w)
        st.pointee.modDepth = s.modulation * maxModSeconds * sr

        // Mix: equal power so the lower half of the control is audible.
        st.pointee.inputGain = frozen ? 0 : 1
        st.pointee.wetGain = sqrtf(s.mix) * 0.9
        st.pointee.dryGain = sqrtf(1 - s.mix)
        st.pointee.widthMid = 1
        st.pointee.widthSide = s.width
    }

    /// Zeroes every delay line and filter memory. Realtime-safe.
    fileprivate static func clearHistory(_ st: UnsafeMutablePointer<HallState>) {
        let s = st.pointee
        s.lines.update(repeating: 0, count: hallLineCount * s.lineCap)
        s.damp.update(repeating: 0, count: hallLineCount)
        s.diff.update(repeating: 0, count: 2 * hallDiffuserCount * s.diffCap)
        s.erL.update(repeating: 0, count: s.erCap)
        s.erR.update(repeating: 0, count: s.erCap)
        s.preL.update(repeating: 0, count: s.preCap)
        s.preR.update(repeating: 0, count: s.preCap)
        st.pointee.lpL = 0; st.pointee.lpR = 0
        st.pointee.hpL = 0; st.pointee.hpR = 0
        st.pointee.lfoSin = 0; st.pointee.lfoCos = 1
    }

    // MARK: Resources

    public override func allocateRenderResources() throws {
        try super.allocateRenderResources()
        let rate = Float(outBus.format.sampleRate)
        state.pointee.sampleRate = rate > 0 ? rate : 48_000
        HallReverbUnit.clearHistory(state)
        HallReverbUnit.recompute(state)
    }

    public override var canProcessInPlace: Bool { true }

    // MARK: Render

    public override var internalRenderBlock: AUInternalRenderBlock {

        let st = state
        let bypass = bypassState
        let ablPtr = scratchABL.unsafeMutablePointer
        let frameCap = maxFrames
        let outScale = HallReverbUnit.outputScale
        let diffOffset = HallReverbUnit.diffStereoOffset

        return { actionFlags, timestamp, frameCount, _, outputData, _, pullInputBlock in

            guard let pull = pullInputBlock else { return kAudioUnitErr_NoConnection }
            let frames = Int(frameCount)
            if frames > frameCap { return kAudioUnitErr_TooManyFramesToProcess }

            let bytes = UInt32(frames * MemoryLayout<Float>.size)
            let inList = UnsafeMutableAudioBufferListPointer(ablPtr)
            inList[0].mNumberChannels = 1
            inList[0].mDataByteSize = bytes
            inList[0].mData = st.pointee.ch0
            inList[1].mNumberChannels = 1
            inList[1].mDataByteSize = bytes
            inList[1].mData = st.pointee.ch1

            let status = pull(actionFlags, timestamp, frameCount, 0, ablPtr)
            if status != noErr { return status }

            let outList = UnsafeMutableAudioBufferListPointer(outputData)
            let outCount = outList.count
            for i in 0..<outCount where outList[i].mData == nil {
                outList[i].mData = inList[min(i, 1)].mData
                outList[i].mDataByteSize = bytes
            }

            guard let inL = inList[0].mData?.assumingMemoryBound(to: Float.self) else {
                return kAudioUnitErr_NoConnection
            }
            let inR = (inList.count > 1 ? inList[1].mData?.assumingMemoryBound(to: Float.self) : nil) ?? inL
            guard let outL = outList[0].mData?.assumingMemoryBound(to: Float.self) else {
                return kAudioUnitErr_NoConnection
            }
            let outR = (outCount > 1 ? outList[1].mData?.assumingMemoryBound(to: Float.self) : nil) ?? outL

            // Bypassed: straight pass-through, no DSP.
            if bypass.pointee.requested {
                if outL != inL { outL.update(from: inL, count: frames) }
                if outR != outL && outR != inR { outR.update(from: inR, count: frames) }
                bypass.pointee.wasBypassed = true
                return noErr
            }
            if bypass.pointee.wasBypassed {
                bypass.pointee.wasBypassed = false
                HallReverbUnit.clearHistory(st)
            }

            // Snapshot everything the loop needs into locals.
            let s = st.pointee
            let lines = s.lines
            let lineCap = s.lineCap
            let lineLen = s.lineLen
            let damp = s.damp
            let a0 = s.a0
            let b1 = s.b1
            let diff = s.diff
            let diffCap = s.diffCap
            let diffLen = s.diffLen
            let diffGain = s.diffGain
            let erL = s.erL, erR = s.erR
            let erCap = s.erCap
            let tapL = s.tapL, tapR = s.tapR
            let tapGainL = s.tapGainL, tapGainR = s.tapGainR
            let earlyGain = s.earlyGain
            let preL = s.preL, preR = s.preR
            let preCap = s.preCap
            let preDelay = s.preDelay
            let lpCoef = s.lpCoef, hpCoef = s.hpCoef
            let rotC = s.lfoRotCos, rotS = s.lfoRotSin
            let modDepth = s.modDepth
            let inputGain = s.inputGain
            let wetGain = s.wetGain, dryGain = s.dryGain
            let side = s.widthSide

            var lineWrite = s.lineWrite
            var diffWrite = s.diffWrite
            var erWrite = s.erWrite
            var preWrite = s.preWrite
            var lpL = s.lpL, lpR = s.lpR
            var hpL = s.hpL, hpR = s.hpR
            var lfoS = s.lfoSin, lfoC = s.lfoCos

            // Tiny alternating offset keeps the loop filters out of the
            // denormal range when the input goes silent.
            var antiDenormal: Float = 1e-18

            // Per-sample working vector for the eight lines.
            var y0: Float = 0, y1: Float = 0, y2: Float = 0, y3: Float = 0
            var y4: Float = 0, y5: Float = 0, y6: Float = 0, y7: Float = 0

            var n = 0
            while n < frames {
                let xL = inL[n]
                let xR = inR[n]

                // --- Pre-delay -------------------------------------------
                preL[preWrite] = xL
                preR[preWrite] = xR
                var pr = preWrite - preDelay
                if pr < 0 { pr += preCap }
                var wL = preL[pr]
                var wR = preR[pr]
                preWrite += 1
                if preWrite >= preCap { preWrite = 0 }

                // --- Wet tone: high-cut then low-cut ----------------------
                lpL += (wL - lpL) * lpCoef
                lpR += (wR - lpR) * lpCoef
                hpL += (lpL - hpL) * hpCoef
                hpR += (lpR - hpR) * hpCoef
                wL = (lpL - hpL) * inputGain
                wR = (lpR - hpR) * inputGain

                // --- Early reflections ------------------------------------
                erL[erWrite] = wL
                erR[erWrite] = wR
                var eL: Float = 0
                var eR: Float = 0
                var t = 0
                while t < hallTapCount {
                    var il = erWrite - tapL[t]
                    if il < 0 { il += erCap }
                    var ir = erWrite - tapR[t]
                    if ir < 0 { ir += erCap }
                    eL += erL[il] * tapGainL[t]
                    eR += erR[ir] * tapGainR[t]
                    t += 1
                }
                erWrite += 1
                if erWrite >= erCap { erWrite = 0 }

                // --- Input diffusion (Schroeder allpasses) ---------------
                var dL = wL
                var dR = wR
                var k = 0
                while k < hallDiffuserCount {
                    let lenL = diffLen[k]
                    let lenR = lenL + diffOffset
                    let baseL = diff + (k * 2) * diffCap
                    let baseR = diff + (k * 2 + 1) * diffCap
                    var rl = diffWrite - lenL
                    if rl < 0 { rl += diffCap }
                    var rr = diffWrite - lenR
                    if rr < 0 { rr += diffCap }
                    let delL = baseL[rl]
                    let delR = baseR[rr]
                    let vL = dL + diffGain * delL
                    let vR = dR + diffGain * delR
                    baseL[diffWrite] = vL
                    baseR[diffWrite] = vR
                    dL = delL - diffGain * vL
                    dR = delR - diffGain * vR
                    k += 1
                }
                diffWrite += 1
                if diffWrite >= diffCap { diffWrite = 0 }

                // --- LFO (rotating phasor, no trig per sample) ------------
                let ns = lfoS * rotC + lfoC * rotS
                let nc = lfoC * rotC - lfoS * rotS
                lfoS = ns
                lfoC = nc

                // --- Read the eight lines (modulated, interpolated) ------
                var i = 0
                while i < hallLineCount {
                    // Four phase variants of the LFO spread across lines.
                    let m: Float
                    switch i & 3 {
                    case 0: m = lfoS
                    case 1: m = lfoC
                    case 2: m = -lfoS
                    default: m = -lfoC
                    }
                    // Always ≥ the base length, so never reads ahead of the head.
                    let delay = lineLen[i] + modDepth * (1 + m)
                    let di = Int(delay)
                    let frac = delay - Float(di)
                    let base = lines + i * lineCap
                    var p0 = lineWrite - di
                    if p0 < 0 { p0 += lineCap }
                    var p1 = p0 - 1
                    if p1 < 0 { p1 += lineCap }
                    let raw = base[p0] * (1 - frac) + base[p1] * frac

                    // Two-band decay: one-pole loop filter.
                    let z = a0[i] * raw + b1[i] * damp[i]
                    damp[i] = z

                    switch i {
                    case 0: y0 = z
                    case 1: y1 = z
                    case 2: y2 = z
                    case 3: y3 = z
                    case 4: y4 = z
                    case 5: y5 = z
                    case 6: y6 = z
                    default: y7 = z
                    }
                    i += 1
                }

                // --- Stereo taps from the damped line outputs ------------
                let tankL = (y0 - y1 + y2 - y3 + y4 - y5 + y6 - y7) * outScale
                let tankR = (y0 + y1 - y2 - y3 + y4 + y5 - y6 - y7) * outScale

                // --- 8×8 Hadamard feedback (fast Walsh–Hadamard) ----------
                var h0 = y0 + y1, h1 = y0 - y1
                var h2 = y2 + y3, h3 = y2 - y3
                var h4 = y4 + y5, h5 = y4 - y5
                var h6 = y6 + y7, h7 = y6 - y7
                let g0 = h0 + h2, g2 = h0 - h2
                let g1 = h1 + h3, g3 = h1 - h3
                let g4 = h4 + h6, g6 = h4 - h6
                let g5 = h5 + h7, g7 = h5 - h7
                let norm: Float = 0.35355339  // 1/√8 keeps the matrix lossless
                h0 = (g0 + g4) * norm; h4 = (g0 - g4) * norm
                h1 = (g1 + g5) * norm; h5 = (g1 - g5) * norm
                h2 = (g2 + g6) * norm; h6 = (g2 - g6) * norm
                h3 = (g3 + g7) * norm; h7 = (g3 - g7) * norm

                // --- Write back: feedback + diffused input ---------------
                antiDenormal = -antiDenormal
                let inE = dL + antiDenormal   // even lines take the left side
                let inO = dR + antiDenormal   // odd lines take the right side
                lines[0 * lineCap + lineWrite] = h0 + inE
                lines[1 * lineCap + lineWrite] = h1 + inO
                lines[2 * lineCap + lineWrite] = h2 + inE
                lines[3 * lineCap + lineWrite] = h3 + inO
                lines[4 * lineCap + lineWrite] = h4 + inE
                lines[5 * lineCap + lineWrite] = h5 + inO
                lines[6 * lineCap + lineWrite] = h6 + inE
                lines[7 * lineCap + lineWrite] = h7 + inO
                lineWrite += 1
                if lineWrite >= lineCap { lineWrite = 0 }

                // --- Wet: tank + early reflections, then width -----------
                let wetL = tankL + eL * earlyGain
                let wetR = tankR + eR * earlyGain
                let mid = (wetL + wetR) * 0.5
                let sideSig = (wetL - wetR) * 0.5 * side
                let outWL = mid + sideSig
                let outWR = mid - sideSig

                let yL = xL * dryGain + outWL * wetGain
                let yR = xR * dryGain + outWR * wetGain
                outL[n] = yL
                if outR != outL { outR[n] = yR }
                n += 1
            }

            // Keep the LFO phasor on the unit circle (it drifts slowly).
            let mag = sqrtf(lfoS * lfoS + lfoC * lfoC)
            if mag > 0 {
                lfoS /= mag
                lfoC /= mag
            } else {
                lfoS = 0
                lfoC = 1
            }

            st.pointee.lineWrite = lineWrite
            st.pointee.diffWrite = diffWrite
            st.pointee.erWrite = erWrite
            st.pointee.preWrite = preWrite
            st.pointee.lpL = lpL; st.pointee.lpR = lpR
            st.pointee.hpL = hpL; st.pointee.hpR = hpR
            st.pointee.lfoSin = lfoS; st.pointee.lfoCos = lfoC
            return noErr
        }
    }
}

/// Render-thread view of the host's bypass switch.
private struct HallBypassState {
    var requested = false
    var wasBypassed = false
}
