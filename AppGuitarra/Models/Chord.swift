//
//  Chord.swift
//  AppGuitarra
//

import Foundation

/// A barre: one finger pressing several strings on the same fret.
nonisolated struct ChordBarre: Codable, Hashable, Sendable {
    /// Absolute fret (same scale as `Chord.frets`).
    let fret: Int
    let finger: Int
    /// Guitar string numbers: 1 = high E, 6 = low E.
    let fromString: Int
    let toString: Int

    /// Indexes into `Chord.frets` (0 = low E) covered by the barre.
    var stringIndexes: ClosedRange<Int> {
        let a = Chord.stringCount - fromString
        let b = Chord.stringCount - toString
        return min(a, b)...max(a, b)
    }
}

/// One fretted note of a chord.
nonisolated struct FingerPlacement: Hashable, Sendable {
    /// 0 = low E ... 5 = high E.
    let stringIndex: Int
    /// Absolute fret.
    let fret: Int
    /// 1 = index, 2 = middle, 3 = ring, 4 = pinky.
    let finger: Int
}

/// A chord shape loaded from `chords.json`.
///
/// Arrays go from the 6th string (low E, index 0) to the 1st string (high E, index 5).
/// In `frets`, -1 means muted and 0 means open. In `fingers`, 0 means no finger.
nonisolated struct Chord: Codable, Identifiable, Hashable, Sendable {
    static let stringCount = 6
    /// MIDI notes of the open strings in standard tuning, low E first.
    static let standardTuning = [40, 45, 50, 55, 59, 64]
    /// Short string names, low E first.
    static let stringNames = ["E", "A", "D", "G", "B", "e"]

    let id: String
    let name: String
    let frets: [Int]
    let fingers: [Int]
    let baseFret: Int
    let barre: ChordBarre?

    func isMuted(_ stringIndex: Int) -> Bool { frets[stringIndex] < 0 }
    func isOpen(_ stringIndex: Int) -> Bool { frets[stringIndex] == 0 }

    /// Fretted notes ordered by finger, then from low to high string.
    var placements: [FingerPlacement] {
        frets.indices
            .compactMap { index in
                frets[index] > 0
                    ? FingerPlacement(stringIndex: index, fret: frets[index], finger: fingers[index])
                    : nil
            }
            .sorted { ($0.finger, $0.stringIndex) < ($1.finger, $1.stringIndex) }
    }

    /// Fingers used, in the order they should be placed.
    var fingerOrder: [Int] {
        Array(Set(placements.map(\.finger))).sorted()
    }

    /// One finger across 5 or 6 strings (not the 2-string partial barre of F).
    var isFullBarre: Bool {
        barre.map { abs($0.fromString - $0.toString) >= 4 } ?? false
    }

    /// Highest fret pressed (0 if the chord is all open strings).
    var highestFret: Int { frets.max() ?? 0 }

    /// Strings that are strummed (not muted).
    var playedStringIndexes: [Int] { frets.indices.filter { !isMuted($0) } }

    /// Lowest string the chord uses: where the bass note is picked.
    var bassStringIndex: Int? { playedStringIndexes.first }

    /// Second bass note for boom-chick patterns: the 4th string when the root is
    /// on the 6th (G → D string), otherwise the next string up (C: 5th → 4th).
    var altBassStringIndex: Int? {
        guard let bass = bassStringIndex else { return nil }
        let preferred = bass == 0 ? 2 : bass + 1
        if playedStringIndexes.contains(preferred) { return preferred }
        return playedStringIndexes.first { $0 > bass }
    }

    /// MIDI note per string, nil when the string is muted.
    var midiNotes: [Int?] {
        zip(Self.standardTuning, frets).map { open, fret in fret >= 0 ? open + fret : nil }
    }

    /// Pitch classes that sound in the chord (0 = C, 1 = C#, ... 11 = B).
    var pitchClasses: Set<Int> {
        Set(midiNotes.compactMap { $0.map { $0 % 12 } })
    }
}

/// Note names in American notation with sharps.
nonisolated enum NoteName {
    static let sharps = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]

    static func name(forMIDI midi: Int) -> String {
        sharps[((midi % 12) + 12) % 12]
    }

    static func octave(forMIDI midi: Int) -> Int {
        Int((Double(midi) / 12).rounded(.down)) - 1
    }
}
