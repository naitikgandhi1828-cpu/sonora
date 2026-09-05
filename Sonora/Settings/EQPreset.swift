//
//  EQPreset.swift
//  Sonora
//
//  Equalizer band model and the built-in preset bank.
//

import Foundation
import AVFoundation

enum EQBandType: Int, Codable, CaseIterable, Identifiable {
    case parametric = 0
    case lowPass = 1
    case highPass = 2
    case lowShelf = 3
    case highShelf = 4
    case resonantLowPass = 5
    case resonantHighPass = 6
    case bandPass = 7
    case bandStop = 8
    case resonantLowShelf = 9
    case resonantHighShelf = 10

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .parametric: return "Peak"
        case .lowPass: return "Low Pass"
        case .highPass: return "High Pass"
        case .lowShelf: return "Low Shelf"
        case .highShelf: return "High Shelf"
        case .resonantLowPass: return "Res Low Pass"
        case .resonantHighPass: return "Res High Pass"
        case .bandPass: return "Band Pass"
        case .bandStop: return "Notch"
        case .resonantLowShelf: return "Res Low Shelf"
        case .resonantHighShelf: return "Res High Shelf"
        }
    }

    var avFilterType: AVAudioUnitEQFilterType {
        switch self {
        case .parametric: return .parametric
        case .lowPass: return .lowPass
        case .highPass: return .highPass
        case .lowShelf: return .lowShelf
        case .highShelf: return .highShelf
        case .resonantLowPass: return .resonantLowPass
        case .resonantHighPass: return .resonantHighPass
        case .bandPass: return .bandPass
        case .bandStop: return .bandStop
        case .resonantLowShelf: return .resonantLowShelf
        case .resonantHighShelf: return .resonantHighShelf
        }
    }

    /// Whether the gain control is meaningful for this filter shape.
    var usesGain: Bool {
        switch self {
        case .lowPass, .highPass, .bandPass, .bandStop,
             .resonantLowPass, .resonantHighPass:
            return false
        default:
            return true
        }
    }
}

struct EQBand: Codable, Hashable, Identifiable {
    var id: UUID = UUID()
    var frequency: Float          // Hz
    var gain: Float               // dB, -24...24
    var bandwidth: Float          // octaves, 0.05...5.0
    var type: EQBandType = .parametric
    var bypass: Bool = false

    init(frequency: Float,
         gain: Float = 0,
         bandwidth: Float = 0.5,
         type: EQBandType = .parametric,
         bypass: Bool = false) {
        self.frequency = frequency
        self.gain = gain
        self.bandwidth = bandwidth
        self.type = type
        self.bypass = bypass
    }
}

struct EQPreset: Codable, Hashable, Identifiable {
    var id: UUID = UUID()
    var name: String
    var isBuiltIn: Bool = false
    var preampDB: Float = 0        // -12...12
    var bands: [EQBand]

    /// Standard ISO-ish 10-band centre frequencies.
    static let standardFrequencies: [Float] = [
        31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000
    ]

    static func flatBands() -> [EQBand] {
        let last = standardFrequencies.count - 1
        return standardFrequencies.enumerated().map { i, freq in
            // The centres above are one octave apart, so bands need ~1 octave
            // of bandwidth to overlap and sum smoothly. At the previous 0.5
            // the response dipped between every slider, which made the curve
            // you drew and the curve you heard disagree.
            //
            // The end bands are shelves rather than peaks: a 31 Hz peaking
            // filter does almost nothing on a phone speaker or on most
            // headphones, whereas a low shelf lifts the whole bottom octave.
            // Same at the top. This is what makes a bass or treble boost feel
            // powerful instead of narrow.
            let type: EQBandType = i == 0 ? .lowShelf
                                 : i == last ? .highShelf
                                 : .parametric
            return EQBand(frequency: freq, gain: 0, bandwidth: 1.0, type: type)
        }
    }

    static func make(_ name: String, _ gains: [Float], preamp: Float = 0) -> EQPreset {
        var bands = flatBands()
        for i in 0..<min(bands.count, gains.count) {
            bands[i].gain = gains[i]
        }
        return EQPreset(name: name, isBuiltIn: true, preampDB: preamp, bands: bands)
    }

    static let flat = make("Flat", Array(repeating: 0, count: 10))

