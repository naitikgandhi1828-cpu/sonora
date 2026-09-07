//
//  AppSettings.swift
//  Sonora
//
//  Every user-tunable value in one observable store, persisted to UserDefaults.
//

import Foundation
import SwiftUI
import Combine

enum ReplayGainMode: Int, Codable, CaseIterable, Identifiable {
    case off = 0, track = 1, album = 2, smart = 3
    var id: Int { rawValue }
    var label: String {
        switch self {
        case .off: return "Off"
        case .track: return "Track Gain"
        case .album: return "Album Gain"
        case .smart: return "Smart (album in album order)"
        }
    }
}

enum RepeatMode: Int, Codable, CaseIterable, Identifiable {
    case off = 0, all = 1, one = 2, stopAfterCurrent = 3
    var id: Int { rawValue }
    var symbol: String {
        switch self {
        case .off: return "repeat"
        case .all: return "repeat"
        case .one: return "repeat.1"
        case .stopAfterCurrent: return "stop.circle"
        }
    }
    var label: String {
        switch self {
        case .off: return "Repeat off"
        case .all: return "Repeat all"
        case .one: return "Repeat one"
        case .stopAfterCurrent: return "Stop after track"
        }
    }
    var next: RepeatMode {
        RepeatMode(rawValue: (rawValue + 1) % 4) ?? .off
    }
}

enum ShuffleMode: Int, Codable, CaseIterable, Identifiable {
    case off = 0, tracks = 1, albums = 2
    var id: Int { rawValue }
    var label: String {
        switch self {
        case .off: return "Shuffle off"
        case .tracks: return "Shuffle tracks"
        case .albums: return "Shuffle albums"
        }
    }
    var next: ShuffleMode { ShuffleMode(rawValue: (rawValue + 1) % 3) ?? .off }
}

@propertyWrapper
struct Stored<Value: Codable> {
    let key: String
    let defaultValue: Value
    let store: UserDefaults = .standard

    var wrappedValue: Value {
        get {
            guard let data = store.data(forKey: key) else { return defaultValue }
            return (try? JSONDecoder().decode(Value.self, from: data)) ?? defaultValue
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                store.set(data, forKey: key)
            }
        }
    }
}

final class AppSettings: ObservableObject {

    static let shared = AppSettings()

    // MARK: Playback

    @Published var gaplessEnabled: Bool { didSet { save(gaplessEnabled, "gapless") } }
    @Published var crossfadeEnabled: Bool { didSet { save(crossfadeEnabled, "crossfadeOn") } }
    @Published var crossfadeSeconds: Double { didSet { save(crossfadeSeconds, "crossfadeSec") } }
    /// Crossfade only when skipping manually, not on natural track end.
    @Published var crossfadeOnManualSkipOnly: Bool { didSet { save(crossfadeOnManualSkipOnly, "crossfadeManual") } }
    @Published var fadeOnPauseResume: Bool { didSet { save(fadeOnPauseResume, "fadePause") } }
    @Published var pauseFadeMS: Double { didSet { save(pauseFadeMS, "fadePauseMS") } }
    @Published var resumeOnHeadphones: Bool { didSet { save(resumeOnHeadphones, "resumeHP") } }
    @Published var pauseOnDisconnect: Bool { didSet { save(pauseOnDisconnect, "pauseDisc") } }
    @Published var seekStepSeconds: Double { didSet { save(seekStepSeconds, "seekStep") } }
    @Published var rewindOnPrevSeconds: Double { didSet { save(rewindOnPrevSeconds, "prevRewind") } }
    @Published var repeatMode: RepeatMode { didSet { save(repeatMode.rawValue, "repeatMode") } }
    @Published var shuffleMode: ShuffleMode { didSet { save(shuffleMode.rawValue, "shuffleMode") } }
    @Published var resumeOnLaunch: Bool { didSet { save(resumeOnLaunch, "resumeLaunch") } }

    // MARK: Tempo / pitch

    @Published var playbackRate: Double { didSet { save(playbackRate, "rate") } }
    @Published var pitchCents: Double { didSet { save(pitchCents, "pitch") } }
    @Published var tempoPitchLinked: Bool { didSet { save(tempoPitchLinked, "tempoLinked") } }

    // MARK: Replay gain / preamp

