//
//  FreeverbUnit.swift
//  Sonora
//
//  A Schroeder–Moorer algorithmic reverb: eight parallel comb filters with
//  damped feedback into four series allpass diffusers, per channel, with the
//  right-hand delay lines offset so the tail decorrelates into a stereo image.
//
//  This is the Freeverb topology and tuning published by Jezar at Dreampoint,
//  released into the public domain. It is denser and warmer than AUReverb2,
//  which has no modulation and limited diffusion.
//
//  Realtime contract, identical to SonoraDSPUnit: every delay line is
//  allocated up front at its worst-case length, `allocateRenderResources`
//  picks the active length for the running sample rate, and the render block
//  only ever reads and writes raw memory. No allocation, no ARC, no locks on
//  the audio thread.
//

import Foundation
import AVFoundation
import AudioToolbox

// MARK: - Parameter addresses

enum FreeverbParam: AUParameterAddress {
    case mix        = 0     // 0...100 %
    case roomSize   = 1     // 0...1
    case damping    = 2     // 0...1
    case width      = 3     // 0...1
    case preDelayMS = 4     // 0...200 ms
}

/// One damped comb filter. Plain-old-data so it can live in malloc'd memory.
private struct Comb {
    var buffer: UnsafeMutablePointer<Float>
    var capacity: Int
    var size: Int
    var index: Int
    var store: Float
}

/// One allpass diffuser. Feedback is fixed at 0.5, as in the original.
private struct Allpass {
    var buffer: UnsafeMutablePointer<Float>
    var capacity: Int
    var size: Int
    var index: Int
}

private struct FVState {
    var combs: UnsafeMutablePointer<Comb>          // 8 left, then 8 right
    var allpasses: UnsafeMutablePointer<Allpass>   // 4 left, then 4 right

    // Derived render values.
    var feedback: Float = 0.84
    var damp1: Float = 0.2
    var damp2: Float = 0.8
    var wet1: Float = 1
    var wet2: Float = 0
    var dry: Float = 1

    // Raw settings, kept so derived values can be rebuilt after a rate change.
    var mix: Float = 35
    var roomSize: Float = 0.5
    var damping: Float = 0.5
    var width: Float = 1
    var preDelayMS: Float = 20

    var sampleRate: Float = 48_000

    // Pre-delay ring, one per channel.
    var preL: UnsafeMutablePointer<Float>
    var preR: UnsafeMutablePointer<Float>
    var preCapacity: Int
    var preSize: Int
    var preIndex: Int

    // Scratch input buffers pulled from upstream. Explicit nil defaults so the
    // memberwise initialiser below does not require them.
    var ch0: UnsafeMutableRawPointer? = nil
    var ch1: UnsafeMutableRawPointer? = nil
}

public final class FreeverbUnit: AUAudioUnit {

    // 'sofv' / 'Snra'
    public static let subType: OSType = 0x736F_6676
    public static let manufacturer: OSType = 0x536E_7261

    public static let componentDescription = AudioComponentDescription(
        componentType: kAudioUnitType_Effect,
        componentSubType: FreeverbUnit.subType,
        componentManufacturer: FreeverbUnit.manufacturer,
        componentFlags: 0,
        componentFlagsMask: 0
    )

    private static var didRegister = false

    public static func registerIfNeeded() {
        guard !didRegister else { return }
        didRegister = true
        AUAudioUnit.registerSubclass(
            FreeverbUnit.self,
            as: componentDescription,
            name: "Sonora Freeverb",
            version: 0x0001_0000
        )
    }

    // MARK: Tuning (Jezar's constants, at 44.1 kHz)

    private static let combTuning: [Int]    = [1116, 1188, 1277, 1356, 1422, 1491, 1557, 1617]
    private static let allpassTuning: [Int] = [556, 441, 341, 225]
    private static let stereoSpread = 23

    private static let fixedGain: Float  = 0.015
    private static let scaleWet: Float   = 3
    private static let scaleDamp: Float  = 0.4
    private static let scaleRoom: Float  = 0.28
    private static let offsetRoom: Float = 0.7

    /// Delay lines are sized for the highest rate we will ever run at, so a
    /// route change to 96 kHz never needs to allocate.
    private static let maxRateFactor: Float = 192_000.0 / 44_100.0

    private static let combCount = 8
    private static let allpassCount = 4

