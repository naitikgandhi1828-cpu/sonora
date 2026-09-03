//
//  ArtworkStore.swift
//  Sonora
//
//  Caches album art on disk (full size + thumbnail) and in memory.
//

import Foundation
import UIKit
import CryptoKit

final class ArtworkStore {

    static let shared = ArtworkStore()

    private let memory = NSCache<NSString, UIImage>()
    private let thumbMemory = NSCache<NSString, UIImage>()
    private let io = DispatchQueue(label: "sonora.artwork", qos: .utility)

    private var directory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Artwork", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private init() {
        memory.countLimit = 60
        thumbMemory.countLimit = 500
    }

    /// Stores artwork bytes under a key derived from the album, so every
    /// track on an album shares one file.
    @discardableResult
    func store(_ data: Data, forAlbumKey albumKey: String) -> String? {
        let key = Self.hash(albumKey)
        let full = directory.appendingPathComponent("\(key).jpg")
        let thumb = directory.appendingPathComponent("\(key)_t.jpg")

        if FileManager.default.fileExists(atPath: full.path) { return key }
        guard let image = UIImage(data: data) else { return nil }

        let resized = image.resized(maxDimension: 1000)
        try? resized.jpegData(compressionQuality: 0.88)?.write(to: full, options: .atomic)
        let thumbnail = image.resized(maxDimension: 200)
        try? thumbnail.jpegData(compressionQuality: 0.8)?.write(to: thumb, options: .atomic)
        return key
    }

    func image(forKey key: String?) -> UIImage? {
        guard let key else { return nil }
        if let cached = memory.object(forKey: key as NSString) { return cached }
        let url = directory.appendingPathComponent("\(key).jpg")
        guard let image = UIImage(contentsOfFile: url.path) else { return nil }
        memory.setObject(image, forKey: key as NSString)
        return image
    }

    func thumbnail(forKey key: String?) -> UIImage? {
        guard let key else { return nil }
        if let cached = thumbMemory.object(forKey: key as NSString) { return cached }
        let url = directory.appendingPathComponent("\(key)_t.jpg")
        guard let thumb = UIImage(contentsOfFile: url.path) else {
            // No thumbnail on disk yet — fall back to the full-size image.
            return self.image(forKey: key)
        }
        thumbMemory.setObject(thumb, forKey: key as NSString)
        return thumb
    }

    func hasArtwork(forAlbumKey albumKey: String) -> String? {
        let key = Self.hash(albumKey)
        let url = directory.appendingPathComponent("\(key).jpg")
        return FileManager.default.fileExists(atPath: url.path) ? key : nil
    }

    /// Looks for cover.jpg / folder.png etc. beside the audio files.
    func importSidecarArtwork(in folder: URL, albumKey: String) -> String? {
        let names = ["cover", "folder", "front", "album", "albumart", "artwork", "thumb"]
        let exts = ["jpg", "jpeg", "png", "webp"]
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(at: folder,
                                                         includingPropertiesForKeys: nil,
                                                         options: [.skipsHiddenFiles]) else { return nil }
        for file in contents {
            let stem = file.deletingPathExtension().lastPathComponent.lowercased()
            let ext = file.pathExtension.lowercased()
            guard exts.contains(ext), names.contains(where: { stem == $0 || stem.hasPrefix($0) }) else { continue }
            if let data = try? Data(contentsOf: file) {
                return store(data, forAlbumKey: albumKey)
            }
        }
        return nil
    }

    func clear() {
        memory.removeAllObjects()
        thumbMemory.removeAllObjects()
        try? FileManager.default.removeItem(at: directory)
    }

    var diskUsageBytes: Int64 {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        return files.reduce(0) { sum, url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return sum + Int64(size)
        }
    }

    private static func hash(_ s: String) -> String {
        let digest = SHA256.hash(data: Data(s.lowercased().utf8))
        return digest.compactMap { String(format: "%02x", $0) }.joined().prefix(24).description
    }
}

extension UIImage {
    func resized(maxDimension: CGFloat) -> UIImage {
        let longest = max(size.width, size.height)
        guard longest > maxDimension, longest > 0 else { return self }
        let scale = maxDimension / longest
        let newSize = CGSize(width: (size.width * scale).rounded(),
                             height: (size.height * scale).rounded())
        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in
            self.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }

    /// Average colour of the image, used to tint the player background.
    var averageColor: UIColor? {
        guard let cg = cgImage else { return nil }
        let width = 12, height = 12
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let ctx = CGContext(data: &pixels, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        var r = 0.0, g = 0.0, b = 0.0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            r += Double(pixels[i]); g += Double(pixels[i + 1]); b += Double(pixels[i + 2])
        }
        let count = Double(width * height)
        return UIColor(red: r / count / 255, green: g / count / 255, blue: b / count / 255, alpha: 1)
    }
}
