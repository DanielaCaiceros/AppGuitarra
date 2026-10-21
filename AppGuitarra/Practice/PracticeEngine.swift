//
//  PracticeEngine.swift
//  AppGuitarra
//
//  Metronome + guide strums rendered sample-by-sample on the audio thread
//  (AVAudioSourceNode), so the click never drifts the way a Timer would.
//  The UI asks `position()` every frame; it is derived from the number of
//  samples rendered, so the arrows on screen follow exactly what you hear.
//

import AVFoundation
import Observation
import Synchronization

@Observable
final class PracticeEngine {
    private(set) var isRunning = false
    /// Set when a run with a fixed number of bars reaches its end.
    private(set) var didFinish = false
    private(set) var timeline: PracticeTimeline?
    private(set) var errorMessage: String?

    var clickOn = true {
        didSet { shared.clickOn.store(clickOn, ordering: .relaxed) }
    }
    var guideOn = true {
        didSet { shared.guideOn.store(guideOn, ordering: .relaxed) }
    }

    @ObservationIgnored private lazy var engine = AVAudioEngine()
    @ObservationIgnored private var sourceNode: AVAudioSourceNode?
    @ObservationIgnored private let shared = RenderShared()
    @ObservationIgnored private var sampleRate: Double = 48_000
    @ObservationIgnored private var latency: Double = 0
    @ObservationIgnored private var runID = 0
    @ObservationIgnored private var soundCache: [String: [Float]] = [:]

    init() {}

    /// Seconds of music heard since `start` (negative while the audio is still starting).
    func elapsed() -> Double {
        Double(shared.frames.load(ordering: .relaxed)) / sampleRate - latency
    }

    func position() -> PracticePosition? {
        timeline?.position(at: elapsed())
    }

