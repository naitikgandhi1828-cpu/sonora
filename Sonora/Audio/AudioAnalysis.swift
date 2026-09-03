//
//  AudioAnalysis.swift
//  Sonora
//
//  Offline analysis: waveform peak envelopes for the seek bar, and a
//  loudness measurement used as a replay-gain fallback when tracks carry
//  no gain tags.
//

import Foundation
import AVFoundation
import Accelerate

// MARK: - Waveform

struct WaveformData: Codable {
    let peaks: [Float]      // 0...1, one value per bucket
    let rms: [Float]        // 0...1
    let bucketCount: Int
}

actor WaveformAnalyzer {

    static let shared = WaveformAnalyzer()

    private var cache: [UUID: WaveformData] = [:]
    private var inFlight: Set<UUID> = []

    private var cacheDirectory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Waveforms", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func waveform(for trackID: UUID,
                  url: URL,
                  startTime: TimeInterval = 0,
                  endTime: TimeInterval? = nil,
                  buckets: Int = 360) async -> WaveformData? {

        if let hit = cache[trackID] { return hit }

        let file = cacheDirectory.appendingPathComponent("\(trackID.uuidString).json")
        if let data = try? Data(contentsOf: file),
           let decoded = try? JSONDecoder().decode(WaveformData.self, from: data) {
            cache[trackID] = decoded
            return decoded
        }

        guard !inFlight.contains(trackID) else { return nil }
        inFlight.insert(trackID)
        defer { inFlight.remove(trackID) }

        let computed = await Task.detached(priority: .utility) {
            WaveformAnalyzer.analyze(url: url,
                                     startTime: startTime,
                                     endTime: endTime,
                                     buckets: buckets)
        }.value
        guard let result = computed else { return nil }

        cache[trackID] = result
        if let encoded = try? JSONEncoder().encode(result) {
            try? encoded.write(to: file, options: .atomic)
        }
        return result
    }

    func clearCache() {
        cache.removeAll()
        try? FileManager.default.removeItem(at: cacheDirectory)
    }

    nonisolated static func analyze(url: URL,
                                    startTime: TimeInterval,
                                    endTime: TimeInterval?,
                                    buckets: Int) -> WaveformData? {

        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let format = file.processingFormat
        let sr = format.sampleRate
        let startFrame = AVAudioFramePosition(max(0, startTime) * sr)
        let endFrame = endTime.map { min(file.length, AVAudioFramePosition($0 * sr)) } ?? file.length
        let totalFrames = max(0, endFrame - startFrame)
        guard totalFrames > 0 else { return nil }

        file.framePosition = startFrame

        let framesPerBucket = max(1, Int(totalFrames) / buckets)
        let chunkFrames = AVAudioFrameCount(min(max(framesPerBucket, 4096), 262_144))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames) else { return nil }

        var peaks: [Float] = []
        var rmsValues: [Float] = []
        peaks.reserveCapacity(buckets)
        rmsValues.reserveCapacity(buckets)

        var accPeak: Float = 0
        var accSquare: Float = 0
        var accCount: Int = 0
        var framesRead: AVAudioFramePosition = 0

        while framesRead < totalFrames {
            let want = AVAudioFrameCount(min(AVAudioFramePosition(chunkFrames), totalFrames - framesRead))
            buffer.frameLength = 0
            do { try file.read(into: buffer, frameCount: want) } catch { break }
            let n = Int(buffer.frameLength)
            if n == 0 { break }
            framesRead += AVAudioFramePosition(n)

            guard let channels = buffer.floatChannelData else { break }
            let channelCount = Int(format.channelCount)

            var mono = [Float](repeating: 0, count: n)
            if channelCount == 1 {
                mono.withUnsafeMutableBufferPointer { dst in
                    dst.baseAddress!.update(from: channels[0], count: n)
                }
            } else {
                // Average all channels into one envelope.
                mono.withUnsafeMutableBufferPointer { dst in
                    vDSP_vclr(dst.baseAddress!, 1, vDSP_Length(n))
                    for c in 0..<channelCount {
                        vDSP_vadd(dst.baseAddress!, 1, channels[c], 1, dst.baseAddress!, 1, vDSP_Length(n))
                    }
                    var scale = 1 / Float(channelCount)
                    vDSP_vsmul(dst.baseAddress!, 1, &scale, dst.baseAddress!, 1, vDSP_Length(n))
                }
            }

            var index = 0
            while index < n {
                let take = min(framesPerBucket - accCount, n - index)
                mono.withUnsafeBufferPointer { src in
                    let base = src.baseAddress! + index
                    var localPeak: Float = 0
                    vDSP_maxmgv(base, 1, &localPeak, vDSP_Length(take))
                    if localPeak > accPeak { accPeak = localPeak }
                    var sumSq: Float = 0
                    vDSP_svesq(base, 1, &sumSq, vDSP_Length(take))
                    accSquare += sumSq
                }
                accCount += take
                index += take

                if accCount >= framesPerBucket {
                    peaks.append(min(1, accPeak))
                    rmsValues.append(min(1, sqrt(accSquare / Float(accCount))))
                    accPeak = 0; accSquare = 0; accCount = 0
                    if peaks.count >= buckets { break }
                }
            }
            if peaks.count >= buckets { break }
        }

        if accCount > 0 && peaks.count < buckets {
            peaks.append(min(1, accPeak))
            rmsValues.append(min(1, sqrt(accSquare / Float(accCount))))
        }
        guard !peaks.isEmpty else { return nil }

        // Normalise so quiet tracks still fill the seek bar.
        let maxPeak = peaks.max() ?? 1
        if maxPeak > 0.0001 {
            let scale = 1 / maxPeak
            peaks = peaks.map { min(1, $0 * scale) }
            rmsValues = rmsValues.map { min(1, $0 * scale) }
        }

        while peaks.count < buckets { peaks.append(0); rmsValues.append(0) }

        return WaveformData(peaks: peaks, rms: rmsValues, bucketCount: peaks.count)
    }
}

