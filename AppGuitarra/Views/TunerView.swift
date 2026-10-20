//
//  TunerView.swift
//  AppGuitarra
//
//  Guitar-mode tuner: shows the string you are playing and how far it is
//  from standard tuning, with plain-language instructions.
//

import SwiftUI
import UIKit

struct TunerView: View {
    @State private var tuner = TunerEngine()
    @State private var isVisible = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(32)
                .navigationTitle("Tuner")
        }
        .onAppear { isVisible = true }
        .task { await tuner.start() }
        .onDisappear {
            isVisible = false
            tuner.stop()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, isVisible {
                Task { await tuner.start() }
            } else if phase != .active {
                tuner.stop()
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch tuner.status {
        case .permissionDenied:
            ContentUnavailableView {
                Label("Microphone access needed", systemImage: "mic.slash")
            } description: {
                Text("The tuner listens to your guitar. Allow microphone access in Settings.")
            } actions: {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        case .failed(let message):
            ContentUnavailableView("Tuner unavailable", systemImage: "exclamationmark.triangle", description: Text(message))
        case .idle, .listening:
            tunerDisplay
        }
    }

    // MARK: - Display

    private var tunerDisplay: some View {
        let output = tuner.output

        return VStack(spacing: 28) {
            StringPicker(
                activeString: output?.stringIndex,
                lockedString: tuner.lockedString,
                inTune: output?.isInTune ?? false
            ) { tuner.lockedString = $0 }

            TunerGauge(cents: output?.cents, tint: tint(for: output))
                .frame(maxWidth: 620, maxHeight: 300)

            VStack(spacing: 8) {
                Text(headline(for: output))
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                    .foregroundStyle(tint(for: output))
                    .contentTransition(.opacity)

                Text(detail(for: output))
                    .font(.title3.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .frame(minHeight: 110)

            HowToTuneHint()
        }
        .animation(.easeOut(duration: 0.2), value: output)
    }

    private func tint(for output: TunerOutput?) -> Color {
        guard let output else { return .secondary }
        if output.isInTune { return .green }
        return abs(output.cents) <= 20 ? .yellow : .orange
    }

    private func headline(for output: TunerOutput?) -> String {
        guard let output else {
            return tuner.lockedString == nil ? "Pluck any string" : "Pluck the \(StringInfo.all[tuner.lockedString!].shortName) string"
        }
        if output.isSettled { return "In tune ✓" }
        if output.isInTune { return "Almost… hold it" }
        let amount = abs(output.cents) > 50 ? "a lot" : (abs(output.cents) > 20 ? "a little" : "just a touch")
        return output.cents < 0 ? "Tighten \(amount) ↑" : "Loosen \(amount) ↓"
    }

    private func detail(for output: TunerOutput?) -> String {
        guard let output else { return "Let it ring for a second" }
        let info = StringInfo.all[output.stringIndex]
        let cents = Int(output.cents.rounded())
        let offset = abs(cents) > 99 ? "far off" : String(format: "%+ld cents", cents)
        return "\(info.ordinal) string (\(info.shortName)) · \(String(format: "%.1f", output.frequency)) Hz · \(offset)"
    }
}

// MARK: - String picker

/// The six strings as tappable chips. Tap one to tune only that string; tap Auto to detect.
private struct StringPicker: View {
    let activeString: Int?
    let lockedString: Int?
    let inTune: Bool
    let onSelect: (Int?) -> Void

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                chip(title: "Auto", subtitle: "detect", isActive: lockedString == nil, isHighlighted: false) {
                    onSelect(nil)
                }
                ForEach(0..<Chord.stringCount, id: \.self) { index in
                    let info = StringInfo.all[index]
                    chip(
                        title: info.shortName,
                        subtitle: "\(info.number)",
                        isActive: lockedString == index,
                        isHighlighted: activeString == index
                    ) {
                        onSelect(lockedString == index ? nil : index)
                    }
                }
            }
            Text(lockedString == nil
                 ? "Auto: the tuner follows whichever string you play. Tap a string to tune only that one."
                 : "Tuning only the \(StringInfo.all[lockedString!].ordinal) string. Tap Auto to go back.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func chip(title: String, subtitle: String, isActive: Bool, isHighlighted: Bool, action: @escaping () -> Void) -> some View {
        let color: Color = isHighlighted ? (inTune ? .green : .accentColor) : .secondary
        return Button(action: action) {
            VStack(spacing: 2) {
                Text(title).font(.title2.weight(.bold))
                Text(subtitle).font(.caption2).foregroundStyle(.secondary)
            }
            .frame(width: 76, height: 64)
            .background(RoundedRectangle(cornerRadius: 14).fill(color.opacity(isHighlighted ? 0.25 : 0.08)))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(isActive ? Color.accentColor : (isHighlighted ? color : .clear), lineWidth: isActive ? 3 : 2)
            )
        }
        .buttonStyle(.plain)
    }
}

private struct HowToTuneHint: View {
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "lightbulb")
                .font(.title2)
                .foregroundStyle(.yellow)
            VStack(alignment: .leading, spacing: 4) {
                Text("How to tune").font(.headline)
                Text("Pluck one string and let it ring. Slowly turn that string's tuning peg until the needle sits in the green zone. Tightening raises the pitch; loosening lowers it. Go from the thickest string (6) to the thinnest (1).")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: 620, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.secondary.opacity(0.08)))
    }
}

