//
//  Song.swift
//  AppGuitarra
//
//  A song imported by the user: its audio file stays on the iPad, and the app
//  stores the chords it detected (and the user corrected) with their start times.
//

import Foundation

/// A chord name like "G", "F#m", "Bb7" or "Cmaj7" (American notation).
nonisolated struct ChordSymbol: Hashable, Sendable {
    nonisolated enum Quality: String, CaseIterable, Sendable {
        case major = ""
        case minor = "m"
        case seventh = "7"
        case minorSeventh = "m7"
        case majorSeventh = "maj7"

        var intervals: [Int] {
            switch self {
            case .major: [0, 4, 7]
            case .minor: [0, 3, 7]
            case .seventh: [0, 4, 7, 10]
            case .minorSeventh: [0, 3, 7, 10]
            case .majorSeventh: [0, 4, 7, 11]
            }
        }
    }

    /// Names guitarists usually use for each pitch class.
    static let rootNames = ["C", "C#", "D", "Eb", "E", "F", "F#", "G", "Ab", "A", "Bb", "B"]
    /// "N" = no chord (silence, intro noise, drums only).
    static let noChord = "N"

    /// Pitch class of the root (C = 0).
    let root: Int
    let quality: Quality

    init(root: Int, quality: Quality) {
        self.root = ((root % 12) + 12) % 12
        self.quality = quality
    }

    init?(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let letter = trimmed.first else { return nil }
        let letters: [Character: Int] = ["C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11]
        guard var root = letters[letter] else { return nil }
        var rest = trimmed.dropFirst()
        if let accidental = rest.first, "#♯b♭".contains(accidental) {
            root += (accidental == "#" || accidental == "♯") ? 1 : -1
            rest = rest.dropFirst()
        }
        let quality: Quality
        switch String(rest) {
        case "": quality = .major
        case "m", "min", "-": quality = .minor
        case "7": quality = .seventh
        case "m7", "min7", "-7": quality = .minorSeventh
        case "maj7", "M7", "Δ7", "Δ": quality = .majorSeventh
        default: return nil
        }
        self.init(root: root, quality: quality)
    }

    var name: String { Self.rootNames[root] + quality.rawValue }

    var pitchClasses: Set<Int> { Set(quality.intervals.map { (root + $0) % 12 }) }

    func transposed(by semitones: Int) -> ChordSymbol {
        ChordSymbol(root: root + semitones, quality: quality)
    }
}

nonisolated struct SongChord: Codable, Hashable, Sendable, Identifiable {
    var id = UUID()
    /// Seconds from the start of the audio.
    var start: Double
    /// Sounding chord name, or "N" for no chord.
    var name: String

    var isNoChord: Bool { name == ChordSymbol.noChord }
}

nonisolated struct Song: Codable, Hashable, Sendable, Identifiable {
    nonisolated enum Status: Codable, Hashable, Sendable {
        case analyzing
        case ready
        case failed(String)
    }

    let id: UUID
    var title: String
    /// File name inside the song's folder.
    var audioFileName: String
    var duration: Double
    var bpm: Double?
    var chords: [SongChord]
    /// Capo fret the user plays with (0 = none). Shapes are shown relative to it.
    var capo: Int
    /// Capo the analysis recommends (nil = none needed or not analyzed yet).
    var suggestedCapo: Int?
    /// Swap hard shapes for easier ones (F → Fmaj7).
    var easyChords: Bool
    var status: Status
    var createdAt: Date
    /// Strum pattern guessed from the recording (nil = not analyzed yet).
    var strum: StrumGuess?
    /// Time of a bar start ("1"). Starts at the guess; the user can move it a beat.
    var barOffset: Double?
    /// Lesson pattern the user picked instead of the guess (nil = use the guess).
    var patternID: String?

    init(id: UUID = UUID(), title: String, audioFileName: String, duration: Double) {
        self.id = id
        self.title = title
        self.audioFileName = audioFileName
        self.duration = duration
        bpm = nil
        chords = []
        capo = 0
        suggestedCapo = nil
        easyChords = true
        status = .analyzing
        createdAt = Date()
        strum = nil
        barOffset = nil
        patternID = nil
    }

    /// The guessed pattern as a `StrumPattern`.
    var detectedPattern: StrumPattern? {
        strum.map { StrumPattern(id: Self.detectedPatternID, name: "Heard in the song", strokes: $0.strokes, accents: $0.accents) }
    }

    static let detectedPatternID = "detected"

    /// Pattern to show: the user's pick, or the guess.
    func strumPattern(library: [String: StrumPattern]) -> StrumPattern? {
        if let patternID, let picked = library[patternID] { return picked }
        return detectedPattern
    }

    /// Slot of the pattern at a song time and how far through it (0..<1).
    func strumPosition(at time: Double, pattern: StrumPattern) -> (slot: Int, fraction: Double)? {
        guard let bpm, bpm > 0, let barOffset else { return nil }
        let slotLength = 60 / bpm / Double(pattern.slotsPerBeat)
        let raw = (time - barOffset) / slotLength
        let whole = raw.rounded(.down)
        let count = pattern.slotsPerBar
        let slot = ((Int(whole) % count) + count) % count
        return (slot, raw - whole)
    }

    /// Index of the chord sounding at a time (the last one that started before it).
    func chordIndex(at time: Double) -> Int? {
        var low = 0
        var high = chords.count - 1
        var found: Int?
        while low <= high {
            let mid = (low + high) / 2
            if chords[mid].start <= time {
                found = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return found
    }

    /// End time of a chord (start of the next one, or the end of the song).
    func end(ofChordAt index: Int) -> Double {
        index + 1 < chords.count ? chords[index + 1].start : duration
    }

    /// What to finger for a sounding chord, given the capo and the easy-chords setting.
    func shape(for name: String, library: Set<String>) -> String {
        CapoAdvisor.shape(for: name, capo: capo, easy: easyChords, library: library)
    }

    /// Chords sorted by time, with neighbours of the same name merged.
    mutating func normalizeChords() {
        chords.sort { $0.start < $1.start }
        var merged: [SongChord] = []
        for chord in chords {
            if let last = merged.last, last.name == chord.name { continue }
            merged.append(chord)
        }
        chords = merged
    }
}

/// Finds the capo position that turns a song's chords into shapes from the library.
nonisolated enum CapoAdvisor {
    nonisolated struct Option: Hashable, Sendable {
        let capo: Int
        /// 0...1: share of the song's time played with an easy open shape.
        let coverage: Double
        /// Distinct shapes you would finger, in order of appearance.
        let shapes: [String]
    }

    /// Shape to finger for a sounding chord with a capo on `capo`.
    static func shape(for sounding: String, capo: Int, easy: Bool, library: Set<String>) -> String {
        guard let symbol = ChordSymbol(sounding) else { return sounding }
        let shape = symbol.transposed(by: -capo).name
        return easy ? easierShape(shape, library: library) : shape
    }

    /// A simpler shape that sounds close: F → Fmaj7, and a 7th chord the
    /// library doesn't have → its plain triad.
    static func easierShape(_ shape: String, library: Set<String>) -> String {
        if shape == "F", library.contains("Fmaj7") { return "Fmaj7" }
        guard !library.contains(shape), let symbol = ChordSymbol(shape) else { return shape }
        let simpler: ChordSymbol.Quality? = switch symbol.quality {
        case .seventh, .majorSeventh: .major
        case .minorSeventh: .minor
        case .major, .minor: nil
        }
        if let simpler {
            let triad = ChordSymbol(root: symbol.root, quality: simpler).name
            if library.contains(triad) { return easierShape(triad, library: library) }
        }
        return shape
    }

    /// How easy a shape is: 1 for open library shapes, less for the partial-barre F / Bm,
    /// full barre chords or shapes that need simplifying, 0 for shapes the app can't show.
    static func ease(of shape: String, library: Set<String>) -> Double {
        if shape == "F" || shape == "Bm" { return 0.7 }
        if ChordLibrary.barreShapes.contains(shape), library.contains(shape) { return 0.4 }
        if library.contains(shape) { return 1 }
        let easier = easierShape(shape, library: library)
        if easier != shape, library.contains(easier) { return 0.8 * ease(of: easier, library: library) }
        return 0
    }

    static func options(for chords: [SongChord], duration: Double, library: Set<String>, maxCapo: Int = 7) -> [Option] {
        var spans: [(name: String, length: Double)] = []
        for (index, chord) in chords.enumerated() where !chord.isNoChord {
            let end = index + 1 < chords.count ? chords[index + 1].start : duration
            spans.append((chord.name, max(0, end - chord.start)))
        }
        let total = spans.reduce(0) { $0 + $1.length }
        return (0...maxCapo).map { capo in
            var covered = 0.0
            var shapes: [String] = []
            for span in spans {
                let fingered = shape(for: span.name, capo: capo, easy: false, library: library)
                covered += span.length * ease(of: fingered, library: library)
                if !shapes.contains(fingered) { shapes.append(fingered) }
            }
            return Option(capo: capo, coverage: total > 0 ? covered / total : 0, shapes: shapes)
        }
    }

    /// Best option; a capo is only suggested when it clearly helps.
    static func best(for chords: [SongChord], duration: Double, library: Set<String>) -> Option? {
        let all = options(for: chords, duration: duration, library: library)
        guard let noCapo = all.first else { return nil }
        let best = all.max { a, b in a.coverage < b.coverage || (a.coverage == b.coverage && a.capo > b.capo) } ?? noCapo
        return best.coverage - noCapo.coverage >= 0.05 ? best : noCapo
    }
}
