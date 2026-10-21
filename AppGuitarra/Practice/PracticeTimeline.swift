//
//  PracticeTimeline.swift
//  AppGuitarra
//
//  Pure timing math shared by the audio thread (what to play when) and the UI
//  (which bar, beat and stroke we are on). No audio or UI code here, so it is unit-tested.
//

import Foundation

nonisolated struct PracticeSegment: Hashable, Sendable {
    let chord: Chord
    let bars: Int
}

nonisolated struct PracticeConfig: Hashable, Sendable {
    let pattern: StrumPattern
    let segments: [PracticeSegment]
    let bpm: Double
    var countInBars = 1
    /// nil = loop the progression until stopped. Otherwise stop after this many bars (count-in excluded).
    var totalBars: Int?
}

/// Where playback is at a moment in time.
nonisolated struct PracticePosition: Equatable, Sendable {
    var isCountIn: Bool
    /// 1-based beat of the count-in ("1, 2, 3, 4").
    var countInBeat: Int
    /// Bars played since the count-in ended (0-based).
    var bar: Int
    /// Slot inside the bar (0 ..< slotsPerBar).
    var slot: Int
    /// 0...1 progress through the current slot.
    var slotFraction: Double
    /// 0-based beat inside the bar.
    var beat: Int
    var segmentIndex: Int
    var nextSegmentIndex: Int
    /// True on the last beat before the chord changes: time to move your fingers.
    var isChangeComing: Bool
    var isFinished: Bool
}

nonisolated struct PracticeTimeline: Hashable, Sendable {
    let config: PracticeConfig

    nonisolated enum SoundID: Hashable, Sendable {
        case clickAccent, click
        case down(String), up(String)
        /// Muted strum ("chuck") on a chord.
        case mute(String)
        /// A single plucked note (MIDI number).
        case note(Int)
    }

    nonisolated struct TimedSound: Hashable, Sendable {
        /// Slot index, counted from the start of its block (count-in or one cycle).
        let slot: Int
        let sound: SoundID
        let gain: Float
        var isClick: Bool { sound == .click || sound == .clickAccent }
        /// Strums cut off the strings that are still ringing; single notes let them ring.
        var damps: Bool {
            switch sound {
            case .down, .up, .mute: true
            case .clickAccent, .click, .note: false
            }
        }
    }

    var pattern: StrumPattern { config.pattern }
    var slotsPerBar: Int { pattern.slotsPerBar }
    var secondsPerBeat: Double { 60 / config.bpm }
    var secondsPerSlot: Double { secondsPerBeat / Double(pattern.slotsPerBeat) }
    var secondsPerBar: Double { secondsPerBeat * Double(pattern.beatsPerBar) }
    var cycleBars: Int { max(1, config.segments.reduce(0) { $0 + max(1, $1.bars) }) }
    var countInSlots: Int { config.countInBars * slotsPerBar }
    var countInDuration: Double { Double(config.countInBars) * secondsPerBar }
    /// Total length including the count-in; nil when looping.
    var duration: Double? {
        config.totalBars.map { countInDuration + Double($0) * secondsPerBar }
    }

    /// Segment index for a bar inside the cycle.
    func segmentIndex(forBar bar: Int) -> Int {
        var remaining = ((bar % cycleBars) + cycleBars) % cycleBars
        for (index, segment) in config.segments.enumerated() {
            let bars = max(1, segment.bars)
            if remaining < bars { return index }
            remaining -= bars
        }
        return 0
    }

    func position(at seconds: Double) -> PracticePosition {
        let time = max(0, seconds)
        let slotFloat = time / secondsPerSlot
        let absoluteSlot = Int(slotFloat.rounded(.down))
        let fraction = slotFloat - Double(absoluteSlot)

        if absoluteSlot < countInSlots {
            let beat = absoluteSlot / pattern.slotsPerBeat
            return PracticePosition(
                isCountIn: true, countInBeat: beat % pattern.beatsPerBar + 1,
                bar: 0, slot: absoluteSlot % slotsPerBar, slotFraction: fraction, beat: beat % pattern.beatsPerBar,
                segmentIndex: 0, nextSegmentIndex: 0, isChangeComing: false, isFinished: false
            )
        }

        let playSlot = absoluteSlot - countInSlots
        let bar = playSlot / slotsPerBar
        let slot = playSlot % slotsPerBar
        let beat = slot / pattern.slotsPerBeat
        let segment = segmentIndex(forBar: bar)
        let next = segmentIndex(forBar: bar + 1)
        let isFinished = config.totalBars.map { bar >= $0 } ?? false
        let isLastBar = config.totalBars.map { bar == $0 - 1 } ?? false
        let isChangeComing = beat == pattern.beatsPerBar - 1
            && config.segments.count > 1
            && next != segment
            && !isLastBar
        return PracticePosition(
            isCountIn: false, countInBeat: 0,
            bar: bar, slot: slot, slotFraction: fraction, beat: beat,
            segmentIndex: segment, nextSegmentIndex: next,
            isChangeComing: isChangeComing, isFinished: isFinished
        )
    }

    /// Count-in: a click on every beat, accent on beat 1.
    var countInSounds: [TimedSound] {
        (0..<countInSlots).compactMap { slot in
            guard slot % pattern.slotsPerBeat == 0 else { return nil }
            let isDownbeat = slot % slotsPerBar == 0
            return TimedSound(slot: slot, sound: isDownbeat ? .clickAccent : .click, gain: isDownbeat ? 1 : 0.7)
        }
    }

    /// One pass through the progression: clicks on the beats plus the guide strums.
    var cycleSounds: [TimedSound] {
        var sounds: [TimedSound] = []
        let strokes = pattern.slots
        for bar in 0..<cycleBars {
            let chord = config.segments[segmentIndex(forBar: bar)].chord
            for slot in 0..<slotsPerBar {
                let absolute = bar * slotsPerBar + slot
                if slot % pattern.slotsPerBeat == 0 {
                    let isDownbeat = slot == 0
                    sounds.append(TimedSound(slot: absolute, sound: isDownbeat ? .clickAccent : .click, gain: isDownbeat ? 1 : 0.7))
                }
                let stroke = strokes[slot]
                guard stroke.isPlayed else { continue }
                let accent: Float = pattern.isAccented(slot) ? 1 : 0.6
                switch stroke {
                case .down: sounds.append(TimedSound(slot: absolute, sound: .down(chord.id), gain: accent))
                case .up: sounds.append(TimedSound(slot: absolute, sound: .up(chord.id), gain: accent * 0.8))
                case .mute: sounds.append(TimedSound(slot: absolute, sound: .mute(chord.id), gain: 0.9))
                case .bass, .altBass, .string:
                    // A string the chord mutes stays silent.
                    guard let string = stroke.stringIndexes(on: chord).first,
                          let midi = chord.midiNotes[string] else { continue }
                    let gain: Float = min(1, (stroke.isBassNote ? 0.95 : 0.75) * (pattern.isAccented(slot) ? 1.15 : 1))
                    sounds.append(TimedSound(slot: absolute, sound: .note(midi), gain: gain))
                case .miss: break
                }
            }
        }
        return sounds
    }

    /// Converts a slot count to audio frames without accumulating rounding drift.
    func frame(forSlot slot: Int, sampleRate: Double) -> Int {
        Int((Double(slot) * secondsPerSlot * sampleRate).rounded())
    }
}