    static let builtIns: [EQPreset] = [
        flat,
        make("Acoustic",     [4, 4, 3, 1, 1.5, 1.5, 3, 3.5, 3, 2], preamp: -2),
        make("Bass Boost",   [7, 6, 5, 3, 1, 0, 0, 0, 0, 0], preamp: -4),
        make("Bass Cut",     [-7, -6, -5, -3, -1, 0, 0, 0, 0, 0], preamp: 1),
        make("Classical",    [4.5, 3.5, 3, 2.5, -1.5, -1.5, 0, 2, 3, 3.5], preamp: -2),
        make("Dance",        [6, 5.5, 3, 0, 1.5, 3.5, 5, 4.5, 3.5, 0], preamp: -4),
        make("Deep",         [5, 4, 1.5, 0.5, 3, 2.5, 1.5, -2, -3.5, -4.5], preamp: -3),
        make("Electronic",   [4.5, 4, 1, 0, -2, 2, 1, 1, 4, 5], preamp: -3),
        make("Hip-Hop",      [6, 5, 1.5, 3, -1, -1, 1.5, -1, 2, 3], preamp: -4),
        make("Jazz",         [4, 3, 1.5, 2.5, -1.5, -1.5, 0, 1.5, 3, 4], preamp: -2),
        make("Latin",        [5, 3, 0, 0, -1.5, -1.5, -1.5, 0, 3, 5], preamp: -3),
        make("Loudness",     [6, 4, 0, 0, -2, 0, -1, -5, 5, 1], preamp: -4),
        make("Lounge",       [-3, -1.5, -0.5, 1.5, 4, 2.5, 0, -1.5, 2, 1], preamp: -2),
        make("Piano",        [3, 2, 0, 2.5, 3, 1.5, 3.5, 4.5, 3, 3.5], preamp: -2),
        make("Pop",          [-1.5, -1, 0, 2, 4, 4, 2, 0, -1, -1.5], preamp: -2),
        make("R&B",          [3, 6.5, 5.5, 1.5, -2.5, -1.5, 2.5, 3, 3.5, 4], preamp: -4),
        make("Rock",         [5, 4, 3, 1.5, -0.5, -1, 0.5, 3, 4, 4.5], preamp: -3),
        make("Small Speakers", [6, 5, 4, 2.5, 1, 0, -1, -2, -3, -3.5], preamp: -4),
        make("Spoken Word",  [-3.5, -0.5, 0, 0.5, 3.5, 4.5, 5, 4, 2.5, 0], preamp: -2),
        make("Treble Boost", [0, 0, 0, 0, 0, 1.5, 3, 4.5, 6, 7], preamp: -4),
        make("Treble Cut",   [0, 0, 0, 0, 0, -1.5, -3, -4.5, -6, -7], preamp: 1),
        make("Vocal Boost",  [-2, -3, -3, 1.5, 4, 4, 3, 1.5, 0, -1.5], preamp: -2),
        make("V-Shape",      [6, 4.5, 2, -1, -3, -3, -1, 2, 4.5, 6], preamp: -4)
    ]
}

// MARK: - Reverb

enum ReverbRoom: Int, Codable, CaseIterable, Identifiable {
    case smallRoom, mediumRoom, largeRoom, mediumHall, largeHall
    case plate, mediumChamber, largeChamber, cathedral, largeRoom2, mediumHall2, mediumHall3, largeHall2

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .smallRoom: return "Small Room"
        case .mediumRoom: return "Medium Room"
        case .largeRoom: return "Large Room"
        case .mediumHall: return "Medium Hall"
        case .largeHall: return "Large Hall"
        case .plate: return "Plate"
        case .mediumChamber: return "Medium Chamber"
        case .largeChamber: return "Large Chamber"
        case .cathedral: return "Cathedral"
        case .largeRoom2: return "Large Room 2"
        case .mediumHall2: return "Medium Hall 2"
        case .mediumHall3: return "Medium Hall 3"
        case .largeHall2: return "Large Hall 2"
        }
    }

    var avPreset: AVAudioUnitReverbPreset {
        switch self {
        case .smallRoom: return .smallRoom
        case .mediumRoom: return .mediumRoom
        case .largeRoom: return .largeRoom
        case .mediumHall: return .mediumHall
        case .largeHall: return .largeHall
        case .plate: return .plate
        case .mediumChamber: return .mediumChamber
        case .largeChamber: return .largeChamber
        case .cathedral: return .cathedral
        case .largeRoom2: return .largeRoom2
        case .mediumHall2: return .mediumHall2
        case .mediumHall3: return .mediumHall3
        case .largeHall2: return .largeHall2
        }
    }

    /// Advanced-engine equivalents: (minDelay, maxDelay, decayAt0Hz, decayAtNyquist)
    var reverb2Shape: (Float, Float, Float, Float) {
        switch self {
        case .smallRoom:     return (0.006, 0.030, 0.9, 0.4)
        case .mediumRoom:    return (0.010, 0.045, 1.4, 0.6)
        case .largeRoom:     return (0.014, 0.060, 2.2, 0.9)
        case .largeRoom2:    return (0.018, 0.070, 2.8, 1.1)
        case .mediumChamber: return (0.012, 0.055, 1.8, 0.8)
        case .largeChamber:  return (0.018, 0.075, 2.6, 1.2)
        case .plate:         return (0.004, 0.024, 1.6, 1.0)
        case .mediumHall:    return (0.020, 0.080, 2.6, 1.1)
        case .mediumHall2:   return (0.024, 0.090, 3.1, 1.3)
        case .mediumHall3:   return (0.028, 0.100, 3.6, 1.5)
        case .largeHall:     return (0.030, 0.110, 4.2, 1.7)
        case .largeHall2:    return (0.034, 0.120, 5.0, 2.0)
        case .cathedral:     return (0.040, 0.140, 7.0, 2.6)
        }
    }
}
