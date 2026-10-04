//
//  DeleteSongDialog.swift
//  Sonora
//
//  "Delete Song…" — the confirmation shown from the player's menu and from
//  the long-press menu on any song.
//
//  Deleting removes the music file itself: from the folder in the Files app,
//  or, for a song downloaded from Google Drive, from the iPhone and (if the
//  user allowed it) from Drive, where it goes to the Bin. The dialog always
//  says exactly what will happen before anything is touched.
//

import SwiftUI

/// Which song the dialog is about. A fresh value each time, so asking twice
/// about the same song shows the dialog twice.
struct SongDeleteRequest: Identifiable {
    let id = UUID()
    let trackID: UUID
}

private struct DeleteSongDialog: ViewModifier {

    @Binding var request: SongDeleteRequest?

    @EnvironmentObject private var library: MediaLibrary
    @State private var problemText: String?

    func body(content: Content) -> some View {
        let info = request.flatMap { library.deleteInfo(for: $0.trackID) }
        let driveAllowed = GoogleDriveManager.shared.canDeleteFromDrive
        let trackID = request?.trackID

        content
            .confirmationDialog(title(info),
                                isPresented: Binding(get: { request != nil },
                                                     set: { if !$0 { request = nil } }),
                                titleVisibility: .visible) {
                if let info, let trackID {
                    if info.isCueOnly {
                        Button("OK", role: .cancel) {}
                    } else if info.driveCount > 0 {
                        if driveAllowed {
                            Button("Delete from iPhone and Google Drive", role: .destructive) {
                                delete(trackID, fromDrive: true)
                            }
                        }
                        Button("Delete from iPhone Only", role: .destructive) {
                            delete(trackID, fromDrive: false)
                        }
                        Button("Cancel", role: .cancel) {}
                    } else {
                        Button(info.fileCount > 1 ? "Delete \(info.fileCount) Files" : "Delete File",
                               role: .destructive) {
                            delete(trackID, fromDrive: false)
                        }
                        Button("Cancel", role: .cancel) {}
                    }
                } else {
                    Button("OK", role: .cancel) {}
                }
            } message: {
                Text(message(info, driveAllowed: driveAllowed))
            }
            .alert("Delete Song",
                   isPresented: Binding(get: { problemText != nil },
                                        set: { if !$0 { problemText = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(problemText ?? "")
            }
    }

    private func title(_ info: SongDeleteInfo?) -> String {
        guard let info else { return "Delete Song" }
        return "Delete “\(info.title)”?"
    }

    private func message(_ info: SongDeleteInfo?, driveAllowed: Bool) -> String {
        guard let info else { return "This song is no longer in your library." }
        if info.isCueOnly {
            return "This song is one part of a longer file that it shares with the rest of the album, so it can't be deleted on its own."
        }

        var lines: [String] = []
        if info.driveCount > 0 {
            if driveAllowed {
                lines.append("The download is deleted from this iPhone. In Google Drive the song goes to the Bin, where Google keeps it for 30 days.")
                lines.append("“iPhone Only” leaves it in Google Drive, and sync will not download it again.")
            } else {
                lines.append("The download is deleted from this iPhone. The song stays in Google Drive, and sync will not download it again.")
                lines.append("To delete it from Google Drive too, first switch on “Allow deleting from Drive” in Settings › Google Drive.")
            }
            let others = info.fileCount - info.driveCount
            if others > 0 {
                lines.append("\(others == 1 ? "A merged copy" : "\(others) merged copies") in your other folders \(others == 1 ? "is" : "are") deleted for good as well.")
            }
        } else {
            lines.append("“\(info.fileName)” is deleted from “\(info.folderName)” for good. This can't be undone.")
            if info.fileCount > 1 {
                let extra = info.fileCount - 1
                lines.append("Its \(extra == 1 ? "merged duplicate copy is" : "\(extra) merged duplicate copies are") deleted too.")
            }
        }
        return lines.joined(separator: "\n\n")
    }

    private func delete(_ trackID: UUID, fromDrive: Bool) {
        let library = self.library
        Task { @MainActor in
            let report = await library.deleteSongs(ids: [trackID], fromDrive: fromDrive)
            if report.problems.isEmpty {
                Haptics.success()
            } else {
                problemText = report.problems.joined(separator: "\n\n")
            }
        }
    }
}

extension View {
    /// Shows the delete confirmation whenever `request` is set.
    func deleteSongDialog(_ request: Binding<SongDeleteRequest?>) -> some View {
        modifier(DeleteSongDialog(request: request))
    }
}
