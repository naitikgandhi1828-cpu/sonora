//
//  AppServices.swift
//  Sonora
//
//  A tiny registry so code that lives outside the SwiftUI view tree (the
//  CarPlay scene delegate, for one) can reach the app's long-lived objects.
//  SonoraApp.init assigns these right after it creates them, before any
//  scene — phone or CarPlay — connects.
//

import Foundation

@MainActor
enum AppServices {
    static var player: PlaybackController?
    static var library: MediaLibrary?
}
