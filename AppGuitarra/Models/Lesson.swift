//
//  Lesson.swift
//  AppGuitarra
//
//  A lesson is plain JSON (Resources/lessons.json): adding one needs no UI code.
//  Each lesson is a list of steps of three kinds:
//    show     – watch a chord being placed, or a strum pattern being played
//    practice – play along with the metronome (loops until you stop)
//    check    – play a fixed number of bars, then say whether you made it
//

import Foundation

/// A chord held for a number of bars inside a progression.
nonisolated struct ProgressionSegment: Codable, Hashable, Sendable {
    let chord: String
    let bars: Int
}

nonisolated struct ShowStep: Codable, Hashable, Sendable {
    let title: String
    let text: String
    /// Show this chord being placed (AnimatedChordView)...
    let chord: String?
    /// ...or this strum pattern being played on a single chord.
    let pattern: String?
    let bpm: Int?
}

nonisolated struct PracticeStep: Codable, Hashable, Sendable {
    let title: String
    let text: String
    let pattern: String
    let progression: [ProgressionSegment]
    /// Target tempo; the player can practice at 50 % or 75 % of it.
    let bpm: Int
}

nonisolated struct CheckStep: Codable, Hashable, Sendable {
    let title: String
    /// The measurable goal, shown big ("4 bars at 70 bpm without losing the pulse").
    let goal: String
    let bars: Int
    let bpm: Int
    /// When omitted, the pattern and progression of the previous practice step are used.
    let pattern: String?
    let progression: [ProgressionSegment]?
}

nonisolated enum LessonStep: Codable, Hashable, Sendable {
    case show(ShowStep)
    case practice(PracticeStep)
    case check(CheckStep)

    nonisolated enum Kind: String, Codable, Sendable, CaseIterable {
        case show, practice, check

        var title: String {
            switch self {
            case .show: "Watch"
            case .practice: "Practice"
            case .check: "Check"
            }
        }

        var systemImage: String {
            switch self {
            case .show: "eye"
            case .practice: "metronome"
            case .check: "checkmark.seal"
            }
        }
    }

    private nonisolated enum CodingKeys: String, CodingKey { case type }

    var kind: Kind {
        switch self {
        case .show: .show
        case .practice: .practice
        case .check: .check
        }
    }

    var title: String {
        switch self {
        case .show(let step): step.title
        case .practice(let step): step.title
        case .check(let step): step.title
        }
    }

    init(from decoder: Decoder) throws {
        let kind = try decoder.container(keyedBy: CodingKeys.self).decode(Kind.self, forKey: .type)
        switch kind {
        case .show: self = .show(try ShowStep(from: decoder))
        case .practice: self = .practice(try PracticeStep(from: decoder))
        case .check: self = .check(try CheckStep(from: decoder))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .type)
        switch self {
        case .show(let step): try step.encode(to: encoder)
        case .practice(let step): try step.encode(to: encoder)
        case .check(let step): try step.encode(to: encoder)
        }
    }
}

nonisolated struct Lesson: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let number: Int
    let module: String
    let title: String
    let summary: String
    let chords: [String]
    let steps: [LessonStep]

    /// Index of the last practice step before `index` (where "Not yet" sends you back).
    func practiceIndex(before index: Int) -> Int? {
        steps.indices.prefix(index).last { steps[$0].kind == .practice }
    }

    /// Pattern and progression a check step plays, inheriting from the previous practice step.
    func resolvedCheck(at index: Int) -> (pattern: String, progression: [ProgressionSegment])? {
        guard case .check(let check) = steps[index] else { return nil }
        var pattern = check.pattern
        var progression = check.progression
        if let practice = practiceIndex(before: index), case .practice(let step) = steps[practice] {
            pattern = pattern ?? step.pattern
            progression = progression ?? step.progression
        }
        guard let pattern, let progression else { return nil }
        return (pattern, progression)
    }
}

nonisolated struct LessonModule: Identifiable, Sendable {
    let name: String
    var lessons: [Lesson]
    var id: String { name }
}