    // MARK: Busses

    private var inBus: AUAudioUnitBus!
    private var outBus: AUAudioUnitBus!
    private var inBusArray: AUAudioUnitBusArray!
    private var outBusArray: AUAudioUnitBusArray!

    public override var inputBusses: AUAudioUnitBusArray { inBusArray }
    public override var outputBusses: AUAudioUnitBusArray { outBusArray }

    // MARK: Realtime storage

    private let state = UnsafeMutablePointer<FVState>.allocate(capacity: 1)
    private let maxFrames = 4096
    private var scratchABL: UnsafeMutableAudioBufferListPointer
    private var scratchMemory: [UnsafeMutableRawPointer] = []
    private var delayMemory: [UnsafeMutablePointer<Float>] = []

    private var _parameterTree: AUParameterTree?
    public override var parameterTree: AUParameterTree? {
        get { _parameterTree }
        set { _parameterTree = newValue }
    }

    // MARK: Init

    public override init(componentDescription: AudioComponentDescription,
                         options: AudioComponentInstantiationOptions = []) throws {

        scratchABL = AudioBufferList.allocate(maximumBuffers: 2)

        let combCount = FreeverbUnit.combCount
        let allpassCount = FreeverbUnit.allpassCount

        let combs = UnsafeMutablePointer<Comb>.allocate(capacity: combCount * 2)
        let allpasses = UnsafeMutablePointer<Allpass>.allocate(capacity: allpassCount * 2)

        // Pre-delay ring: 200 ms at the highest supported rate.
        let preCapacity = Int(0.2 * 192_000) + 4
        let preL = UnsafeMutablePointer<Float>.allocate(capacity: preCapacity)
        let preR = UnsafeMutablePointer<Float>.allocate(capacity: preCapacity)
        preL.initialize(repeating: 0, count: preCapacity)
        preR.initialize(repeating: 0, count: preCapacity)

        try super.init(componentDescription: componentDescription, options: options)

        delayMemory.append(preL)
        delayMemory.append(preR)

        // Allocate each delay line at its worst-case length once.
        for side in 0..<2 {
            let spread = side == 0 ? 0 : FreeverbUnit.stereoSpread
            for k in 0..<combCount {
                let base = FreeverbUnit.combTuning[k] + spread
                let cap = Int(Float(base) * FreeverbUnit.maxRateFactor) + 4
                let buf = UnsafeMutablePointer<Float>.allocate(capacity: cap)
                buf.initialize(repeating: 0, count: cap)
                delayMemory.append(buf)
                combs[side * combCount + k] = Comb(buffer: buf, capacity: cap,
                                                   size: base, index: 0, store: 0)
            }
            for k in 0..<allpassCount {
                let base = FreeverbUnit.allpassTuning[k] + spread
                let cap = Int(Float(base) * FreeverbUnit.maxRateFactor) + 4
                let buf = UnsafeMutablePointer<Float>.allocate(capacity: cap)
                buf.initialize(repeating: 0, count: cap)
                delayMemory.append(buf)
                allpasses[side * allpassCount + k] = Allpass(buffer: buf, capacity: cap,
                                                             size: base, index: 0)
            }
        }

        state.initialize(to: FVState(combs: combs,
                                     allpasses: allpasses,
                                     preL: preL,
                                     preR: preR,
                                     preCapacity: preCapacity,
                                     preSize: 1,
                                     preIndex: 0))

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
            scratchABL[i] = AudioBuffer(mNumberChannels: 1,
                                        mDataByteSize: UInt32(bytes),
                                        mData: p)
        }
        state.pointee.ch0 = scratchMemory[0]
        state.pointee.ch1 = scratchMemory[1]

