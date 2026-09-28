//
//  EQRouteMemory.swift
//  Sonora
//
//  Remembers a separate equalizer for each audio output (AirPods, the phone
//  speaker, the car…) and swaps it in when the route changes.
//
//  Only active while `AppSettings.eqPerDevice` is on. The current route's
//  label is always kept up to date so the Equalizer screen can show which
//  output it is editing.
//

import Foundation
import AVFoundation
import Combine
import UIKit

/// One output's saved equalizer.
struct EQRouteSnapshot: Codable, Equatable {
    var enabled: Bool
    var preampDB: Double
    var bands: [EQBand]
    var presetName: String
}

@MainActor
final class EQRouteMemory: ObservableObject {

    static let shared = EQRouteMemory()

    /// Friendly name of the current output, e.g. "AirPods Pro" or "iPhone Speaker".
    @Published private(set) var currentRouteLabel: String = "Output"

    private var settings: AppSettings?
    private var currentKey: String = ""
    private var snapshots: [String: EQRouteSnapshot] = [:]
    /// True while a saved EQ is being written into AppSettings.
    private var isApplying = false
    private var cancellables = Set<AnyCancellable>()
    private var routeObserver: NSObjectProtocol?

    private static let storageKey = "eqRouteSnapshots"

    private init() {}

    // MARK: - Lifecycle

    /// Starts tracking the output route. Safe to call more than once.
    func start(settings: AppSettings) {
        guard self.settings == nil else { return }
        self.settings = settings
        snapshots = Self.loadSnapshots()

        let route = Self.currentRoute()
        currentRouteLabel = route.label
        if let key = route.key {
            currentKey = key
            if settings.eqPerDevice {
                if let saved = snapshots[key] {
                    apply(saved)
                } else {
                    saveCurrent()
                }
            }
        }

        routeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.routeDidChange()
            }
        }

        // Save the EQ under the current output whenever it is edited.
        // `dropFirst` skips the value @Published replays on subscription;
        // the debounce both coalesces slider drags and lets the property
        // finish assigning (@Published emits from willSet).
        let edits: [AnyPublisher<Void, Never>] = [
            settings.$eqEnabled.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            settings.$eqPreampDB.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            settings.$eqBands.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            settings.$selectedPresetName.dropFirst().map { _ in () }.eraseToAnyPublisher()
        ]
        Publishers.MergeMany(edits)
            .debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.settingsDidChange()
                }
            }
            .store(in: &cancellables)

        // Turning per-device EQ on adopts the current EQ for this output.
        settings.$eqPerDevice
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.perDeviceDidChange()
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Events

    private func routeDidChange() {
        guard let settings else { return }
        let route = Self.currentRoute()
        // Mid-switch the route can briefly have no outputs; wait for the real one.
        guard let newKey = route.key else { return }
        currentRouteLabel = route.label
        guard newKey != currentKey else { return }

        let oldKey = currentKey
        if settings.eqPerDevice, !oldKey.isEmpty {
            // Save under the output we are leaving before anything changes.
            store(snapshotOf(settings), for: oldKey)
        }
        currentKey = newKey

        guard settings.eqPerDevice else { return }
        if let saved = snapshots[newKey] {
            apply(saved)
        } else {
            // First time on this output: start from the EQ in use now.
            saveCurrent()
        }
    }

    private func settingsDidChange() {
        guard !isApplying, let settings, settings.eqPerDevice else { return }
        saveCurrent()
    }

    private func perDeviceDidChange() {
        guard let settings, settings.eqPerDevice else { return }
        saveCurrent()
    }

    // MARK: - Snapshots

    private func snapshotOf(_ settings: AppSettings) -> EQRouteSnapshot {
        EQRouteSnapshot(enabled: settings.eqEnabled,
                        preampDB: settings.eqPreampDB,
                        bands: settings.eqBands,
                        presetName: settings.selectedPresetName)
    }

    private func saveCurrent() {
        guard let settings, !currentKey.isEmpty else { return }
        store(snapshotOf(settings), for: currentKey)
    }

    private func store(_ snapshot: EQRouteSnapshot, for key: String) {
        // Skipping identical writes also stops a just-loaded EQ from being
        // written straight back when its change notifications arrive.
        guard snapshots[key] != snapshot else { return }
        snapshots[key] = snapshot
        if let data = try? JSONEncoder().encode(snapshots) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }

    private func apply(_ snapshot: EQRouteSnapshot) {
        guard let settings,
              snapshot.bands.count == EQPreset.standardFrequencies.count else { return }
        isApplying = true
        defer { isApplying = false }
        if settings.eqBands != snapshot.bands { settings.eqBands = snapshot.bands }
        if settings.eqPreampDB != snapshot.preampDB { settings.eqPreampDB = snapshot.preampDB }
        if settings.selectedPresetName != snapshot.presetName { settings.selectedPresetName = snapshot.presetName }
        if settings.eqEnabled != snapshot.enabled { settings.eqEnabled = snapshot.enabled }
    }

    private static func loadSnapshots() -> [String: EQRouteSnapshot] {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([String: EQRouteSnapshot].self, from: data)
        else { return [:] }
        return decoded
    }

    // MARK: - Route identity

    /// Stable key ("BluetoothA2DPOutput|AirPods Pro") and display label for
    /// the current output. The key is nil when there is no output right now.
    private static func currentRoute() -> (key: String?, label: String) {
        guard let port = AVAudioSession.sharedInstance().currentRoute.outputs.first else {
            return (nil, "Output")
        }
        let key = "\(port.portType.rawValue)|\(port.portName)"
        return (key, label(for: port))
    }

    private static func label(for port: AVAudioSessionPortDescription) -> String {
        let device = UIDevice.current.model   // "iPhone" / "iPad"
        switch port.portType {
        case .builtInSpeaker:
            return "\(device) Speaker"
        case .builtInReceiver:
            return "\(device) Earpiece"
        case .headphones:
            return port.portName.isEmpty ? "Headphones" : port.portName
        default:
            return port.portName.isEmpty ? "Output" : port.portName
        }
    }
}
