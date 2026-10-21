//
//  PracticeStageView.swift
//  AppGuitarra
//
//  The play-along screen used by lessons: current chord on the fretboard,
//  the strum pattern with the current stroke lit, a moving pick, a count-in,
//  and tempo / click / guide controls. Everything follows the audio clock.
//

import SwiftUI

nonisolated enum PracticeMode: Hashable, Sendable {
    /// Loops a pattern on one chord so you can hear and see it.
    case preview
    /// Loops the progression until you stop.
    case practice
    /// Plays a fixed number of bars at the target tempo, then calls `onFinish`.
    case check(bars: Int)

    var checkBars: Int? {
        if case .check(let bars) = self { bars } else { nil }
    }
}

struct PracticeStageView: View {
    let pattern: StrumPattern
    let segments: [PracticeSegment]
    let targetBpm: Int
    let mode: PracticeMode
    @Binding var tempo: DemoSpeed
    /// Called when a check ends. The result is nil when the microphone was not used.
    var onFinish: (CheckResult?) -> Void = { _ in }
    /// Called when the user presses Start (used for the practice streak).
    var onStart: () -> Void = {}

    @State private var engine = PracticeEngine()
    @State private var listener = ChordListener()
    @State private var scorer: CheckScorer?
    /// Latest microphone verdict while checking: true = the right chord is ringing.
    @State private var liveMatch: Bool?
    @AppStorage("micCheck") private var micCheck = true
    @AppStorage("detectionTolerance") private var tolerance: DetectionTolerance = .normal

    private var isCheck: Bool { mode.checkBars != nil }

    private func bpm(for speed: DemoSpeed) -> Int {
        mode.checkBars != nil ? targetBpm : max(30, Int((Double(targetBpm) * speed.rate).rounded()))
    }

    private var config: PracticeConfig {
        PracticeConfig(pattern: pattern, segments: segments, bpm: Double(bpm(for: tempo)),
                       countInBars: 1, totalBars: mode.checkBars)
    }