        maximumFramesToRender = AUAudioFrameCount(maxFrames)
        buildParameterTree()
        FreeverbUnit.recompute(state)
    }

    deinit {
        for p in scratchMemory { p.deallocate() }
        for p in delayMemory { p.deallocate() }
        state.pointee.combs.deallocate()
        state.pointee.allpasses.deallocate()
        free(scratchABL.unsafeMutablePointer)
        state.deinitialize(count: 1)
        state.deallocate()
    }

    // MARK: Parameters

    private func buildParameterTree() {
        func p(_ addr: FreeverbParam, _ id: String, _ name: String,
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
            p(.mix,        "mix",      "Mix",        0, 100, 35, .percent),
            p(.roomSize,   "room",     "Room Size",  0,   1, 0.5, .generic),
            p(.damping,    "damping",  "Damping",    0,   1, 0.5, .generic),
            p(.width,      "width",    "Width",      0,   1, 1,   .generic),
            p(.preDelayMS, "predelay", "Pre-delay",  0, 200, 20,  .milliseconds)
        ]

        let tree = AUParameterTree.createTree(withChildren: params)
        _parameterTree = tree

        let st = state
        tree.implementorValueObserver = { param, value in
            FreeverbUnit.apply(param.address, value, to: st)
        }
        tree.implementorValueProvider = { param in
            FreeverbUnit.read(param.address, from: st)
        }
        tree.implementorStringFromValueCallback = { param, valuePtr in
            let v = valuePtr?.pointee ?? param.value
            switch FreeverbParam(rawValue: param.address) {
            case .mix:        return String(format: "%.0f%%", v)
            case .preDelayMS: return String(format: "%.0f ms", v)
            default:          return String(format: "%.0f%%", v * 100)
            }
        }

        for param in params { FreeverbUnit.apply(param.address, param.value, to: st) }
    }

    private static func apply(_ addr: AUParameterAddress,
                              _ value: AUValue,
                              to st: UnsafeMutablePointer<FVState>) {
        switch FreeverbParam(rawValue: addr) {
        case .mix:        st.pointee.mix = max(0, min(100, value))
        case .roomSize:   st.pointee.roomSize = max(0, min(1, value))
        case .damping:    st.pointee.damping = max(0, min(1, value))
        case .width:      st.pointee.width = max(0, min(1, value))
        case .preDelayMS: st.pointee.preDelayMS = max(0, min(200, value))
        case .none:       return
        }
        recompute(st)
    }

    private static func read(_ addr: AUParameterAddress,
                             from st: UnsafeMutablePointer<FVState>) -> AUValue {
        switch FreeverbParam(rawValue: addr) {
        case .mix:        return st.pointee.mix
        case .roomSize:   return st.pointee.roomSize
        case .damping:    return st.pointee.damping
        case .width:      return st.pointee.width
        case .preDelayMS: return st.pointee.preDelayMS
        case .none:       return 0
        }
    }

    /// Rebuilds every derived render value from the raw settings. Called off
    /// the audio thread only.
    private static func recompute(_ st: UnsafeMutablePointer<FVState>) {
        let s = st.pointee

        st.pointee.feedback = s.roomSize * scaleRoom + offsetRoom
        st.pointee.damp1 = s.damping * scaleDamp
        st.pointee.damp2 = 1 - s.damping * scaleDamp

        // Equal-power blend so the lower half of the mix slider is audible.
        let m = s.mix / 100
        let wetG = sqrt(m) * scaleWet
        let dryG = sqrt(1 - m)
        let w = s.width
        st.pointee.wet1 = wetG * (w / 2 + 0.5)
        st.pointee.wet2 = wetG * ((1 - w) / 2)
        st.pointee.dry = dryG

        let sr = max(s.sampleRate, 8_000)
        let preSamples = Int(s.preDelayMS * 0.001 * sr)
        st.pointee.preSize = max(1, min(s.preCapacity - 1, preSamples))
    }

    // MARK: Resources

    public override func allocateRenderResources() throws {
        try super.allocateRenderResources()

        let rate = Float(outBus.format.sampleRate)
        let sr = rate > 0 ? rate : 48_000
        state.pointee.sampleRate = sr

        // Freeverb's tunings are prime-ish lengths chosen at 44.1 kHz. Scaling
        // them keeps the modal density of the room constant across rates
        // rather than letting the reverb change character with the hardware.
        let factor = sr / 44_100
        let combCount = FreeverbUnit.combCount
        let allpassCount = FreeverbUnit.allpassCount
        let combs = state.pointee.combs
        let allpasses = state.pointee.allpasses

        for side in 0..<2 {
            let spread = side == 0 ? 0 : FreeverbUnit.stereoSpread
            for k in 0..<combCount {
                let idx = side * combCount + k
                let base = Float(FreeverbUnit.combTuning[k] + spread)
                let size = max(1, min(combs[idx].capacity - 1, Int(base * factor)))
                combs[idx].size = size
                combs[idx].index = 0
                combs[idx].store = 0
                combs[idx].buffer.update(repeating: 0, count: combs[idx].capacity)
            }
            for k in 0..<allpassCount {
                let idx = side * allpassCount + k
                let base = Float(FreeverbUnit.allpassTuning[k] + spread)
                let size = max(1, min(allpasses[idx].capacity - 1, Int(base * factor)))
                allpasses[idx].size = size
                allpasses[idx].index = 0
                allpasses[idx].buffer.update(repeating: 0, count: allpasses[idx].capacity)
            }
        }

        state.pointee.preIndex = 0
        state.pointee.preL.update(repeating: 0, count: state.pointee.preCapacity)
        state.pointee.preR.update(repeating: 0, count: state.pointee.preCapacity)

        FreeverbUnit.recompute(state)
    }

    public override var canProcessInPlace: Bool { true }

    // MARK: Render

    public override var internalRenderBlock: AUInternalRenderBlock {

        let st = state
        let ablPtr = scratchABL.unsafeMutablePointer
        let frameCap = maxFrames
        let combCount = FreeverbUnit.combCount
        let allpassCount = FreeverbUnit.allpassCount
        let gain = FreeverbUnit.fixedGain

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

            let s = st.pointee
            let combs = s.combs
            let allpasses = s.allpasses
            let feedback = s.feedback
            let damp1 = s.damp1
            let damp2 = s.damp2
            let wet1 = s.wet1
            let wet2 = s.wet2
            let dry = s.dry

            let preL = s.preL
            let preR = s.preR
            let preSize = s.preSize
            var preIndex = s.preIndex

            var i = 0
            while i < frames {
                let dryL = inL[i]
                let dryR = inR[i]

                // Pre-delay ahead of the reverb only; the dry path is untouched.
                preL[preIndex] = dryL
                preR[preIndex] = dryR
                var readIndex = preIndex - preSize
                if readIndex < 0 { readIndex += preSize + 1 }
                let wetInL = preL[readIndex]
                let wetInR = preR[readIndex]
                preIndex += 1
                if preIndex > preSize { preIndex = 0 }

                let input = (wetInL + wetInR) * gain

                var accL: Float = 0
                var accR: Float = 0

                // Eight damped combs per channel, in parallel.
                var k = 0
                while k < combCount {
                    let li = k
                    let lOut = combs[li].buffer[combs[li].index]
                    let lStore = lOut * damp2 + combs[li].store * damp1
                    combs[li].store = lStore
                    combs[li].buffer[combs[li].index] = input + lStore * feedback
                    combs[li].index += 1
                    if combs[li].index >= combs[li].size { combs[li].index = 0 }
                    accL += lOut

                    let ri = combCount + k
                    let rOut = combs[ri].buffer[combs[ri].index]
                    let rStore = rOut * damp2 + combs[ri].store * damp1
                    combs[ri].store = rStore
                    combs[ri].buffer[combs[ri].index] = input + rStore * feedback
                    combs[ri].index += 1
                    if combs[ri].index >= combs[ri].size { combs[ri].index = 0 }
                    accR += rOut

                    k += 1
                }

                // Four allpass diffusers per channel, in series. Feedback 0.5.
                var a = 0
                while a < allpassCount {
                    let li = a
                    let lBuf = allpasses[li].buffer[allpasses[li].index]
                    let lNew = -accL + lBuf
                    allpasses[li].buffer[allpasses[li].index] = accL + lBuf * 0.5
                    allpasses[li].index += 1
                    if allpasses[li].index >= allpasses[li].size { allpasses[li].index = 0 }
                    accL = lNew

                    let ri = allpassCount + a
                    let rBuf = allpasses[ri].buffer[allpasses[ri].index]
                    let rNew = -accR + rBuf
                    allpasses[ri].buffer[allpasses[ri].index] = accR + rBuf * 0.5
                    allpasses[ri].index += 1
                    if allpasses[ri].index >= allpasses[ri].size { allpasses[ri].index = 0 }
                    accR = rNew

                    a += 1
                }

                let mixedL = accL * wet1 + accR * wet2 + dryL * dry
                let mixedR = accR * wet1 + accL * wet2 + dryR * dry

                outL[i] = mixedL
                if outR != outL { outR[i] = mixedR }
                i += 1
            }

            st.pointee.preIndex = preIndex
            return noErr
        }
    }
}
