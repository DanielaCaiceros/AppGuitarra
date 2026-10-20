//
//  AnimatedChordView.swift
//  AppGuitarra
//
//  Demo of a chord in two clear phases:
//  1. Place your fingers: they appear one at a time, with a caption for each.
//  2. Strum: the strings you should play light up top to bottom while the chord sounds.
//

import SwiftUI

nonisolated enum DemoSpeed: String, CaseIterable, Identifiable {
    case slow, medium, normal

    var id: String { rawValue }
    /// Playback rate relative to normal speed.
    var rate: Double {
        switch self {
        case .slow: 0.5
        case .medium: 0.75
        case .normal: 1.0
        }
    }
    var label: String { rawValue.capitalized }
}

struct AnimatedChordView: View {
    let chord: Chord
    /// Change this from outside to restart the demo (e.g. after closing the guide).
    var restartToken = 0

    @AppStorage("demoSpeed") private var speed: DemoSpeed = .normal
    @AppStorage("soundOn") private var soundOn = true

    @State private var phase: Phase = .ready
    @State private var visibleCount = 0
    @State private var strummed: Set<Int> = []
    @State private var request = 0
    @State private var strumOnly = false

    nonisolated enum Phase: Equatable {
        case ready, placing, strumming, done
    }

    private nonisolated struct PlaybackRequest: Hashable {
        let chordID: String
        let speed: DemoSpeed
        let token: Int
        let restart: Int
    }

    private var fingerOrder: [Int] { chord.fingerOrder }
    private var visibleFingers: Set<Int> { Set(fingerOrder.prefix(visibleCount)) }
    private var currentFinger: Int? {
        phase == .placing && visibleCount > 0 ? fingerOrder[visibleCount - 1] : nil
    }

    var body: some View {
        VStack(spacing: 20) {
            PhaseIndicator(phase: phase)

            FretboardView(
                chord: chord,
                visibleFingers: visibleFingers,
                strummedStrings: strummed,
                highlightedFinger: currentFinger
            )
            .overlay(alignment: .trailing) {
                if phase == .strumming {
                    StrumArrow(speed: speed.rate)
                        .padding(.trailing, 8)
                        .transition(.opacity)
                }
            }

            caption

            stepCards

            controls
        }
        .task(id: PlaybackRequest(chordID: chord.id, speed: speed, token: request, restart: restartToken)) {
            await play()
        }
        .onDisappear { ChordSynth.shared.shutdown() }
    }

    // MARK: - Caption