/// Everything the lesson engine needs, loaded once from the bundle.
nonisolated struct LessonCatalog: Sendable {
    let lessons: [Lesson]
    let patterns: [String: StrumPattern]
    let chords: [String: Chord]

    nonisolated enum LoadError: LocalizedError {
        case missingResource(String)

        var errorDescription: String? {
            switch self {
            case .missingResource(let name): "Could not find \(name) in the app bundle."
            }
        }
    }

    static func load(from bundle: Bundle = .main) throws -> LessonCatalog {
        func data(_ name: String) throws -> Data {
            guard let url = bundle.url(forResource: name, withExtension: "json") else {
                throw LoadError.missingResource("\(name).json")
            }
            return try Data(contentsOf: url)
        }
        let decoder = JSONDecoder()
        let lessons = try decoder.decode([Lesson].self, from: data("lessons"))
        let patterns = try decoder.decode([StrumPattern].self, from: data("patterns"))
        let chords = try ChordLibrary.decode(data("chords"))
        return LessonCatalog(
            lessons: lessons.sorted { $0.number < $1.number },
            patterns: Dictionary(uniqueKeysWithValues: patterns.map { ($0.id, $0) }),
            chords: Dictionary(uniqueKeysWithValues: chords.map { ($0.id, $0) })
        )
    }

    /// Modules in lesson order, each with its lessons.
    var modules: [LessonModule] {
        var result: [LessonModule] = []
        for lesson in lessons {
            if let last = result.indices.last, result[last].name == lesson.module {
                result[last].lessons.append(lesson)
            } else {
                result.append(LessonModule(name: lesson.module, lessons: [lesson]))
            }
        }
        return result
    }

    func chords(for progression: [ProgressionSegment]) -> [Chord] {
        progression.compactMap { chords[$0.chord] }
    }

    /// Problems with the content (unknown chord/pattern ids, bad patterns). Empty = valid.
    func validationErrors() -> [String] {
        var errors: [String] = []
        for pattern in patterns.values where !pattern.isValid {
            errors.append("Pattern \(pattern.id): strokes must have \(pattern.slotsPerBar) slots of D, U or -")
        }
        func checkChord(_ id: String, _ where_: String) {
            if chords[id] == nil { errors.append("\(where_): unknown chord \(id)") }
        }
        func checkPattern(_ id: String, _ where_: String) {
            if patterns[id] == nil { errors.append("\(where_): unknown pattern \(id)") }
        }
        func checkProgression(_ segments: [ProgressionSegment], _ where_: String) {
            if segments.isEmpty { errors.append("\(where_): empty progression") }
            for segment in segments {
                checkChord(segment.chord, where_)
                if segment.bars < 1 { errors.append("\(where_): bars must be ≥ 1") }
            }
        }
        for lesson in lessons {
            lesson.chords.forEach { checkChord($0, lesson.id) }
            if !lesson.steps.contains(where: { $0.kind == .practice }) {
                errors.append("\(lesson.id): needs a practice step")
            }
            for (index, step) in lesson.steps.enumerated() {
                let place = "\(lesson.id) step \(index + 1)"
                switch step {
                case .show(let show):
                    if show.chord == nil && show.pattern == nil { errors.append("\(place): show needs a chord or a pattern") }
                    if let chord = show.chord { checkChord(chord, place) }
                    if let pattern = show.pattern { checkPattern(pattern, place) }
                case .practice(let practice):
                    checkPattern(practice.pattern, place)
                    checkProgression(practice.progression, place)
                    if practice.bpm < 40 || practice.bpm > 200 { errors.append("\(place): bpm out of range") }
                case .check(let check):
                    if let resolved = lesson.resolvedCheck(at: index) {
                        checkPattern(resolved.pattern, place)
                        checkProgression(resolved.progression, place)
                    } else {
                        errors.append("\(place): check has no pattern/progression and no practice step before it")
                    }
                    if check.bars < 1 { errors.append("\(place): bars must be ≥ 1") }
                }
            }
        }
        return errors
    }
}
