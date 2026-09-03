//
//  SearchView.swift
//  Sonora
//

import SwiftUI

struct SearchView: View {

    @EnvironmentObject private var library: MediaLibrary
    @EnvironmentObject private var player: PlaybackController
    @EnvironmentObject private var themes: ThemeManager

    @State private var query = ""
    @State private var scope: Scope = .all

    enum Scope: String, CaseIterable, Identifiable {
        case all = "All", tracks = "Tracks", albums = "Albums", artists = "Artists"
        var id: String { rawValue }
    }

    private var results: [Track] { library.search(query) }

    private var albumResults: [AlbumGroup] {
        guard !query.isEmpty else { return [] }
        let q = query.lowercased()
        return library.albums.filter {
            $0.title.lowercased().contains(q) || $0.artist.lowercased().contains(q)
        }
    }

    private var artistResults: [ArtistGroup] {
        guard !query.isEmpty else { return [] }
        let q = query.lowercased()
        return library.artists.filter { $0.name.lowercased().contains(q) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if query.isEmpty {
                    EmptyStateView(symbol: "magnifyingglass",
                                   title: "Search your library",
                                   message: "Titles, artists, albums, genres and file names.")
                } else if results.isEmpty && albumResults.isEmpty && artistResults.isEmpty {
                    EmptyStateView(symbol: "questionmark.folder",
                                   title: "No matches",
                                   message: "Nothing in your library matches “\(query)”.")
                } else {
                    List {
                        if scope == .all || scope == .artists, !artistResults.isEmpty {
                            Section("Artists") {
                                ForEach(artistResults.prefix(scope == .all ? 4 : 100)) { artist in
                                    NavigationLink {
                                        TrackListView(title: artist.name, trackIDs: artist.trackIDs, groupByAlbum: true)
                                    } label: {
                                        HStack(spacing: 12) {
                                            ArtworkView(key: artist.artworkKey, size: 42, cornerRadius: 21)
                                            Text(artist.name).font(.system(size: 15))
                                        }
                                    }
                                }
                            }
                        }
                        if scope == .all || scope == .albums, !albumResults.isEmpty {
                            Section("Albums") {
                                ForEach(albumResults.prefix(scope == .all ? 4 : 200)) { album in
                                    NavigationLink { AlbumDetailView(album: album) } label: {
                                        HStack(spacing: 12) {
                                            ArtworkView(key: album.artworkKey, size: 42, cornerRadius: 6)
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(album.title).font(.system(size: 15)).lineLimit(1)
                                                Text(album.artist).font(.system(size: 11.5))
                                                    .foregroundStyle(themes.theme.textSecondary)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                        if scope == .all || scope == .tracks, !results.isEmpty {
                            Section("Tracks") {
                                ForEach(Array(results.enumerated()), id: \.element.id) { index, track in
                                    TrackRow(track: track,
                                             isCurrent: player.currentTrack?.id == track.id,
                                             isPlaying: player.currentTrack?.id == track.id && player.isPlaying)
                                        .contentShape(Rectangle())
                                        .onTapGesture {
                                            player.play(trackIDs: results.map(\.id),
                                                        startIndex: index,
                                                        sourceName: "Search")
                                            Haptics.tap()
                                        }
                                        .trackContextMenu(track: track)
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .background(themes.theme.background)
            .navigationTitle("Search")
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Songs, albums, artists")
            .toolbar {
                ToolbarItem(placement: .principal) {
                    if !query.isEmpty {
                        Picker("", selection: $scope) {
                            ForEach(Scope.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 300)
                    }
                }
            }
        }
    }
}
