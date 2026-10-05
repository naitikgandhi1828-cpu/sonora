//
//  VideoAudioExtractor.swift
//  Sonora
//
//  Saves the sound of a video file as an audio file (.m4a).
//
//  Used for music videos in Google Drive: the video is downloaded to a
//  temporary place, its sound is saved into the library, and the video is
//  removed from the iPhone. Sonora is an audio player, so there is no reason
//  to keep a file ten times the size for the same sound.
//
//  The sound is copied out exactly as it is whenever iOS allows that, which
//  is quick and loses no quality. Only when the sound is in a form an .m4a
//  file cannot hold is it converted to AAC instead.
//

import Foundation
import AVFoundation

enum VideoAudioExtractor {

    enum Failure: LocalizedError {
        case noSound
        case cannotSave(String)

        var errorDescription: String? {
            switch self {
            case .noSound:
                return "This video has no sound track, so there is nothing to save as audio."
            case .cannotSave(let detail):
                let base = "The sound of this video couldn't be saved as audio."
                return detail.isEmpty ? base : base + " " + detail
            }
        }
    }

    /// Writes the first sound track of `video` to `destination` as .m4a,
    /// replacing a file that is already there. The video is not changed.
    static func extractAudio(from video: URL, to destination: URL) async throws {
        let asset = AVURLAsset(url: video)

        let soundTracks: [AVAssetTrack]
        let duration: CMTime
        do {
            soundTracks = try await asset.loadTracks(withMediaType: .audio)
            duration = try await asset.load(.duration)
        } catch {
            throw Failure.cannotSave("iOS couldn't open the video.")
        }
        guard let source = soundTracks.first else { throw Failure.noSound }

        // A copy of the file with only the sound in it.
        let soundOnly = AVMutableComposition()
        guard let track = soundOnly.addMutableTrack(withMediaType: .audio,
                                                    preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw Failure.cannotSave("")
        }
        do {
            try track.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: source, at: .zero)
        } catch {
            throw Failure.cannotSave("")
        }

        // Title, artist and cover, where the video carries them.
        let metadata = (try? await asset.load(.metadata)) ?? []

        let fm = FileManager.default
        let folder = destination.deletingLastPathComponent()
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        // Written under a hidden temporary name first, so a half-written
        // file can never show up in the library.
        let working = folder.appendingPathComponent("." + UUID().uuidString + ".m4a")
        defer { try? fm.removeItem(at: working) }

        var lastProblem = ""
        // First try copying the sound untouched; if that isn't possible,
        // convert it.
        for preset in [AVAssetExportPresetPassthrough, AVAssetExportPresetAppleM4A] {
            try Task.checkCancellation()
            try? fm.removeItem(at: working)
            guard let exporter = AVAssetExportSession(asset: soundOnly, presetName: preset),
                  exporter.supportedFileTypes.contains(.m4a) else { continue }
            exporter.outputURL = working
            exporter.outputFileType = .m4a
            exporter.metadata = metadata
            await exporter.export()

            if exporter.status == .completed, fileSize(working) > 0 {
                if fm.fileExists(atPath: destination.path) {
                    try fm.removeItem(at: destination)
                }
                try fm.moveItem(at: working, to: destination)
                return
            }
            if exporter.status == .cancelled { throw CancellationError() }
            lastProblem = exporter.error?.localizedDescription ?? ""
        }
        throw Failure.cannotSave(lastProblem)
    }

    private static func fileSize(_ url: URL) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }
}