    @Published var replayGainMode: ReplayGainMode { didSet { save(replayGainMode.rawValue, "rgMode") } }
    @Published var replayGainPreampDB: Double { didSet { save(replayGainPreampDB, "rgPreamp") } }
    @Published var replayGainFallbackDB: Double { didSet { save(replayGainFallbackDB, "rgFallback") } }
    @Published var preventClipping: Bool { didSet { save(preventClipping, "rgClip") } }
    @Published var autoAnalyzeGain: Bool { didSet { save(autoAnalyzeGain, "rgAuto") } }

    // MARK: Equalizer

    @Published var eqEnabled: Bool { didSet { save(eqEnabled, "eqOn") } }
    @Published var eqPreampDB: Double { didSet { save(eqPreampDB, "eqPreamp") } }
    @Published var eqBands: [EQBand] { didSet { save(eqBands, "eqBands") } }
    @Published var selectedPresetName: String { didSet { save(selectedPresetName, "eqPresetName") } }
    @Published var userPresets: [EQPreset] { didSet { save(userPresets, "eqUserPresets") } }

    // MARK: Tone

    @Published var toneEnabled: Bool { didSet { save(toneEnabled, "toneOn") } }
    @Published var bassDB: Double { didSet { save(bassDB, "bass") } }
    @Published var trebleDB: Double { didSet { save(trebleDB, "treble") } }
    @Published var bassFrequency: Double { didSet { save(bassFrequency, "bassFreq") } }
    @Published var trebleFrequency: Double { didSet { save(trebleFrequency, "trebleFreq") } }

    // MARK: Reverb

    // The control set matches Poweramp's, because that is the reverb being
    // compared against and its knobs separate things the old set conflated:
    // Size is the room's dimensions, Fade is how long the tail takes to die.
    // Every value is normalised 0...1 so the UI shows the same numbers.
    @Published var reverbEnabled: Bool { didSet { save(reverbEnabled, "revOn") } }
    @Published var reverbPresetName: String { didSet { save(reverbPresetName, "revPreset") } }
    @Published var reverbDamp: Double { didSet { save(reverbDamp, "revDamp2") } }
    @Published var reverbFilter: Double { didSet { save(reverbFilter, "revFilter") } }
    @Published var reverbFade: Double { didSet { save(reverbFade, "revFade") } }
    @Published var reverbPreDelay: Double { didSet { save(reverbPreDelay, "revPre2") } }
    @Published var reverbPreDelayMix: Double { didSet { save(reverbPreDelayMix, "revPreMix") } }
    @Published var reverbSize: Double { didSet { save(reverbSize, "revSize") } }
    @Published var reverbMix: Double { didSet { save(reverbMix, "revMix2") } }
    @Published var reverbUseAdvanced: Bool { didSet { save(reverbUseAdvanced, "revAdv") } }
    /// true = Freeverb (Schroeder-Moorer), false = Apple AUReverb2.
    @Published var reverbUseFreeverb: Bool { didSet { save(reverbUseFreeverb, "revFv") } }

    // MARK: Spatial

    /// Binaural spatialiser. Not Dolby Atmos and never described as such —
    /// see SpatialUnit for why that is not a thing an offline player can do.
    @Published var spatialEnabled: Bool { didSet { save(spatialEnabled, "spOn") } }
    @Published var spatialAmount: Double { didSet { save(spatialAmount, "spAmt") } }       // 0...100 %
    @Published var spatialWidth: Double { didSet { save(spatialWidth, "spWidth") } }       // 0...2
    @Published var spatialCrossfeed: Double { didSet { save(spatialCrossfeed, "spXf") } }  // 0...100 %
    @Published var spatialDepth: Double { didSet { save(spatialDepth, "spDepth") } }       // 0...100 %
    @Published var spatialElevation: Double { didSet { save(spatialElevation, "spElev") } }// 0...100 %

    // MARK: Stereo / limiter

    @Published var stereoWidth: Double { didSet { save(stereoWidth, "width") } }        // 0...2
    @Published var balance: Double { didSet { save(balance, "balance") } }              // -1...1
    @Published var monoDownmix: Bool { didSet { save(monoDownmix, "mono") } }
    @Published var limiterEnabled: Bool { didSet { save(limiterEnabled, "limOn") } }
    @Published var limiterThresholdDB: Double { didSet { save(limiterThresholdDB, "limThr") } }
    @Published var limiterReleaseMS: Double { didSet { save(limiterReleaseMS, "limRel") } }
    @Published var masterPreampDB: Double { didSet { save(masterPreampDB, "masterPreamp") } }

