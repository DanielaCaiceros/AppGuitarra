//
//  PathRanker.swift
//  AppGuitarra
//
//  The personalized path: songs you like, ordered from the most convenient to
//  the hardest, with only the lessons you're missing inserted before the song
//  that needs them. Pure logic (no UI, no storage), so it is unit-tested.
//
//  Score = 40 % interest + 40 % closeness + 20 % unlock
//    interest  – "I want it now", a favorite artist, or a song you half-play
//    closeness – few new chords, a strum pattern and tempo near your level
//    unlock    – how many other songs on your list become playable after it
//
//  The path is built greedily: pick the best song for what you know now,
//  pretend you learned it (and the lessons before it), and score the rest again.
//

import Foundation

/// A song the path can recommend: from the built-in catalog or imported by the user.
nonisolated struct PathCandidate: Hashable, Sendable, Identifiable {
    let id: String
    let title: String
    let artist: String?
    /// Chord shapes you finger (after capo).
    let chords: [String]
    let bpm: Int?
    let pattern: String?

    init(id: String, title: String, artist: String?, chords: [String], bpm: Int?, pattern: String?) {
        self.id = id
        self.title = title
        self.artist = artist
        self.chords = chords
        self.bpm = bpm
        self.pattern = pattern
    }

    init(_ song: CatalogSong) {
        self.init(id: song.id, title: song.title, artist: song.artist, chords: song.chords, bpm: song.bpm, pattern: song.pattern)
    }

    static func importedID(_ uuid: UUID) -> String { "import:\(uuid.uuidString)" }
}

/// What the user told the app about their taste.
nonisolated struct PathPreferences: Codable, Hashable, Sendable {
    var favoriteArtists: Set<String> = []
    /// "I want this one now."
    var wantSongs: Set<String> = []
    /// "I can already half-play it."
    var halfPlaySongs: Set<String> = []
    /// Songs the user marked as learned: off the path, their chords count as known.
    var learnedSongs: Set<String> = []
    /// Chords the user already plays, outside the lessons.
    var knownChords: Set<String> = []

    var hasTaste: Bool { !favoriteArtists.isEmpty || !wantSongs.isEmpty || !halfPlaySongs.isEmpty }
}

/// A lesson as the path needs it.
nonisolated struct PathLesson: Hashable, Sendable, Identifiable {
    let id: String
    let number: Int
    let title: String
    let chords: [String]
    /// Strum patterns the lesson practices.
    let patterns: [String]

    init(id: String, number: Int, title: String, chords: [String], patterns: [String]) {
        self.id = id
        self.number = number
        self.title = title
        self.chords = chords
        self.patterns = patterns
    }

    init(_ lesson: Lesson) {
        var patterns: [String] = []
        for step in lesson.steps {
            if case .practice(let practice) = step, !patterns.contains(practice.pattern) {
                patterns.append(practice.pattern)
            }
        }
        self.init(id: lesson.id, number: lesson.number, title: lesson.title, chords: lesson.chords, patterns: patterns)
    }
}

nonisolated struct PathScore: Hashable, Sendable {
    let interest: Double
    let closeness: Double
    let unlock: Double
    /// Chords you don't know yet.
    let newChords: [String]
    /// Other songs on your list this one makes playable.
    let unlocks: Int
    let reason: String

    var total: Double {
        PathRanker.interestWeight * interest + PathRanker.closenessWeight * closeness + PathRanker.unlockWeight * unlock
    }
}

nonisolated enum PathItem: Hashable, Sendable, Identifiable {
    case lesson(PathLesson, because: String)
    case song(PathCandidate, PathScore)

    var id: String {
        switch self {
        case .lesson(let lesson, _): "lesson-\(lesson.id)"
        case .song(let song, _): "song-\(song.id)"
        }
    }
}

