//
//  SongDetailView.swift
//  AppGuitarra
//
//  Play along with an imported song: the current chord (as the shape you
//  finger, with capo and easy chords applied), the next one, a chord strip,
//  speed 50–100 % without changing pitch, a loop for hard parts, and the
//  strum pattern (guessed from the recording, or picked from the lessons)
//  with the current stroke lit in time with the song. Separated songs get a
//  mixer to bring the guitar up or take it out.
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
                .onAppear { loadPlayer(song) }
                .onChange(of: song.stems != nil) { _, _ in loadPlayer(song) }
                .onDisappear { player.stop() }
                .onChange(of: speed) { _, value in player.rate = value.rate }
        } else {
            ContentUnavailableView("Song not found", systemImage: "music.note")
        }
    }

    /// The separated tracks when there are, else the original file.
    private func loadPlayer(_ song: Song) {
        if let mix = song.stems, store.hasStems(song) {
            let urls = Dictionary(uniqueKeysWithValues: Stem.allCases.map { ($0, store.stemURL($0, for: song)) })
            player.load(stems: urls, mix: mix)
        } else {
            player.load(url: store.audioURL(for: song))
        }
    }

    private func content(_ song: Song) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                statusBanner(song)
                TracksPanel(
                    song: song,
                    hasStems: store.hasStems(song) && !player.stems.isEmpty,
                    progress: store.separation[song.id],
                    error: store.separationErrors[song.id],
                    isAnalyzing: store.progress[song.id] != nil,
                    onSeparate: { store.separate(song) },
                    onCancel: { store.cancelSeparation(song) },
                    onPreview: { player.setMix($0) },
                    onCommit: { mix in
                        player.setMix(mix)
                        update(song) { $0.stems = mix }
                    },
                    onFindChords: { Task { await store.analyze(song) } }
                )
                if song.status == .ready || !song.chords.isEmpty {
                    capoSettings(song)
                }
                TimelineView(.animation(minimumInterval: 1 / 30, paused: !player.isPlaying)) { _ in
                    let time = player.currentTime()
                    VStack(alignment: .leading, spacing: 24) {
                        SongStage(song: song, time: time, library: store.library, chords: store.chords)
                        StrumPanel(
                            song: song,
                            time: time,
                            isPlaying: player.isPlaying,
                            patterns: store.patterns,
                            patternsByID: store.patternsByID,
                            isFinding: store.progress[song.id] != nil,
                            onFind: { Task { await store.findStrum(song) } },
                            edit: { change in update(song, change) }
                        )
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
                if song.stems == nil {
                    Button("Split into tracks", systemImage: "slider.vertical.3") { store.separate(song) }
                        .disabled(!StemSeparator.isAvailable || store.separation[song.id] != nil)
                } else {
                    Button("Delete separated tracks", systemImage: "trash", role: .destructive) {
                        player.pause()
                        store.removeStems(song)
                    }
                }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
        }
    }
}

// MARK: - Separated tracks

/// Split the song into drums, bass, guitar & others and vocals, then set how
/// loud each one plays.
private struct TracksPanel: View {
    let song: Song
    let hasStems: Bool
    /// 0...1 while separating.
    let progress: Double?
    let error: String?
    let isAnalyzing: Bool
    let onSeparate: () -> Void
    let onCancel: () -> Void
    /// While a slider moves: only the player changes.
    let onPreview: (StemMix) -> Void
    /// When it's let go, or a preset is picked: saved with the song.
    let onCommit: (StemMix) -> Void
    let onFindChords: () -> Void

