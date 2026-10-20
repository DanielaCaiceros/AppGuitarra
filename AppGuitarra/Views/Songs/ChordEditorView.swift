//
//  ChordEditorView.swift
//  AppGuitarra
//
//  Fix the detected chords: change a chord, nudge when it starts, delete it,
//  or add one at the current playback position.
//

import SwiftUI

struct ChordEditorView: View {
    @Environment(SongStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var draft: Song
    let currentTime: Double
    let onSeek: (Double) -> Void

    init(song: Song, currentTime: Double, onSeek: @escaping (Double) -> Void) {
        _draft = State(initialValue: song)
        self.currentTime = currentTime
        self.onSeek = onSeek
    }

    /// Sounding chord names offered in the menus.
    private static let roots = ChordSymbol.rootNames
    private static let qualities: [ChordSymbol.Quality] = [.major, .minor, .seventh, .minorSeventh, .majorSeventh]

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        addChord(at: currentTime)
                    } label: {
                        Label("Add a chord at \(formatTime(currentTime))", systemImage: "plus.circle.fill")
                    }
                } footer: {
                    Text("Names are the chords as they sound. With a capo, the app shows the shapes to play.")
                }

                Section("Chords") {
                    ForEach($draft.chords) { $chord in
                        row($chord)
                    }
                    .onDelete { draft.chords.remove(atOffsets: $0) }
                }
            }
            .navigationTitle("Edit chords")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        var song = draft
                        song.normalizeChords()
                        if song.status != .analyzing { song.status = song.chords.isEmpty ? song.status : .ready }
                        store.save(song)
                        dismiss()
                    }
                    .bold()
                }
            }
        }
    }

    private func row(_ chord: Binding<SongChord>) -> some View {
        HStack(spacing: 16) {
            Button {
                onSeek(chord.wrappedValue.start)
            } label: {
                Image(systemName: "play.circle")
                    .font(.title2)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Play from here")

            Text(formatTime(chord.wrappedValue.start) + "." + String(Int(chord.wrappedValue.start * 10) % 10))
                .font(.body.monospacedDigit())
                .frame(width: 70, alignment: .leading)

            Stepper("Start", value: chord.start, in: 0...max(0, draft.duration), step: 0.25)
                .labelsHidden()

            Spacer()

            chordMenu(chord)

            if !chord.wrappedValue.isNoChord {
                let shape = draft.shape(for: chord.wrappedValue.name, library: store.library)
                Text(shape == chord.wrappedValue.name ? " " : "play \(shape)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(width: 90, alignment: .leading)
            }
        }
    }

    private func chordMenu(_ chord: Binding<SongChord>) -> some View {
        Menu {
            Section("In the app") {
                ForEach(store.library.sorted(), id: \.self) { id in
                    Button(id) { chord.wrappedValue.name = id }
                }
            }
            ForEach(Self.qualities, id: \.self) { quality in
                Menu(Self.menuTitle(quality)) {
                    ForEach(Self.roots, id: \.self) { root in
                        let name = root + quality.rawValue
                        Button(name) { chord.wrappedValue.name = name }
                    }
                }
            }
            Button("No chord (—)") { chord.wrappedValue.name = ChordSymbol.noChord }
        } label: {
            Text(chord.wrappedValue.isNoChord ? "—" : chord.wrappedValue.name)
                .font(.title3.weight(.bold))
                .frame(minWidth: 80)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.accentColor.opacity(0.12)))
        }
    }

    private static func menuTitle(_ quality: ChordSymbol.Quality) -> String {
        switch quality {
        case .major: "Major"
        case .minor: "Minor (m)"
        case .seventh: "Seventh (7)"
        case .minorSeventh: "Minor seventh (m7)"
        case .majorSeventh: "Major seventh (maj7)"
        }
    }

    private func addChord(at time: Double) {
        let previous = draft.chordIndex(at: time).map { draft.chords[$0].name } ?? "G"
        draft.chords.append(SongChord(start: time, name: previous))
        draft.chords.sort { $0.start < $1.start }
    }
}
