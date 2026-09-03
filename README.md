# Sonora

A folder-first offline music player for iPhone, built with SwiftUI and
AVAudioEngine. Written from scratch — original UI, original code.

Feature-wise it aims at the class of player Poweramp occupies on Android:
gapless playback, a real DSP rack (10-band parametric EQ, reverb, tone,
stereo width, limiter), replay gain, cue-sheet support, folder browsing and
a waveform seek bar.

---

## Build & install (sideload)

> **On Windows?** See [INSTALL-WINDOWS.md](INSTALL-WINDOWS.md) — GitHub Actions
> builds the IPA on a hosted Mac for free, and AltStore installs it from your
> PC. No Mac required. The workflow is already in `.github/workflows/`.


**Requirements:** macOS with Xcode 16 or newer, an iPhone running iOS 17+,
and any Apple ID (a paid developer account is not required).

1. Open `Sonora.xcodeproj` in Xcode.
2. Select the **Sonora** target → **Signing & Capabilities**.
   - Tick **Automatically manage signing**.
   - Pick your Apple ID under **Team** (add one via Xcode → Settings → Accounts).
   - Change **Bundle Identifier** from `com.example.Sonora` to something
     unique, e.g. `com.yourname.sonora`. Free provisioning rejects
     identifiers already in use.
3. Plug in your iPhone, select it as the run destination, press ⌘R.
4. On the phone: **Settings → General → VPN & Device Management** → trust
   your developer certificate.

With a free Apple ID the app expires after 7 days; rebuild to renew. A paid
account ($99/yr) extends that to a year, and lets you install over the air
with tools like AltStore or SideStore.

### Getting music in

Three routes, all handled by the app:

- **Add Folder** (Library tab → **+**): pick any folder in the Files app —
  iCloud Drive, "On My iPhone", or an external USB-C/Lightning drive. Sonora
  keeps a security-scoped bookmark and reads the files in place. Nothing is
  copied or duplicated.
- **Add Files**: import individual tracks.
- **Files app**: the app exposes its own *Sonora* folder under "On My
  iPhone". Drag music in there and it is picked up on next launch.

---

## What's inside

```
Sonora/
├── App/          SonoraApp.swift — entry point, dependency wiring
├── Audio/
│   ├── PlaybackEngine.swift    AVAudioEngine graph + sample-accurate scheduler
│   ├── PlaybackController.swift Queue, shuffle/repeat, resume state
│   ├── DSPChain.swift          Effect nodes bound to settings
│   ├── SonoraDSPUnit.swift     Custom AUAudioUnit: pre-amp, width, balance, limiter
│   ├── ReverbUnit.swift        AUReverb2 with an AVAudioUnitReverb fallback
│   ├── AudioSessionManager.swift  Category, routes, interruptions
│   ├── AudioAnalysis.swift     Waveform peaks + loudness measurement
│   ├── NowPlayingCenter.swift  Lock screen / Control Center
│   └── SleepTimer.swift
├── Library/
│   ├── Models.swift            Track, FolderRoot, Playlist, aggregates
│   ├── MediaLibrary.swift      The observable store + persistence
│   ├── LibraryIndexer.swift    Folder walk, tag reads, progress
│   ├── MetadataReader.swift    Tags, artwork, technical info
│   ├── PlaylistParsers.swift   .cue and .m3u
│   ├── ArtworkStore.swift      Disk + memory art cache
│   └── FolderAccessManager.swift  Security-scoped bookmarks
├── Settings/     AppSettings.swift, EQPreset.swift (23 built-in presets)
├── UI/
│   ├── Player/   NowPlayingView, MiniPlayerView, WaveformSeekBar, QueueView
│   ├── Browse/   LibraryHomeView, BrowseViews, SearchView
│   ├── DSP/      EqualizerView, DSPHomeView (effects, output, sleep timer)
│   ├── Common/   Theme.swift (7 themes), Components.swift
│   ├── RootView.swift
│   └── SettingsView.swift
└── Resources/    Assets.xcassets
```

### Signal chain

```
playerA ─┐
         ├─▶ sourceMixer ─▶ EQ ─▶ Tone ─▶ Reverb ─▶ TimePitch ─▶ SonoraDSP ─▶ out
playerB ─┘   crossfade,     10-band  bass/     wet mix    rate/       pre-amp, width,
             replay gain    parametric treble              pitch       balance, limiter
```

**Gapless** works by scheduling the next file onto the *same* player node
immediately behind the current one, so the engine never stops. Position is
derived from the node's sample clock against a list of scheduled segments,
which is what makes track transitions frame-accurate. Chaining is skipped
when the next file has a different sample rate or channel count — that case
needs a reconnect, so it falls back to a normal transition.

**Crossfade** uses the second player node with an equal-power volume ramp.

**SonoraDSPUnit** is a real in-process Audio Unit. Its render block is
realtime-safe: it pulls into pre-allocated buffers, touches only a malloc'd
parameter struct, and never allocates or retains on the audio thread.

---

## Where iOS differs from Android

Worth knowing up front, because a few things genuinely cannot work the same way:

| | Android | iOS / this app |
|---|---|---|
| Filesystem | Free-roaming SD card scan | Sandboxed; user grants folders via Files, stored as bookmarks |
| Codecs | Ships its own decoders (Opus, APE, WMA, DSD, WavPack…) | Uses the system decoders: MP3, AAC/M4A, ALAC, FLAC, WAV, AIFF, CAF |
| Output | Direct hardware sample-rate control | Sonora *requests* the file's native rate; iOS grants it when the route allows (Bluetooth usually won't) |
| System EQ hooks | Global audio effects | Per-app only |

Unsupported files are counted during a scan and reported, rather than
silently ignored.

### Adding more codecs

To play Opus, WMA, APE, WavPack or DSD you need a decoder in the app. The
practical path is to vendor **FFmpeg** (or `libopus` + `libFLAC` alone, which
is far lighter) as an xcframework, decode into `AVAudioPCMBuffer`s and
schedule those on the player node with `scheduleBuffer` instead of
`scheduleSegment`. `PlaybackEngine` is structured so this is a contained
change: everything downstream of the player node stays identical.

Note the licensing: FFmpeg is LGPL/GPL depending on build flags. Fine for
personal sideloading; read the terms carefully before distributing.

---

## Not implemented yet

These need extra targets or entitlements Apple gates:

- **CarPlay** — needs the `com.apple.developer.playable-content` audio
  entitlement, which Apple grants by application only. Lock screen and
  Control Center already work everywhere via `MPRemoteCommandCenter`.
- **Home screen widgets / Live Activity** — needs a WidgetKit extension
  target. The now-playing data is already centralised in `NowPlayingCenter`,
  so an App Group plus a widget target is the whole job.
- **Tag editing**, **scrobbling**, **visualiser presets beyond the spectrum
  bars**, **folder-level bookmarks for audiobooks**.

---

## Notes on behaviour

- **Replay gain** reads `REPLAYGAIN_TRACK_GAIN` / `_ALBUM_GAIN` tags. Tracks
  with no tags can be measured on first play (Settings → Sound → Output);
  the measurement is a mean-square approximation, not full EBU R128.
- **Cue sheets** become virtual tracks pointing at byte ranges of one file.
  Seeking, gapless and the waveform all respect the range.
- **Waveforms** are computed once per track in the background and cached in
  `Caches/Waveforms`. Clearing the cache is safe.
- **Library index** lives in Application Support as JSON. Erasing it never
  touches your audio files.
- The **limiter** is on by default and worth leaving on — a +12 dB bass
  preset will clip without it.
