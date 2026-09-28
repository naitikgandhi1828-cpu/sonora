//
//  CarPlaySceneDelegate.swift
//  Sonora
//
//  CarPlay audio-app browsing: a tab bar of Recent / Albums / Playlists /
//  Folders lists. Picking a track replaces the queue with that list and shows
//  the system Now Playing screen.
//
//  The scene is declared in Config/Info.plist (role
//  CPTemplateApplicationSceneSessionRoleApplication) and only appears in the
//  car when the signing profile carries com.apple.developer.carplay-audio.
//

import UIKit
import CarPlay
import Combine

@MainActor
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {

    private var interfaceController: CPInterfaceController?

    // Lazy so they are built on the main actor on first use rather than in a
    // (nonisolated, in Swift 5 mode) stored-property initializer.
    private lazy var recentTemplate = CPListTemplate(title: "Recent", sections: [])
    private lazy var albumsTemplate = CPListTemplate(title: "Albums", sections: [])
    private lazy var playlistsTemplate = CPListTemplate(title: "Playlists", sections: [])
    private lazy var foldersTemplate = CPListTemplate(title: "Folders", sections: [])

    private var cancellables = Set<AnyCancellable>()

    /// Decoding a thumbnail is a synchronous disk read; only the first rows of
    /// a list get artwork so building a long list stays cheap.
    private let artworkRowLimit = 40

    // MARK: - CPTemplateApplicationSceneDelegate

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didConnect interfaceController: CPInterfaceController) {
        self.interfaceController = interfaceController

        configureTab(recentTemplate, title: "Recent", symbol: "clock",
                     emptyTitle: "Nothing played yet")
        configureTab(albumsTemplate, title: "Albums", symbol: "square.stack",
                     emptyTitle: "No albums")
        configureTab(playlistsTemplate, title: "Playlists", symbol: "music.note.list",
                     emptyTitle: "No playlists")
        configureTab(foldersTemplate, title: "Folders", symbol: "folder",
                     emptyTitle: "No folders added")

        rebuildAll()

        let tabs: [CPTemplate] = [recentTemplate, albumsTemplate, playlistsTemplate, foldersTemplate]
        let tabBar = CPTabBarTemplate(templates: Array(tabs.prefix(CPTabBarTemplate.maximumTabCount)))
        interfaceController.setRootTemplate(tabBar, animated: false, completion: nil)

        observeChanges()
    }

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didDisconnectInterfaceController interfaceController: CPInterfaceController) {
        cancellables.removeAll()
        self.interfaceController = nil
    }

    // MARK: - Setup

    private func configureTab(_ template: CPListTemplate, title: String, symbol: String, emptyTitle: String) {
        template.tabTitle = title
        template.tabImage = UIImage(systemName: symbol)
        template.emptyViewTitleVariants = [emptyTitle]
    }

    private func observeChanges() {
        cancellables.removeAll()

        if let library = AppServices.library {
            // Scans publish progress many times a second; wait for a quiet spell.
            library.objectWillChange
                .debounce(for: .seconds(1), scheduler: RunLoop.main)
                .sink { [weak self] _ in
                    self?.rebuildAll()
                }
                .store(in: &cancellables)
        }

        if let player = AppServices.player {
            player.$currentTrack
                .map { $0?.id }
                .removeDuplicates()
                .receive(on: RunLoop.main)
                .sink { [weak self] id in
                    self?.updatePlayingIndicators(currentID: id)
                }
                .store(in: &cancellables)
        }
    }

    // MARK: - Building the tabs

    private func rebuildAll() {
        guard interfaceController != nil else { return }
        recentTemplate.updateSections(clampedSections(recentSections()))
        albumsTemplate.updateSections(clampedSections(albumSections()))
        playlistsTemplate.updateSections(clampedSections(playlistSections()))
        foldersTemplate.updateSections(clampedSections(folderSections()))
    }

    private func recentSections() -> [CPListSection] {
        guard let library = AppServices.library else { return [] }
        let tracks = library.tracks(ids: library.recentlyPlayedIDs)
        guard !tracks.isEmpty else { return [] }
        return [trackSection(tracks, sourceName: "Recently Played")]
    }

    private func albumSections() -> [CPListSection] {
        guard let library = AppServices.library else { return [] }
        let albums = library.albums
        guard !albums.isEmpty else { return [] }

        let items: [CPListItem] = albums.prefix(maxItems).enumerated().map { index, album in
            let count = album.trackIDs.count
            let item = CPListItem(text: album.title,
                                  detailText: "\(album.artist) · \(count) song\(count == 1 ? "" : "s")",
                                  image: index < artworkRowLimit ? thumbnail(album.artworkKey) : nil)
            item.accessoryType = .disclosureIndicator
            item.handler = { [weak self] _, completion in
                self?.showAlbum(album)
                completion()
            }
            return item
        }
        return [CPListSection(items: items)]
    }

    private func playlistSections() -> [CPListSection] {
        guard let library = AppServices.library else { return [] }
        let playlists = library.playlists
        guard !playlists.isEmpty else { return [] }

        let items: [CPListItem] = playlists.prefix(maxItems).map { playlist in
            let count = playlist.trackIDs.count
            let item = CPListItem(text: playlist.name,
                                  detailText: "\(count) song\(count == 1 ? "" : "s")",
                                  image: UIImage(systemName: "music.note.list"))
            item.accessoryType = .disclosureIndicator
            item.handler = { [weak self] _, completion in
                self?.showPlaylist(id: playlist.id)
                completion()
            }
            return item
        }
        return [CPListSection(items: items)]
    }

    private func folderSections() -> [CPListSection] {
        guard let library = AppServices.library else { return [] }
        let roots = library.folderTree().children
        guard !roots.isEmpty else { return [] }

        let items: [CPListItem] = roots.prefix(maxItems).map { node in
            let count = node.totalTrackCount
            let item = CPListItem(text: node.name,
                                  detailText: "\(count) song\(count == 1 ? "" : "s")",
                                  image: UIImage(systemName: "folder"))
            item.accessoryType = .disclosureIndicator
            item.handler = { [weak self] _, completion in
                self?.showFolder(node)
                completion()
            }
            return item
        }
        return [CPListSection(items: items)]
    }

    // MARK: - Drill-down lists

    private func showAlbum(_ album: AlbumGroup) {
        guard let library = AppServices.library else { return }
        let tracks = library.tracks(ids: album.trackIDs)
            .sorted(by: TrackSort.trackNumber.comparator(ascending: true))
        pushTrackList(title: album.title, tracks: tracks)
    }

    private func showPlaylist(id: UUID) {
        // Look it up again so edits made since the tab was built are honoured.
        guard let library = AppServices.library,
              let playlist = library.playlists.first(where: { $0.id == id }) else { return }
        pushTrackList(title: playlist.name, tracks: library.tracks(ids: playlist.trackIDs))
    }

    private func showFolder(_ node: FolderNode) {
        guard let library = AppServices.library else { return }
        pushTrackList(title: node.name, tracks: library.tracks(ids: flattenedTrackIDs(node)))
    }

    private func pushTrackList(title: String, tracks: [Track]) {
        guard let interfaceController else { return }
        let sections = tracks.isEmpty ? [] : [trackSection(tracks, sourceName: title)]
        let template = CPListTemplate(title: title, sections: clampedSections(sections))
        template.emptyViewTitleVariants = ["No songs"]
        interfaceController.pushTemplate(template, animated: true, completion: nil)
    }

    /// A folder's own tracks, then each subfolder's, depth first.
    private func flattenedTrackIDs(_ node: FolderNode) -> [UUID] {
        var ids = node.trackIDs
        for child in node.children {
            ids.append(contentsOf: flattenedTrackIDs(child))
        }
        return ids
    }

    // MARK: - Track rows

    /// One row per track. Selecting row `i` queues the whole list (not just the
    /// rows CarPlay lets us show) starting at `i`.
    private func trackSection(_ tracks: [Track], sourceName: String) -> CPListSection {
        let ids = tracks.map(\.id)
        let currentID = AppServices.player?.currentTrack?.id

        let items: [CPListItem] = tracks.prefix(maxItems).enumerated().map { index, track in
            let item = CPListItem(text: track.displayTitle,
                                  detailText: track.displayArtist,
                                  image: index < artworkRowLimit ? thumbnail(track.artworkKey) : nil)
            item.userInfo = track.id
            item.isPlaying = (track.id == currentID)
            item.handler = { [weak self] _, completion in
                self?.play(ids: ids, startIndex: index, sourceName: sourceName)
                completion()
            }
            return item
        }
        return CPListSection(items: items)
    }

    private func play(ids: [UUID], startIndex: Int, sourceName: String) {
        guard let player = AppServices.player else { return }
        player.play(trackIDs: ids, startIndex: startIndex, sourceName: sourceName)
        showNowPlaying()
    }

    private func showNowPlaying() {
        guard let interfaceController else { return }
        let nowPlaying = CPNowPlayingTemplate.shared
        if interfaceController.topTemplate === nowPlaying { return }
        if interfaceController.templates.contains(where: { $0 === nowPlaying }) {
            interfaceController.pop(to: nowPlaying, animated: true, completion: nil)
        } else {
            interfaceController.pushTemplate(nowPlaying, animated: true, completion: nil)
        }
    }

    // MARK: - Now-playing indicator

    private func updatePlayingIndicators(currentID: UUID?) {
        guard let interfaceController else { return }
        var lists: [CPListTemplate] = [recentTemplate, albumsTemplate, playlistsTemplate, foldersTemplate]
        lists.append(contentsOf: interfaceController.templates.compactMap { $0 as? CPListTemplate })

        for list in lists {
            for section in list.sections {
                for case let item as CPListItem in section.items {
                    guard let id = item.userInfo as? UUID else { continue }
                    let playing = (id == currentID)
                    if item.isPlaying != playing { item.isPlaying = playing }
                }
            }
        }
    }

    // MARK: - Helpers

    private var maxItems: Int { max(1, CPListTemplate.maximumItemCount) }

    private func clampedSections(_ sections: [CPListSection]) -> [CPListSection] {
        Array(sections.prefix(max(1, CPListTemplate.maximumSectionCount)))
    }

    private func thumbnail(_ key: String?) -> UIImage? {
        guard let key else { return nil }
        return ArtworkStore.shared.thumbnail(forKey: key)
    }
}