    /// - Parameter recording: keep the microphone usable (lesson checks listen while the click plays).
    func start(_ config: PracticeConfig, recording: Bool = false) async {
        stop()
        runID += 1
        let run = runID
        didFinish = false
        errorMessage = nil

        do {
            let session = AVAudioSession.sharedInstance()
            try AudioSessionHelper.activate(recording: recording)
            sampleRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
            if sampleRate <= 0 { sampleRate = session.sampleRate > 0 ? session.sampleRate : 48_000 }
            latency = session.outputLatency + session.ioBufferDuration
        } catch {
            errorMessage = error.localizedDescription
            return
        }

        let timeline = PracticeTimeline(config: config)
        let bank = await soundBank(for: config)
        guard run == runID else { return }   // stopped or restarted while rendering sounds

        let program = RenderProgram(timeline: timeline, bank: bank, sampleRate: sampleRate)
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        shared.frames.store(0, ordering: .relaxed)
        shared.clickOn.store(clickOn, ordering: .relaxed)
        shared.guideOn.store(guideOn, ordering: .relaxed)
        let node = Self.makeSourceNode(format: format, program: program, shared: shared)
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        sourceNode = node

        do {
            engine.prepare()
            try engine.start()
        } catch {
            detachNode()
            errorMessage = error.localizedDescription
            return
        }
        self.timeline = timeline
        isRunning = true

        if let duration = timeline.duration {
            let wait = duration + latency + 0.05
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(wait))
                guard let self, self.runID == run, self.isRunning else { return }
                self.stop()
                self.didFinish = true
            }
        }
    }

    func stop() {
        runID += 1
        guard isRunning || sourceNode != nil else { return }
        engine.stop()
        detachNode()
        isRunning = false
        timeline = nil
    }

    private func detachNode() {
        if let sourceNode {
            engine.detach(sourceNode)
        }
        sourceNode = nil
    }

    // MARK: - Sounds

    /// Clicks plus every strum, chuck and single note the progression plays.
    private func soundBank(for config: PracticeConfig) async -> SoundBank {
        var ids: [PracticeTimeline.SoundID] = [.clickAccent, .click]
        for timed in PracticeTimeline(config: config).cycleSounds where !timed.isClick && !ids.contains(timed.sound) {
            ids.append(timed.sound)
        }
        var chords: [String: Chord] = [:]
        for segment in config.segments { chords[segment.chord.id] = segment.chord }

        let rate = sampleRate
        var samples: [[Float]] = []
        for id in ids {
            let key = "\(id)-\(Int(rate))"
            if let cached = soundCache[key] {
                samples.append(cached)
                continue
            }
            let rendered: [Float]
            switch id {
            case .clickAccent:
                rendered = Self.renderClick(frequency: 1_760, sampleRate: rate)
            case .click:
                rendered = Self.renderClick(frequency: 1_175, sampleRate: rate)
            case .down(let chordID), .up(let chordID), .mute(let chordID):
                guard let chord = chords[chordID] else { rendered = []; break }
                rendered = await Task.detached(priority: .userInitiated) { () -> [Float] in
                    switch id {
                    case .up: PracticeEngine.renderStrum(chord, up: true, sampleRate: rate)
                    case .mute: PracticeEngine.renderMute(chord, sampleRate: rate)
                    default: PracticeEngine.renderStrum(chord, up: false, sampleRate: rate)
                    }
                }.value
            case .note(let midi):
                rendered = await Task.detached(priority: .userInitiated) { () -> [Float] in
                    ChordSynth.renderStrum(midiNotes: [midi], stringDelay: 0, sampleRate: rate, duration: 1.6)
                }.value
            }
            soundCache[key] = rendered
            samples.append(rendered)
        }
        return SoundBank(ids: ids, samples: samples)
    }

    nonisolated static func renderStrum(_ chord: Chord, up: Bool, sampleRate: Double) -> [Float] {
        let notes = chord.midiNotes.compactMap { $0 }
        // Upstrokes mostly catch the thin strings, from high to low.
        let ordered: [Int?] = up ? notes.reversed().prefix(4).map { $0 } : notes.map { $0 }
        return ChordSynth.renderStrum(midiNotes: ordered, stringDelay: 0.012, sampleRate: sampleRate, duration: 1.6)
    }

    /// A "chuck": the strings are hit but the palm stops them at once,
    /// so you hear a short, dull click with only a hint of the chord.
    nonisolated static func renderMute(_ chord: Chord, sampleRate: Double) -> [Float] {
        let strum = ChordSynth.renderStrum(midiNotes: chord.midiNotes, stringDelay: 0.004, sampleRate: sampleRate, duration: 0.12)
        var generator = SystemRandomNumberGenerator()
        var low: Float = 0
        return strum.enumerated().map { n, sample in
            let t = Double(n) / sampleRate
            // Low-passed noise burst for the thump of the palm.
            low += 0.15 * (Float.random(in: -1...1, using: &generator) - low)
            let body = sample * Float(exp(-t * 45)) * 0.6
            let thump = low * Float(exp(-t * 80)) * 1.6
            return body + thump
        }
    }

    /// Short "tock": a sine burst with a fast exponential decay.
    nonisolated static func renderClick(frequency: Double, sampleRate: Double) -> [Float] {
        let length = Int(sampleRate * 0.04)
        return (0..<length).map { n in
            let t = Double(n) / sampleRate
            return Float(sin(2 * .pi * frequency * t) * exp(-t * 120) * 0.9)
        }
    }

    // MARK: - Audio thread

    /// Built outside the main actor so the render block runs freely on the audio thread.
    nonisolated private static func makeSourceNode(
        format: AVAudioFormat,
        program: RenderProgram,
        shared: RenderShared
    ) -> AVAudioSourceNode {
        let renderer = Renderer(program: program, shared: shared)
        return AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList in
            renderer.render(frameCount: Int(frameCount), into: UnsafeMutableAudioBufferListPointer(audioBufferList))
            return noErr
        }
    }
}

// MARK: - Render-thread types

/// Values shared between the main actor and the audio thread.
nonisolated final class RenderShared: Sendable {
    let frames = Atomic<Int>(0)
    let clickOn = Atomic<Bool>(true)
    let guideOn = Atomic<Bool>(true)
}

nonisolated struct SoundBank: Sendable {
    let ids: [PracticeTimeline.SoundID]
    let samples: [[Float]]
}

