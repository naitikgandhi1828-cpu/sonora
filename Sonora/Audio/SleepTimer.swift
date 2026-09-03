//
//  SleepTimer.swift
//  Sonora
//

import Foundation
import Combine

final class SleepTimer: ObservableObject {

    @Published private(set) var isActive = false
    @Published private(set) var remaining: TimeInterval = 0
    @Published private(set) var totalDuration: TimeInterval = 0
    /// When set, the timer waits for the current track to end before stopping.
    @Published var finishTrackFirst = false

    /// Called with a 0...1 fade multiplier during the fade-out window, then
    /// with `nil` when the timer expires and playback should stop.
    var onFade: ((Double) -> Void)?
    var onExpire: (() -> Void)?

    private var timer: Timer?
    private var endDate: Date?
    private var fadeSeconds: Double = 0

    func start(minutes: Double, fadeSeconds: Double, finishTrack: Bool) {
        cancel()
        let duration = max(10, minutes * 60)
        totalDuration = duration
        remaining = duration
        self.fadeSeconds = max(0, fadeSeconds)
        finishTrackFirst = finishTrack
        endDate = Date().addingTimeInterval(duration)
        isActive = true

        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func extend(minutes: Double) {
        guard isActive, let end = endDate else { return }
        endDate = end.addingTimeInterval(minutes * 60)
        totalDuration += minutes * 60
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
        endDate = nil
        isActive = false
        remaining = 0
        onFade?(1)
    }

    private func tick() {
        guard let end = endDate else { return }
        remaining = max(0, end.timeIntervalSinceNow)

        if fadeSeconds > 0 && remaining <= fadeSeconds {
            onFade?(max(0, remaining / fadeSeconds))
        }

        if remaining <= 0 {
            timer?.invalidate()
            timer = nil
            isActive = false
            endDate = nil
            onExpire?()
        }
    }

    var formattedRemaining: String {
        let total = Int(remaining.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s)
                     : String(format: "%d:%02d", m, s)
    }

    static let presets: [Double] = [5, 10, 15, 20, 30, 45, 60, 90, 120]
}
