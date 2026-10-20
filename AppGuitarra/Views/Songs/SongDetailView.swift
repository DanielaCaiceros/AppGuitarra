//
//  SongDetailView.swift
//  AppGuitarra
//
//  Play along with an imported song: the current chord (as the shape you
//  finger, with capo and easy chords applied), the next one, a chord strip,
//  speed 50–100 % without changing pitch, and a loop for hard parts.
//

import SwiftUI

struct SongDetailView: View {
    let songID: UUID

    @Environment(SongStore.self) private var store
    @State private var player = SongPlayer()
    @State private var speed: DemoSpeed = .normal
    @State private var showsEditor = false
    @State private var loopStart: Double?

    var body: some View {
        if let song = store.song(id: songID) {
            content(song)
                .navigationTitle(song.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbar(song) }
                .sheet(isPresented: $showsEditor) {
                    ChordEditorView(song: song, currentTime: player.currentTime()) { player.seek(to: $0) }
                }
                .onAppear { player.load(url: store.audioURL(for: song)) }
                .onDisappear { player.stop() }
                .onChange(of: speed) { _, value in player.rate = value.rate }
        } else {
            ContentUnavailableView("Song not found", systemImage: "music.note")
        }
    }

    private func content(_ song: Song) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                statusBanner(song)
                if song.status == .ready || !song.chords.isEmpty {
                    capoSettings(song)
                }
                TimelineView(.animation(minimumInterval: 1 / 30, paused: !player.isPlaying)) { _ in
                    let time = player.currentTime()
                    VStack(alignment: .leading, spacing: 24) {
                        SongStage(song: song, time: time, library: store.library, chords: store.chords)
                        ChordStrip(song: song, time: time, library: store.library, loop: player.loop) { player.seek(to: $0) }
                        transport(song, time: time)
                    }
                }
                if let error = player.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                }
            }
            .padding(32)
        }
    }

    // MARK: - Status and capo

    @ViewBuilder
    private func statusBanner(_ song: Song) -> some View {
        switch song.status {
        case .analyzing:
            VStack(alignment: .leading, spacing: 8) {
                Label("Listening to the song to find its chords and tempo…", systemImage: "waveform")
                    .font(.title3.weight(.semibold))
                ProgressView(value: store.progress[song.id] ?? 0)
            }
            .padding(20)
            .background(RoundedRectangle(cornerRadius: 16).fill(Color.accentColor.opacity(0.1)))
        case .failed(let message):
            HStack {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.title3)
                Spacer()
                Button("Try again") { Task { await store.analyze(song) } }
                    .buttonStyle(.borderedProminent)
            }
            .padding(20)
            .background(RoundedRectangle(cornerRadius: 16).fill(Color.orange.opacity(0.12)))
        case .ready:
            HStack(spacing: 20) {
                if let bpm = song.bpm {
                    Label("\(Int(bpm.rounded())) bpm", systemImage: "metronome")
                }
                Label("\(song.chords.filter { !$0.isNoChord }.count) chord changes", systemImage: "guitars")
                Label("Detected automatically. Fix any chord with Edit.", systemImage: "info.circle")
                    .foregroundStyle(.secondary)
            }
            .font(.headline)
        }
    }

    private func capoSettings(_ song: Song) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let suggested = song.suggestedCapo, suggested != song.capo {
                HStack {
                    Label("Capo on fret \(suggested) turns this song into easier shapes: \(shapes(song, capo: suggested).joined(separator: ", ")).",
                          systemImage: "lightbulb.fill")
                        .font(.title3)
                    Spacer()
                    Button("Use capo \(suggested)") { update(song) { $0.capo = suggested } }
                        .buttonStyle(.borderedProminent)
                }
                .padding(16)
                .background(RoundedRectangle(cornerRadius: 14).fill(Color.yellow.opacity(0.15)))
            }
            HStack(spacing: 28) {
                Stepper(value: Binding(get: { song.capo }, set: { value in update(song) { $0.capo = value } }), in: 0...7) {
                    Label(song.capo == 0 ? "No capo" : "Capo on fret \(song.capo)", systemImage: "guitars")
                        .font(.headline)
                }
                .frame(maxWidth: 320)
                Toggle(isOn: Binding(get: { song.easyChords }, set: { value in update(song) { $0.easyChords = value } })) {
                    Label("Easy chords (F → Fmaj7)", systemImage: "hand.thumbsup")
                        .font(.headline)
                }
                .frame(maxWidth: 360)
            }
        }
    }

    private func shapes(_ song: Song, capo: Int) -> [String] {
        var copy = song
        copy.capo = capo
        var result: [String] = []
        for chord in song.chords where !chord.isNoChord {
            let shape = copy.shape(for: chord.name, library: store.library)
            if !result.contains(shape) { result.append(shape) }
        }
        return result
    }

    private func update(_ song: Song, _ change: (inout Song) -> Void) {
        var copy = song
        change(&copy)
        store.save(copy)
    }

    // MARK: - Transport

    private func transport(_ song: Song, time: Double) -> some View {
        VStack(spacing: 16) {
            HStack(spacing: 16) {
                Text(formatTime(time))
                    .font(.headline.monospacedDigit())
                    .frame(width: 60, alignment: .trailing)
                Slider(value: Binding(get: { time }, set: { player.seek(to: $0) }), in: 0...max(1, player.duration))
                Text(formatTime(player.duration))
                    .font(.headline.monospacedDigit())
                    .frame(width: 60, alignment: .leading)
            }

            HStack(spacing: 20) {
                Button { player.seek(to: time - 5) } label: { Image(systemName: "gobackward.5") }
                    .font(.title)
                Button {
                    player.togglePlay()
                } label: {
                    Label(player.isPlaying ? "Pause" : "Play", systemImage: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title2.weight(.bold))
                        .frame(minWidth: 140, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.extraLarge)
                Button { player.seek(to: time + 5) } label: { Image(systemName: "goforward.5") }
                    .font(.title)

                Spacer()

                VStack(alignment: .leading, spacing: 6) {
                    Label("Speed", systemImage: "tortoise")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Picker("Speed", selection: $speed) {
                        ForEach(DemoSpeed.allCases) { value in
                            Text("\(Int(value.rate * 100)) %").tag(value)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 260)
                }
            }

            loopControls(song, time: time)
        }
        .padding(20)
        .background(RoundedRectangle(cornerRadius: 20).fill(Color(uiColor: .secondarySystemBackground)))
    }

    private func loopControls(_ song: Song, time: Double) -> some View {
        HStack(spacing: 14) {
            Image(systemName: "repeat")
                .font(.title2)
                .foregroundStyle(player.loop == nil ? Color.secondary : Color.accentColor)
            if let loop = player.loop {
                Text("Looping \(formatTime(loop.lowerBound)) – \(formatTime(loop.upperBound))")
                    .font(.headline.monospacedDigit())
                Button("Stop loop") {
                    player.loop = nil
                    loopStart = nil
                }
                .buttonStyle(.bordered)
            } else if let start = loopStart {
                Text("Loop from \(formatTime(start)) to…")
                    .font(.headline.monospacedDigit())
                Button("Set end here") {
                    if time > start + 0.5 { player.loop = start...time }
                    loopStart = nil
                    player.seek(to: start)
                }
                .buttonStyle(.borderedProminent)
                Button("Cancel") { loopStart = nil }
            } else {
                Button("Loop these 4 chords") { loopFourChords(song, time: time) }
                    .buttonStyle(.bordered)
                    .disabled(song.chords.isEmpty)
                Button("Set loop start here") { loopStart = time }
                    .buttonStyle(.bordered)
            }
            Spacer()
        }
        .font(.headline)
    }

    private func loopFourChords(_ song: Song, time: Double) {
        guard let index = song.chordIndex(at: time) ?? (song.chords.isEmpty ? nil : 0) else { return }
        let last = min(index + 3, song.chords.count - 1)
        let start = song.chords[index].start
        let end = song.end(ofChordAt: last)
        guard end > start + 0.5 else { return }
        player.loop = start...end
        player.seek(to: start)
        if !player.isPlaying { player.play() }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private func toolbar(_ song: Song) -> some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button("Edit chords", systemImage: "pencil") {
                player.pause()
                showsEditor = true
            }
            Menu {
                Button("Find chords again", systemImage: "waveform") { Task { await store.analyze(song) } }
                    .disabled(song.status == .analyzing)
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
        }
    }
}

// MARK: - Stage

/// Big current chord, its diagram and the next chord with a countdown.
private struct SongStage: View {
    let song: Song
    let time: Double
    let library: Set<String>
    let chords: [String: Chord]

    var body: some View {
        let index = song.chordIndex(at: time)
        let current = index.map { song.chords[$0] }
        let next: SongChord? = if let index {
            index + 1 < song.chords.count ? song.chords[index + 1] : nil
        } else {
            song.chords.first
        }

        HStack(alignment: .center, spacing: 32) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Now")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Text(current.map(display) ?? "—")
                    .font(.system(size: 96, weight: .heavy, design: .rounded))
                    .contentTransition(.numericText())
                    .animation(.snappy(duration: 0.15), value: current?.id)
                if let current, song.capo > 0, !current.isNoChord {
                    Text("Sounds as \(current.name) with capo \(song.capo)")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }
                if let index {
                    ProgressView(value: progress(index))
                        .frame(width: 260)
                }
            }
            .frame(minWidth: 280, alignment: .leading)

            if let current, let chord = chords[song.shape(for: current.name, library: library)] {
                ChordDiagramView(chord: chord)
                    .frame(width: 190)
            } else if let current, !current.isNoChord {
                Text("No diagram for \(display(current)) yet")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .frame(width: 190, height: 190)
                    .background(RoundedRectangle(cornerRadius: 16).strokeBorder(.secondary.opacity(0.3), style: StrokeStyle(lineWidth: 2, dash: [6])))
            }

            Spacer()

            if let next {
                VStack(alignment: .trailing, spacing: 8) {
                    Text("Next")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Text(display(next))
                        .font(.system(size: 56, weight: .bold, design: .rounded))
                    let wait = next.start - time
                    if wait >= 0 {
                        Text(String(format: "in %.1f s", wait))
                            .font(.title3.monospacedDigit().weight(.semibold))
                            .foregroundStyle(wait < 1 ? Color.orange : Color.secondary)
                    }
                }
            }
        }
        .padding(28)
        .background(RoundedRectangle(cornerRadius: 24).fill(Color.accentColor.opacity(0.07)))
    }

    private func display(_ chord: SongChord) -> String {
        chord.isNoChord ? "—" : song.shape(for: chord.name, library: library)
    }

    private func progress(_ index: Int) -> Double {
        let start = song.chords[index].start
        let end = song.end(ofChordAt: index)
        guard end > start else { return 1 }
        return min(1, max(0, (time - start) / (end - start)))
    }
}

