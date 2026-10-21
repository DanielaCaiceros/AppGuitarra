//
//  PathView.swift
//  AppGuitarra
//
//  Home: your practice streak and your personalized path, songs you like in
//  the order that suits you best, with the lessons you still need in between.
//

import SwiftUI

nonisolated enum PathDestination: Hashable {
    case lesson(Lesson)
    case catalogSong(String)
    case importedSong(UUID)
}

/// Everything the path screens need, loaded once from the bundle.
struct PathContent {
    let lessons: LessonCatalog
    let songs: [CatalogSong]

    static func load() throws -> PathContent {
        let lessons = try LessonCatalog.load()
        let songs = try SongCatalog.load()
        #if DEBUG
        let problems = SongCatalog.validationErrors(songs, chords: Set(lessons.chords.keys), patterns: Set(lessons.patterns.keys))
        assert(problems.isEmpty, "Song catalog problems:\n" + problems.joined(separator: "\n"))
        #endif
        return PathContent(lessons: lessons, songs: songs)
    }

    var pathLessons: [PathLesson] { lessons.lessons.map(PathLesson.init) }
    var candidates: [PathCandidate] { songs.map(PathCandidate.init) }
}

/// The path as computed from the stores (shared by the home screen and the song screen).
struct PathSnapshot {
    let known: Set<String>
    let level: Int
    let items: [PathItem]
    let pool: [PathCandidate]

    @MainActor
    init(content: PathContent, progress: LessonProgress, store: PathStore, songStore: SongStore) {
        let preferences = store.preferences
        let lessons = content.pathLessons
        let imported = Self.importedCandidates(songStore)
        let all = content.candidates + imported
        known = PathRanker.knownChords(preferences: preferences, completedLessons: progress.completed, lessons: lessons, songs: all)
        level = PathRanker.level(completedLessons: progress.completed, lessons: lessons, preferences: preferences, songs: all)
        pool = PathRanker.pool(catalog: content.candidates, imported: imported, preferences: preferences)
        items = PathRanker.buildPath(pool: pool, lessons: lessons, completedLessons: progress.completed,
                                     known: known, level: level, preferences: preferences)
    }

    @MainActor
    static func importedCandidates(_ store: SongStore) -> [PathCandidate] {
        store.songs.compactMap { song in
            guard case .ready = song.status else { return nil }
            var shapes: [String] = []
            for chord in song.chords where !chord.isNoChord {
                let shape = song.shape(for: chord.name, library: store.library)
                if !shapes.contains(shape) { shapes.append(shape) }
            }
            guard !shapes.isEmpty else { return nil }
            return PathCandidate(id: PathCandidate.importedID(song.id), title: song.title, artist: nil,
                                 chords: shapes, bpm: song.bpm.map { Int($0.rounded()) }, pattern: nil)
        }
    }

    func score(for songID: String) -> PathScore? {
        for item in items {
            if case .song(let song, let score) = item, song.id == songID { return score }
        }
        return nil
    }
}

struct PathView: View {
    @Environment(LessonProgress.self) private var progress
    @Environment(PathStore.self) private var store
    @Environment(SongStore.self) private var songStore

    @State private var content: PathContent?
    @State private var loadError: String?
    @State private var navigation: [PathDestination] = []
    @State private var showingTaste = false