    // MARK: Library

    @Published var showUnsupportedFiles: Bool { didSet { save(showUnsupportedFiles, "showUnsup") } }
    @Published var parseCueSheets: Bool { didSet { save(parseCueSheets, "cue") } }
    @Published var importM3U: Bool { didSet { save(importM3U, "m3u") } }
    @Published var groupCompilations: Bool { didSet { save(groupCompilations, "compil") } }
    @Published var trackSort: TrackSort { didSet { save(trackSort.rawValue, "trackSort") } }
    @Published var trackSortAscending: Bool { didSet { save(trackSortAscending, "trackSortAsc") } }
    @Published var minimumTrackSeconds: Double { didSet { save(minimumTrackSeconds, "minTrackSec") } }
    /// Allow the artwork finder to query the iTunes Search API for covers it
    /// cannot find on disk. This is the only thing in the app that touches the
    /// network, which is why it gets its own switch.
    @Published var downloadMissingArtwork: Bool { didSet { save(downloadMissingArtwork, "artDownload") } }

    // MARK: Appearance

    @Published var themeID: String { didSet { save(themeID, "themeID") } }
    @Published var useAlbumArtColors: Bool { didSet { save(useAlbumArtColors, "artColors") } }
    @Published var showWaveformSeekBar: Bool { didSet { save(showWaveformSeekBar, "waveform") } }
    @Published var showVisualizer: Bool { didSet { save(showVisualizer, "visualizer") } }
    @Published var blurredArtBackground: Bool { didSet { save(blurredArtBackground, "blurBG") } }
    @Published var keepScreenAwake: Bool { didSet { save(keepScreenAwake, "awake") } }

    // MARK: Sleep timer

    @Published var sleepFadeOut: Bool { didSet { save(sleepFadeOut, "sleepFade") } }
    @Published var sleepFadeSeconds: Double { didSet { save(sleepFadeSeconds, "sleepFadeSec") } }
    @Published var sleepFinishTrack: Bool { didSet { save(sleepFinishTrack, "sleepFinish") } }

    // MARK: - Init

