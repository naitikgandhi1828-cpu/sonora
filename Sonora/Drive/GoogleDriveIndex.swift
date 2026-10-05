//
//  GoogleDriveIndex.swift
//  Sonora
//
//  Sonora's memory of what it has downloaded from Google Drive: a small JSON
//  file in Application Support that maps each Drive file id to where the
//  song landed on disk, plus the list of folders being kept in sync.
//
//  It is what lets "Sync" skip files that have not changed, re-download the
//  ones that have, and show a tick next to songs already on the iPhone.
//

import Foundation

/// One downloaded Drive file.
struct DriveIndexEntry: Codable, Hashable {
    /// Path inside "Documents/Google Drive".
    var relativePath: String
    var size: Int64
    var md5: String?
    var modifiedTime: String?
}

struct DriveIndexSnapshot: Codable {
    var version: Int = 1
    /// Drive file id → downloaded file.
    var files: [String: DriveIndexEntry] = [:]
    var syncedFolders: [DriveSyncedFolder] = []
    /// Drive file ids the user deleted from the iPhone but left in Drive.
    /// Sync leaves these alone so a deleted song does not come back by
    /// itself. Optional so an index saved by an older version still loads.
    var ignored: [String]?
}

enum DriveIndexStore {

    private static let queue = DispatchQueue(label: "sonora.drive.index", qos: .utility)

    static var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("SonoraGoogleDrive.json")
    }

    static func load() -> DriveIndexSnapshot {
        guard let data = try? Data(contentsOf: fileURL),
              let snapshot = try? JSONDecoder().decode(DriveIndexSnapshot.self, from: data) else {
            return DriveIndexSnapshot()
        }
        return snapshot
    }

    /// Written on one serial queue so an older copy can never land on top
    /// of a newer one.
    static func save(_ snapshot: DriveIndexSnapshot) {
        let url = fileURL
        queue.async {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }
}

// MARK: - Local folder

enum DriveLocalFolder {

    /// "Documents/Google Drive". Worked out fresh every time, because the
    /// app's container path can change between launches.
    static var url: URL {
        FolderAccessManager.documentsFolder
            .appendingPathComponent(GoogleDriveConfig.localFolderName, isDirectory: true)
    }

    /// Creates the folder and keeps it out of iCloud / computer backups:
    /// everything in it can be downloaded again.
    static func prepare() {
        var folder = url
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? folder.setResourceValues(values)
    }

    static func fileSize(_ url: URL) -> Int64? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value
    }

    /// Free space iOS is willing to give an app for something the user asked for.
    static func freeSpace() -> Int64? {
        let values = try? FolderAccessManager.documentsFolder
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    /// What is really on disk. Returns the total size of the folder and the
    /// ids of indexed files that are no longer there (deleted through the
    /// Files app, for example).
    static func audit(index: [String: DriveIndexEntry]) async -> (bytes: Int64, missing: [String]) {
        let root = url
        let fm = FileManager.default
        var total: Int64 = 0
        if let enumerator = fm.enumerator(at: root,
                                          includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                                          options: []) {
            while let next = enumerator.nextObject() {
                guard let file = next as? URL,
                      let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                      values.isRegularFile == true else { continue }
                total += Int64(values.fileSize ?? 0)
            }
        }
        var missing: [String] = []
        for (id, entry) in index
        where !fm.fileExists(atPath: root.appendingPathComponent(entry.relativePath).path) {
            missing.append(id)
        }
        return (total, missing)
    }
}

// MARK: - Planning a download

/// A Drive file together with the folder names leading to it.
struct DriveCandidate {
    let item: DriveItem
    let folders: [String]
}

/// One file waiting to be downloaded.
struct DriveJob: Identifiable, Hashable {
    /// Drive file id.
    let id: String
    let name: String
    /// Where it goes, inside "Documents/Google Drive".
    let relativePath: String
    let expectedSize: Int64?
    let md5: String?
    let modifiedTime: String?
    let wifiOnly: Bool
    /// The Drive file is a video; only its sound is kept (see `DriveItem.isVideo`).
    var isVideo: Bool = false
}

struct DrivePlan {
    /// Files that need downloading.
    var jobs: [DriveJob] = []
    /// Files found on disk that the index did not know about; nothing to
    /// download, only to remember.
    var adopted: [String: DriveIndexEntry] = [:]
    /// Files that were already downloaded and have not changed.
    var alreadyHave = 0
}

