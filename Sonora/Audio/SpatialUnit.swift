//
//  SpatialUnit.swift
//  Sonora
//
//  A binaural spatialiser for ordinary stereo material.
//
//  This is NOT Dolby Atmos and cannot be. Atmos is a licensed, object-based
//  format: the renderer is Dolby's, and the objects have to be authored into
//  the file. A FLAC or MP3 of a stereo mix carries no objects, so there is
//  nothing for an Atmos renderer to place. What players actually give you when
//  they "spatialise" a stereo track is a psychoacoustic model of listening to
//  speakers in a room, and that is what this is.
//
//  Four cues, which together are most of what makes a mix feel like it is
//  around you rather than inside your head:
//
//    * Crossfeed with an interaural time difference. Your left ear hears the
//      right speaker roughly 270 us late and dulled by the shadow of your own
//      head. Headphones deliver each channel to one ear only, which is why a
//      hard-panned mix sounds like it is happening inside your skull. Feeding
//      each channel to the far ear, delayed and low-passed, puts the image back
//      out in front.
//    * Early reflections. Six short taps per ear, cross-fed and decorrelated,
//      standing in for the first bounces off the walls. This is the cue that
//      reads as "room", and it is the one that carries most of the effect.
//    * Mid/side widening ahead of the whole thing, so the side content has
//      something to spread into.
//    * An elevation cue. The pinna imposes a notch near 6 kHz and a lift above
//      it on sound arriving from above; nudging the spectrum that way raises
//      the perceived height of the image, which is the part people recognise
//      as "height channels".
//
//  Realtime contract, identical to SonoraDSPUnit and FreeverbUnit: every delay
//  line is allocated up front at its worst-case length, `allocateRenderResources`
//  picks the active lengths for the running sample rate, and the render block
//  only reads and writes raw memory. No allocation, no ARC, no locks on the
//  audio thread.
//

import Foundation
import AVFoundation
import AudioToolbox

// MARK: - Parameter addresses

enum SpatialParam: AUParameterAddress {
    case amount    = 0     // 0...100 %, dry/processed blend
    case width     = 1     // 0...2, mid/side spread ahead of the model
    case crossfeed = 2     // 0...100 %
    case depth     = 3     // 0...100 %, early reflection level
    case elevation = 4     // 0...100 %
}

private struct SPState {
    /// Early-reflection ring, one per channel.
    var erL: UnsafeMutablePointer<Float>
    var erR: UnsafeMutablePointer<Float>
    var erCapacity: Int
    var erIndex: Int = 0

    /// Interaural delay ring for the crossfeed path.
    var itdL: UnsafeMutablePointer<Float>
    var itdR: UnsafeMutablePointer<Float>
    var itdCapacity: Int
    var itdSize: Int = 13
    var itdIndex: Int = 0

    /// Tap lengths in samples: six for the left ear, then six for the right.
    var tapSizes: UnsafeMutablePointer<Int>
    /// Matching amplitudes. Kept in malloc'd memory rather than a Swift array
    /// so the render block never touches a heap object.
    var tapGains: UnsafeMutablePointer<Float>

    // One-pole filter memories.
    var shadowL: Float = 0
    var shadowR: Float = 0
    var elevLowL: Float = 0
    var elevLowR: Float = 0
    var elevHighL: Float = 0
    var elevHighR: Float = 0

    // Settings, as the user left them.
    var amount: Float = 60
    var width: Float = 1.25
    var crossfeed: Float = 45
    var depth: Float = 40
    var elevation: Float = 35
    var sampleRate: Float = 48_000

    // Derived render values.
    var widthGain: Float = 1.25
    var crossGain: Float = 0.29
    var shadowCoef: Float = 0.11
    var erGain: Float = 0.22
    var elevDip: Float = 0.25
    var elevLift: Float = 0.21
    var elevCoefLow: Float = 0.48
    var elevCoefHigh: Float = 0.69
    var norm: Float = 1
    var wet: Float = 0.6
    var dry: Float = 0.4

    var ch0: UnsafeMutableRawPointer?
    var ch1: UnsafeMutableRawPointer?
}

public final class SpatialUnit: AUAudioUnit {

    // 'sosp' / 'Snra'
    public static let subType: OSType = 0x736F_7370
    public static let manufacturer: OSType = 0x536E_7261

    public static let componentDescription = AudioComponentDescription(
        componentType: kAudioUnitType_Effect,
        componentSubType: SpatialUnit.subType,
        componentManufacturer: SpatialUnit.manufacturer,
        componentFlags: 0,
        componentFlagsMask: 0
    )