    private var caption: some View {
        HStack(spacing: 14) {
            Image(systemName: captionIcon)
                .font(.title)
                .foregroundStyle(Color.accentColor)
                .frame(width: 40)
            Text(captionText)
                .font(.title3.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 76)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.accentColor.opacity(0.1)))
        .animation(.easeInOut(duration: 0.2), value: captionText)
    }

    private var captionIcon: String {
        switch phase {
        case .ready: "eye"
        case .placing: "hand.point.up.left"
        case .strumming: "arrow.down"
        case .done: "checkmark.circle"
        }
    }

    private var captionText: String {
        switch phase {
        case .ready:
            return "Watch: your fingers go on one at a time."
        case .placing:
            guard let finger = currentFinger else { return "" }
            return "Finger \(finger) (\(Self.fingerName(finger))) → \(instruction(for: finger))"
        case .strumming:
            return "Strum down: brush across the lit strings, from the thick one to the thin one."
        case .done:
            let muted = chord.frets.indices.filter(chord.isMuted)
            let skip = muted.isEmpty
                ? "All six strings ring."
                : "Don't play the strings marked ✕ (\(muted.map { StringInfo.all[$0].ordinal }.joined(separator: ", "))."
            return "Your turn! Make the shape and strum. \(skip)"
        }
    }

    // MARK: - Step cards

    private var stepCards: some View {
        HStack(alignment: .top, spacing: 12) {
            ForEach(Array(fingerOrder.enumerated()), id: \.element) { index, finger in
                let isDone = index < visibleCount
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text("\(finger)")
                            .font(.headline.monospacedDigit())
                            .foregroundStyle(.white)
                            .frame(width: 26, height: 26)
                            .background(Circle().fill(Color.accentColor))
                        Text(Self.fingerName(finger).capitalized)
                            .font(.headline)
                    }
                    Text(instruction(for: finger))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(isDone ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(finger == currentFinger ? Color.accentColor : .clear, lineWidth: 2)
                )
            }
        }
    }

    // MARK: - Controls

    private var controls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 20) {
                speedControl
                Spacer(minLength: 12)
                actionButtons
            }
            VStack(alignment: .leading, spacing: 16) {
                speedControl
                actionButtons
            }
        }
    }

    private var speedControl: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Demo speed", systemImage: "speedometer")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Image(systemName: "tortoise.fill").foregroundStyle(.secondary)
                Picker("Demo speed", selection: $speed) {
                    ForEach(DemoSpeed.allCases) { speed in
                        Text(speed.label).tag(speed)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 280)
                Image(systemName: "hare.fill").foregroundStyle(.secondary)
            }
        }
    }

    private var actionButtons: some View {
        HStack(spacing: 12) {
            Button {
                soundOn.toggle()
            } label: {
                Image(systemName: soundOn ? "speaker.wave.2.fill" : "speaker.slash.fill")
                    .font(.title2)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel(soundOn ? "Sound on" : "Sound off")

            Button {
                strumOnly = true
                request += 1
            } label: {
                Label("Strum", systemImage: "music.note")
                    .font(.title3.weight(.semibold))
            }
            .buttonStyle(.bordered)
            .controlSize(.large)

            Button {
                strumOnly = false
                request += 1
            } label: {
                Label("Replay", systemImage: "arrow.counterclockwise")
                    .font(.title3.weight(.semibold))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }

    // MARK: - Text helpers

    private func instruction(for finger: Int) -> String {
        let spots = chord.placements.filter { $0.finger == finger }
        guard let first = spots.first else { return "" }
        let fret = "fret \(first.fret)"
        if spots.count > 1 {
            let names = spots.map { StringInfo.all[$0.stringIndex].ordinal }.joined(separator: " + ")
            return "lay it flat across the \(names) strings, \(fret)"
        }
        let info = StringInfo.all[first.stringIndex]
        return "\(info.ordinal) string (\(info.shortName)), \(fret)"
    }

    static func fingerName(_ finger: Int) -> String {
        ["", "index", "middle", "ring", "pinky"][max(0, min(4, finger))]
    }

    // MARK: - Playback

    private func play() async {
        let step = 0.9 / speed.rate
        let stringDelay = 0.07 / speed.rate

        let onlyStrum = strumOnly
        strumOnly = false
        if onlyStrum {
            withAnimation { visibleCount = fingerOrder.count }
        } else {
            visibleCount = 0
            strummed = []
            phase = .ready
            guard await pause(step * 0.8) else { return }

            phase = .placing
            for count in stride(from: 1, through: fingerOrder.count, by: 1) {
                withAnimation(.spring(duration: 0.4, bounce: 0.45)) { visibleCount = count }
                guard await pause(step * 1.3) else { return }
            }
        }

        // Strum: thick string to thin string.
        withAnimation { phase = .strumming }
        if soundOn {
            ChordSynth.shared.strum(chord, stringDelay: stringDelay)
        }
        for string in chord.playedStringIndexes {
            withAnimation(.easeOut(duration: 0.08)) { _ = strummed.insert(string) }
            guard await pause(stringDelay) else { return }
        }
        guard await pause(step * 1.5) else { return }
        withAnimation(.easeOut(duration: 0.5)) {
            strummed = []
            phase = .done
        }
    }

    /// Sleeps for `seconds`; returns false if the task was cancelled.
    private func pause(_ seconds: Double) async -> Bool {
        do {
            try await Task.sleep(for: .seconds(seconds))
            return true
        } catch {
            return false
        }
    }
}

// MARK: - Pieces

/// "① Place fingers → ② Strum" with the current phase highlighted.
private struct PhaseIndicator: View {
    let phase: AnimatedChordView.Phase

    var body: some View {
        HStack(spacing: 12) {
            pill(number: 1, title: "Place your fingers", isActive: phase == .ready || phase == .placing,
                 isDone: phase == .strumming || phase == .done)
            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            pill(number: 2, title: "Strum", isActive: phase == .strumming, isDone: phase == .done)
            Spacer()
        }
        .animation(.easeInOut(duration: 0.2), value: phase)
    }

    private func pill(number: Int, title: String, isActive: Bool, isDone: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: isDone ? "checkmark.circle.fill" : "\(number).circle.fill")
            Text(title)
        }
        .font(.headline)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .foregroundStyle(isActive ? Color.white : (isDone ? Color.accentColor : Color.secondary))
        .background(Capsule().fill(isActive ? Color.accentColor : Color.secondary.opacity(0.1)))
    }
}

/// Big downward arrow that slides over the strings while they are strummed.
private struct StrumArrow: View {
    let speed: Double
    @State private var moved = false

    var body: some View {
        Image(systemName: "arrow.down")
            .font(.system(size: 44, weight: .heavy))
            .foregroundStyle(.yellow)
            .shadow(color: .black.opacity(0.4), radius: 3)
            .offset(y: moved ? 60 : -60)
            .onAppear {
                withAnimation(.easeIn(duration: 0.45 / speed)) { moved = true }
            }
    }
}

#Preview {
    if let chord = (try? ChordLibrary.loadChords())?.first(where: { $0.id == "G" }) {
        AnimatedChordView(chord: chord)
            .padding(40)
    }
}