enum DrivePlanner {

    /// True when the Drive file still matches what was downloaded.
    static func isUnchanged(_ entry: DriveIndexEntry, _ item: DriveItem) -> Bool {
        if let old = entry.md5, let new = item.md5 { return old == new }
        if let size = item.size, size != entry.size { return false }
        if let old = entry.modifiedTime, let new = item.modifiedTime { return old == new }
        return true
    }

    /// Decides, for each candidate, whether to skip it, download it, and
    /// where it goes. Touches the disk (to see what exists), so it runs off
    /// the main thread.
    ///
    /// Name clashes: two different Drive files that would land on the same
    /// path get " (2)", " (3)"… — unless they are byte-for-byte the same
    /// song (same size and checksum), in which case one copy is enough.
    static func plan(candidates: [DriveCandidate],
                     index: [String: DriveIndexEntry],
                     busyIDs: Set<String>,
                     wifiOnly: Bool) async -> DrivePlan {
        let root = DriveLocalFolder.url
        let fm = FileManager.default
        var plan = DrivePlan()

        // Lower-cased so "Song.mp3" and "song.MP3" never fight over a path.
        var owners: [String: String] = [:]
        var known: [String: (size: Int64?, md5: String?)] = [:]
        for (id, entry) in index {
            owners[entry.relativePath.lowercased()] = id
            known[id] = (entry.size, entry.md5)
        }

        var seen = Set<String>()
        for candidate in candidates {
            let item = candidate.item
            guard !item.isFolder, seen.insert(item.id).inserted, !busyIDs.contains(item.id) else { continue }

            // Downloaded before: keep it, or fetch it again to the same place.
            if let entry = index[item.id] {
                let onDisk = fm.fileExists(atPath: root.appendingPathComponent(entry.relativePath).path)
                if onDisk, isUnchanged(entry, item) {
                    plan.alreadyHave += 1
                } else {
                    plan.jobs.append(DriveJob(id: item.id, name: item.name,
                                              relativePath: entry.relativePath,
                                              expectedSize: item.size, md5: item.md5,
                                              modifiedTime: item.modifiedTime, wifiOnly: wifiOnly,
                                              isVideo: item.isVideo))
                }
                continue
            }

            let folders = candidate.folders.map { DriveFileNames.sanitised($0) }
            let fileName = DriveFileNames.sanitised(item.localName)

            var number = 1
            while number <= 300 {
                let name = number == 1 ? fileName : DriveFileNames.numbered(fileName, number)
                let relative = DriveFileNames.relativePath(folders: folders, fileName: name)
                let key = relative.lowercased()

                if let ownerID = owners[key] {
                    // Another Drive file already has this path.
                    if let other = known[ownerID], let otherMD5 = other.md5, let myMD5 = item.md5,
                       otherMD5 == myMD5, other.size == item.size {
                        // Same song twice in Drive: one copy is enough.
                        if let entry = index[ownerID] ?? plan.adopted[ownerID] {
                            plan.adopted[item.id] = entry
                        }
                        plan.alreadyHave += 1
                        break
                    }
                    number += 1
                    continue
                }

                let target = root.appendingPathComponent(relative)
                if fm.fileExists(atPath: target.path) {
                    // A file Sonora has no record of (its index was lost,
                    // say). Same size: take it as this song.
                    if let size = item.size, DriveLocalFolder.fileSize(target) == size {
                        plan.adopted[item.id] = DriveIndexEntry(relativePath: relative, size: size,
                                                                md5: item.md5,
                                                                modifiedTime: item.modifiedTime)
                        owners[key] = item.id
                        known[item.id] = (item.size, item.md5)
                        plan.alreadyHave += 1
                        break
                    }
                    number += 1
                    continue
                }

                plan.jobs.append(DriveJob(id: item.id, name: item.name, relativePath: relative,
                                          expectedSize: item.size, md5: item.md5,
                                          modifiedTime: item.modifiedTime, wifiOnly: wifiOnly,
                                              isVideo: item.isVideo))
                owners[key] = item.id
                known[item.id] = (item.size, item.md5)
                break
            }
        }
        return plan
    }
}