/// Everything the audio thread plays, precomputed in frames.
nonisolated struct RenderProgram: Sendable {
    nonisolated struct Event: Sendable {
        let frame: Int
        let sound: Int
        let gain: Float
        let isClick: Bool
        /// Cuts off ringing strings (strums do, single notes don't).
        let damps: Bool
    }

    /// All sounds back to back, with (start, length) per sound.
    let samples: [Float]
    let ranges: [(start: Int, length: Int)]
    let countIn: [Event]
    let cycle: [Event]
    let countInFrames: Int
    let cycleFrames: Int
    let endFrame: Int

    init(timeline: PracticeTimeline, bank: SoundBank, sampleRate: Double) {
        var samples: [Float] = []
        var ranges: [(start: Int, length: Int)] = []
        for sound in bank.samples {
            ranges.append((samples.count, sound.count))
            samples.append(contentsOf: sound)
        }
        self.samples = samples
        self.ranges = ranges

        func events(_ sounds: [PracticeTimeline.TimedSound]) -> [Event] {
            sounds.compactMap { timed in
                guard let index = bank.ids.firstIndex(of: timed.sound) else { return nil }
                return Event(frame: timeline.frame(forSlot: timed.slot, sampleRate: sampleRate),
                             sound: index, gain: timed.gain, isClick: timed.isClick, damps: timed.damps)
            }
            .sorted { $0.frame < $1.frame }
        }
        countIn = events(timeline.countInSounds)
        cycle = events(timeline.cycleSounds)
        countInFrames = timeline.frame(forSlot: timeline.countInSlots, sampleRate: sampleRate)
        cycleFrames = max(1, timeline.frame(forSlot: timeline.cycleBars * timeline.slotsPerBar, sampleRate: sampleRate))
        endFrame = timeline.duration.map { Int(($0 * sampleRate).rounded()) } ?? .max
    }
}

/// Owned and mutated only by the audio thread.
nonisolated final class Renderer: @unchecked Sendable {
    private nonisolated struct Voice {
        var sound = -1
        var position = 0
        var gain: Float = 0
        var isStrum = false
        /// Frames left in a fade-out, or -1 when not fading.
        var fade = -1
    }

    private static let fadeLength = 384
    private let program: RenderProgram
    private let shared: RenderShared
    private var voices = ContiguousArray(repeating: Voice(), count: 16)
    private var frame = 0
    private var countInCursor = 0
    private var cycleCursor = 0
    private var lastCycleStart = -1

    init(program: RenderProgram, shared: RenderShared) {
        self.program = program
        self.shared = shared
    }

    func render(frameCount: Int, into buffers: UnsafeMutableAudioBufferListPointer) {
        let clickOn = shared.clickOn.load(ordering: .relaxed)
        let guideOn = shared.guideOn.load(ordering: .relaxed)

        program.samples.withUnsafeBufferPointer { samples in
            for i in 0..<frameCount {
                let f = frame + i
                var value: Float = 0
                if f < program.endFrame {
                    triggerEvents(at: f, clickOn: clickOn, guideOn: guideOn)
                    value = mixVoices(samples)
                }
                for buffer in buffers {
                    buffer.mData?.assumingMemoryBound(to: Float.self)[i] = value
                }
            }
        }
        frame += frameCount
        shared.frames.store(frame, ordering: .relaxed)
    }

    private func triggerEvents(at f: Int, clickOn: Bool, guideOn: Bool) {
        if f < program.countInFrames {
            // The count-in always clicks, even with the click turned off.
            while countInCursor < program.countIn.count, program.countIn[countInCursor].frame == f {
                start(program.countIn[countInCursor])
                countInCursor += 1
            }
            return
        }
        let offset = f - program.countInFrames
        let cycleStart = offset - offset % program.cycleFrames
        if cycleStart != lastCycleStart {
            lastCycleStart = cycleStart
            cycleCursor = 0
        }
        let local = offset - cycleStart
        while cycleCursor < program.cycle.count, program.cycle[cycleCursor].frame == local {
            let event = program.cycle[cycleCursor]
            if event.isClick ? clickOn : guideOn {
                start(event)
            }
            cycleCursor += 1
        }
    }

    private func start(_ event: RenderProgram.Event) {
        let isStrum = !event.isClick
        if event.damps {
            // A new strum damps whatever still rings, like on a real guitar.
            for index in voices.indices where voices[index].isStrum && voices[index].sound >= 0 && voices[index].fade < 0 {
                voices[index].fade = Self.fadeLength
            }
        }
        let slot = voices.firstIndex { $0.sound < 0 } ?? 0
        voices[slot] = Voice(sound: event.sound, position: 0, gain: event.gain, isStrum: isStrum, fade: -1)
    }

    private func mixVoices(_ samples: UnsafeBufferPointer<Float>) -> Float {
        var sum: Float = 0
        for index in voices.indices where voices[index].sound >= 0 {
            let range = program.ranges[voices[index].sound]
            let position = voices[index].position
            guard position < range.length else {
                voices[index].sound = -1
                continue
            }
            var gain = voices[index].gain
            if voices[index].fade >= 0 {
                gain *= Float(voices[index].fade) / Float(Self.fadeLength)
                voices[index].fade -= 1
                if voices[index].fade < 0 {
                    voices[index].sound = -1
                    continue
                }
            }
            sum += samples[range.start + position] * gain
            voices[index].position = position + 1
        }
        return max(-1, min(1, sum * 0.8))
    }
}
