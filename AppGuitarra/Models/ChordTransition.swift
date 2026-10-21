//
//  ChordTransition.swift
//  AppGuitarra
//
//  What each finger does when you change from one chord to another, worked out
//  from the chord data: anchors stay put, guide fingers slide along their string,
//  the rest move to a new string. Used by the chord-change illustration.
//

import Foundation

nonisolated struct ChordTransition: Hashable, Sendable {
    nonisolated enum Move: Hashable, Sendable {
        /// Stays on the same string and fret: keep it pressed.
        case anchor
        /// Same string, another fret: keep it touching the string as you slide.
        case slide(fromFret: Int, toFret: Int)
        /// Jumps to another string.
        case move(fromString: Int, toString: Int, toFret: Int)
        /// Not used in the new chord.
        case lift
        /// Only used in the new chord.
        case place(string: Int, fret: Int)
    }

    nonisolated struct FingerMove: Hashable, Sendable, Identifiable {
        let finger: Int
        let move: Move
        var id: Int { finger }

        /// "Finger 1 stays put", in plain English. Strings are guitar numbers (1 = thin e).
        var description: String {
            let name = "Finger \(finger)"
            switch move {
            case .anchor:
                return "\(name) stays put: it's your anchor."
            case .slide(let from, let to):
                return "\(name) slides along its string from fret \(from) to fret \(to). Keep it touching the string: it's your guide."
            case .move(let fromString, let toString, let fret):
                let direction = toString < fromString ? "toward the thin strings" : "toward the thick strings"
                let steps = abs(toString - fromString)
                let distance = steps == 1 ? "one string" : "\(steps) strings"
                return "\(name) moves \(distance) \(direction), to string \(toString), fret \(fret)."
            case .lift:
                return "\(name) lifts off."
            case .place(let string, let fret):
                return "\(name) goes to string \(string), fret \(fret)."
            }
        }
    }

    let from: Chord
    let to: Chord
    let moves: [FingerMove]

    init(from: Chord, to: Chord) {
        self.from = from
        self.to = to
        let fingers = Set(from.placements.map(\.finger)).union(to.placements.map(\.finger)).sorted()
        moves = fingers.map { finger in
            let a = from.placements.filter { $0.finger == finger }
            let b = to.placements.filter { $0.finger == finger }
            return FingerMove(finger: finger, move: Self.move(from: a, to: b))
        }
    }

    private static func guitarString(_ index: Int) -> Int { Chord.stringCount - index }

    private static func move(from a: [FingerPlacement], to b: [FingerPlacement]) -> Move {
        guard let first = b.first else { return .lift }
        guard let start = a.first else { return .place(string: guitarString(first.stringIndex), fret: first.fret) }
        let spotsA = Set(a.map { [$0.stringIndex, $0.fret] })
        if b.contains(where: { spotsA.contains([$0.stringIndex, $0.fret]) }) { return .anchor }
        if let same = b.first(where: { target in a.contains { $0.stringIndex == target.stringIndex } }),
           let origin = a.first(where: { $0.stringIndex == same.stringIndex }) {
            return .slide(fromFret: origin.fret, toFret: same.fret)
        }
        return .move(fromString: guitarString(start.stringIndex), toString: guitarString(first.stringIndex), toFret: first.fret)
    }

    var anchorFingers: Set<Int> {
        Set(moves.filter { $0.move == .anchor }.map(\.finger))
    }

    /// Placements that are held through the change (drawn with a ring).
    func anchoredPlacements(in chord: Chord) -> Set<FingerPlacement> {
        let other = chord == from ? to : from
        let spots = Set(other.placements.map { [$0.stringIndex, $0.fret, $0.finger] })
        return Set(chord.placements.filter { spots.contains([$0.stringIndex, $0.fret, $0.finger]) })
    }

    /// One-line takeaway for the change.
    var summary: String {
        let anchors = moves.filter { $0.move == .anchor }.map(\.finger)
        let slides = moves.filter { if case .slide = $0.move { true } else { false } }.map(\.finger)
        if anchors.count >= 2 {
            return "Fingers \(anchors.map(String.init).joined(separator: " and ")) never leave the strings. Only move the others."
        }
        if let anchor = anchors.first {
            return "Finger \(anchor) stays down the whole time. Pivot around it."
        }
        if let slide = slides.first {
            return "Finger \(slide) slides along its string and guides the others into place."
        }
        return "No finger can stay, so lift them together, hold the new shape in the air and land them as one."
    }
}
