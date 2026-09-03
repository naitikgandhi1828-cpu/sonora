//
//  AudioSessionManager.swift
//  Sonora
//
//  Owns AVAudioSession: category, route changes, interruptions and the
//  hardware sample rate we try to match for bit-transparent playback.
//

import Foundation
import AVFoundation
import Combine

final class AudioSessionManager: ObservableObject {

    static let shared = AudioSessionManager()

    @Published private(set) var currentRouteName: String = "Output"
    @Published private(set) var isHeadphonesConnected: Bool = false
    @Published private(set) var hardwareSampleRate: Double = 48_000
    @Published private(set) var outputLatency: Double = 0

    /// Called when the system interrupts us (phone call, other app).
    var onInterruptionBegan: (() -> Void)?
    /// `shouldResume` is true when the system says we may pick up again.
    var onInterruptionEnded: ((Bool) -> Void)?
    /// Old device was unplugged; the caller usually pauses.
    var onOldDeviceUnavailable: (() -> Void)?
    var onNewDeviceAvailable: (() -> Void)?
    /// Sample rate or channel layout changed under us; the engine must rebuild.
    var onRouteConfigurationChanged: (() -> Void)?

    private var observers: [NSObjectProtocol] = []

    private init() {}

    func activate() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback,
                                    mode: .default,
                                    policy: .longFormAudio,
                                    options: [])
            try session.setActive(true, options: [])
        } catch {
            print("[AudioSession] activation failed: \(error)")
        }
        registerObservers()
        refreshRoute()
    }

    func deactivate() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Ask the hardware to run at the file's native rate so Core Audio does
    /// not have to resample. iOS may refuse; we simply take what we get.
    @discardableResult
    func preferSampleRate(_ rate: Double) -> Double {
        let session = AVAudioSession.sharedInstance()
        guard rate > 0 else { return session.sampleRate }
        if abs(session.sampleRate - rate) < 1 { return session.sampleRate }
        do {
            try session.setPreferredSampleRate(rate)
        } catch {
            print("[AudioSession] preferred rate \(rate) rejected: \(error)")
        }
        hardwareSampleRate = session.sampleRate
        return session.sampleRate
    }

    func preferIOBufferDuration(_ seconds: Double) {
        try? AVAudioSession.sharedInstance().setPreferredIOBufferDuration(seconds)
    }

    // MARK: - Notifications

    private func registerObservers() {
        guard observers.isEmpty else { return }
        let nc = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()

        observers.append(nc.addObserver(forName: AVAudioSession.interruptionNotification,
                                        object: session, queue: .main) { [weak self] note in
            self?.handleInterruption(note)
        })

        observers.append(nc.addObserver(forName: AVAudioSession.routeChangeNotification,
                                        object: session, queue: .main) { [weak self] note in
            self?.handleRouteChange(note)
        })

        observers.append(nc.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification,
                                        object: session, queue: .main) { [weak self] _ in
            self?.activate()
            self?.onRouteConfigurationChanged?()
        })
    }

    private func handleInterruption(_ note: Notification) {
        guard let info = note.userInfo,
              let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }

        switch type {
        case .began:
            onInterruptionBegan?()
        case .ended:
            var shouldResume = false
            if let optRaw = info[AVAudioSessionInterruptionOptionKey] as? UInt {
                shouldResume = AVAudioSession.InterruptionOptions(rawValue: optRaw).contains(.shouldResume)
            }
            try? AVAudioSession.sharedInstance().setActive(true)
            onInterruptionEnded?(shouldResume)
        @unknown default:
            break
        }
    }

    private func handleRouteChange(_ note: Notification) {
        refreshRoute()
        guard let info = note.userInfo,
              let raw = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }

        switch reason {
        case .oldDeviceUnavailable:
            onOldDeviceUnavailable?()
        case .newDeviceAvailable:
            onNewDeviceAvailable?()
        case .routeConfigurationChange, .override, .categoryChange:
            onRouteConfigurationChanged?()
        default:
            break
        }
    }

    private func refreshRoute() {
        let session = AVAudioSession.sharedInstance()
        let outputs = session.currentRoute.outputs
        currentRouteName = outputs.first?.portName ?? "Output"
        hardwareSampleRate = session.sampleRate
        outputLatency = session.outputLatency

        let wiredOrWireless: Set<AVAudioSession.Port> = [
            .headphones, .bluetoothA2DP, .bluetoothLE, .bluetoothHFP,
            .usbAudio, .airPlay, .lineOut, .HDMI
        ]
        isHeadphonesConnected = outputs.contains { wiredOrWireless.contains($0.portType) }
    }

    var routeSymbol: String {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        guard let port = outputs.first else { return "speaker.wave.2" }
        switch port.portType {
        case .headphones, .headsetMic: return "headphones"
        case .bluetoothA2DP, .bluetoothLE, .bluetoothHFP: return "airpods"
        case .airPlay: return "airplayaudio"
        case .usbAudio: return "cable.connector"
        case .HDMI: return "tv"
        case .builtInSpeaker: return "speaker.wave.2.fill"
        default: return "speaker.wave.2"
        }
    }
}
