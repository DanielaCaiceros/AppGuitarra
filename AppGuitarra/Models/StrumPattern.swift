//
//  StrumPattern.swift
//  AppGuitarra
//
//  A strumming pattern written as one character per slot (eighth notes by default):
//  "D" = downstroke, "U" = upstroke, "-" = the hand moves but misses the strings.
//  Example, the folk pattern ↓ ↓↑ ↑↓↑ is "D-DU-UDU".
//

import Foundation

nonisolated enum Stroke: Character, Hashable, Sendable {
    case down = "D"
    case up = "U"
    case miss = "-"

    var isPlayed: Bool { self != .miss }
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
            guard let stroke = Stroke(rawValue: character) else { return nil }
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

    /// Count label under each slot: "1 & 2 & 3 & 4 &" for eighths.
    func countLabel(_ slot: Int) -> String {
        if slot % slotsPerBeat == 0 { return "\(slot / slotsPerBeat + 1)" }
        switch slotsPerBeat {
        case 2: return "&"
        case 4: return ["", "e", "&", "a"][slot % 4]
        default: return "·"
        }
    }
}
