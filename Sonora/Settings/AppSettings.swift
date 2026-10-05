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

/// Which reverb algorithm is in circuit.
enum ReverbEngine: Int, Codable, CaseIterable, Identifiable {
    /// Sonora's eight-line feedback delay network (HallReverbUnit).
    case studio = 0
    /// The Freeverb comb/allpass engine (FreeverbUnit).
    case classic = 1
    /// Apple's AUReverb2.
    case apple = 2
    var id: Int { rawValue }
    var label: String {
        switch self {
        case .studio: return "Studio"
        case .classic: return "Classic"
        case .apple: return "Apple"
        }
    }
    var blurb: String {
        switch self {
        case .studio: return "Dense, smooth tail with separate bass and treble decay. Best quality."
        case .classic: return "Freeverb comb-filter reverb with Poweramp-style controls."
        case .apple: return "iOS's built-in reverb rooms. Lightest on battery."
        }
    }
}

/// How aggressively Sonora trades features for battery life.
enum PowerMode: Int, Codable, CaseIterable, Identifiable {
    case off = 0, lowPowerOnly = 1, always = 2
    var id: Int { rawValue }
    var label: String {
        switch self {
        case .off: return "Off"
        case .lowPowerOnly: return "In Low Power Mode"
        case .always: return "Always"
        }
    }
}

/// How the cover is drawn on the Now Playing screen.
enum ArtworkShape: Int, Codable, CaseIterable, Identifiable {
    case rounded = 0, square = 1, circle = 2, vinyl = 3
    var id: Int { rawValue }
    var label: String {
        switch self {
        case .rounded: return "Rounded"
        case .square: return "Square"
        case .circle: return "Circle"
        case .vinyl: return "Vinyl Record"
        }
    }
    var symbol: String {
        switch self {
        case .rounded: return "app"
        case .square: return "square"
        case .circle: return "circle"
        case .vinyl: return "record.circle"
        }
    }
}

/// Look of the spectrum visualizer on the Now Playing cover.
enum VisualizerStyle: Int, Codable, CaseIterable, Identifiable {
    case bars = 0, mirror = 1, wave = 2
    var id: Int { rawValue }
    var label: String {
        switch self {
        case .bars: return "Bars"
        case .mirror: return "Mirror"
        case .wave: return "Wave"
        }
    }
}

/// App-wide typeface family.
enum FontStyle: Int, Codable, CaseIterable, Identifiable {
    case standard = 0, rounded = 1, serif = 2, mono = 3
    var id: Int { rawValue }
    var label: String {
        switch self {
        case .standard: return "Default"
        case .rounded: return "Rounded"
        case .serif: return "Serif"
        case .mono: return "Mono"
        }
    }
    /// nil keeps the system's own design.
    var design: Font.Design? {
        switch self {
        case .standard: return nil
        case .rounded: return .rounded
        case .serif: return .serif
        case .mono: return .monospaced
        }
    }
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
    /// Lock screen / CarPlay show ±seek-step buttons instead of previous/next track.
    @Published var lockScreenSkipButtons: Bool { didSet { save(lockScreenSkipButtons, "lockSkip") } }

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
    /// Remember a separate EQ for each output (AirPods, speaker, car…).
    @Published var eqPerDevice: Bool { didSet { save(eqPerDevice, "eqPerDev") } }
    /// Lower the EQ pre-amp automatically so boosted bands can't clip.
    @Published var eqAutoPreamp: Bool { didSet { save(eqAutoPreamp, "eqAutoPre") } }
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
    /// Kept for older settings screens; `reverbEngine` is what the audio uses.
    @Published var reverbUseFreeverb: Bool { didSet { save(reverbUseFreeverb, "revFv") } }
    @Published var reverbEngine: ReverbEngine { didSet { save(reverbEngine.rawValue, "revEngine") } }

    // MARK: Studio reverb (HallReverbUnit)

