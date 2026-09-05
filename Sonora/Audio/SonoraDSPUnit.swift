//
//  SonoraDSPUnit.swift
//  Sonora
//
//  A small in-process Audio Unit that handles the parts of the signal chain
//  AVFoundation does not give us: master pre-amp, mid/side stereo width,
//  balance, mono downmix and a soft-knee peak limiter.
//
//  The render block is realtime-safe: it touches only a malloc'd parameter
//  block and pre-allocated buffers, and never allocates, locks or retains.
//

import Foundation
import AVFoundation
import AudioToolbox

// MARK: - Parameter addresses

enum SonoraDSPParam: AUParameterAddress {
    case preampDB      = 0
    case stereoWidth   = 1
    case balance       = 2
    case monoDownmix   = 3
    case limiterOn     = 4
    case limiterCeilDB = 5
    case limiterRelMS  = 6
}

/// Plain-old-data block shared with the render thread.
private struct DSPState {
    var preampLinear: Float = 1
    var width: Float = 1
    var balance: Float = 0
    var mono: Float = 0
    var limiterOn: Float = 1
    var ceiling: Float = 0.944          // -0.5 dBFS
    var releaseCoef: Float = 0.9995
    var attackCoef: Float = 0.35
    var envelope: Float = 0
    var gain: Float = 1
    var sampleRate: Float = 48_000
    /// Kept alongside `releaseCoef` so the coefficient can be rebuilt when the
    /// sample rate changes. Deriving the millisecond value back out of the
    /// coefficient would use the *new* rate and reproduce the same stale
    /// number, so the raw setting has to be stored.
    var releaseMS: Float = 120
    var ch0: UnsafeMutableRawPointer?
    var ch1: UnsafeMutableRawPointer?
}

public final class SonoraDSPUnit: AUAudioUnit {

    // 'sodx' / 'Snra'
    public static let subType: OSType = 0x736F_6478
    public static let manufacturer: OSType = 0x536E_7261

    public static let componentDescription = AudioComponentDescription(
        componentType: kAudioUnitType_Effect,
        componentSubType: SonoraDSPUnit.subType,
        componentManufacturer: SonoraDSPUnit.manufacturer,
        componentFlags: 0,
        componentFlagsMask: 0
    )

    private static var didRegister = false

    /// Registers the subclass with AudioComponent so `AVAudioUnitEffect`
    /// can instantiate it. Safe to call more than once.
    public static func registerIfNeeded() {
        guard !didRegister else { return }
        didRegister = true
        AUAudioUnit.registerSubclass(
            SonoraDSPUnit.self,
            as: componentDescription,
            name: "Sonora DSP",
            version: 0x0001_0000
        )
    }

    // MARK: Busses

    private var inBus: AUAudioUnitBus!
    private var outBus: AUAudioUnitBus!
    private var inBusArray: AUAudioUnitBusArray!
    private var outBusArray: AUAudioUnitBusArray!

    public override var inputBusses: AUAudioUnitBusArray { inBusArray }
    public override var outputBusses: AUAudioUnitBusArray { outBusArray }

    // MARK: Realtime storage

    private let state = UnsafeMutablePointer<DSPState>.allocate(capacity: 1)
    private let maxFrames = 4096
    private let maxChannels = 2
    private var scratchABL: UnsafeMutableAudioBufferListPointer
    private var scratchMemory: [UnsafeMutableRawPointer] = []

    private var _parameterTree: AUParameterTree?
    public override var parameterTree: AUParameterTree? {
        get { _parameterTree }
        set { _parameterTree = newValue }
    }

    // MARK: Init

    public override init(componentDescription: AudioComponentDescription,
                         options: AudioComponentInstantiationOptions = []) throws {

        scratchABL = AudioBufferList.allocate(maximumBuffers: 2)

        try super.init(componentDescription: componentDescription, options: options)

        state.initialize(to: DSPState())

        let defaultFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        inBus = try AUAudioUnitBus(format: defaultFormat)
        inBus.maximumChannelCount = 2
        outBus = try AUAudioUnitBus(format: defaultFormat)
        outBus.maximumChannelCount = 2

        inBusArray = AUAudioUnitBusArray(audioUnit: self, busType: .input, busses: [inBus])
        outBusArray = AUAudioUnitBusArray(audioUnit: self, busType: .output, busses: [outBus])

        for i in 0..<maxChannels {
            let bytes = maxFrames * MemoryLayout<Float>.size
            let p = UnsafeMutableRawPointer.allocate(byteCount: bytes, alignment: 16)
            memset(p, 0, bytes)
            scratchMemory.append(p)
            scratchABL[i] = AudioBuffer(mNumberChannels: 1,
                                        mDataByteSize: UInt32(bytes),
                                        mData: p)
        }
        state.pointee.ch0 = scratchMemory[0]
        state.pointee.ch1 = scratchMemory[1]

        maximumFramesToRender = AUAudioFrameCount(maxFrames)
        buildParameterTree()
    }