/// All chords in order; tap one to jump there.
private struct ChordStrip: View {
    let song: Song
    let time: Double
    let library: Set<String>
    let loop: ClosedRange<Double>?
    let onSeek: (Double) -> Void

    var body: some View {
        let currentIndex = song.chordIndex(at: time)
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 10) {
                    ForEach(Array(song.chords.enumerated()), id: \.element.id) { index, chord in
                        let isCurrent = index == currentIndex
                        let inLoop = loop.map { $0.contains(chord.start) } ?? false
                        Button { onSeek(chord.start) } label: {
                            VStack(spacing: 4) {
                                Text(chord.isNoChord ? "—" : song.shape(for: chord.name, library: library))
                                    .font(.title2.weight(.bold))
                                Text(formatTime(chord.start))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(isCurrent ? Color.white.opacity(0.85) : Color.secondary)
                            }
                            .frame(minWidth: 70, minHeight: 64)
                            .padding(.horizontal, 6)
                            .foregroundStyle(isCurrent ? Color.white : Color.primary)
                            .background(
                                RoundedRectangle(cornerRadius: 14)
                                    .fill(isCurrent ? Color.accentColor : Color.secondary.opacity(0.1))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 14)
                                    .strokeBorder(inLoop ? Color.accentColor : .clear, lineWidth: 2)
                            )
                        }
                        .buttonStyle(.plain)
                        .id(chord.id)
                    }
                }
                .padding(.vertical, 4)
            }
            .onChange(of: currentIndex) { _, index in
                guard let index, song.chords.indices.contains(index) else { return }
                withAnimation(.easeInOut(duration: 0.3)) {
                    proxy.scrollTo(song.chords[index].id, anchor: .center)
                }
            }
        }
        .frame(height: 80)
    }
}
