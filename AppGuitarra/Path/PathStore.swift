//
//  PathStore.swift
//  AppGuitarra
//
//  The user's taste (favorite artists, songs they want, songs they half-play),
//  chords they already know and songs they learned. Stored on the device.
//

import Foundation
import Observation

@Observable
final class PathStore {
    private static let key = "pathPreferences"
    @ObservationIgnored private let defaults: UserDefaults

    private(set) var preferences: PathPreferences

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode(PathPreferences.self, from: data) {
            preferences = saved
        } else {
            preferences = PathPreferences()
        }
    }

    func update(_ change: (inout PathPreferences) -> Void) {
        change(&preferences)
        if let data = try? JSONEncoder().encode(preferences) {
            defaults.set(data, forKey: Self.key)
        }
    }

    func toggleArtist(_ artist: String) {
        update { $0.favoriteArtists.toggle(artist) }
    }

    func toggleKnownChord(_ chord: String) {
        update { $0.knownChords.toggle(chord) }
    }

    /// How the user feels about a song: one of none / want / half-play.
    func setInterest(_ interest: SongInterest, for songID: String) {
        update {
            $0.wantSongs.remove(songID)
            $0.halfPlaySongs.remove(songID)
            switch interest {
            case .none: break
            case .want: $0.wantSongs.insert(songID)
            case .halfPlay: $0.halfPlaySongs.insert(songID)
            }
        }
    }

    func interest(for songID: String) -> SongInterest {
        if preferences.wantSongs.contains(songID) { return .want }
        if preferences.halfPlaySongs.contains(songID) { return .halfPlay }
        return .none
    }

    func setLearned(_ learned: Bool, songID: String) {
        update { preferences in
            if learned {
                preferences.learnedSongs.insert(songID)
            } else {
                preferences.learnedSongs.remove(songID)
            }
            return
        }
    }

    func isLearned(_ songID: String) -> Bool { preferences.learnedSongs.contains(songID) }
}

nonisolated enum SongInterest: String, CaseIterable, Identifiable, Sendable {
    case none, want, halfPlay
    var id: String { rawValue }

    var label: String {
        switch self {
        case .none: "—"
        case .want: "I want it"
        case .halfPlay: "I half-play it"
        }
    }

    var systemImage: String {
        switch self {
        case .none: "circle"
        case .want: "heart.fill"
        case .halfPlay: "circle.lefthalf.filled"
        }
    }
}

extension Set {
    nonisolated mutating func toggle(_ member: Element) {
        if contains(member) { remove(member) } else { insert(member) }
    }
}