    @Published var studioPresetName: String { didSet { save(studioPresetName, "stPreset") } }
    @Published var studioMix: Double { didSet { save(studioMix, "stMix") } }                 // 0...1
    @Published var studioDecay: Double { didSet { save(studioDecay, "stDecay") } }           // s, 0.2...20
    @Published var studioSize: Double { didSet { save(studioSize, "stSize") } }              // 0...1
    @Published var studioPreDelayMS: Double { didSet { save(studioPreDelayMS, "stPre") } }   // ms, 0...250
    @Published var studioBassDecay: Double { didSet { save(studioBassDecay, "stBass") } }    // ×, 0.5...2
    @Published var studioTrebleDecay: Double { didSet { save(studioTrebleDecay, "stTreb") } }// ×, 0.1...1
    @Published var studioLowCut: Double { didSet { save(studioLowCut, "stLowCut") } }        // Hz, 20...600
    @Published var studioHighCut: Double { didSet { save(studioHighCut, "stHighCut") } }     // Hz, 1k...20k
    @Published var studioDiffusion: Double { didSet { save(studioDiffusion, "stDiff") } }    // 0...1
    @Published var studioModulation: Double { didSet { save(studioModulation, "stMod") } }   // 0...1
    @Published var studioEarly: Double { didSet { save(studioEarly, "stEarly") } }           // 0...1
    @Published var studioWidth: Double { didSet { save(studioWidth, "stWidth") } }           // 0...1
    /// Ducks the reverb under vocals (Studio and Classic engines). 0...1.
    @Published var reverbClarity: Double { didSet { save(reverbClarity, "revClarity") } }
    /// How far into the room the singer stands (Studio engine). 0...1.
    @Published var studioPresence: Double { didSet { save(studioPresence, "stPresence") } }
    /// Holds the current tail indefinitely. Deliberately not persisted.
    @Published var studioFreeze: Bool = false

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
    /// "#RRGGBB" accent chosen by the user; empty means use the theme's own.
    @Published var customAccentHex: String { didSet { save(customAccentHex, "accentHex") } }
    /// Shape of the Now Playing cover (Rounded, Square, Circle, Vinyl).
    @Published var artworkShape: ArtworkShape {
        didSet {
            save(artworkShape.rawValue, "artShape")
            // Older builds read this flag; keep it in step.
            save(artworkShape == .vinyl, "vinylArt")
        }
    }
    /// Show the Now Playing cover as a spinning vinyl record. Kept for older
    /// callers; it is now just one of the artwork shapes.
    var vinylArtwork: Bool {
        get { artworkShape == .vinyl }
        set {
            if newValue { artworkShape = .vinyl }
            else if artworkShape == .vinyl { artworkShape = .rounded }
        }
    }

    // MARK: Visual effects

    /// Slowly drifting colour glow behind the Now Playing screen.
    @Published var ambientBackground: Bool { didSet { save(ambientBackground, "ambientBG") } }
    /// Cover shrinks a little when paused and springs back when playing.
    @Published var breathingArtwork: Bool { didSet { save(breathingArtwork, "breatheArt") } }
    /// Coloured shadow under the cover, taken from the album colour.
    @Published var artworkGlow: Bool { didSet { save(artworkGlow, "artGlow") } }
    @Published var visualizerStyle: VisualizerStyle { didSet { save(visualizerStyle.rawValue, "vizStyle") } }
    @Published var fontStyle: FontStyle { didSet { save(fontStyle.rawValue, "fontStyle") } }
    /// Frosted-glass panels behind the player controls and mini player.
    @Published var glassControls: Bool { didSet { save(glassControls, "glassUI") } }

    // MARK: Battery

    @Published var powerMode: PowerMode { didSet { save(powerMode.rawValue, "powerMode") } }
    /// Mirrors iOS Low Power Mode so views can react when it flips.
    @Published private(set) var systemLowPowerMode: Bool = ProcessInfo.processInfo.isLowPowerModeEnabled

    /// True when Sonora should run in its lightest configuration.
    var batterySaverActive: Bool {
        switch powerMode {
        case .off: return false
        case .always: return true
        case .lowPowerOnly: return systemLowPowerMode
        }
    }

    /// Visualizer is shown only when the user wants it and battery saver is off.
    var visualizerAllowed: Bool { showVisualizer && !batterySaverActive }

