//
//  SonoraApp.swift
//  Sonora
//
//  An offline, folder-first music player for iOS with a full DSP chain.
//

import SwiftUI
import AVFoundation

@main
struct SonoraApp: App {

    @StateObject private var settings: AppSettings
    @StateObject private var library: MediaLibrary
    @StateObject private var player: PlaybackController
    @StateObject private var themes: ThemeManager
    @StateObject private var artwork: ArtworkFinder

    @Environment(\.scenePhase) private var scenePhase

    init() {
        // The audio session has to exist before the engine is built.
        AudioSessionManager.shared.activate()

        let settings = AppSettings.shared
        let library = MediaLibrary(settings: settings)
        let player = PlaybackController(library: library, settings: settings)
        let themes = ThemeManager(settings: settings)
        let artwork = ArtworkFinder(settings: settings, library: library)
        player.artworkFinder = artwork

        _settings = StateObject(wrappedValue: settings)
        _library = StateObject(wrappedValue: library)
        _player = StateObject(wrappedValue: player)
        _themes = StateObject(wrappedValue: themes)
        _artwork = StateObject(wrappedValue: artwork)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(settings)
                .environmentObject(library)
                .environmentObject(player)
                .environmentObject(themes)
                .environmentObject(artwork)
                .task {
                    // Pick up anything the user dropped in through the Files app.
                    await library.importDocumentsFolder()
                }
                .onOpenURL { url in
                    Task { await library.importFiles(urls: [url]) }
                }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background, .inactive:
                player.persistNow()
                library.save()
            case .active:
                AudioSessionManager.shared.activate()
            @unknown default:
                break
            }
        }
    }
}
