//
//  SonoraApp.swift
//  Sonora
//
//  An offline, folder-first music player for iOS with a full DSP chain.
//

import SwiftUI
import UIKit
import AVFoundation
import UserNotifications

@main
struct SonoraApp: App {

    @StateObject private var settings: AppSettings
    @StateObject private var library: MediaLibrary
    @StateObject private var player: PlaybackController
    @StateObject private var themes: ThemeManager
    @StateObject private var artwork: ArtworkFinder

    @Environment(\.scenePhase) private var scenePhase

    init() {
        // The audio session category has to be set before the engine is
        // built. It is only *activated* when something plays, so opening
        // Sonora never stops another app's music.
        AudioSessionManager.shared.configure()
        PowerState.startMonitoring()
        UNUserNotificationCenter.current().delegate = ForegroundNotifications.shared
        // Tell iOS up front that Sonora takes remote-control events (lock
        // screen, headphones, car head units, CarPlay's Now Playing).
        UIApplication.shared.beginReceivingRemoteControlEvents()

        let settings = AppSettings.shared
        let library = MediaLibrary(settings: settings)
        let player = PlaybackController(library: library, settings: settings)
        let themes = ThemeManager(settings: settings)
        let artwork = ArtworkFinder(settings: settings, library: library)
        player.artworkFinder = artwork

        // Non-SwiftUI consumers (CarPlay) reach the same instances through this.
        AppServices.library = library
        AppServices.player = player

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
                // Refresh the route only; activating here would interrupt
                // Spotify or YouTube every time you switch to Sonora.
                AudioSessionManager.shared.configure()
                // Confirms an update from the laptop and keeps the expiry reminders up to date.
                SigningStatus.requestPermission()
                SigningStatus.check()
            @unknown default:
                break
            }
        }
    }
}