    /// Screen stays awake only when asked for and battery saver is off.
    var effectiveKeepScreenAwake: Bool { keepScreenAwake && !batterySaverActive }

    private var powerObserver: NSObjectProtocol?

    // MARK: Sleep timer

    @Published var sleepFadeOut: Bool { didSet { save(sleepFadeOut, "sleepFade") } }
    @Published var sleepFadeSeconds: Double { didSet { save(sleepFadeSeconds, "sleepFadeSec") } }
    @Published var sleepFinishTrack: Bool { didSet { save(sleepFinishTrack, "sleepFinish") } }

    // MARK: - Init

    private init() {
        let d = UserDefaults.standard
        func b(_ k: String, _ def: Bool) -> Bool { d.object(forKey: k) == nil ? def : d.bool(forKey: k) }
        // A corrupted or hand-edited value (NaN, ±inf) must never reach the
        // audio engine or a Slider, both of which can trap on it.
        func n(_ k: String, _ def: Double) -> Double {
            guard d.object(forKey: k) != nil else { return def }
            let v = d.double(forKey: k)
            return v.isFinite ? v : def
        }
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
        lockScreenSkipButtons = b("lockSkip", false)

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
        eqPerDevice = b("eqPerDev", true)
        eqAutoPreamp = b("eqAutoPre", true)
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
        reverbEngine = ReverbEngine(rawValue: i("revEngine", ReverbEngine.studio.rawValue)) ?? .studio

        let studioDefault = StudioReverbPreset.chamber
        studioPresetName = s("stPreset", studioDefault.name)
        studioMix = n("stMix", studioDefault.mix)
        studioDecay = n("stDecay", studioDefault.decay)
        studioSize = n("stSize", studioDefault.size)
        studioPreDelayMS = n("stPre", studioDefault.preDelayMS)
        studioBassDecay = n("stBass", studioDefault.bassDecay)
        studioTrebleDecay = n("stTreb", studioDefault.trebleDecay)
        studioLowCut = n("stLowCut", studioDefault.lowCut)
        studioHighCut = n("stHighCut", studioDefault.highCut)
        studioDiffusion = n("stDiff", studioDefault.diffusion)
        studioModulation = n("stMod", studioDefault.modulation)
        studioEarly = n("stEarly", studioDefault.early)
        studioWidth = n("stWidth", studioDefault.width)
        reverbClarity = min(1, max(0, n("revClarity", 0.6)))
        studioPresence = min(1, max(0, n("stPresence", studioDefault.presence)))

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
        // Song lists start with the newest additions on top. Applied once,
        // to an existing installation too; after that whatever is chosen in
        // the list's sort menu is kept.
        if !d.bool(forKey: "trackSortNewestFirst.v1") {
            d.set(true, forKey: "trackSortNewestFirst.v1")
            d.set(TrackSort.dateAdded.rawValue, forKey: "trackSort")
            d.set(false, forKey: "trackSortAsc")
        }
        trackSort = TrackSort(rawValue: s("trackSort", "dateAdded")) ?? .dateAdded
        trackSortAscending = b("trackSortAsc", false)
        minimumTrackSeconds = n("minTrackSec", 0)
        downloadMissingArtwork = b("artDownload", true)

        themeID = s("themeID", "ember")
        useAlbumArtColors = b("artColors", true)
        showWaveformSeekBar = b("waveform", true)
        showVisualizer = b("visualizer", true)
        blurredArtBackground = b("blurBG", true)
        keepScreenAwake = b("awake", false)
        customAccentHex = s("accentHex", "")
        // Users who had the old vinyl switch on keep their record.
        artworkShape = ArtworkShape(rawValue: i("artShape", b("vinylArt", false)
                                                ? ArtworkShape.vinyl.rawValue
                                                : ArtworkShape.rounded.rawValue)) ?? .rounded
        ambientBackground = b("ambientBG", false)
        breathingArtwork = b("breatheArt", true)
        artworkGlow = b("artGlow", false)
        visualizerStyle = VisualizerStyle(rawValue: i("vizStyle", 0)) ?? .bars
        fontStyle = FontStyle(rawValue: i("fontStyle", 0)) ?? .standard
        glassControls = b("glassUI", false)
        powerMode = PowerMode(rawValue: i("powerMode", PowerMode.always.rawValue)) ?? .always

        sleepFadeOut = b("sleepFade", true)
        sleepFadeSeconds = n("sleepFadeSec", 20)
        sleepFinishTrack = b("sleepFinish", false)

        powerObserver = NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.systemLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        }
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
        // Presets saved by older versions may carry a different band count;
        // pad or trim to the ten bands the engine and UI expect.
        var bands = preset.bands
        let flat = EQPreset.flatBands()
        if bands.count < flat.count { bands.append(contentsOf: flat[bands.count...]) }
        if bands.count > flat.count { bands = Array(bands.prefix(flat.count)) }
        eqBands = bands
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
        apply(studioPreset: .chamber)
        studioFreeze = false
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