    var body: some View {
        NavigationStack(path: $navigation) {
            Group {
                if let content {
                    home(content, snapshot: PathSnapshot(content: content, progress: progress, store: store, songStore: songStore))
                } else if let loadError {
                    ContentUnavailableView("Path unavailable", systemImage: "exclamationmark.triangle", description: Text(loadError))
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Your path")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingTaste = true
                    } label: {
                        Label("My songs", systemImage: "heart.text.square")
                            .font(.headline)
                    }
                    .disabled(content == nil)
                }
            }
            .navigationDestination(for: PathDestination.self) { destination in
                if let content {
                    switch destination {
                    case .lesson(let lesson):
                        LessonPlayerView(lesson: lesson, catalog: content.lessons) { next in
                            navigation = [.lesson(next)]
                        }
                        .id(lesson.id)
                    case .catalogSong(let id):
                        if let song = content.songs.first(where: { $0.id == id }) {
                            CatalogSongView(song: song, content: content)
                        }
                    case .importedSong(let id):
                        SongDetailView(songID: id)
                    }
                }
            }
            .sheet(isPresented: $showingTaste) {
                if let content {
                    TasteView(content: content)
                }
            }
        }
        .onAppear(perform: load)
    }

    private func load() {
        guard content == nil else { return }
        do {
            content = try PathContent.load()
        } catch {
            loadError = error.localizedDescription
        }
    }

    // MARK: - Home

    private func home(_ content: PathContent, snapshot: PathSnapshot) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                stats(content, snapshot: snapshot)

                if !store.preferences.hasTaste {
                    tasteBanner
                }

                if let first = snapshot.items.first {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Up next")
                            .font(.title.weight(.bold))
                        PathRow(item: first, index: 1, known: snapshot.known, isFeatured: true) { open(first, content) }
                    }
                }

                if snapshot.items.count > 1 {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Then")
                            .font(.title.weight(.bold))
                        ForEach(Array(snapshot.items.enumerated().dropFirst()), id: \.element.id) { index, item in
                            PathRow(item: item, index: index + 1, known: snapshot.known, isFeatured: false) { open(item, content) }
                        }
                    }
                } else if snapshot.items.isEmpty {
                    ContentUnavailableView("Nothing left on your path",
                                           systemImage: "checkmark.seal",
                                           description: Text("Add more songs you like in My songs."))
                }

                learnedSongs(content)
            }
            .padding(32)
        }
    }

    private func stats(_ content: PathContent, snapshot: PathSnapshot) -> some View {
        let streak = progress.streak()
        let lessonsDone = content.lessons.lessons.filter { progress.isCompleted($0) }.count
        return HStack(spacing: 16) {
            StatTile(value: "\(streak)", label: streak == 1 ? "day in a row" : "days in a row",
                     systemImage: "flame.fill", tint: streak > 0 ? .orange : .secondary)
            StatTile(value: "\(lessonsDone)/\(content.lessons.lessons.count)", label: "lessons done",
                     systemImage: "graduationcap.fill", tint: .accentColor)
            StatTile(value: "\(snapshot.known.count)", label: "chords you play",
                     systemImage: "hand.raised.fingers.spread.fill", tint: .green)
            StatTile(value: "\(store.preferences.learnedSongs.count)", label: "songs learned",
                     systemImage: "music.note", tint: .purple)
        }
    }

    private var tasteBanner: some View {
        HStack(spacing: 16) {
            Image(systemName: "sparkles")
                .font(.largeTitle)
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 4) {
                Text("Make this path yours")
                    .font(.title3.weight(.bold))
                Text("Pick the artists and songs you like, and the chords you already play. For now the path uses every song in the app.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("Choose songs") { showingTaste = true }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .padding(20)
        .background(RoundedRectangle(cornerRadius: 20).fill(Color.accentColor.opacity(0.1)))
    }

    @ViewBuilder
    private func learnedSongs(_ content: PathContent) -> some View {
        let learned = content.songs.filter { store.isLearned($0.id) }
        if !learned.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("Songs you play")
                    .font(.title.weight(.bold))
                FlowChips(items: learned.map(\.title)) { title in
                    if let song = learned.first(where: { $0.title == title }) {
                        navigation.append(.catalogSong(song.id))
                    }
                }
            }
        }
    }

    private func open(_ item: PathItem, _ content: PathContent) {
        switch item {
        case .lesson(let lesson, _):
            if let full = content.lessons.lessons.first(where: { $0.id == lesson.id }) {
                navigation.append(.lesson(full))
            }
        case .song(let song, _):
            if song.id.hasPrefix("import:"), let uuid = UUID(uuidString: String(song.id.dropFirst("import:".count))) {
                navigation.append(.importedSong(uuid))
            } else {
                navigation.append(.catalogSong(song.id))
            }
        }
    }
}

// MARK: - Pieces

private struct StatTile: View {
    let value: String
    let label: String
    let systemImage: String
    let tint: Color

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.title)
                .foregroundStyle(tint)
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(value)
                    .font(.title.weight(.bold).monospacedDigit())
                Text(label)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(18)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 18).fill(Color(uiColor: .secondarySystemBackground)))
    }
}

/// One step of the path: a lesson or a song.
struct PathRow: View {
    let item: PathItem
    let index: Int
    let known: Set<String>
    let isFeatured: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 18) {
                Text("\(index)")
                    .font(.title3.weight(.bold).monospacedDigit())
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(tint))
                VStack(alignment: .leading, spacing: 8) {
                    content
                }
                Spacer(minLength: 12)
                Image(systemName: "chevron.right")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 8)
            }
            .padding(isFeatured ? 24 : 18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 20)
                    .fill(isFeatured ? tint.opacity(0.12) : Color(uiColor: .secondarySystemBackground))
            )
            .contentShape(RoundedRectangle(cornerRadius: 20))
        }
        .buttonStyle(.plain)
    }

    private var tint: Color {
        if case .lesson = item { return .accentColor }
        return .purple
    }

    @ViewBuilder
    private var content: some View {
        switch item {
        case .lesson(let lesson, let because):
            Label("Lesson \(lesson.number)", systemImage: "graduationcap.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.accentColor)
            Text(lesson.title)
                .font(isFeatured ? .title.weight(.bold) : .title3.weight(.bold))
            Text(because)
                .foregroundStyle(.secondary)
        case .song(let song, let score):
            Label(song.artist ?? "Your song", systemImage: "music.note")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.purple)
            Text(song.title)
                .font(isFeatured ? .title.weight(.bold) : .title3.weight(.bold))
            HStack(spacing: 6) {
                ForEach(song.chords, id: \.self) { chord in
                    let isNew = score.newChords.contains(chord)
                    Text(chord)
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .foregroundStyle(isNew ? Color.white : Color.primary)
                        .background(Capsule().fill(isNew ? Color.orange : Color.secondary.opacity(0.12)))
                }
            }
            Text(score.reason)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Wrapping row of tappable chips.
struct FlowChips: View {
    let items: [String]
    var selected: Set<String> = []
    let onTap: (String) -> Void

    var body: some View {
        ChipLayout(spacing: 10) {
            ForEach(items, id: \.self) { item in
                let isOn = selected.contains(item)
                Button {
                    onTap(item)
                } label: {
                    Text(item)
                        .font(.headline)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .foregroundStyle(isOn ? Color.white : Color.primary)
                        .background(Capsule().fill(isOn ? Color.accentColor : Color.secondary.opacity(0.12)))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Lays children out left to right, wrapping to new lines.
struct ChipLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxX, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