nonisolated enum PathRanker {
    static let interestWeight = 0.4
    static let closenessWeight = 0.4
    static let unlockWeight = 0.2
    /// Lessons a complete beginner does before the first song.
    static let starterLessons = 2

    /// How demanding each strum pattern is (1 = first lessons).
    static let patternLevels: [String: Int] = [
        "quarter-downs": 1, "eighths": 1,
        "folk": 2, "backbeat": 2, "waltz": 2,
        "chuck": 3, "six-eight": 3, "arpeggio": 3,
        "carter": 4,
    ]

    static func level(of pattern: String?) -> Int {
        pattern.flatMap { patternLevels[$0] } ?? 1
    }

    /// Effort to learn a chord: barre or four-finger shapes cost more,
    /// and F is cheap if you already play the easy Fmaj7.
    static func effort(of chord: String, known: Set<String>) -> Double {
        switch chord {
        case "F": known.contains("Fmaj7") ? 0.6 : 1.3
        case "Bm", "B7": 1.3
        default: 1
        }
    }

    static func newChords(_ song: PathCandidate, known: Set<String>) -> [String] {
        song.chords.filter { !known.contains($0) }
    }

    static func isPlayable(_ song: PathCandidate, known: Set<String>) -> Bool {
        newChords(song, known: known).isEmpty
    }

    static func interest(_ song: PathCandidate, preferences: PathPreferences) -> Double {
        if preferences.wantSongs.contains(song.id) { return 1 }
        if let artist = song.artist, preferences.favoriteArtists.contains(artist) { return 0.7 }
        if preferences.halfPlaySongs.contains(song.id) { return 0.6 }
        return 0.2
    }

    static func closeness(_ song: PathCandidate, known: Set<String>, level: Int, halfPlays: Bool) -> Double {
        let totalEffort = newChords(song, known: known).reduce(0.0) { $0 + Self.effort(of: $1, known: known) }
        let patternGap = max(0, Self.level(of: song.pattern) - level)
        let tempo = song.bpm ?? 90
        let tempoPenalty = tempo > 125 ? 0.15 : (tempo > 105 ? 0.07 : 0)
        let value = 1 - 0.28 * totalEffort - 0.12 * Double(patternGap) - tempoPenalty + (halfPlays ? 0.15 : 0)
        return min(1, max(0, value))
    }

    /// Songs in `pool` that become playable once you also know `song`'s chords.
    static func unlocks(_ song: PathCandidate, pool: [PathCandidate], known: Set<String>) -> Int {
        let after = known.union(song.chords)
        return pool.filter { other in
            other.id != song.id && !isPlayable(other, known: known) && isPlayable(other, known: after)
        }.count
    }

    static func score(
        _ song: PathCandidate,
        pool: [PathCandidate],
        known: Set<String>,
        level: Int,
        preferences: PathPreferences
    ) -> PathScore {
        let halfPlays = preferences.halfPlaySongs.contains(song.id)
        let new = newChords(song, known: known)
        let unlockCount = new.isEmpty ? 0 : unlocks(song, pool: pool, known: known)
        return PathScore(
            interest: Self.interest(song, preferences: preferences),
            closeness: Self.closeness(song, known: known, level: level, halfPlays: halfPlays),
            unlock: min(1, Double(unlockCount) / 3),
            newChords: new,
            unlocks: unlockCount,
            reason: reason(song, newChords: new, unlocks: unlockCount, preferences: preferences)
        )
    }

    static func reason(_ song: PathCandidate, newChords: [String], unlocks: Int, preferences: PathPreferences) -> String {
        var parts: [String] = []
        if preferences.wantSongs.contains(song.id) {
            parts.append("You want this one")
        } else if let artist = song.artist, preferences.favoriteArtists.contains(artist) {
            parts.append("From \(artist)")
        } else if preferences.halfPlaySongs.contains(song.id) {
            parts.append("You already half-play it")
        }
        switch newChords.count {
        case 0: parts.append("you know every chord")
        case 1: parts.append("only 1 new chord (\(newChords[0]))")
        default: parts.append("\(newChords.count) new chords (\(newChords.joined(separator: ", ")))")
        }
        var text = parts.joined(separator: ", ")
        if unlocks == 1 {
            text += ", and it opens 1 more song"
        } else if unlocks > 1 {
            text += ", and it opens \(unlocks) more songs"
        }
        return text.prefix(1).uppercased() + String(text.dropFirst()) + "."
    }

    /// Songs the path draws from: your favorites (plus imported songs), or the
    /// whole catalog until you pick some. Learned songs are left out.
    static func pool(catalog: [PathCandidate], imported: [PathCandidate], preferences: PathPreferences) -> [PathCandidate] {
        let liked = catalog.filter { song in
            preferences.wantSongs.contains(song.id)
                || preferences.halfPlaySongs.contains(song.id)
                || song.artist.map { preferences.favoriteArtists.contains($0) } ?? false
        }
        let base = preferences.hasTaste ? liked : catalog
        return (base + imported).filter { !preferences.learnedSongs.contains($0.id) }
    }

    /// The ordered path: songs, each preceded by the lessons it still needs.
    static func buildPath(
        pool: [PathCandidate],
        lessons: [PathLesson],
        completedLessons: Set<String>,
        known startKnown: Set<String>,
        level startLevel: Int,
        preferences: PathPreferences,
        limit: Int = 15
    ) -> [PathItem] {
        let ordered = lessons.sorted { $0.number < $1.number }
        var known = startKnown
        var level = startLevel
        var remaining = pool
        var inserted: Set<String> = completedLessons
        var items: [PathItem] = []
        var songs = 0

        func insert(_ lesson: PathLesson, because: String) {
            inserted.insert(lesson.id)
            items.append(.lesson(lesson, because: because))
            known.formUnion(lesson.chords)
            level = max(level, lesson.patterns.map { Self.level(of: $0) }.max() ?? level)
        }

        // A real beginner starts with the basics of the first module.
        if completedLessons.isEmpty, known.count < 3 {
            for lesson in ordered.prefix(starterLessons) {
                insert(lesson, because: "Start here: the basics of rhythm")
            }
        }

        while !remaining.isEmpty, songs < limit {
            let scored = remaining.map { ($0, score($0, pool: remaining, known: known, level: level, preferences: preferences)) }
            guard let pick = scored.max(by: { a, b in
                a.1.total < b.1.total || (a.1.total == b.1.total && a.0.title > b.0.title)
            }) else { break }
            let (song, best) = pick

            // Lessons that teach the new chords, in lesson order...
            var needed: [(PathLesson, String)] = []
            for chord in best.newChords {
                guard let lesson = ordered.first(where: { $0.chords.contains(chord) }),
                      !inserted.contains(lesson.id), !needed.contains(where: { $0.0.id == lesson.id }) else { continue }
                needed.append((lesson, "Teaches \(chord) for \(song.title)"))
            }
            for (lesson, because) in needed.sorted(by: { $0.0.number < $1.0.number }) {
                insert(lesson, because: because)
            }
            // ...then the strum pattern, if it's above your level (not for songs you already half-play).
            if let pattern = song.pattern, Self.level(of: pattern) > level,
               !preferences.halfPlaySongs.contains(song.id),
               let lesson = ordered.first(where: { $0.patterns.contains(pattern) }), !inserted.contains(lesson.id) {
                insert(lesson, because: "Teaches the strum in \(song.title)")
            }

            items.append(.song(song, best))
            songs += 1
            known.formUnion(song.chords)
            level = max(level, Self.level(of: song.pattern))
            remaining.removeAll { $0.id == song.id }
        }
        return items
    }

    /// Chords you can play now: chosen by hand, from finished lessons and from learned songs.
    static func knownChords(
        preferences: PathPreferences,
        completedLessons: Set<String>,
        lessons: [PathLesson],
        songs: [PathCandidate]
    ) -> Set<String> {
        var known = preferences.knownChords
        for lesson in lessons where completedLessons.contains(lesson.id) { known.formUnion(lesson.chords) }
        for song in songs where preferences.learnedSongs.contains(song.id) { known.formUnion(song.chords) }
        return known
    }

    /// Strum level from finished lessons and learned songs (at least 1).
    static func level(completedLessons: Set<String>, lessons: [PathLesson], preferences: PathPreferences, songs: [PathCandidate]) -> Int {
        var level = 1
        for lesson in lessons where completedLessons.contains(lesson.id) {
            level = max(level, lesson.patterns.map { Self.level(of: $0) }.max() ?? 1)
        }
        for song in songs where preferences.learnedSongs.contains(song.id) {
            level = max(level, Self.level(of: song.pattern))
        }
        return level
    }
}
