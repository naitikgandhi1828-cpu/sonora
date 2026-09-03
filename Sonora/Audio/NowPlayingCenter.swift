//
//  NowPlayingCenter.swift
//  Sonora
//
//  Lock screen / Control Center metadata and remote command handling.
//

import Foundation
import MediaPlayer
import UIKit

final class NowPlayingCenter {

    static let shared = NowPlayingCenter()

    var onPlay: (() -> Void)?
    var onPause: (() -> Void)?
    var onToggle: (() -> Void)?
    var onNext: (() -> Void)?
    var onPrevious: (() -> Void)?
    var onSeek: ((TimeInterval) -> Void)?
    var onSkipForward: ((TimeInterval) -> Void)?
    var onSkipBackward: ((TimeInterval) -> Void)?
    var onChangeRating: ((Int) -> Void)?

    private var configured = false
    private var lastArtworkKey: String?
    private var cachedArtwork: MPMediaItemArtwork?

    private init() {}

    func configure(skipInterval: TimeInterval) {
        guard !configured else { return }
        configured = true

        let c = MPRemoteCommandCenter.shared()

        c.playCommand.addTarget { [weak self] _ in self?.onPlay?(); return .success }
        c.pauseCommand.addTarget { [weak self] _ in self?.onPause?(); return .success }
        c.togglePlayPauseCommand.addTarget { [weak self] _ in self?.onToggle?(); return .success }
        c.nextTrackCommand.addTarget { [weak self] _ in self?.onNext?(); return .success }
        c.previousTrackCommand.addTarget { [weak self] _ in self?.onPrevious?(); return .success }

        c.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self?.onSeek?(e.positionTime)
            return .success
        }

        c.skipForwardCommand.preferredIntervals = [NSNumber(value: skipInterval)]
        c.skipBackwardCommand.preferredIntervals = [NSNumber(value: skipInterval)]
        c.skipForwardCommand.addTarget { [weak self] event in
            guard let e = event as? MPSkipIntervalCommandEvent else { return .commandFailed }
            self?.onSkipForward?(e.interval)
            return .success
        }
        c.skipBackwardCommand.addTarget { [weak self] event in
            guard let e = event as? MPSkipIntervalCommandEvent else { return .commandFailed }
            self?.onSkipBackward?(e.interval)
            return .success
        }

        c.ratingCommand.minimumRating = 0
        c.ratingCommand.maximumRating = 5
        c.ratingCommand.addTarget { [weak self] event in
            guard let e = event as? MPRatingCommandEvent else { return .commandFailed }
            self?.onChangeRating?(Int(e.rating))
            return .success
        }

        // Commands we do not implement should be explicitly disabled so the
        // lock screen does not show dead buttons.
        c.seekForwardCommand.isEnabled = false
        c.seekBackwardCommand.isEnabled = false
        c.changeShuffleModeCommand.isEnabled = false
        c.changeRepeatModeCommand.isEnabled = false
    }

    func update(track: Track?,
                artwork: UIImage?,
                position: TimeInterval,
                duration: TimeInterval,
                rate: Double,
                queueIndex: Int?,
                queueCount: Int?) {

        guard let track else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.displayTitle,
            MPMediaItemPropertyArtist: track.displayArtist,
            MPMediaItemPropertyAlbumTitle: track.displayAlbum,
            MPMediaItemPropertyAlbumArtist: track.effectiveAlbumArtist,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPNowPlayingInfoPropertyPlaybackRate: rate,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyIsLiveStream: false
        ]

        if !track.genre.isEmpty { info[MPMediaItemPropertyGenre] = track.genre }
        if let n = track.trackNumber { info[MPMediaItemPropertyAlbumTrackNumber] = n }
        if let t = track.trackTotal { info[MPMediaItemPropertyAlbumTrackCount] = t }
        if let d = track.discNumber { info[MPMediaItemPropertyDiscNumber] = d }
        if track.rating > 0 { info[MPMediaItemPropertyRating] = track.rating }
        if let idx = queueIndex { info[MPNowPlayingInfoPropertyPlaybackQueueIndex] = idx }
        if let cnt = queueCount { info[MPNowPlayingInfoPropertyPlaybackQueueCount] = cnt }

        if let artwork {
            if track.artworkKey != lastArtworkKey || cachedArtwork == nil {
                lastArtworkKey = track.artworkKey
                cachedArtwork = MPMediaItemArtwork(boundsSize: artwork.size) { _ in artwork }
            }
            if let cachedArtwork { info[MPMediaItemPropertyArtwork] = cachedArtwork }
        } else {
            lastArtworkKey = nil
            cachedArtwork = nil
        }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = rate > 0 ? .playing : .paused
    }

    func clear() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
    }
}