    // MARK: - Studio reverb presets

    /// Rooms for the Studio engine. Values are Sonora's own, tuned by ear
    /// against what each space should feel like: decay in seconds (RT60),
    /// bass/treble decay as multiples of it, filters in Hz.
    struct StudioReverbPreset: Identifiable, Hashable {
        let name: String
        let symbol: String
        let decay: Double
        let size: Double
        let preDelayMS: Double
        let bassDecay: Double
        let trebleDecay: Double
        let lowCut: Double
        let highCut: Double
        let diffusion: Double
        let modulation: Double
        let early: Double
        let width: Double
        let mix: Double

        var id: String { name }

        /// How far into the room the singer stands for this preset: small
        /// dead rooms keep the voice close, big live spaces place it deep
        /// inside the room.
        var presence: Double {
            switch name {
            case "Vocal Booth": return 0.3
            case "Drum Room": return 0.45
            case "Small Room": return 0.55
            case "Ambience": return 0.5
            case "Chamber": return 0.75
            case "Vocal Plate": return 0.5
            case "Bright Plate": return 0.5
            case "Concert Hall": return 0.7
            case "Warm Hall": return 0.7
            case "Arena": return 0.65
            case "Cathedral": return 0.85
            case "Dark Space": return 0.75
            case "Infinite": return 0.6
            default: return 0.6
            }
        }