    private init() {
        let d = UserDefaults.standard
        func b(_ k: String, _ def: Bool) -> Bool { d.object(forKey: k) == nil ? def : d.bool(forKey: k) }
        func n(_ k: String, _ def: Double) -> Double { d.object(forKey: k) == nil ? def : d.double(forKey: k) }
        func i(_ k: String, _ def: Int) -> Int { d.object(forKey: k) == nil ? def : d.integer(forKey: k) }
        func s(_ k: String, _ def: String) -> String { d.string(forKey: k) ?? def }

        gaplessEnabled = b("gapless", true)
        crossfadeEnabled = b("crossfadeOn", false)
        crossfadeSeconds = n("crossfadeSec", 4)
        crossfadeOnManualSkipOnly = b("crossfadeManual", false)
        fadeOnPauseResume = b("fadePause", true)
        pauseFadeMS = n("fadePauseMS", 180)
        resumeOnHeadphones = b("resumeHP", false)
        pauseOnDisconnect = b("pauseDisc", true)
        seekStepSeconds = n("seekStep", 10)
        rewindOnPrevSeconds = n("prevRewind", 5)
        repeatMode = RepeatMode(rawValue: i("repeatMode", 1)) ?? .all
        shuffleMode = ShuffleMode(rawValue: i("shuffleMode", 0)) ?? .off
        resumeOnLaunch = b("resumeLaunch", true)

        playbackRate = n("rate", 1.0)
        pitchCents = n("pitch", 0)
        tempoPitchLinked = b("tempoLinked", false)

        replayGainMode = ReplayGainMode(rawValue: i("rgMode", 0)) ?? .off
        replayGainPreampDB = n("rgPreamp", 0)
        replayGainFallbackDB = n("rgFallback", -6)
        preventClipping = b("rgClip", true)
        autoAnalyzeGain = b("rgAuto", false)

        eqEnabled = b("eqOn", false)
        eqPreampDB = n("eqPreamp", 0)
        if let data = d.data(forKey: "eqBands"),
           let decoded = try? JSONDecoder().decode([EQBand].self, from: data), decoded.count == 10 {
            eqBands = decoded
        } else {
            eqBands = EQPreset.flatBands()
        }
        selectedPresetName = s("eqPresetName", "Flat")
        if let data = d.data(forKey: "eqUserPresets"),
           let decoded = try? JSONDecoder().decode([EQPreset].self, from: data) {
            userPresets = decoded
        } else {
            userPresets = []
        }

        toneEnabled = b("toneOn", false)
        bassDB = n("bass", 0)
        trebleDB = n("treble", 0)
        bassFrequency = n("bassFreq", 120)
        trebleFrequency = n("trebleFreq", 6000)

        reverbEnabled = b("revOn", false)
        let defaultReverb = AppSettings.ReverbPreset.scene
        reverbPresetName = s("revPreset", defaultReverb.name)
        reverbDamp = n("revDamp2", defaultReverb.damp)
        reverbFilter = n("revFilter", defaultReverb.filter)
        reverbFade = n("revFade", defaultReverb.fade)
        reverbPreDelay = n("revPre2", defaultReverb.preDelay)
        reverbPreDelayMix = n("revPreMix", defaultReverb.preDelayMix)
        reverbSize = n("revSize", defaultReverb.size)
        reverbMix = n("revMix2", defaultReverb.mix)
        reverbUseAdvanced = b("revAdv", true)
        reverbUseFreeverb = b("revFv", true)

        spatialEnabled = b("spOn", false)
        spatialAmount = n("spAmt", 60)
        spatialWidth = n("spWidth", 1.25)
        spatialCrossfeed = n("spXf", 45)
        spatialDepth = n("spDepth", 40)
        spatialElevation = n("spElev", 35)

        stereoWidth = n("width", 1.0)
        balance = n("balance", 0)
        monoDownmix = b("mono", false)
        limiterEnabled = b("limOn", true)
        limiterThresholdDB = n("limThr", -0.5)
        limiterReleaseMS = n("limRel", 120)
        masterPreampDB = n("masterPreamp", 0)

        showUnsupportedFiles = b("showUnsup", false)
        parseCueSheets = b("cue", true)
        importM3U = b("m3u", true)
        groupCompilations = b("compil", true)
        trackSort = TrackSort(rawValue: s("trackSort", "trackNumber")) ?? .trackNumber
        trackSortAscending = b("trackSortAsc", true)
        minimumTrackSeconds = n("minTrackSec", 0)
        downloadMissingArtwork = b("artDownload", true)

        themeID = s("themeID", "ember")
        useAlbumArtColors = b("artColors", true)
        showWaveformSeekBar = b("waveform", true)
        showVisualizer = b("visualizer", true)
        blurredArtBackground = b("blurBG", true)
        keepScreenAwake = b("awake", false)

        sleepFadeOut = b("sleepFade", true)
        sleepFadeSeconds = n("sleepFadeSec", 20)
        sleepFinishTrack = b("sleepFinish", false)
    }

    private func save<T: Codable>(_ value: T, _ key: String) {
        let d = UserDefaults.standard
        switch value {
        case let v as Bool: d.set(v, forKey: key)
        case let v as Double: d.set(v, forKey: key)
        case let v as Int: d.set(v, forKey: key)
        case let v as String: d.set(v, forKey: key)
        default:
            if let data = try? JSONEncoder().encode(value) { d.set(data, forKey: key) }
        }
    }

    // MARK: - Preset helpers

    var allPresets: [EQPreset] { EQPreset.builtIns + userPresets }

    func apply(preset: EQPreset) {
        eqBands = preset.bands
        eqPreampDB = Double(preset.preampDB)
        selectedPresetName = preset.name
        eqEnabled = true
    }

    func saveCurrentAsPreset(named name: String) {
        var p = EQPreset(name: name, isBuiltIn: false, preampDB: Float(eqPreampDB), bands: eqBands)
        p.id = UUID()
        if let idx = userPresets.firstIndex(where: { $0.name == name }) {
            userPresets[idx] = p
        } else {
            userPresets.append(p)
        }
        selectedPresetName = name
    }

    func deleteUserPreset(named name: String) {
        userPresets.removeAll { $0.name == name }
        if selectedPresetName == name { selectedPresetName = "Flat" }
    }