    @State private var draft: StemMix?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let progress {
                separating(progress)
            } else if hasStems, let mix = song.stems {
                mixer(draft ?? mix)
            } else {
                offer
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 20).fill(Color(uiColor: .secondarySystemBackground)))
    }

    private var offer: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 16) {
                Image(systemName: "slider.vertical.3")
                    .font(.largeTitle)
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Hear the guitar better")
                        .font(.title3.weight(.semibold))
                    Text("Splits the song into vocals, drums, bass and guitar, right on your iPad. Then you can turn the guitar up, play it alone, or take it out and play that part yourself.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Split into tracks", systemImage: "wand.and.stars", action: onSeparate)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!StemSeparator.isAvailable)
            }
            if !StemSeparator.isAvailable {
                Label("The separation model isn't in this build (HTDemucs.mlpackage, see tools/demucs).", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            }
        }
    }

    private func separating(_ progress: Double) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Splitting the song into tracks…", systemImage: "wand.and.stars")
                    .font(.title3.weight(.semibold))
                Spacer()
                Text("\(Int((progress * 100).rounded())) %")
                    .font(.headline.monospacedDigit())
                Button("Cancel", role: .cancel, action: onCancel)
                    .buttonStyle(.bordered)
            }
            ProgressView(value: progress)
            Text("Keep the app open. It takes about as long as the song, often less.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private func mixer(_ mix: StemMix) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("Tracks", systemImage: "slider.vertical.3")
                    .font(.title3.weight(.semibold))
                Spacer()
                Picker("Mix", selection: Binding(
                    get: { mix.preset },
                    set: { preset in
                        guard let preset else { return }
                        draft = nil
                        onCommit(preset.mix)
                    }
                )) {
                    ForEach(StemMix.Preset.allCases) { preset in
                        Text(preset.title).tag(Optional(preset))
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 520)
            }
            Text(mix.preset?.explanation ?? "Your own mix.")
                .foregroundStyle(.secondary)

            ForEach(Stem.allCases) { stem in
                HStack(spacing: 14) {
                    Label(stem.title, systemImage: stem.systemImage)
                        .font(.headline)
                        .frame(width: 190, alignment: .leading)
                    Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                    Slider(
                        value: Binding(
                            get: { mix.volume(stem) },
                            set: { value in
                                var changed = draft ?? mix
                                changed.setVolume(value, for: stem)
                                draft = changed
                                onPreview(changed)
                            }
                        ),
                        in: 0...1,
                        onEditingChanged: { editing in
                            if !editing, let draft {
                                onCommit(draft)
                                self.draft = nil
                            }
                        }
                    )
                    Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
                    Text("\(Int((mix.volume(stem) * 100).rounded())) %")
                        .font(.subheadline.monospacedDigit())
                        .frame(width: 52, alignment: .trailing)
                }
            }

            if song.chordsFromStems != true {
                HStack(spacing: 12) {
                    Label("The chords were found from the full song. From the guitar and bass alone they're usually more accurate.", systemImage: "lightbulb")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Find chords again", systemImage: "waveform", action: onFindChords)
                        .buttonStyle(.bordered)
                        .disabled(isAnalyzing)
                }
                Text("This replaces the chords, including any you fixed by hand.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Strum pattern

/// The pattern as arrows with the current stroke lit, a moving pick, and
/// controls to pick another pattern or move where the bar starts.
private struct StrumPanel: View {
    let song: Song
    let time: Double
    let isPlaying: Bool
    let patterns: [StrumPattern]
    let patternsByID: [String: StrumPattern]
    let isFinding: Bool
    let onFind: () -> Void
    let edit: ((inout Song) -> Void) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            if let pattern = song.strumPattern(library: patternsByID), song.barOffset != nil, song.bpm != nil {
                stage(pattern)
                footnote(pattern)
            } else if song.status == .ready || !song.chords.isEmpty {
                findPrompt
            }
        }
        .padding(24)
        .background(RoundedRectangle(cornerRadius: 24).fill(Color(uiColor: .secondarySystemBackground)))
    }

    private var header: some View {
        HStack(spacing: 14) {
            Label("Strum pattern", systemImage: "arrow.up.arrow.down")
                .font(.title2.weight(.bold))
            if let pattern = song.strumPattern(library: patternsByID) {
                Text(pattern.name)
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if song.strum != nil || song.patternID != nil {
                patternMenu
                beatShift
            }
        }
    }

    private var patternMenu: some View {
        Menu {
            if let detected = song.strum {
                Button {
                    edit { $0.patternID = nil }
                } label: {
                    Label("Heard in the song (\(spaced(detected.strokes)))",
                          systemImage: song.patternID == nil ? "checkmark" : "waveform")
                }
                Divider()
            }
            ForEach(patterns) { pattern in
                Button {
                    edit { $0.patternID = pattern.id }
                } label: {
                    if song.patternID == pattern.id {
                        Label(pattern.name, systemImage: "checkmark")
                    } else {
                        Text(pattern.name)
                    }
                }
            }
            Divider()
            Button("Listen again for the pattern", systemImage: "waveform") { onFind() }
                .disabled(isFinding)
            if let bpm = song.bpm {
                Button("Tempo is double (\(Int((bpm / 2).rounded())) bpm)", systemImage: "tortoise") {
                    edit { $0.bpm = bpm / 2 }
                }
                Button("Tempo is half (\(Int((bpm * 2).rounded())) bpm)", systemImage: "hare") {
                    edit { $0.bpm = bpm * 2 }
                }
            }
        } label: {
            Label("Change", systemImage: "slider.horizontal.3")
                .font(.headline)
        }
        .buttonStyle(.bordered)
    }

    /// Moves the "1" one beat earlier or later, for when the arrows feel shifted.
    private var beatShift: some View {
        HStack(spacing: 6) {
            Button { shift(by: -1) } label: { Image(systemName: "chevron.left") }
            Text("Move the 1")
                .font(.subheadline.weight(.semibold))
            Button { shift(by: 1) } label: { Image(systemName: "chevron.right") }
        }
        .buttonStyle(.bordered)
        .disabled(song.barOffset == nil || song.bpm == nil)
    }

    private func shift(by beats: Int) {
        edit { song in
            guard let bpm = song.bpm, let offset = song.barOffset else { return }
            song.barOffset = offset + Double(beats) * 60 / bpm
        }
    }

    private func stage(_ pattern: StrumPattern) -> some View {
        let index = song.chordIndex(at: time)
        let hasChord = index.map { !song.chords[$0].isNoChord } ?? false
        let position = isPlaying && hasChord ? song.strumPosition(at: time, pattern: pattern) : nil
        let stroke = position.map { pattern.slots[$0.slot] } ?? .miss

        return HStack(alignment: .center, spacing: 24) {
            StrumPatternView(pattern: pattern, activeSlot: position?.slot)
            if pattern.slotsPerBeat == 2 {
                PickMotionView(
                    slot: position?.slot,
                    fraction: position?.fraction ?? 0,
                    hits: position != nil && stroke.isPlayed
                )
                .frame(width: 70, height: 150)
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func footnote(_ pattern: StrumPattern) -> some View {
        if song.patternID == nil, let guess = song.strum {
            VStack(alignment: .leading, spacing: 6) {
                if let match = StrumDetector.closest(to: guess.strokes, in: patterns) {
                    Label(match.distance == 0 ? "This is the \(match.pattern.name.lowercased()) from the lessons."
                                              : "Close to the \(match.pattern.name.lowercased()) from the lessons. Try it from Change.",
                          systemImage: "graduationcap")
                }
                Label(guess.confidence < 0.25
                      ? "Not sure about this one: the drums or voice cover the guitar. Listen and pick a pattern from Change if it doesn't fit."
                      : "Guessed from where the song's hits fall: down on the beat, up on the \"and\". If the arrows feel off by a beat, use Move the 1.",
                      systemImage: guess.confidence < 0.25 ? "questionmark.circle" : "info.circle")
                    .foregroundStyle(.secondary)
                if guess.strokes.contains("x") {
                    Label("x = chuck: those hits die at once, so the strings are muted with the strumming hand or the fretting hand.",
                          systemImage: "hand.raised")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.subheadline)
        } else {
            Label("Picked from the lessons. The arrows follow the song's tempo\(song.bpm.map { " (\(Int($0.rounded())) bpm)" } ?? "").",
                  systemImage: "info.circle")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var findPrompt: some View {
        HStack(spacing: 16) {
            Text("Listen to the song again to guess how it's strummed. Your chords stay as they are.")
                .font(.title3)
            Spacer()
            if isFinding {
                ProgressView()
                Text("Listening…").foregroundStyle(.secondary)
            } else {
                Button("Find the strum pattern", systemImage: "waveform") { onFind() }
                    .buttonStyle(.borderedProminent)
            }
            Menu("Pick one") {
                ForEach(patterns) { pattern in
                    Button(pattern.name) {
                        edit { song in
                            song.patternID = pattern.id
                            // Without a guess, bars start on the first chord.
                            if song.barOffset == nil {
                                song.barOffset = song.chords.first(where: { !$0.isNoChord })?.start ?? 0
                            }
                        }
                    }
                }
            }
            .buttonStyle(.bordered)
            .disabled(song.bpm == nil)
        }
    }

    private func spaced(_ strokes: String) -> String {
        strokes.map { $0 == "D" ? "↓" : $0 == "U" ? "↑" : "·" }.joined(separator: " ")
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
