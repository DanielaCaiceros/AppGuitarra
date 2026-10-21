//
//  TasteView.swift
//  AppGuitarra
//
//  "My songs": favorite artists, how you feel about each song in the catalog,
//  and the chords you already play. The path re-ranks as you change anything.
//

import SwiftUI

struct TasteView: View {
    let content: PathContent

    @Environment(PathStore.self) private var store
    @Environment(LessonProgress.self) private var progress
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    private var artists: [String] {
        Array(Set(content.songs.map(\.artist))).sorted()
    }

    /// Chords that count as known because a finished lesson taught them.
    private var fromLessons: Set<String> {
        Set(content.lessons.lessons.filter { progress.isCompleted($0) }.flatMap(\.chords))
    }

    private var filteredSongs: [CatalogSong] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return content.songs }
        return content.songs.filter {
            $0.title.localizedCaseInsensitiveContains(query) || $0.artist.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 32) {
                    section("Artists you like", subtitle: "Their songs go on your path.") {
                        FlowChips(items: artists, selected: store.preferences.favoriteArtists) { store.toggleArtist($0) }
                    }

                    section("Chords you already play", subtitle: "Chords from finished lessons are on automatically.") {
                        let ids = content.lessons.chords.keys.sorted { order($0) < order($1) }
                        ChipLayout(spacing: 10) {
                            ForEach(ids, id: \.self) { chord in
                                chordChip(chord)
                            }
                        }
                    }

                    section("Songs", subtitle: "Mark the ones you want to learn next and the ones you can half-play.") {
                        VStack(spacing: 0) {
                            ForEach(filteredSongs) { song in
                                songRow(song)
                                Divider()
                            }
                        }
                    }
                }
                .padding(32)
            }
            .searchable(text: $search, prompt: "Search songs or artists")
            .navigationTitle("My songs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .font(.headline)
                }
            }
        }
    }

    private func section<Content: View>(_ title: String, subtitle: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.title2.weight(.bold))
            Text(subtitle)
                .foregroundStyle(.secondary)
            content()
        }
    }

    /// Library order: majors, minors, sevenths, then the rest.
    private func order(_ chord: String) -> Int {
        let ordered = ["C", "D", "E", "G", "A", "Am", "Dm", "Em", "Bm", "E7", "A7", "D7", "G7", "B7", "F", "Fmaj7"]
        return ordered.firstIndex(of: chord) ?? ordered.count
    }

    private func chordChip(_ chord: String) -> some View {
        let locked = fromLessons.contains(chord)
        let isOn = locked || store.preferences.knownChords.contains(chord)
        return Button {
            store.toggleKnownChord(chord)
        } label: {
            HStack(spacing: 6) {
                if locked { Image(systemName: "graduationcap.fill") }
                Text(chord)
            }
            .font(.headline)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .foregroundStyle(isOn ? Color.white : Color.primary)
            .background(Capsule().fill(isOn ? Color.green : Color.secondary.opacity(0.12)))
        }
        .buttonStyle(.plain)
        .disabled(locked)
        .accessibilityLabel(locked ? "\(chord), learned in a lesson" : chord)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    private func songRow(_ song: CatalogSong) -> some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(song.title)
                    .font(.headline)
                Text("\(song.artist) · \(song.chords.joined(separator: " "))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Picker("How you feel about \(song.title)", selection: Binding(
                get: { store.interest(for: song.id) },
                set: { store.setInterest($0, for: song.id) }
            )) {
                ForEach(SongInterest.allCases) { interest in
                    Text(interest.label).tag(interest)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 330)
        }
        .padding(.vertical, 12)
    }
}