    func resetEQ() {
        eqBands = EQPreset.flatBands()
        eqPreampDB = 0
        selectedPresetName = "Flat"
    }

    func resetDSP() {
        bassDB = 0; trebleDB = 0; toneEnabled = false
        stereoWidth = 1; balance = 0; monoDownmix = false
        reverbEnabled = false
        apply(reverbPreset: .scene)
        spatialEnabled = false
        applySpatialPreset(.headphones)
        playbackRate = 1; pitchCents = 0
        masterPreampDB = 0
    }

    // MARK: - Reverb presets

    /// The eight rooms Poweramp ships, with its own values.
    struct ReverbPreset: Identifiable, Hashable {
        let name: String
        let damp: Double
        let filter: Double
        let fade: Double
        let preDelay: Double
        let preDelayMix: Double
        let size: Double
        let mix: Double

        var id: String { name }

        //                                        damp  filt  fade  pre  preMix size  mix
        static let studio       = ReverbPreset(name: "Studio",
                                               damp: 0.99, filter: 0.11, fade: 1.00,
                                               preDelay: 0.04, preDelayMix: 0.44,
                                               size: 0.03, mix: 0.47)
        static let smallRoom    = ReverbPreset(name: "Small Room",
                                               damp: 0.53, filter: 1.00, fade: 1.00,
                                               preDelay: 0.00, preDelayMix: 0.62,
                                               size: 0.00, mix: 0.32)
        static let lightReverb  = ReverbPreset(name: "Light Reverb",
                                               damp: 0.44, filter: 0.80, fade: 0.32,
                                               preDelay: 0.25, preDelayMix: 0.35,
                                               size: 0.60, mix: 0.38)
        static let scene        = ReverbPreset(name: "Scene",
                                               damp: 0.41, filter: 0.70, fade: 0.50,
                                               preDelay: 0.12, preDelayMix: 0.43,
                                               size: 0.24, mix: 0.45)
        static let echo         = ReverbPreset(name: "Echo",
                                               damp: 0.36, filter: 0.91, fade: 0.27,
                                               preDelay: 0.54, preDelayMix: 0.58,
                                               size: 0.73, mix: 0.37)
        static let auditorium   = ReverbPreset(name: "Auditorium",
                                               damp: 0.90, filter: 0.70, fade: 0.81,
                                               preDelay: 0.00, preDelayMix: 0.00,
                                               size: 0.00, mix: 0.50)
        static let greatHall    = ReverbPreset(name: "Great Hall",
                                               damp: 0.26, filter: 0.71, fade: 0.00,
                                               preDelay: 0.95, preDelayMix: 0.53,
                                               size: 0.52, mix: 0.44)
        static let stadium      = ReverbPreset(name: "Stadium",
                                               damp: 0.84, filter: 0.62, fade: 0.83,
                                               preDelay: 0.45, preDelayMix: 0.74,
                                               size: 0.99, mix: 0.38)

        static let all: [ReverbPreset] = [studio, smallRoom, lightReverb, scene,
                                          echo, auditorium, greatHall, stadium]
    }

    func apply(reverbPreset preset: ReverbPreset) {
        reverbDamp = preset.damp
        reverbFilter = preset.filter
        reverbFade = preset.fade
        reverbPreDelay = preset.preDelay
        reverbPreDelayMix = preset.preDelayMix
        reverbSize = preset.size
        reverbMix = preset.mix
        reverbPresetName = preset.name
    }

    // MARK: - Spatial presets

    enum SpatialPreset: String, CaseIterable, Identifiable {
        case subtle = "Subtle"
        case headphones = "Headphones"
        case wide = "Wide"
        case concert = "Concert Hall"

        var id: String { rawValue }

        /// amount, width, crossfeed, depth, elevation
        var values: (Double, Double, Double, Double, Double) {
            switch self {
            case .subtle:     return (35, 1.10, 35, 20, 15)
            case .headphones: return (55, 1.15, 55, 30, 25)
            case .wide:       return (70, 1.60, 40, 45, 35)
            case .concert:    return (85, 1.40, 45, 75, 45)
            }
        }
    }

    func applySpatialPreset(_ preset: SpatialPreset) {
        let v = preset.values
        spatialAmount = v.0
        spatialWidth = v.1
        spatialCrossfeed = v.2
        spatialDepth = v.3
        spatialElevation = v.4
    }
}
