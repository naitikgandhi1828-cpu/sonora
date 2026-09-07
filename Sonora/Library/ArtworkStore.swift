//
//  ArtworkStore.swift
//  Sonora
//
//  Caches album art on disk (full size + thumbnail) and in memory.
//

import Foundation
import UIKit
import ImageIO
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
        // Counting objects is the wrong unit for images: 500 thumbnails sounds
        // modest until each one is a few hundred kilobytes of decoded bitmap.
        // Both caches are bounded by bytes as well, and every insert declares
        // its real cost, so memory pressure evicts something sensible instead
        // of the app being killed.
        memory.countLimit = 24
        memory.totalCostLimit = 48 * 1024 * 1024
        thumbMemory.countLimit = 300
        thumbMemory.totalCostLimit = 16 * 1024 * 1024
    }

    /// Decodes an image file straight to the size we intend to use.
    ///
    /// `UIImage(contentsOfFile:)` decodes at full resolution, so a 3000px cover
    /// costs 36 MB of bitmap however small it is drawn. ImageIO can decode
    /// directly to a bounded size, which caps what any one cover can cost no
    /// matter what is already sitting in the cache directory.
    private static func decode(_ url: URL, maxPixel: CGFloat) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: cg)
    }

    /// Decoded size in bytes, for the cache's cost accounting.
    private static func cost(_ image: UIImage) -> Int {
        guard let cg = image.cgImage else { return 1 }
        return cg.bytesPerRow * cg.height
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
        guard let image = Self.decode(url, maxPixel: 1000) else { return nil }
        memory.setObject(image, forKey: key as NSString, cost: Self.cost(image))
        return image
    }

    func thumbnail(forKey key: String?) -> UIImage? {
        guard let key else { return nil }
        if let cached = thumbMemory.object(forKey: key as NSString) { return cached }
        let url = directory.appendingPathComponent("\(key)_t.jpg")
        guard let thumb = Self.decode(url, maxPixel: 200) else {
            // No thumbnail on disk yet — fall back to the full-size image.
            return self.image(forKey: key)
        }
        thumbMemory.setObject(thumb, forKey: key as NSString, cost: Self.cost(thumb))
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

        // `UIGraphicsImageRendererFormat.default()` inherits the screen scale,
        // which on this phone is 3. Every "1000 point" cover was therefore
        // written out at 3000 pixels and every "200 point" thumbnail at 600 -
        // nine times the pixels, nine times the decode cost and nine times the
        // memory. Pinning the scale to 1 makes the number mean pixels.
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true

        let renderer = UIGraphicsImageRenderer(size: newSize, format: format)
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
