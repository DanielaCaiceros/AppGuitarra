//
//  StrumPattern.swift
//  AppGuitarra
//
//  A strumming pattern written as one character per slot (eighth notes by default):
//    "D" = downstroke, "U" = upstroke, "-" = the hand moves but misses the strings,
//    "x" = muted strum ("chuck": the palm kills the strings),
//    "B" = bass note (lowest string of the chord), "A" = alternate bass note,
//    "1"…"6" = pick that single string (1 = thin high e, 6 = thick low E).
//  Example, the folk pattern ↓ ↓↑ ↑↓↑ is "D-DU-UDU"; an arpeggio is "B3212321".
//

import Foundation

nonisolated enum Stroke: Hashable, Sendable {
    case down
    case up
    case miss
    /// Percussive muted strum ("chuck").
    case mute
    /// Root bass note: the lowest string the chord uses.
    case bass
    /// Alternate bass note (boom-chick / Carter style).
    case altBass
    /// One string picked on its own. 1 = high e … 6 = low E.
    case string(Int)

    init?(character: Character) {
        switch character {
        case "D": self = .down
        case "U": self = .up
        case "-": self = .miss
        case "x": self = .mute
        case "B": self = .bass
        case "A": self = .altBass
        case "1", "2", "3", "4", "5", "6": self = .string(Int(String(character))!)
        default: return nil
        }
    }

    var character: Character {
        switch self {
        case .down: "D"
        case .up: "U"
        case .miss: "-"
        case .mute: "x"
        case .bass: "B"
        case .altBass: "A"
        case .string(let number): Character(String(number))
        }
    }

    var isPlayed: Bool { self != .miss }

    /// Single notes (bass and picked strings) instead of strums.
    var isSingleNote: Bool {
        switch self {
        case .bass, .altBass, .string: true
        default: false
        }
    }

    var isBassNote: Bool { self == .bass || self == .altBass }

    /// Strings (0 = low E) that sound for this stroke on a chord.
    func stringIndexes(on chord: Chord) -> [Int] {
        switch self {
        case .miss: []
        case .down, .up, .mute: chord.playedStringIndexes
        case .bass: chord.bassStringIndex.map { [$0] } ?? []
        case .altBass: chord.altBassStringIndex.map { [$0] } ?? []
        case .string(let number):
            Chord.stringCount - number >= 0 && !chord.isMuted(Chord.stringCount - number) ? [Chord.stringCount - number] : []
        }
    }
}

nonisolated struct StrumPattern: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    /// One character per slot, see `Stroke`. Spaces are ignored ("D-DU -UDU").
    let strokes: String
    /// Slot indexes (0-based) that are played louder.
    let accents: [Int]
    let beatsPerBar: Int
    let slotsPerBeat: Int

    nonisolated enum CodingKeys: String, CodingKey {
        case id, name, strokes, accents, beatsPerBar, slotsPerBeat
    }

    init(id: String, name: String, strokes: String, accents: [Int] = [], beatsPerBar: Int = 4, slotsPerBeat: Int = 2) {
        self.id = id
        self.name = name
        self.strokes = strokes
        self.accents = accents
        self.beatsPerBar = beatsPerBar
        self.slotsPerBeat = slotsPerBeat
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decode(String.self, forKey: .id),
            name: try c.decode(String.self, forKey: .name),
            strokes: try c.decode(String.self, forKey: .strokes),
            accents: try c.decodeIfPresent([Int].self, forKey: .accents) ?? [],
            beatsPerBar: try c.decodeIfPresent(Int.self, forKey: .beatsPerBar) ?? 4,
            slotsPerBeat: try c.decodeIfPresent(Int.self, forKey: .slotsPerBeat) ?? 2
        )
    }

    var slotsPerBar: Int { beatsPerBar * slotsPerBeat }

    /// Parsed strokes; nil if the string has an unknown character.
    var parsedStrokes: [Stroke]? {
        var result: [Stroke] = []
        for character in strokes where character != " " {
            guard let stroke = Stroke(character: character) else { return nil }
            result.append(stroke)
        }
        return result
    }

    /// Strokes for one bar; unknown characters become misses (validated by tests).
    var slots: [Stroke] {
        let parsed = parsedStrokes ?? []
        return (0..<slotsPerBar).map { $0 < parsed.count ? parsed[$0] : .miss }
    }

    var isValid: Bool {
        guard let parsed = parsedStrokes else { return false }
        return parsed.count == slotsPerBar && accents.allSatisfy { (0..<slotsPerBar).contains($0) }
    }

    func isAccented(_ slot: Int) -> Bool { accents.contains(slot) }

    /// True when the pattern picks single notes or mutes (the strip shows a legend).
    var hasSpecialStrokes: Bool {
        slots.contains { $0 == .mute || $0.isSingleNote }
    }

    /// Count label under each slot: "1 & 2 & 3 & 4 &" for eighths, "1 la li 2 la li" for 6/8.
    func countLabel(_ slot: Int) -> String {
        if slot % slotsPerBeat == 0 { return "\(slot / slotsPerBeat + 1)" }
        switch slotsPerBeat {
        case 2: return "&"
        case 3: return ["", "la", "li"][slot % 3]
        case 4: return ["", "e", "&", "a"][slot % 4]
        default: return "·"
        }
    }
}
