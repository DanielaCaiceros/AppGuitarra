//
//  LessonPlayerView.swift
//  AppGuitarra
//
//  Plays a lesson step by step: Watch → Practice → Check.
//  If the check fails, you go back to practice one tempo slower.
//

import SwiftUI

struct LessonPlayerView: View {
    let lesson: Lesson
    let catalog: LessonCatalog
    var onOpenLesson: (Lesson) -> Void = { _ in }

    @Environment(LessonProgress.self) private var progress
    @Environment(\.dismiss) private var dismiss

    @State private var stepIndex = 0
    @State private var tempo: DemoSpeed = .medium
    @State private var checkTempo: DemoSpeed = .normal
    @State private var checkFinished = false
    @State private var checkResult: CheckResult?
    @State private var isComplete = false
    @State private var slowerNotice: String?

    private var step: LessonStep { lesson.steps[stepIndex] }
    private var nextLesson: Lesson? {
        catalog.lessons.first { $0.number > lesson.number }
    }

    var body: some View {
        VStack(spacing: 0) {
            if isComplete {
                completion
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        phaseHeader
                        VStack(alignment: .leading, spacing: 24) {
                            stepContent
                        }
                        .id(stepIndex)   // fresh audio/animation state per step
                    }
                    .padding(32)
                }
                bottomBar
            }
        }
        .navigationTitle("Lesson \(lesson.number): \(lesson.title)")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Header

    private var phaseHeader: some View {
        HStack(spacing: 12) {
            ForEach(LessonStep.Kind.allCases, id: \.self) { kind in
                let isActive = step.kind == kind
                let isDone = order(kind) < order(step.kind)
                HStack(spacing: 8) {
                    Image(systemName: isDone ? "checkmark.circle.fill" : kind.systemImage)
                    Text(kind.title)
                }
                .font(.headline)
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .foregroundStyle(isActive ? Color.white : (isDone ? Color.accentColor : Color.secondary))
                .background(Capsule().fill(isActive ? Color.accentColor : Color.secondary.opacity(0.1)))
                if kind != .check {
                    Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                }
            }
            Spacer()
            Text("Step \(stepIndex + 1) of \(lesson.steps.count)")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private func order(_ kind: LessonStep.Kind) -> Int {
        LessonStep.Kind.allCases.firstIndex(of: kind) ?? 0
    }

    private func intro(title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.largeTitle.weight(.bold))
            Text(text)
                .font(.title3)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Steps

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case .show(let show):
            intro(title: show.title, text: show.text)
            if let id = show.pattern, let pattern = catalog.patterns[id],
               let chord = catalog.chords[show.chord ?? lesson.chords.first ?? ""] {
                PracticeStageView(
                    pattern: pattern,
                    segments: [PracticeSegment(chord: chord, bars: 1)],
                    targetBpm: show.bpm ?? 70,
                    mode: .preview,
                    tempo: $tempo,
                    onStart: { progress.recordPractice() }
                )
            } else if let fromID = show.chord, let toID = show.toChord,
                      let from = catalog.chords[fromID], let to = catalog.chords[toID] {
                ChordChangeView(from: from, to: to)
            } else if let id = show.chord, let chord = catalog.chords[id] {
                AnimatedChordView(chord: chord)
            }

        case .practice(let practice):
            intro(title: practice.title, text: practice.text)
            if let slowerNotice {
                Label(slowerNotice, systemImage: "tortoise.fill")
                    .font(.headline)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Color.orange.opacity(0.15)))
            }
            if let pattern = catalog.patterns[practice.pattern] {
                PracticeStageView(
                    pattern: pattern,
                    segments: segments(practice.progression),
                    targetBpm: practice.bpm,
                    mode: .practice,
                    tempo: $tempo,
                    onStart: { progress.recordPractice() }
                )
            }

        case .check(let check):
            checkContent(check)
        }
    }

    @ViewBuilder
    private func checkContent(_ check: CheckStep) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(check.title)
                .font(.largeTitle.weight(.bold))
            Label(check.goal, systemImage: "target")
                .font(.title2.weight(.semibold))
                .foregroundStyle(Color.accentColor)
            Text("Press Start and play along after the count-in. The mic listens to every bar; you get the final say.")
                .font(.title3)
                .foregroundStyle(.secondary)
        }

        if let resolved = lesson.resolvedCheck(at: stepIndex), let pattern = catalog.patterns[resolved.pattern] {
            PracticeStageView(
                pattern: pattern,
                segments: segments(resolved.progression),
                targetBpm: check.bpm,
                mode: .check(bars: check.bars),
                tempo: $checkTempo,
                onFinish: { result in
                    withAnimation {
                        checkResult = result
                        checkFinished = true
                    }
                }
            )
        }

        if checkFinished {
            CheckVerdictPanel(
                result: checkResult,
                onRetry: { withAnimation { checkFinished = false; checkResult = nil } },
                onSlower: backToPracticeSlower,
                onComplete: complete
            )
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private func segments(_ progression: [ProgressionSegment]) -> [PracticeSegment] {
        progression.compactMap { segment in
            catalog.chords[segment.chord].map { PracticeSegment(chord: $0, bars: segment.bars) }
        }
    }

    // MARK: - Navigation

    private var bottomBar: some View {
        HStack {
            Button {
                go(to: stepIndex - 1)
            } label: {
                Label("Back", systemImage: "chevron.left")
                    .font(.title3.weight(.semibold))
                    .frame(minWidth: 120, minHeight: 44)
            }
            .buttonStyle(.bordered)
            .disabled(stepIndex == 0)

            Spacer()

            if step.kind != .check {
                Button {
                    if stepIndex + 1 < lesson.steps.count {
                        go(to: stepIndex + 1)
                    } else {
                        complete()
                    }
                } label: {
                    Label(nextTitle, systemImage: "chevron.right")
                        .labelStyle(TrailingIconLabelStyle())
                        .font(.title3.weight(.semibold))
                        .frame(minWidth: 160, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .controlSize(.large)
        .padding(.horizontal, 32)
        .padding(.vertical, 16)
        .background(.bar)
    }

    private var nextTitle: String {
        guard stepIndex + 1 < lesson.steps.count else { return "Finish" }
        return "Next: \(lesson.steps[stepIndex + 1].kind.title)"
    }

    private func go(to index: Int) {
        guard lesson.steps.indices.contains(index) else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            stepIndex = index
            checkFinished = false
            checkResult = nil
            if lesson.steps[index].kind != .practice { slowerNotice = nil }
        }
    }

    private func backToPracticeSlower() {
        let slower: DemoSpeed = switch tempo {
        case .normal: .medium
        case .medium, .slow: .slow
        }
        tempo = slower
        go(to: lesson.practiceIndex(before: stepIndex) ?? 0)
        slowerNotice = "Let's slow it down: practice at \(slower.label.lowercased()) speed, then try the check again."
    }

    private func complete() {
        progress.markCompleted(lesson)
        withAnimation(.spring(duration: 0.4)) { isComplete = true }
    }

    // MARK: - Completion

    private var completion: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 110))
                .foregroundStyle(.green)
                .symbolEffect(.bounce, value: isComplete)
            Text("Lesson complete!")
                .font(.largeTitle.weight(.bold))
            Text(lesson.title)
                .font(.title2)
                .foregroundStyle(.secondary)
            HStack(spacing: 20) {
                Button("Back to lessons") { dismiss() }
                    .buttonStyle(.bordered)
                if let nextLesson {
                    Button {
                        onOpenLesson(nextLesson)
                    } label: {
                        Label("Next: \(nextLesson.title)", systemImage: "chevron.right")
                            .labelStyle(TrailingIconLabelStyle())
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .font(.title3.weight(.semibold))
            .controlSize(.extraLarge)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(32)
    }
}

/// "Next ›" with the icon after the text.
struct TrailingIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            configuration.title
            configuration.icon
        }
    }
}