// MARK: - Gauge

/// Needle gauge from −50 to +50 cents. Readings beyond that pin the needle to the edge.
private struct TunerGauge: View {
    let cents: Double?
    let tint: Color

    private let maxAngle = 60.0   // degrees at ±50 cents

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let radius = min(size.width / 2, size.height) * 0.92
            let center = CGPoint(x: size.width / 2, y: size.height * 0.98)

            ZStack {
                Canvas { context, _ in
                    // In-tune zone (±5 cents)
                    var zone = Path()
                    zone.addArc(center: center, radius: radius * 0.9,
                                startAngle: .degrees(angle(-5).degrees - 90), endAngle: .degrees(angle(5).degrees - 90),
                                clockwise: false)
                    context.stroke(zone, with: .color(.green.opacity(0.5)), lineWidth: radius * 0.1)

                    for value in stride(from: -50, through: 50, by: 5) {
                        let isMajor = value % 10 == 0
                        let theta = angle(Double(value)).radians
                        var tick = Path()
                        tick.move(to: point(center, radius, theta))
                        tick.addLine(to: point(center, radius * (isMajor ? 0.84 : 0.9), theta))
                        context.stroke(tick, with: .foreground, lineWidth: isMajor ? 3 : 1.5)
                    }

                    let labelSize = radius * 0.08
                    context.draw(Text("♭ low").font(.system(size: labelSize, weight: .semibold)).foregroundStyle(.secondary),
                                 at: point(center, radius * 0.7, angle(-40).radians))
                    context.draw(Text("high ♯").font(.system(size: labelSize, weight: .semibold)).foregroundStyle(.secondary),
                                 at: point(center, radius * 0.7, angle(40).radians))
                    context.draw(Text("✓").font(.system(size: labelSize * 1.2, weight: .bold)).foregroundStyle(.green),
                                 at: point(center, radius * 0.72, 0))
                }

                Capsule()
                    .fill(tint)
                    .frame(width: 6, height: radius * 0.95)
                    .rotationEffect(angle(cents ?? 0), anchor: .bottom)
                    .opacity(cents == nil ? 0.25 : 1)
                    .position(x: center.x, y: center.y - radius * 0.95 / 2)

                Circle()
                    .fill(tint)
                    .frame(width: 22, height: 22)
                    .position(center)
            }
            .animation(.interpolatingSpring(stiffness: 120, damping: 20), value: cents)
        }
    }

    private func angle(_ cents: Double) -> Angle {
        .degrees(max(-50, min(50, cents)) / 50 * maxAngle)
    }

    /// Point at `radius` from `center`; theta 0 = straight up.
    private func point(_ center: CGPoint, _ radius: CGFloat, _ theta: Double) -> CGPoint {
        CGPoint(x: center.x + radius * sin(theta), y: center.y - radius * cos(theta))
    }
}