    deinit {
        for p in scratchMemory { p.deallocate() }
        free(scratchABL.unsafeMutablePointer)
        state.deinitialize(count: 1)
        state.deallocate()
    }

    // MARK: Parameters

    private func buildParameterTree() {
        func p(_ addr: SonoraDSPParam, _ id: String, _ name: String,
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
            p(.preampDB,      "preamp",   "Pre-amp",          -24, 12, 0,   .decibels),
            p(.stereoWidth,   "width",    "Stereo Width",       0,  2, 1,   .generic),
            p(.balance,       "balance",  "Balance",           -1,  1, 0,   .pan),
            p(.monoDownmix,   "mono",     "Mono Downmix",       0,  1, 0,   .boolean),
            p(.limiterOn,     "limiter",  "Limiter",            0,  1, 1,   .boolean),
            p(.limiterCeilDB, "ceiling",  "Limiter Ceiling",  -12,  0, -0.5, .decibels),
            p(.limiterRelMS,  "release",  "Limiter Release",   10, 1000, 120, .milliseconds)
        ]

        let tree = AUParameterTree.createTree(withChildren: params)
        _parameterTree = tree

        let st = state
        tree.implementorValueObserver = { param, value in
            SonoraDSPUnit.apply(param.address, value, to: st)
        }
        tree.implementorValueProvider = { param in
            SonoraDSPUnit.read(param.address, from: st)
        }
        tree.implementorStringFromValueCallback = { param, valuePtr in
            let v = valuePtr?.pointee ?? param.value
            switch SonoraDSPParam(rawValue: param.address) {
            case .balance:
                if abs(v) < 0.005 { return "Center" }
                return v < 0 ? String(format: "L %.0f%%", -v * 100)
                             : String(format: "R %.0f%%", v * 100)
            case .stereoWidth:
                return String(format: "%.0f%%", v * 100)
            case .monoDownmix, .limiterOn:
                return v > 0.5 ? "On" : "Off"
            default:
                return String(format: "%.1f", v)
            }
        }

        // Seed the shared state from the defaults.
        for param in params { SonoraDSPUnit.apply(param.address, param.value, to: st) }
    }

    private static func apply(_ addr: AUParameterAddress,
                              _ value: AUValue,
                              to st: UnsafeMutablePointer<DSPState>) {
        switch SonoraDSPParam(rawValue: addr) {
        case .preampDB:      st.pointee.preampLinear = powf(10, value / 20)
        case .stereoWidth:   st.pointee.width = value
        case .balance:       st.pointee.balance = value
        case .monoDownmix:   st.pointee.mono = value
        case .limiterOn:     st.pointee.limiterOn = value
        case .limiterCeilDB: st.pointee.ceiling = powf(10, value / 20)
        case .limiterRelMS:
            st.pointee.releaseMS = max(value, 1)
            refreshReleaseCoef(st)
        case .none: break
        }
    }

    /// Rebuilds the release coefficient from `releaseMS` at the current rate.
    private static func refreshReleaseCoef(_ st: UnsafeMutablePointer<DSPState>) {
        let sr = max(st.pointee.sampleRate, 8_000)
        let samples = max(st.pointee.releaseMS, 1) * 0.001 * sr
        st.pointee.releaseCoef = expf(-1.0 / max(samples, 1))
    }

