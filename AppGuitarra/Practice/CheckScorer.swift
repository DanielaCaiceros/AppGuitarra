//
//  CheckScorer.swift
//  AppGuitarra
//
//  Microphone scoring for the lesson "check" step and the change trainer.
//  Pure logic: it receives verdicts with their time and counts what happened.
//

import Foundation

/// What the microphone heard during one bar of a check.
nonisolated struct BarResult: Hashable, Sendable {
    nonisolated enum Outcome: Hashable, Sendable {
        /// Mostly the right chord.
        case clean
        /// Mostly another chord (wrong shape, or changed too late/early).
        case wrongChord(String)
        /// Sound, but not clearly the chord: muted strings, buzzing, out of tune.
        case messy
        /// Hardly anything played.
        case silent
    }

    let bar: Int
    let expected: String
    let outcome: Outcome

    var isClean: Bool { outcome == .clean }
}

nonisolated struct CheckResult: Hashable, Sendable {
    let bars: [BarResult]
    /// Share of clean bars needed to pass.
    var passShare = 0.75

    var cleanBars: Int { bars.filter(\.isClean).count }
    var neededBars: Int { Int((Double(bars.count) * passShare).rounded(.up)) }
    var passed: Bool { !bars.isEmpty && cleanBars >= neededBars }

    /// Short explanation of the most common problem, or nil when it went well.
    var advice: String? {
        let problems = bars.filter { !$0.isClean }
        guard !problems.isEmpty else { return nil }
        let silent = problems.filter { $0.outcome == .silent }.count
        let wrong = problems.compactMap { bar -> String? in
            if case .wrongChord(let heard) = bar.outcome { return "\(bar.expected)→\(heard)" } else { return nil }
        }
        if silent * 2 >= problems.count {
            return "Some bars were too quiet. Strum a bit harder or move the iPad closer."
        }
        if wrong.count * 2 >= problems.count, let first = problems.first(where: {
            if case .wrongChord = $0.outcome { true } else { false }
        }) {
            if case .wrongChord(let heard) = first.outcome {
                return "In bar \(first.bar + 1) it sounded like \(heard) instead of \(first.expected). Change on the last beat so the new chord is ready on 1."
            }
        }
        return "Some chords sounded unclear. Press right behind the frets and check that no finger touches the string below."
    }
}

/// Collects verdicts during a check and turns them into a result per bar.
nonisolated struct CheckScorer: Sendable {
    let timeline: PracticeTimeline
    /// Ignore the start of each bar: the window still holds the previous chord,
    /// and the change itself takes a moment.
    var settleSeconds = 0.3

    private var tallies: [Int: Tally] = [:]

    private nonisolated struct Tally: Sendable {
        var matches = 0
        var silent = 0
        var unclear = 0
        var others: [String: Int] = [:]
        var total: Int { matches + silent + unclear + others.values.reduce(0, +) }
    }

    init(timeline: PracticeTimeline) {
        self.timeline = timeline
    }

    var barCount: Int { timeline.config.totalBars ?? timeline.cycleBars }

    /// Chord expected in a bar.
    func expectedChord(inBar bar: Int) -> String {
        timeline.config.segments[timeline.segmentIndex(forBar: bar)].chord.id
    }

    /// The bar a moment belongs to, or nil during the count-in, the settle time or after the end.
    func bar(at seconds: Double) -> Int? {
        let played = seconds - timeline.countInDuration
        guard played >= 0 else { return nil }
        let bar = Int(played / timeline.secondsPerBar)
        guard bar < barCount else { return nil }
        let intoBar = played - Double(bar) * timeline.secondsPerBar
        guard intoBar >= min(settleSeconds, timeline.secondsPerBar * 0.4) else { return nil }
        return bar
    }

    /// - Parameters:
    ///   - seconds: time since the start, count-in included (`PracticeEngine.elapsed()`).
    mutating func add(_ verdict: ChordVerdict, at seconds: Double) {
        guard let bar = bar(at: seconds) else { return }
        var tally = tallies[bar] ?? Tally()
        switch verdict {
        case .silence: tally.silent += 1
        case .match: tally.matches += 1
        case .other(let id): tally.others[id, default: 0] += 1
        case .unclear: tally.unclear += 1
        }
        tallies[bar] = tally
    }

    var result: CheckResult {
        CheckResult(bars: (0..<barCount).map { bar in
            BarResult(bar: bar, expected: expectedChord(inBar: bar), outcome: outcome(tallies[bar]))
        })
    }

    private func outcome(_ tally: Tally?) -> BarResult.Outcome {
        guard let tally, tally.total > 0 else { return .silent }
        let sounding = tally.total - tally.silent
        guard Double(sounding) >= 0.4 * Double(tally.total), sounding > 0 else { return .silent }
        if Double(tally.matches) >= 0.6 * Double(sounding) { return .clean }
        if let top = tally.others.max(by: { $0.value < $1.value }), Double(top.value) >= 0.4 * Double(sounding) {
            return .wrongChord(top.key)
        }
        return .messy
    }
}

/// Counts clean changes between two chords for the 60-second trainer.
///
/// A change counts when the other chord is heard steadily for a few frames
/// in a row. Silence (between strums) keeps the current chord.
nonisolated struct ChangeCounter: Sendable {
    let first: String
    let second: String
    /// Frames in a row (~43 ms each) the new chord must be heard.
    var framesToConfirm = 3

    private(set) var changes = 0
    private(set) var current: String?
    private var candidate: String?
    private var candidateCount = 0

    init(first: String, second: String) {
        self.first = first
        self.second = second
    }

    /// Feeds the chord heard in one frame (nil = silence or unclear).
    /// Returns true when this frame completed a change.
    @discardableResult
    mutating func add(_ heard: String?) -> Bool {
        guard let heard, heard == first || heard == second else {
            candidate = nil
            candidateCount = 0
            return false
        }
        guard heard != current else {
            candidate = nil
            candidateCount = 0
            return false
        }
        if heard == candidate {
            candidateCount += 1
        } else {
            candidate = heard
            candidateCount = 1
        }
        guard candidateCount >= framesToConfirm else { return false }
        let isChange = current != nil
        current = heard
        candidate = nil
        candidateCount = 0
        if isChange { changes += 1 }
        return isChange
    }
}

/// Best scores of the change trainer, stored on the device.
nonisolated enum TrainerRecords {
    private static let key = "changeTrainerRecords"

    /// Same key for G↔D and D↔G.
    static func pairKey(_ a: String, _ b: String) -> String {
        [a, b].sorted().joined(separator: "-")
    }

    static func record(_ a: String, _ b: String, defaults: UserDefaults = .standard) -> Int {
        (defaults.dictionary(forKey: key) as? [String: Int])?[pairKey(a, b)] ?? 0
    }

    /// Saves the score if it beats the record. Returns true for a new record.
    @discardableResult
    static func submit(_ score: Int, _ a: String, _ b: String, defaults: UserDefaults = .standard) -> Bool {
        var all = (defaults.dictionary(forKey: key) as? [String: Int]) ?? [:]
        let pair = pairKey(a, b)
        guard score > all[pair, default: 0] else { return false }
        all[pair] = score
        defaults.set(all, forKey: key)
        return true
    }
}