// MARK: - Loudness / replay gain

enum LoudnessAnalyzer {

    struct Result {
        let gainDB: Float       // suggested replay gain
        let peak: Float         // sample peak, linear
        let rmsDB: Float
    }

    /// Reference level used by the ReplayGain spec, in dBFS.
    static let referenceDB: Float = -18.0

    /// Measures mean-square loudness across the file. This is a pragmatic
    /// approximation of ReplayGain, not a full EBU R128 implementation, but
    /// it lines up closely enough to level a mixed library.
    static func analyze(url: URL,
                        startTime: TimeInterval = 0,
                        endTime: TimeInterval? = nil) -> Result? {

        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let format = file.processingFormat
        let sr = format.sampleRate
        let startFrame = AVAudioFramePosition(max(0, startTime) * sr)
        let endFrame = endTime.map { min(file.length, AVAudioFramePosition($0 * sr)) } ?? file.length
        let total = max(0, endFrame - startFrame)
        guard total > 0 else { return nil }
        file.framePosition = startFrame

        let chunk: AVAudioFrameCount = 65_536
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { return nil }

        var sumSquares: Double = 0
        var count: Double = 0
        var peak: Float = 0
        var read: AVAudioFramePosition = 0

        while read < total {
            let want = AVAudioFrameCount(min(AVAudioFramePosition(chunk), total - read))
            buffer.frameLength = 0
            do { try file.read(into: buffer, frameCount: want) } catch { break }
            let n = Int(buffer.frameLength)
            if n == 0 { break }
            read += AVAudioFramePosition(n)

            guard let channels = buffer.floatChannelData else { break }
            for c in 0..<Int(format.channelCount) {
                var localPeak: Float = 0
                vDSP_maxmgv(channels[c], 1, &localPeak, vDSP_Length(n))
                if localPeak > peak { peak = localPeak }
                var sq: Float = 0
                vDSP_svesq(channels[c], 1, &sq, vDSP_Length(n))
                sumSquares += Double(sq)
                count += Double(n)
            }
        }

        guard count > 0 else { return nil }
        let rms = sqrt(sumSquares / count)
        let rmsDB = Float(20 * log10(max(rms, 1e-7)))
        let gain = referenceDB - rmsDB
        return Result(gainDB: max(-24, min(24, gain)), peak: peak, rmsDB: rmsDB)
    }
}