        static let booth = StudioReverbPreset(name: "Vocal Booth", symbol: "mic",
            decay: 0.45, size: 0.15, preDelayMS: 0, bassDecay: 1.0, trebleDecay: 0.6,
            lowCut: 120, highCut: 10_000, diffusion: 0.6, modulation: 0.1,
            early: 0.6, width: 0.7, mix: 0.18)
        static let drumRoom = StudioReverbPreset(name: "Drum Room", symbol: "music.note",
            decay: 0.7, size: 0.25, preDelayMS: 3, bassDecay: 1.0, trebleDecay: 0.55,
            lowCut: 90, highCut: 9_000, diffusion: 0.7, modulation: 0.15,
            early: 0.7, width: 0.9, mix: 0.25)
        static let smallRoom = StudioReverbPreset(name: "Small Room", symbol: "square",
            decay: 0.9, size: 0.3, preDelayMS: 5, bassDecay: 1.1, trebleDecay: 0.5,
            lowCut: 80, highCut: 8_000, diffusion: 0.75, modulation: 0.2,
            early: 0.55, width: 0.85, mix: 0.25)
        static let ambience = StudioReverbPreset(name: "Ambience", symbol: "sparkles",
            decay: 1.2, size: 0.5, preDelayMS: 10, bassDecay: 1.0, trebleDecay: 0.6,
            lowCut: 150, highCut: 11_000, diffusion: 0.85, modulation: 0.5,
            early: 0.2, width: 1.0, mix: 0.2)
        static let chamber = StudioReverbPreset(name: "Chamber", symbol: "building.columns",
            decay: 1.6, size: 0.45, preDelayMS: 15, bassDecay: 1.2, trebleDecay: 0.55,
            lowCut: 70, highCut: 9_000, diffusion: 0.8, modulation: 0.3,
            early: 0.45, width: 1.0, mix: 0.3)
        static let vocalPlate = StudioReverbPreset(name: "Vocal Plate", symbol: "waveform",
            decay: 1.8, size: 0.35, preDelayMS: 12, bassDecay: 0.9, trebleDecay: 0.75,
            lowCut: 180, highCut: 12_000, diffusion: 0.9, modulation: 0.3,
            early: 0.15, width: 1.0, mix: 0.28)
        static let brightPlate = StudioReverbPreset(name: "Bright Plate", symbol: "sun.max",
            decay: 2.2, size: 0.4, preDelayMS: 8, bassDecay: 0.8, trebleDecay: 0.9,
            lowCut: 250, highCut: 16_000, diffusion: 0.95, modulation: 0.45,
            early: 0.1, width: 1.0, mix: 0.3)
        static let concertHall = StudioReverbPreset(name: "Concert Hall", symbol: "music.mic",
            decay: 2.6, size: 0.7, preDelayMS: 25, bassDecay: 1.35, trebleDecay: 0.45,
            lowCut: 60, highCut: 8_000, diffusion: 0.85, modulation: 0.35,
            early: 0.4, width: 1.0, mix: 0.32)
        static let warmHall = StudioReverbPreset(name: "Warm Hall", symbol: "flame",
            decay: 3.2, size: 0.75, preDelayMS: 30, bassDecay: 1.6, trebleDecay: 0.3,
            lowCut: 50, highCut: 6_000, diffusion: 0.85, modulation: 0.4,
            early: 0.35, width: 1.0, mix: 0.33)
        static let arena = StudioReverbPreset(name: "Arena", symbol: "sportscourt",
            decay: 4.5, size: 1.0, preDelayMS: 70, bassDecay: 1.3, trebleDecay: 0.4,
            lowCut: 60, highCut: 7_500, diffusion: 0.8, modulation: 0.35,
            early: 0.5, width: 1.0, mix: 0.35)
        static let cathedral = StudioReverbPreset(name: "Cathedral", symbol: "building",
            decay: 6.5, size: 0.95, preDelayMS: 45, bassDecay: 1.5, trebleDecay: 0.35,
            lowCut: 40, highCut: 7_000, diffusion: 0.9, modulation: 0.5,
            early: 0.3, width: 1.0, mix: 0.38)
        static let darkSpace = StudioReverbPreset(name: "Dark Space", symbol: "moon.stars",
            decay: 8.0, size: 0.9, preDelayMS: 60, bassDecay: 1.8, trebleDecay: 0.2,
            lowCut: 40, highCut: 4_500, diffusion: 0.9, modulation: 0.6,
            early: 0.2, width: 1.0, mix: 0.4)
        static let infinite = StudioReverbPreset(name: "Infinite", symbol: "infinity",
            decay: 12.0, size: 0.9, preDelayMS: 20, bassDecay: 1.2, trebleDecay: 0.6,
            lowCut: 80, highCut: 10_000, diffusion: 1.0, modulation: 0.7,
            early: 0.1, width: 1.0, mix: 0.4)

        static let all: [StudioReverbPreset] = [booth, drumRoom, smallRoom, ambience,
                                                chamber, vocalPlate, brightPlate,
                                                concertHall, warmHall, arena,
                                                cathedral, darkSpace, infinite]
    }

    func apply(studioPreset p: StudioReverbPreset) {
        studioDecay = p.decay
        studioSize = p.size
        studioPreDelayMS = p.preDelayMS
        studioBassDecay = p.bassDecay
        studioTrebleDecay = p.trebleDecay
        studioLowCut = p.lowCut
        studioHighCut = p.highCut
        studioDiffusion = p.diffusion
        studioModulation = p.modulation
        studioEarly = p.early
        studioWidth = p.width
        studioMix = p.mix
        studioPresence = p.presence
        studioPresetName = p.name
    }

    /// Name shown for the active reverb, whichever engine is in use.
    var activeReverbName: String {
        reverbEngine == .studio ? studioPresetName : reverbPresetName
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