    private static func read(_ addr: AUParameterAddress,
                             from st: UnsafeMutablePointer<DSPState>) -> AUValue {
        switch SonoraDSPParam(rawValue: addr) {
        case .preampDB:      return 20 * log10f(max(st.pointee.preampLinear, 1e-6))
        case .stereoWidth:   return st.pointee.width
        case .balance:       return st.pointee.balance
        case .monoDownmix:   return st.pointee.mono
        case .limiterOn:     return st.pointee.limiterOn
        case .limiterCeilDB: return 20 * log10f(max(st.pointee.ceiling, 1e-6))
        case .limiterRelMS: return st.pointee.releaseMS
        case .none: return 0
        }
    }

    // MARK: Resources

    public override func allocateRenderResources() throws {
        try super.allocateRenderResources()
        let rate = Float(outBus.format.sampleRate)
        state.pointee.sampleRate = rate > 0 ? rate : 48_000
        state.pointee.envelope = 0
        state.pointee.gain = 1
        // The coefficient was built at init against the 48 kHz placeholder.
        // Without this, the limiter releases ~9% off on 44.1 kHz material and
        // is badly wrong at 96 kHz.
        SonoraDSPUnit.refreshReleaseCoef(state)
    }

    public override func deallocateRenderResources() {
        super.deallocateRenderResources()
    }

    public override var canProcessInPlace: Bool { true }

    // MARK: Render

    public override var internalRenderBlock: AUInternalRenderBlock {

        let st = state
        let ablPtr = scratchABL.unsafeMutablePointer
        let frameCap = maxFrames

        return { actionFlags, timestamp, frameCount, _, outputData, _, pullInputBlock in

            guard let pull = pullInputBlock else { return kAudioUnitErr_NoConnection }
            let frames = Int(frameCount)
            if frames > frameCap { return kAudioUnitErr_TooManyFramesToProcess }

            // Point the scratch list back at our own memory, sized for this pull.
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

            // Adopt in-place operation when the host gave us null buffers.
            for i in 0..<outCount {
                if outList[i].mData == nil {
                    outList[i].mData = inList[min(i, 1)].mData
                    outList[i].mDataByteSize = bytes
                }
            }

            guard let inL = inList[0].mData?.assumingMemoryBound(to: Float.self) else {
                return kAudioUnitErr_NoConnection
            }
            let inR = (inList.count > 1 ? inList[1].mData?.assumingMemoryBound(to: Float.self) : nil) ?? inL

            guard let outL = outList[0].mData?.assumingMemoryBound(to: Float.self) else {
                return kAudioUnitErr_NoConnection
            }
            let outR = (outCount > 1 ? outList[1].mData?.assumingMemoryBound(to: Float.self) : nil) ?? outL

            let s = st.pointee
            let preamp = s.preampLinear
            let width = s.width
            let isMono = s.mono > 0.5
            let bal = s.balance
            let gainL: Float = bal > 0 ? (1 - bal) : 1
            let gainR: Float = bal < 0 ? (1 + bal) : 1
            let limiting = s.limiterOn > 0.5
            let ceiling = s.ceiling
            let relCoef = s.releaseCoef
            let atkCoef = s.attackCoef

            var env = s.envelope
            var gain = s.gain

            var i = 0
            while i < frames {
                var l = inL[i] * preamp
                var r = inR[i] * preamp

                // Mid/side width
                if isMono {
                    let m = (l + r) * 0.5
                    l = m; r = m
                } else if width != 1 {
                    let m = (l + r) * 0.5
                    let sd = (l - r) * 0.5 * width
                    l = m + sd
                    r = m - sd
                }

                l *= gainL
                r *= gainR

                if limiting {
                    let peak = max(abs(l), abs(r))
                    // Instant attack, exponential release on the envelope.
                    env = peak > env ? peak : env * relCoef
                    let target: Float = env > ceiling ? ceiling / env : 1
                    // One-pole smoothing so gain changes never click.
                    gain += (target - gain) * (target < gain ? atkCoef : (1 - relCoef) * 8)
                    if gain > 1 { gain = 1 }
                    if gain < 0.0001 { gain = 0.0001 }
                    l *= gain
                    r *= gain
                    // Hard safety clamp.
                    if l > ceiling { l = ceiling } else if l < -ceiling { l = -ceiling }
                    if r > ceiling { r = ceiling } else if r < -ceiling { r = -ceiling }
                }

                outL[i] = l
                if outR != outL { outR[i] = r }
                i += 1
            }

            st.pointee.envelope = env
            st.pointee.gain = gain
            return noErr
        }
    }
}
