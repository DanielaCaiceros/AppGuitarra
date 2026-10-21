//
//  ChordLibrary.swift
//  AppGuitarra
//

import Foundation

/// Loads chord shapes bundled with the app.
nonisolated enum ChordLibrary {
    nonisolated enum LoadError: LocalizedError {
        case missingResource(String)

        var errorDescription: String? {
            switch self {
            case .missingResource(let name): "Could not find \(name) in the app bundle."
            }
        }
    }

    /// Full-barre shapes (one finger across 5 or 6 strings). They cover every
    /// major and minor chord the song analysis can find, but are hard for a
    /// beginner, so the capo advice treats them as a last resort.
    static let barreShapes: Set<String> = [
        "Bb", "B", "C#", "Eb", "F#", "Ab",
        "Cm", "C#m", "Ebm", "Fm", "F#m", "Gm", "Abm", "Bbm",
    ]

    static func loadChords(from bundle: Bundle = .main) throws -> [Chord] {
        guard let url = bundle.url(forResource: "chords", withExtension: "json") else {
            throw LoadError.missingResource("chords.json")
        }
        return try decode(Data(contentsOf: url))
    }

    static func decode(_ data: Data) throws -> [Chord] {
        try JSONDecoder().decode([Chord].self, from: data)
    }
}