/// End of a check: what the mic heard (if it listened) and what to do next.
struct CheckVerdictPanel: View {
    let result: CheckResult?
    let onRetry: () -> Void
    let onSlower: () -> Void
    let onComplete: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            if let result {
                micSummary(result)
            } else {
                Text("Did you make it?")
                    .font(.title.weight(.bold))
            }
            buttons
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 20).fill(tint.opacity(0.1)))
    }

    private var tint: Color {
        guard let result else { return .accentColor }
        return result.passed ? .green : .orange
    }

    @ViewBuilder
    private func micSummary(_ result: CheckResult) -> some View {
        Label(result.passed ? "Nailed it!" : "Almost there", systemImage: result.passed ? "checkmark.seal.fill" : "ear")
            .font(.largeTitle.weight(.bold))
            .foregroundStyle(tint)
        Text("The mic heard \(result.cleanBars) of \(result.bars.count) clean bars (goal: \(result.neededBars)).")
            .font(.title3)
        HStack(spacing: 10) {
            ForEach(result.bars, id: \.bar) { bar in
                VStack(spacing: 4) {
                    Image(systemName: symbol(bar.outcome))
                        .font(.title2)
                        .foregroundStyle(bar.isClean ? Color.green : Color.orange)
                    Text(bar.expected)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .frame(minWidth: 36)
                .accessibilityLabel("Bar \(bar.bar + 1), \(bar.expected): \(description(bar.outcome))")
            }
        }
        if let advice = result.advice {
            Label(advice, systemImage: "lightbulb")
                .font(.headline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var buttons: some View {
        HStack(spacing: 20) {
            if let result, result.passed {
                button("Try again", systemImage: "arrow.counterclockwise", prominent: false, action: onRetry)
                button("Continue", systemImage: "checkmark", prominent: true, action: onComplete)
            } else if result != nil {
                button("I made it anyway", systemImage: "hand.thumbsup", prominent: false, action: onComplete)
                button("Practice slower", systemImage: "tortoise.fill", prominent: true, action: onSlower)
            } else {
                button("Not yet", systemImage: "arrow.uturn.backward", prominent: false, action: onSlower)
                button("Yes, nailed it!", systemImage: "checkmark", prominent: true, action: onComplete)
            }
        }
    }

    @ViewBuilder
    private func button(_ title: String, systemImage: String, prominent: Bool, action: @escaping () -> Void) -> some View {
        if prominent {
            Button(action: action) {
                Label(title, systemImage: systemImage)
                    .font(.title2.weight(.bold))
                    .frame(maxWidth: .infinity, minHeight: 60)
            }
            .buttonStyle(.borderedProminent)
        } else {
            Button(action: action) {
                Label(title, systemImage: systemImage)
                    .font(.title2.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 60)
            }
            .buttonStyle(.bordered)
        }
    }

    private func symbol(_ outcome: BarResult.Outcome) -> String {
        switch outcome {
        case .clean: "checkmark.circle.fill"
        case .wrongChord: "arrow.left.arrow.right.circle.fill"
        case .messy: "waveform.badge.exclamationmark"
        case .silent: "speaker.slash.circle.fill"
        }
    }

    private func description(_ outcome: BarResult.Outcome) -> String {
        switch outcome {
        case .clean: "clean"
        case .wrongChord(let heard): "sounded like \(heard)"
        case .messy: "unclear"
        case .silent: "too quiet"
        }
    }
}
