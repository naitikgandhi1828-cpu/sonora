//
//  BrowseViews.swift
//  Sonora
//
//  Folder tree, albums, artists, genres, playlists and the shared track list.
//

import SwiftUI

// MARK: - Folder browser

struct FolderBrowserView: View {

    let node: FolderNode

    @EnvironmentObject private var library: MediaLibrary
    @EnvironmentObject private var player: PlaybackController
    @EnvironmentObject private var themes: ThemeManager

    var body: some View {
        List {
            if !node.children.isEmpty {
                Section("Folders") {
                    ForEach(node.children) { child in
                        NavigationLink {
                            FolderBrowserView(node: child)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "folder.fill")
                                    .foregroundStyle(themes.accent)
                                    .frame(width: 24)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(child.name).font(.system(size: 15))
                                    Text("\(child.totalTrackCount) track\(child.totalTrackCount == 1 ? "" : "s")")
                                        .font(.system(size: 11))
                                        .foregroundStyle(themes.theme.textSecondary)
                                }
                            }
                        }
                        .contextMenu {
                            Button {
                                player.play(trackIDs: collectTracks(child), sourceName: child.name)
                            } label: { Label("Play Folder", systemImage: "play.fill") }
                            Button {
                                player.enqueue(collectTracks(child), playNext: false)
                            } label: { Label("Add to Queue", systemImage: "text.append") }
                        }
                    }
                }
            }

            if !node.trackIDs.isEmpty {
                Section("Tracks") {
                    ForEach(Array(library.tracks(ids: node.trackIDs).enumerated()), id: \.element.id) { index, track in
                        TrackRow(track: track,
                                 isCurrent: player.currentTrack?.id == track.id,
                                 isPlaying: player.currentTrack?.id == track.id && player.isPlaying)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                player.play(trackIDs: node.trackIDs, startIndex: index,
                                            sourceName: node.name)
                                Haptics.tap()
                            }
                            .trackContextMenu(track: track)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(node.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        player.play(trackIDs: collectTracks(node), sourceName: node.name)
                    } label: { Label("Play All", systemImage: "play.fill") }
                    Button {
                        player.play(trackIDs: collectTracks(node).shuffled(), sourceName: node.name)
                    } label: { Label("Shuffle All", systemImage: "shuffle") }
                    Button {
                        player.enqueue(collectTracks(node), playNext: false)
                    } label: { Label("Add to Queue", systemImage: "text.append") }
                } label: { Image(systemName: "ellipsis.circle") }
                .tint(themes.accent)
            }
        }
    }

    private func collectTracks(_ node: FolderNode) -> [UUID] {
        var ids = node.trackIDs
        for child in node.children { ids.append(contentsOf: collectTracks(child)) }
        return ids
    }
}

// MARK: - Albums

struct AlbumsView: View {

    @EnvironmentObject private var library: MediaLibrary
    @EnvironmentObject private var themes: ThemeManager
    @State private var query = ""
    @State private var gridMode = true

    private var albums: [AlbumGroup] {
        let all = library.albums
        guard !query.isEmpty else { return all }
        let q = query.lowercased()
        return all.filter { $0.title.lowercased().contains(q) || $0.artist.lowercased().contains(q) }
    }

