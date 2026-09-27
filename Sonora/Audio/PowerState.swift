//
//  PowerState.swift
//  Sonora
//
//  Tiny helpers for battery-aware behaviour, plus the small observable model
//  that carries the playhead (meter levels live in MeterState).
//
//  Keeping fast-changing values off `PlaybackController` matters: every view
//  that observes the controller re-renders whenever one of its @Published
//  properties changes. Splitting them out means only the seek bar and the
//  visualizer redraw while music plays — not the whole app.
//

import Foundation
import UIKit
import Combine

enum PowerState {

    /// Call once at launch; `batteryState` reads `.unknown` until enabled.
    @MainActor
    static func startMonitoring() {
        UIDevice.current.isBatteryMonitoringEnabled = true
    }

    /// True while the phone is plugged in. Heavy one-off work (waveform and
    /// loudness analysis) is deferred to these moments under battery saver.
    @MainActor
    static var isCharging: Bool {
        switch UIDevice.current.batteryState {
        case .charging, .full: return true
        default: return false
        }
    }

    /// Whether heavy background analysis may run right now.
    @MainActor
    static func mayRunHeavyWork(settings: AppSettings) -> Bool {
        !settings.batterySaverActive || isCharging
    }
}

/// Playhead position and duration. Only progress views observe this.
@MainActor
final class PlaybackClock: ObservableObject {
    @Published private(set) var position: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0

    func update(position: TimeInterval, duration: TimeInterval) {
        // Skip sub-10ms changes so an unchanged playhead never triggers a redraw.
        if abs(self.position - position) >= 0.01 { self.position = position }
        if abs(self.duration - duration) >= 0.01 { self.duration = duration }
    }
}
