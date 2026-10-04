//
//  FileRemover.swift
//  Sonora
//
//  Deletes one music file from wherever it lives: Sonora's own folder, a
//  folder picked in the Files app, iCloud Drive or a USB drive.
//
//  The delete goes through a file coordinator, which is what iOS expects for
//  folders that belong to another app or to iCloud, so the Files app and the
//  cloud see the change properly. It runs off the main thread because a
//  cloud folder can take a moment to answer.
//

import Foundation

enum FileRemover {

    enum Outcome {
        case removed
        /// The file was not there any more; as good as deleted.
        case alreadyGone
        /// A sentence that can be shown as it is.
        case failed(String)
    }

    static func remove(_ url: URL) async -> Outcome {
        await Task.detached(priority: .userInitiated) { () -> Outcome in
            removeNow(url)
        }.value
    }

    private static func removeNow(_ url: URL) -> Outcome {
        // Library folders keep their access open for the whole launch; this
        // covers single files that carry their own permission.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        var outcome: Outcome?
        var coordinationError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url,
                                                         options: .forDeleting,
                                                         error: &coordinationError) { target in
            do {
                try FileManager.default.removeItem(at: target)
                outcome = .removed
            } catch {
                outcome = classify(error as NSError)
            }
        }
        if let outcome { return outcome }
        if let coordinationError { return classify(coordinationError) }
        return .failed("iOS didn't let Sonora reach this file. Try again, or delete it in the Files app.")
    }

    private static func classify(_ error: NSError) -> Outcome {
        if error.domain == NSCocoaErrorDomain {
            switch error.code {
            case NSFileNoSuchFileError, NSFileReadNoSuchFileError:
                return .alreadyGone
            case NSFileWriteNoPermissionError, NSFileReadNoPermissionError:
                return .failed("iOS didn't allow Sonora to delete this file. Delete it in the Files app instead.")
            case NSFileWriteVolumeReadOnlyError:
                return .failed("This folder is read-only, so the file can't be deleted from here.")
            default:
                break
            }
        }
        if error.domain == NSPOSIXErrorDomain, error.code == Int(ENOENT) {
            return .alreadyGone
        }
        return .failed("The file couldn't be deleted. \(error.localizedDescription)")
    }
}
