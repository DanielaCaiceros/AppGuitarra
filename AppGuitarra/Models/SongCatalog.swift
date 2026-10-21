//
//  SongCatalog.swift
//  AppGuitarra
//
//  Built-in songs for the personalized path (Resources/catalog.json): chord
//  shapes to finger (already relative to the capo), tempo, strum pattern and
//  sections. No audio and no lyrics: just what you need to play along.
//
//  A section's chords are written one bar each, "C:2" = two bars of C:
//      { "name": "Verse", "chords": "Am G C:2 F" }
//

import Foundation

nonisolated struct CatalogSection: Codable, Hashable, Sendable, Identifiable {
    let name: String
    let chords: String
    var id: String { name }

    /// Parsed "Am G C:2" → [Am×1, G×1, C×2]; nil if a token is malformed.
    var progression: [ProgressionSegment]? {
        var result: [ProgressionSegment] = []
        for token in chords.split(separator: " ") {
            let parts = token.split(separator: ":", omittingEmptySubsequences: false)
            guard let name = parts.first, !name.isEmpty, parts.count <= 2 else { return nil }
            var bars = 1
            if parts.count == 2 {
                guard let parsed = Int(parts[1]), parsed >= 1 else { return nil }
                bars = parsed
            }
            result.append(ProgressionSegment(chord: String(name), bars: bars))
        }
        return result.isEmpty ? nil : result
    }
}

nonisolated struct CatalogSong: Codable, Hashable, Sendable, Identifiable {
    nonisolated enum Source: String, Codable, Sendable {
        /// Compared against chord charts when the catalog was written.
        case checked
        /// The widely used standard chart.
        case common
        /// Simplified or uncertain: check by ear.
        case review
    }

    let id: String
    let title: String
    let artist: String
    let capo: Int
    /// Tempo of the recording, in the beat the strum pattern counts
    /// (half time or dotted quarters when `bpmNote` says so).
    let bpm: Int
    /// Checked against tempo databases (songbpm.com, tunebat, getsongbpm).
    let bpmChecked: Bool?
    /// How the tempo was counted, or why it needs checking by ear.
    let bpmNote: String?
    let pattern: String
    let source: Source
    let note: String?
    let sections: [CatalogSection]

    /// Distinct chord shapes in order of appearance.
    var chords: [String] {
        var seen: [String] = []
        for section in sections {
            for segment in section.progression ?? [] where !seen.contains(segment.chord) {
                seen.append(segment.chord)
            }
        }
        return seen
    }
}

nonisolated enum SongCatalog {
    static func load(from bundle: Bundle = .main) throws -> [CatalogSong] {
        guard let url = bundle.url(forResource: "catalog", withExtension: "json") else {
            throw LessonCatalog.LoadError.missingResource("catalog.json")
        }
        return try JSONDecoder().decode([CatalogSong].self, from: Data(contentsOf: url))
    }

    /// Problems with the catalog content. Empty = valid.
    static func validationErrors(_ songs: [CatalogSong], chords: Set<String>, patterns: Set<String>) -> [String] {
        var errors: [String] = []
        if Set(songs.map(\.id)).count != songs.count { errors.append("Song ids must be unique") }
        for song in songs {
            if !patterns.contains(song.pattern) { errors.append("\(song.id): unknown pattern \(song.pattern)") }
            if !(0...9).contains(song.capo) { errors.append("\(song.id): capo out of range") }
            if !(40...200).contains(song.bpm) { errors.append("\(song.id): bpm out of range") }
            if song.sections.isEmpty { errors.append("\(song.id): no sections") }
            for section in song.sections {
                guard let progression = section.progression else {
                    errors.append("\(song.id) \(section.name): can't read \"\(section.chords)\"")
                    continue
                }
                for segment in progression where !chords.contains(segment.chord) {
                    errors.append("\(song.id) \(section.name): unknown chord \(segment.chord)")
                }
            }
        }
        return errors
    }
}