    var body: some View {
        Group {
            if gridMode {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 14)], spacing: 18) {
                        ForEach(albums) { album in
                            NavigationLink { AlbumDetailView(album: album) } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    ArtworkView(key: album.artworkKey, size: 168, cornerRadius: 10)
                                        .frame(maxWidth: .infinity)
                                    Text(album.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                                    Text(album.artist)
                                        .font(.system(size: 11))
                                        .foregroundStyle(themes.theme.textSecondary)
                                        .lineLimit(1)
                                }
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(themes.theme.textPrimary)
                        }
                    }
                    .padding(16)
                    .padding(.bottom, 80)
                }
            } else {
                List(albums) { album in
                    NavigationLink { AlbumDetailView(album: album) } label: {
                        HStack(spacing: 12) {
                            ArtworkView(key: album.artworkKey, size: 52, cornerRadius: 7)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(album.title).font(.system(size: 15)).lineLimit(1)
                                Text("\(album.artist) · \(album.trackIDs.count) tracks")
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(themes.theme.textSecondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .background(themes.theme.background)
        .searchable(text: $query, prompt: "Search albums")
        .navigationTitle("Albums")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { gridMode.toggle() } label: {
                    Image(systemName: gridMode ? "list.bullet" : "square.grid.2x2")
                }
                .tint(themes.accent)
            }
        }
    }
}

struct AlbumDetailView: View {

    let album: AlbumGroup

    @EnvironmentObject private var library: MediaLibrary
    @EnvironmentObject private var player: PlaybackController
    @EnvironmentObject private var themes: ThemeManager

    private var tracks: [Track] {
        library.tracks(ids: album.trackIDs)
            .sorted(by: TrackSort.trackNumber.comparator(ascending: true))
    }

    var body: some View {
        List {
            Section {
                VStack(spacing: 12) {
                    ArtworkView(key: album.artworkKey, size: 200, cornerRadius: 14, useThumbnail: false)
                    VStack(spacing: 3) {
                        Text(album.title).font(.system(size: 19, weight: .bold)).multilineTextAlignment(.center)
                        Text(album.artist).font(.system(size: 14)).foregroundStyle(themes.theme.textSecondary)
                        Text([album.year.map(String.init), "\(album.trackIDs.count) tracks", album.totalDuration.longFormat]
                            .compactMap { $0 }.joined(separator: " · "))
                            .font(.system(size: 11))
                            .foregroundStyle(themes.theme.textSecondary)
                    }
                    HStack(spacing: 10) {
                        Button {
                            player.playAlbum(album); Haptics.tap()
                        } label: {
                            Label("Play", systemImage: "play.fill")
                                .font(.system(size: 14, weight: .semibold))
                                .frame(maxWidth: .infinity).padding(.vertical, 11)
                                .background(themes.accent, in: RoundedRectangle(cornerRadius: 10))
                                .foregroundStyle(.white)
                        }
                        Button {
                            player.play(trackIDs: tracks.map(\.id).shuffled(), sourceName: album.title)
                            Haptics.tap()
                        } label: {
                            Label("Shuffle", systemImage: "shuffle")
                                .font(.system(size: 14, weight: .semibold))
                                .frame(maxWidth: .infinity).padding(.vertical, 11)
                                .background(themes.accent.opacity(0.16), in: RoundedRectangle(cornerRadius: 10))
                                .foregroundStyle(themes.accent)
                        }
                    }
                    .buttonStyle(.plain)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .listRowBackground(Color.clear)
            }

            Section {
                ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                    TrackRow(track: track,
                             showTrackNumber: true,
                             isCurrent: player.currentTrack?.id == track.id,
                             isPlaying: player.currentTrack?.id == track.id && player.isPlaying)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            player.play(trackIDs: tracks.map(\.id), startIndex: index, sourceName: album.title)
                            Haptics.tap()
                        }
                        .trackContextMenu(track: track)
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle(album.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Artists / Genres

struct ArtistsView: View {
    @EnvironmentObject private var library: MediaLibrary
    @EnvironmentObject private var themes: ThemeManager
    @State private var query = ""

    private var artists: [ArtistGroup] {
        guard !query.isEmpty else { return library.artists }
        return library.artists.filter { $0.name.lowercased().contains(query.lowercased()) }
    }

    var body: some View {
        List(artists) { artist in
            NavigationLink {
                TrackListView(title: artist.name, trackIDs: artist.trackIDs, groupByAlbum: true)
            } label: {
                HStack(spacing: 12) {
                    ArtworkView(key: artist.artworkKey, size: 46, cornerRadius: 23)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(artist.name).font(.system(size: 15)).lineLimit(1)
                        Text("\(artist.albumCount) album\(artist.albumCount == 1 ? "" : "s") · \(artist.trackIDs.count) tracks")
                            .font(.system(size: 11.5))
                            .foregroundStyle(themes.theme.textSecondary)
                    }
                }
            }
        }
        .listStyle(.plain)
        .searchable(text: $query, prompt: "Search artists")
        .navigationTitle("Artists")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct GenresView: View {
    @EnvironmentObject private var library: MediaLibrary
    @EnvironmentObject private var themes: ThemeManager

    var body: some View {
        List(library.genres) { genre in
            NavigationLink {
                TrackListView(title: genre.name, trackIDs: genre.trackIDs)
            } label: {
                HStack(spacing: 12) {
                    ArtworkView(key: genre.artworkKey, size: 46, cornerRadius: 8)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(genre.name).font(.system(size: 15))
                        Text("\(genre.trackIDs.count) tracks")
                            .font(.system(size: 11.5))
                            .foregroundStyle(themes.theme.textSecondary)
                    }
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("Genres")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Playlists

struct PlaylistsView: View {

    @EnvironmentObject private var library: MediaLibrary
    @EnvironmentObject private var player: PlaybackController
    @EnvironmentObject private var themes: ThemeManager

    @State private var showNew = false
    @State private var newName = ""

    var body: some View {
        Group {
            if library.playlists.isEmpty {
                EmptyStateView(symbol: "text.badge.plus",
                               title: "No playlists",
                               message: "Create one here, or drop an .m3u file into a folder you have indexed.",
                               actionTitle: "New Playlist",
                               action: { showNew = true })
            } else {
                List {
                    ForEach(library.playlists) { playlist in
                        NavigationLink {
                            TrackListView(title: playlist.name,
                                          trackIDs: playlist.trackIDs,
                                          playlistID: playlist.id)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: playlist.importedFrom == nil ? "music.note.list" : "doc.text")
                                    .foregroundStyle(themes.accent)
                                    .frame(width: 24)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(playlist.name).font(.system(size: 15))
                                    Text("\(playlist.trackIDs.count) tracks")
                                        .font(.system(size: 11.5))
                                        .foregroundStyle(themes.theme.textSecondary)
                                }
                            }
                        }
                        .swipeActions {
                            Button(role: .destructive) {
                                library.deletePlaylist(playlist.id)
                            } label: { Label("Delete", systemImage: "trash") }
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("Playlists")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showNew = true } label: { Image(systemName: "plus") }
                    .tint(themes.accent)
            }
        }
        .alert("New Playlist", isPresented: $showNew) {
            TextField("Name", text: $newName)
            Button("Cancel", role: .cancel) { newName = "" }
            Button("Create") {
                let name = newName.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { library.createPlaylist(named: name) }
                newName = ""
            }
        }
    }
}

// MARK: - Shared track list

struct TrackListView: View {

    let title: String
    let trackIDs: [UUID]
    var groupByAlbum: Bool = false
    var playlistID: UUID?

    @EnvironmentObject private var library: MediaLibrary
    @EnvironmentObject private var player: PlaybackController
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var themes: ThemeManager
    @State private var query = ""

    private var tracks: [Track] {
        var list = library.tracks(ids: trackIDs)
        if !query.isEmpty {
            let q = query.lowercased()
            list = list.filter {
                $0.displayTitle.lowercased().contains(q)
                || $0.displayArtist.lowercased().contains(q)
                || $0.displayAlbum.lowercased().contains(q)
            }
        }
        if playlistID == nil {
            list.sort(by: settings.trackSort.comparator(ascending: settings.trackSortAscending))
        }
        return list
    }

    var body: some View {
        List {
            if groupByAlbum {
                let grouped = Dictionary(grouping: tracks, by: \.albumKey)
                ForEach(grouped.keys.sorted(), id: \.self) { key in
                    let items = (grouped[key] ?? []).sorted(by: TrackSort.trackNumber.comparator(ascending: true))
                    Section(items.first?.displayAlbum ?? "") {
                        rows(items)
                    }
                }
            } else {
                rows(tracks)
            }
        }
        .listStyle(.plain)
        .searchable(text: $query, prompt: "Filter")
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        player.play(trackIDs: tracks.map(\.id), sourceName: title)
                    } label: { Label("Play All", systemImage: "play.fill") }
                    Button {
                        player.play(trackIDs: tracks.map(\.id).shuffled(), sourceName: title)
                    } label: { Label("Shuffle All", systemImage: "shuffle") }
                    Button {
                        player.enqueue(tracks.map(\.id), playNext: false)
                    } label: { Label("Add to Queue", systemImage: "text.append") }

                    if playlistID == nil {
                        Divider()
                        Picker("Sort", selection: Binding(
                            get: { settings.trackSort },
                            set: { settings.trackSort = $0 })) {
                            ForEach(TrackSort.allCases) { Text($0.label).tag($0) }
                        }
                        Toggle("Ascending", isOn: Binding(
                            get: { settings.trackSortAscending },
                            set: { settings.trackSortAscending = $0 }))
                    }
                } label: { Image(systemName: "ellipsis.circle") }
                .tint(themes.accent)
            }
        }
    }

    private var deleteHandler: ((IndexSet) -> Void)? {
        guard let id = playlistID else { return nil }
        return { offsets in library.removeFromPlaylist(id, at: offsets) }
    }

    private var moveHandler: ((IndexSet, Int) -> Void)? {
        guard let id = playlistID else { return nil }
        return { from, to in library.movePlaylistItems(id, from: from, to: to) }
    }

    @ViewBuilder
    private func rows(_ items: [Track]) -> some View {
        ForEach(Array(items.enumerated()), id: \.element.id) { index, track in
            TrackRow(track: track,
                     isCurrent: player.currentTrack?.id == track.id,
                     isPlaying: player.currentTrack?.id == track.id && player.isPlaying)
                .contentShape(Rectangle())
                .onTapGesture {
                    player.play(trackIDs: items.map(\.id), startIndex: index, sourceName: title)
                    Haptics.tap()
                }
                .trackContextMenu(track: track)
        }
        .onDelete(perform: deleteHandler)
        .onMove(perform: moveHandler)
    }
}

// MARK: - Shared context menu

private struct TrackContextMenu: ViewModifier {
    let track: Track
    @EnvironmentObject private var library: MediaLibrary
    @EnvironmentObject private var player: PlaybackController
    @State private var showInfo = false

    func body(content: Content) -> some View {
        content
            .contextMenu {
                Button { player.enqueue([track.id], playNext: true) } label: {
                    Label("Play Next", systemImage: "text.insert")
                }
                Button { player.enqueue([track.id], playNext: false) } label: {
                    Label("Add to Queue", systemImage: "text.append")
                }
                Menu("Add to Playlist") {
                    ForEach(library.playlists) { p in
                        Button(p.name) { library.addToPlaylist(p.id, trackIDs: [track.id]) }
                    }
                    if library.playlists.isEmpty { Text("No playlists yet") }
                }
                Menu("Rate") {
                    ForEach((0...5).reversed(), id: \.self) { r in
                        Button(r == 0 ? "No rating" : String(repeating: "★", count: r)) {
                            library.setRating(r, for: track.id)
                        }
                    }
                }
                Divider()
                Button { showInfo = true } label: { Label("Track Info", systemImage: "info.circle") }
            }
            .sheet(isPresented: $showInfo) {
                TrackInfoView(track: track).presentationDetents([.medium, .large])
            }
    }
}

extension View {
    func trackContextMenu(track: Track) -> some View {
        modifier(TrackContextMenu(track: track))
    }
}