    private static var didRegister = false

    public static func registerIfNeeded() {
        guard !didRegister else { return }
        didRegister = true
        AUAudioUnit.registerSubclass(
            SpatialUnit.self,
            as: componentDescription,
            name: "Sonora Spatial",
            version: 0x0001_0000
        )
    }

    // MARK: Tuning

    /// Reflection times in milliseconds. The two ears get different, mutually
    /// prime-ish delays so the reflected field decorrelates instead of arriving
    /// as one phantom centre image.
    private static let tapsMS: [Float] = [11.3, 17.9, 23.1, 29.7, 37.3, 43.1,
                                          13.1, 19.7, 25.3, 31.9, 39.1, 45.7]
    /// Amplitude of each reflection, falling away with time.
    private static let tapGains: [Float] = [0.50, 0.38, 0.29, 0.22, 0.16, 0.11]
    private static let tapCount = 6

    /// Interaural time difference for a source at the side of the head:
    /// roughly the extra 22 cm the sound has to travel.
    private static let itdSeconds: Float = 0.00027
    /// Corner of the head-shadow low-pass on the crossfed path.
    private static let shadowHz: Float = 900
    /// The two corners that bracket the pinna's elevation notch.
    private static let elevLowHz: Float = 5_000
    private static let elevHighHz: Float = 9_000

    private static let maxRate: Float = 192_000

    // MARK: Busses

    private var inBus: AUAudioUnitBus!
    private var outBus: AUAudioUnitBus!
    private var inBusArray: AUAudioUnitBusArray!
    private var outBusArray: AUAudioUnitBusArray!

    public override var inputBusses: AUAudioUnitBusArray { inBusArray }
    public override var outputBusses: AUAudioUnitBusArray { outBusArray }

    // MARK: Realtime storage

    private let state = UnsafeMutablePointer<SPState>.allocate(capacity: 1)
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

        // Sized for the longest reflection at the highest rate we will ever
        // run at, so a route change to 96 kHz never needs to allocate.
        let longestTapMS = SpatialUnit.tapsMS.max() ?? 46
        let erCapacity = Int(longestTapMS * 0.001 * SpatialUnit.maxRate) + 16
        let itdCapacity = Int(SpatialUnit.itdSeconds * 4 * SpatialUnit.maxRate) + 8

        let erL = UnsafeMutablePointer<Float>.allocate(capacity: erCapacity)
        let erR = UnsafeMutablePointer<Float>.allocate(capacity: erCapacity)
        let itdL = UnsafeMutablePointer<Float>.allocate(capacity: itdCapacity)
        let itdR = UnsafeMutablePointer<Float>.allocate(capacity: itdCapacity)
        erL.initialize(repeating: 0, count: erCapacity)
        erR.initialize(repeating: 0, count: erCapacity)
        itdL.initialize(repeating: 0, count: itdCapacity)
        itdR.initialize(repeating: 0, count: itdCapacity)

        let tapSizes = UnsafeMutablePointer<Int>.allocate(capacity: SpatialUnit.tapsMS.count)
        tapSizes.initialize(repeating: 1, count: SpatialUnit.tapsMS.count)

        let tapGains = UnsafeMutablePointer<Float>.allocate(capacity: SpatialUnit.tapCount)
        for (i, g) in SpatialUnit.tapGains.enumerated() { tapGains.advanced(by: i).initialize(to: g) }

        try super.init(componentDescription: componentDescription, options: options)

        delayMemory.append(contentsOf: [erL, erR, itdL, itdR])

