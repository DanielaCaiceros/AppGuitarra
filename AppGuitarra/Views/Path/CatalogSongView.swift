//
//  CatalogSongView.swift
//  AppGuitarra
//
//  A song from the built-in catalog: why it's on your path, its chords (new
//  ones marked), and a play-along for each section with click and guide guitar.
//

import SwiftUI

struct CatalogSongView: View {
    let song: CatalogSong
    let content: PathContent

    @Environment(LessonProgress.self) private var progress
    @Environment(PathStore.self) private var store
    @Environment(SongStore.self) private var songStore
    @State private var sectionID: String?
    @State private var tempo: DemoSpeed = .slow

    private var snapshot: PathSnapshot {
        PathSnapshot(content: content, progress: progress, store: store, songStore: songStore)
    }

    private var section: CatalogSection? {
        song.sections.first { $0.id == sectionID } ?? song.sections.first
    }

    var body: some View {
        let current = snapshot
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header(current)
                chords(known: current.known)
                playAlong
                actions
            }
            .padding(32)
        }
        .navigationTitle(song.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Header

    private func header(_ snapshot: PathSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(song.title)
                .font(.largeTitle.weight(.bold))
            Text(song.artist)
                .font(.title2)
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                badge(song.capo == 0 ? "No capo" : "Capo \(song.capo)", systemImage: "guitars")
                badge(song.bpmChecked == true ? "\(song.bpm) bpm" : "~\(song.bpm) bpm", systemImage: "metronome")
                badge(content.lessons.patterns[song.pattern]?.name ?? song.pattern, systemImage: "arrow.up.arrow.down")
                sourceBadge
            }
            if let score = snapshot.score(for: song.id) {
                Label(score.reason, systemImage: "sparkles")
                    .font(.title3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let note = song.note {
                Label(note, systemImage: "info.circle")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let tempoNote = song.bpmNote {
                Label(tempoNote, systemImage: "metronome")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func badge(_ text: String, systemImage: String, tint: Color = .secondary) -> some View {
        Label(text, systemImage: systemImage)
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .foregroundStyle(tint == .secondary ? Color.primary : tint)
            .background(Capsule().fill(tint.opacity(0.12)))
    }

    @ViewBuilder
    private var sourceBadge: some View {
        switch song.source {
        case .checked: badge("Chords checked", systemImage: "checkmark.seal", tint: .green)
        case .common: badge("Standard chart", systemImage: "checkmark", tint: .green)
        case .review: badge("Check by ear", systemImage: "ear", tint: .orange)
        }
    }

    // MARK: - Chords

    private func chords(known: Set<String>) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Chords")
                .font(.title2.weight(.bold))
            ScrollView(.horizontal) {
                HStack(spacing: 20) {
                    ForEach(song.chords, id: \.self) { id in
                        if let chord = content.lessons.chords[id] {
                            VStack(spacing: 6) {
                                ChordDiagramView(chord: chord)
                                    .frame(width: 130, height: 170)
                                Text(known.contains(id) ? "You know it" : lessonHint(for: id))
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(known.contains(id) ? Color.green : Color.orange)
                                    .multilineTextAlignment(.center)
                                    .frame(width: 130)
                            }
                            .onTapGesture { ChordSynth.shared.strum(chord, stringDelay: 0.02) }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private func lessonHint(for chord: String) -> String {
        if let lesson = content.lessons.lessons.first(where: { $0.chords.contains(chord) }) {
            return "New · Lesson \(lesson.number)"
        }
        return "New · see Chords tab"
    }

    // MARK: - Play along

    @ViewBuilder
    private var playAlong: some View {
        if let section, let progression = section.progression, let pattern = content.lessons.patterns[song.pattern] {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Play along")
                        .font(.title2.weight(.bold))
                    Spacer()
                    if song.sections.count > 1 {
                        Picker("Section", selection: Binding(get: { section.id }, set: { sectionID = $0 })) {
                            ForEach(song.sections) { Text($0.name).tag($0.id) }
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 420)
                    }
                }
                Text(song.capo > 0
                     ? "One bar per chord as a guide; the recording may hold some chords longer. Put the capo on fret \(song.capo) to match the original key."
                     : "One bar per chord as a guide; the recording may hold some chords longer.")
                    .foregroundStyle(.secondary)
                PracticeStageView(
                    pattern: pattern,
                    segments: progression.compactMap { segment in
                        content.lessons.chords[segment.chord].map { PracticeSegment(chord: $0, bars: segment.bars) }
                    },
                    targetBpm: song.bpm,
                    mode: .practice,
                    tempo: $tempo,
                    onStart: { progress.recordPractice() }
                )
                .id("\(song.id)-\(section.id)")
            }
        }
    }

    // MARK: - Actions

    private var actions: some View {
        HStack(spacing: 16) {
            Picker("How you feel about it", selection: Binding(
                get: { store.interest(for: song.id) },
                set: { store.setInterest($0, for: song.id) }
            )) {
                ForEach(SongInterest.allCases) { interest in
                    Label(interest.label, systemImage: interest.systemImage).tag(interest)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 420)

            Spacer()

            let learned = store.isLearned(song.id)
            Button {
                store.setLearned(!learned, songID: song.id)
                if !learned { progress.recordPractice() }
            } label: {
                Label(learned ? "You play this song" : "I can play it now",
                      systemImage: learned ? "checkmark.seal.fill" : "checkmark.seal")
                    .font(.title3.weight(.semibold))
                    .frame(minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .tint(learned ? .green : .accentColor)
            .controlSize(.large)
        }
    }
}