    var body: some View {
        VStack(spacing: 20) {
            TimelineView(.animation(paused: !engine.isRunning)) { _ in
                stage(position: engine.isRunning ? engine.position() : nil)
            }
            controls
            if let error = engine.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            }
            if isCheck, micCheck {
                switch listener.status {
                case .permissionDenied:
                    Label("Microphone access is off, so you'll rate yourself. You can allow it in Settings.", systemImage: "mic.slash")
                        .foregroundStyle(.secondary)
                case .failed(let message):
                    Label("Microphone unavailable: \(message)", systemImage: "mic.slash")
                        .foregroundStyle(.secondary)
                case .idle, .listening:
                    EmptyView()
                }
            }
        }
        .onAppear {
            // In a check you play alone; elsewhere the guide guitar plays along.
            engine.guideOn = mode.checkBars == nil
        }
        .onDisappear { stopAll() }
        .onChange(of: engine.didFinish) { _, finished in
            guard finished else { return }
            let result = scorer?.result
            listener.stop()
            scorer = nil
            liveMatch = nil
            onFinish(result)
        }
        .onChange(of: tempo) {
            if engine.isRunning { Task { await engine.start(config) } }
        }
    }

    // MARK: - Stage

    @ViewBuilder
    private func stage(position: PracticePosition?) -> some View {
        let segmentIndex = min(position?.segmentIndex ?? 0, segments.count - 1)
        let chord = segments[segmentIndex].chord
        let playing = position.map { !$0.isCountIn } ?? false
        let stroke = position.map { pattern.slots[$0.slot] } ?? .miss
        let flash = playing && stroke.isPlayed && (position?.slotFraction ?? 1) < 0.45

        HStack(alignment: .top, spacing: 20) {
            VStack(spacing: 16) {
                header(chord: chord, position: position)

                FretboardView(
                    chord: chord,
                    strummedStrings: flash ? Set(stroke.stringIndexes(on: chord)) : []
                )
                .overlay {
                    if let position, position.isCountIn {
                        countIn(position.countInBeat)
                    }
                }
                .animation(.easeInOut(duration: 0.15), value: chord.id)

                StrumPatternView(pattern: pattern, activeSlot: playing ? position?.slot : nil)
            }

            PickMotionView(
                slot: playing ? position?.slot : nil,
                fraction: position?.slotFraction ?? 0,
                hits: playing && stroke.isPlayed
            )
            .frame(width: 70)
        }
    }

    private func header(chord: Chord, position: PracticePosition?) -> some View {
        HStack(alignment: .center, spacing: 16) {
            Text(chord.id)
                .font(.system(size: 56, weight: .bold, design: .rounded))
                .contentTransition(.numericText())
            Text(chord.name)
                .font(.title3)
                .foregroundStyle(.secondary)

            if segments.count > 1, let position, !position.isCountIn {
                let next = segments[min(position.nextSegmentIndex, segments.count - 1)].chord
                Label("Next: \(next.id)", systemImage: "arrow.right")
                    .font(.title2.weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .foregroundStyle(position.isChangeComing ? Color.white : Color.secondary)
                    .background(Capsule().fill(position.isChangeComing ? Color.orange : Color.secondary.opacity(0.1)))
                    .animation(.easeOut(duration: 0.1), value: position.isChangeComing)
            }

            Spacer()

            if listener.isListening {
                micBadge
            }

            VStack(alignment: .trailing, spacing: 6) {
                beatDots(position)
                if let bars = mode.checkBars, let position, !position.isCountIn {
                    Text("Bar \(min(position.bar + 1, bars)) of \(bars)")
                        .font(.headline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func beatDots(_ position: PracticePosition?) -> some View {
        HStack(spacing: 10) {
            ForEach(0..<pattern.beatsPerBar, id: \.self) { beat in
                let isCurrent = position?.beat == beat
                Circle()
                    .fill(isCurrent ? (beat == 0 ? Color.orange : Color.accentColor) : Color.secondary.opacity(0.2))
                    .frame(width: beat == 0 ? 22 : 18, height: beat == 0 ? 22 : 18)
            }
        }
    }

    private func countIn(_ beat: Int) -> some View {
        VStack(spacing: 4) {
            Text("\(beat)")
                .font(.system(size: 120, weight: .heavy, design: .rounded))
                .contentTransition(.numericText())
            Text("Get ready…")
                .font(.title2.weight(.semibold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 48)
        .padding(.vertical, 16)
        .background(RoundedRectangle(cornerRadius: 28).fill(.black.opacity(0.55)))
        .animation(.easeOut(duration: 0.1), value: beat)
    }

    // MARK: - Controls

    private var controls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 20) {
                tempoControl
                Spacer(minLength: 12)
                soundToggles
                startButton
            }
            VStack(alignment: .leading, spacing: 16) {
                tempoControl
                HStack(spacing: 16) {
                    soundToggles
                    Spacer()
                    startButton
                }
            }
        }
    }

    @ViewBuilder
    private var tempoControl: some View {
        if mode.checkBars != nil {
            Label("\(targetBpm) bpm · \(mode.checkBars ?? 0) bars", systemImage: "metronome")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Label("Tempo", systemImage: "metronome")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Picker("Tempo", selection: $tempo) {
                    ForEach(DemoSpeed.allCases) { speed in
                        Text("\(speed.label) · \(bpm(for: speed))").tag(speed)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 360)
            }
        }
    }

    private var micBadge: some View {
        HStack(spacing: 8) {
            Image(systemName: liveMatch == true ? "checkmark.circle.fill" : "mic.fill")
                .foregroundStyle(liveMatch == true ? Color.green : Color.secondary)
            ProgressView(value: Double(listener.level))
                .frame(width: 60)
                .tint(liveMatch == true ? .green : .accentColor)
        }
        .font(.title2)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Capsule().fill(Color.secondary.opacity(0.1)))
        .accessibilityLabel(liveMatch == true ? "Right chord heard" : "Listening")
    }

    private var soundToggles: some View {
        HStack(spacing: 10) {
            if isCheck {
                Toggle(isOn: $micCheck) {
                    Label("Mic check", systemImage: micCheck ? "mic.fill" : "mic.slash")
                }
                .disabled(engine.isRunning)
            }
            Toggle(isOn: $engine.clickOn) {
                Label("Click", systemImage: "metronome.fill")
            }
            Toggle(isOn: $engine.guideOn) {
                Label("Guitar", systemImage: "guitars.fill")
            }
        }
        .toggleStyle(.button)
        .buttonStyle(.bordered)
        .controlSize(.large)
        .font(.headline)
    }

    private var startButton: some View {
        Button {
            if engine.isRunning {
                stopAll()
            } else {
                onStart()
                Task { await start() }
            }
        } label: {
            Label(
                engine.isRunning ? "Stop" : (mode.checkBars != nil ? "Start check" : "Start"),
                systemImage: engine.isRunning ? "stop.fill" : "play.fill"
            )
            .font(.title2.weight(.bold))
            .frame(minWidth: 150, minHeight: 44)
        }
        .buttonStyle(.borderedProminent)
        .tint(engine.isRunning ? .red : .accentColor)
        .controlSize(.extraLarge)
    }
}

// MARK: - Microphone check

extension PracticeStageView {
    private func start() async {
        guard isCheck, micCheck else {
            await engine.start(config)
            return
        }
        await listener.start()
        guard listener.isListening else {
            // No permission or no mic: the check still runs, and you rate yourself.
            await engine.start(config)
            return
        }
        let chords = (try? ChordLibrary.loadChords()) ?? segments.map(\.chord)
        let judge = ChordJudge(chords: chords, tolerance: tolerance)
        scorer = CheckScorer(timeline: PracticeTimeline(config: config))
        listener.onFrame = { frame in
            guard engine.isRunning else { return }
            let time = engine.elapsed()
            guard let bar = scorer?.bar(at: time), let expected = scorer?.expectedChord(inBar: bar) else { return }
            let verdict = judge.verdict(frame, expected: expected)
            scorer?.add(verdict, at: time)
            if verdict != .silence { liveMatch = verdict.isMatch }
        }
        await engine.start(config, recording: true)
        if !engine.isRunning { stopAll() }
    }

    private func stopAll() {
        engine.stop()
        listener.stop()
        scorer = nil
        liveMatch = nil
    }
}

#Preview {
    @Previewable @State var tempo = DemoSpeed.normal
    if let catalog = try? LessonCatalog.load(), let folk = catalog.patterns["folk"],
       let g = catalog.chords["G"], let d = catalog.chords["D"] {
        PracticeStageView(
            pattern: folk,
            segments: [PracticeSegment(chord: g, bars: 2), PracticeSegment(chord: d, bars: 2)],
            targetBpm: 70, mode: .practice, tempo: $tempo
        )
        .padding(32)
    }
}