        state.initialize(to: SPState(erL: erL,
                                     erR: erR,
                                     erCapacity: erCapacity,
                                     itdL: itdL,
                                     itdR: itdR,
                                     itdCapacity: itdCapacity,
                                     tapSizes: tapSizes,
                                     tapGains: tapGains))

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
        SpatialUnit.recompute(state)
    }

    deinit {
        for p in scratchMemory { p.deallocate() }
        for p in delayMemory { p.deallocate() }
        state.pointee.tapSizes.deallocate()
        state.pointee.tapGains.deallocate()
        free(scratchABL.unsafeMutablePointer)
        state.deinitialize(count: 1)
        state.deallocate()
    }

    // MARK: Parameters

    private func buildParameterTree() {
        func p(_ addr: SpatialParam, _ id: String, _ name: String,
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
            p(.amount,    "amount",    "Amount",     0, 100, 60,   .percent),
            p(.width,     "width",     "Width",      0,   2, 1.25, .generic),
            p(.crossfeed, "crossfeed", "Crossfeed",  0, 100, 45,   .percent),
            p(.depth,     "depth",     "Room Depth", 0, 100, 40,   .percent),
            p(.elevation, "elevation", "Height",     0, 100, 35,   .percent)
        ]

        let tree = AUParameterTree.createTree(withChildren: params)
        _parameterTree = tree

        let st = state
        tree.implementorValueObserver = { param, value in
            SpatialUnit.apply(param.address, value, to: st)
        }
        tree.implementorValueProvider = { param in
            SpatialUnit.read(param.address, from: st)
        }

        for param in params { SpatialUnit.apply(param.address, param.value, to: st) }
    }

    private static func apply(_ addr: AUParameterAddress,
                              _ value: AUValue,
                              to st: UnsafeMutablePointer<SPState>) {
        switch SpatialParam(rawValue: addr) {
        case .amount:    st.pointee.amount = value
        case .width:     st.pointee.width = value
        case .crossfeed: st.pointee.crossfeed = value
        case .depth:     st.pointee.depth = value
        case .elevation: st.pointee.elevation = value
        case .none:      return
        }
        recompute(st)
    }

    private static func read(_ addr: AUParameterAddress,
                             from st: UnsafeMutablePointer<SPState>) -> AUValue {
        switch SpatialParam(rawValue: addr) {
        case .amount:    return st.pointee.amount
        case .width:     return st.pointee.width
        case .crossfeed: return st.pointee.crossfeed
        case .depth:     return st.pointee.depth
        case .elevation: return st.pointee.elevation
        case .none:      return 0
        }
    }

    /// One-pole coefficient for a given corner frequency.
    private static func onePole(_ hz: Float, _ sr: Float) -> Float {
        let c = 1 - expf(-2 * .pi * hz / max(sr, 8_000))
        return min(0.999, max(0.0001, c))
    }

    /// Turns the five settings into the handful of numbers the render block
    /// actually uses. Never called from the audio thread.
    private static func recompute(_ st: UnsafeMutablePointer<SPState>) {
        let sr = max(st.pointee.sampleRate, 8_000)

        st.pointee.widthGain = max(0, min(2, st.pointee.width))
        st.pointee.crossGain = max(0, min(1, st.pointee.crossfeed / 100)) * 0.65
        st.pointee.erGain = max(0, min(1, st.pointee.depth / 100)) * 0.55

        let elev = max(0, min(1, st.pointee.elevation / 100))
        st.pointee.elevDip = elev * 0.7
        st.pointee.elevLift = elev * 0.6

        st.pointee.shadowCoef = onePole(shadowHz, sr)
        st.pointee.elevCoefLow = onePole(elevLowHz, sr)
        st.pointee.elevCoefHigh = onePole(elevHighHz, sr)

        // Crossfeed and reflections both add energy. Without this the effect
        // would read as "louder" rather than "wider", and the limiter
        // downstream would start working for a living the moment it was
        // switched on.
        st.pointee.norm = 1 / (1 + st.pointee.crossGain * 0.8 + st.pointee.erGain * 0.9)

        let a = max(0, min(1, st.pointee.amount / 100))
        st.pointee.wet = a
        st.pointee.dry = 1 - a
    }

    // MARK: Resources

    public override func allocateRenderResources() throws {
        try super.allocateRenderResources()

        let rate = Float(outBus.format.sampleRate)
        let sr = rate > 0 ? rate : 48_000
        state.pointee.sampleRate = sr

        let taps = state.pointee.tapSizes
        let capacity = state.pointee.erCapacity
        for (i, ms) in SpatialUnit.tapsMS.enumerated() {
            taps[i] = max(1, min(capacity - 1, Int(ms * 0.001 * sr)))
        }

        state.pointee.itdSize = max(1, min(state.pointee.itdCapacity - 1,
                                           Int(SpatialUnit.itdSeconds * sr)))

        state.pointee.erIndex = 0
        state.pointee.itdIndex = 0
        state.pointee.erL.update(repeating: 0, count: capacity)
        state.pointee.erR.update(repeating: 0, count: capacity)
        state.pointee.itdL.update(repeating: 0, count: state.pointee.itdCapacity)
        state.pointee.itdR.update(repeating: 0, count: state.pointee.itdCapacity)

        state.pointee.shadowL = 0
        state.pointee.shadowR = 0
        state.pointee.elevLowL = 0
        state.pointee.elevLowR = 0
        state.pointee.elevHighL = 0
        state.pointee.elevHighR = 0

        SpatialUnit.recompute(state)
    }

    public override var canProcessInPlace: Bool { true }

    // MARK: Render

    public override var internalRenderBlock: AUInternalRenderBlock {

        let st = state
        let ablPtr = scratchABL.unsafeMutablePointer
        let frameCap = maxFrames
        let tapCount = SpatialUnit.tapCount

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
            let erL = s.erL
            let erR = s.erR
            let erCapacity = s.erCapacity
            let itdL = s.itdL
            let itdR = s.itdR
            let itdCapacity = s.itdCapacity
            let itdSize = s.itdSize
            let taps = s.tapSizes
            let gains = s.tapGains

            let widthGain = s.widthGain
            let crossGain = s.crossGain
            let shadowCoef = s.shadowCoef
            let erGain = s.erGain
            let elevDip = s.elevDip
            let elevLift = s.elevLift
            let coefLow = s.elevCoefLow
            let coefHigh = s.elevCoefHigh
            let norm = s.norm
            let wet = s.wet
            let dry = s.dry

            var erIndex = s.erIndex
            var itdIndex = s.itdIndex
            var shadowL = s.shadowL
            var shadowR = s.shadowR
            var elevLowL = s.elevLowL
            var elevLowR = s.elevLowR
            var elevHighL = s.elevHighL
            var elevHighR = s.elevHighR

            var i = 0
            while i < frames {
                let dryL = inL[i]
                let dryR = inR[i]

                // Mid/side spread first, so everything below works on an image
                // that is already as wide as the user asked for.
                let mid = (dryL + dryR) * 0.5
                let side = (dryL - dryR) * 0.5 * widthGain
                let l = mid + side
                let r = mid - side

                // Early reflections, taken from the opposite channel's line so
                // the reflected field arrives from the other side of the room.
                erL[erIndex] = l
                erR[erIndex] = r
                var reflectedL: Float = 0
                var reflectedR: Float = 0
                var k = 0
                while k < tapCount {
                    var readL = erIndex - taps[k]
                    if readL < 0 { readL += erCapacity }
                    var readR = erIndex - taps[tapCount + k]
                    if readR < 0 { readR += erCapacity }
                    let g = gains[k]
                    reflectedL += erR[readL] * g
                    reflectedR += erL[readR] * g
                    k += 1
                }
                erIndex += 1
                if erIndex >= erCapacity { erIndex = 0 }

                // Crossfeed: each channel reaches the far ear late and dulled.
                itdL[itdIndex] = l
                itdR[itdIndex] = r
                var readCross = itdIndex - itdSize
                if readCross < 0 { readCross += itdCapacity }
                let lateL = itdL[readCross]
                let lateR = itdR[readCross]
                itdIndex += 1
                if itdIndex >= itdCapacity { itdIndex = 0 }

                shadowL += (lateR - shadowL) * shadowCoef
                shadowR += (lateL - shadowR) * shadowCoef

                var spatialL = (l + shadowL * crossGain + reflectedL * erGain) * norm
                var spatialR = (r + shadowR * crossGain + reflectedR * erGain) * norm

                // Elevation: dip the band the pinna shadows, lift what sits
                // above it. Two one-poles give both the band and the top end.
                elevLowL += (spatialL - elevLowL) * coefLow
                elevHighL += (spatialL - elevHighL) * coefHigh
                let bandL = elevLowL - elevHighL
                spatialL += (spatialL - elevHighL) * elevLift - bandL * elevDip

                elevLowR += (spatialR - elevLowR) * coefLow
                elevHighR += (spatialR - elevHighR) * coefHigh
                let bandR = elevLowR - elevHighR
                spatialR += (spatialR - elevHighR) * elevLift - bandR * elevDip

                outL[i] = dryL * dry + spatialL * wet
                if outR != outL { outR[i] = dryR * dry + spatialR * wet }
                i += 1
            }

            st.pointee.erIndex = erIndex
            st.pointee.itdIndex = itdIndex
            st.pointee.shadowL = shadowL
            st.pointee.shadowR = shadowR
            st.pointee.elevLowL = elevLowL
            st.pointee.elevLowR = elevLowR
            st.pointee.elevHighL = elevHighL
            st.pointee.elevHighR = elevHighR
            return noErr
        }
    }
}
