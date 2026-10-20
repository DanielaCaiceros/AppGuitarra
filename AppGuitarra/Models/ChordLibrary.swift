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
