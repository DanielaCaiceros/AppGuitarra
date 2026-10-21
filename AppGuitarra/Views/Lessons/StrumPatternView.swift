//
//  StrumPatternView.swift
//  AppGuitarra
//
//  The strum pattern as a row of arrows ("1 & 2 & 3 & 4 &"), with the current
//  stroke lit, plus a pick that moves up and down in time so you can see that
//  the hand never stops, even on the strokes that miss the strings.
//

import SwiftUI

struct StrumPatternView: View {
    let pattern: StrumPattern
    /// Slot being played right now; nil when stopped or counting in.
    var activeSlot: Int?

    var body: some View {
        VStack(spacing: 10) {
            strip
            if pattern.hasSpecialStrokes {
                legend
            }
        }
    }

    private var strip: some View {
        HStack(spacing: 0) {
            ForEach(0..<pattern.beatsPerBar, id: \.self) { beat in
                HStack(spacing: 6) {
                    ForEach(0..<pattern.slotsPerBeat, id: \.self) { sub in
                        slotView(beat * pattern.slotsPerBeat + sub)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 14).fill(Color.secondary.opacity(0.07)))
                .padding(.horizontal, 6)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Strum pattern \(pattern.name)")
    }

    private func slotView(_ slot: Int) -> some View {
        let stroke = pattern.slots[slot]
        let isActive = slot == activeSlot
        let isAccented = pattern.isAccented(slot) && stroke.isPlayed
        return VStack(spacing: 4) {
            Text(isAccented ? ">" : " ")
                .font(.headline.weight(.heavy))
                .foregroundStyle(.orange)
            StrokeSymbol(stroke: stroke)
                .frame(height: 48)
                .foregroundStyle(stroke.isPlayed ? (isActive ? Color.white : Color.primary) : Color.secondary.opacity(0.5))
            Text(pattern.countLabel(slot))
                .font(.title3.weight(slot % pattern.slotsPerBeat == 0 ? .bold : .regular))
                .foregroundStyle(isActive ? Color.white : Color.secondary)
        }
        .frame(width: 58, height: 112)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(isActive ? (stroke.isPlayed ? Color.accentColor : Color.secondary.opacity(0.6)) : .clear)
        )
        .scaleEffect(isActive ? 1.08 : 1)
        .animation(.easeOut(duration: 0.08), value: isActive)
    }

    /// What the special symbols mean, only for patterns that use them.
    private var legend: some View {
        let slots = pattern.slots
        return HStack(spacing: 18) {
            if slots.contains(.mute) {
                legendItem(.mute, "muted strum (chuck)")
            }
            if slots.contains(.bass) {
                legendItem(.bass, "bass note")
            }
            if slots.contains(.altBass) {
                legendItem(.altBass, "other bass note")
            }
            if slots.contains(where: { if case .string = $0 { true } else { false } }) {
                legendItem(.string(1), "string number (1 = thinnest)")
            }
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }

    private func legendItem(_ stroke: Stroke, _ text: String) -> some View {
        HStack(spacing: 6) {
            StrokeSymbol(stroke: stroke, size: 18)
                .foregroundStyle(.primary)
            Text(text)
        }
    }
}

/// Arrow, chuck, bass marker or string number for one slot.
struct StrokeSymbol: View {
    let stroke: Stroke
    var size: CGFloat = 40

    var body: some View {
        switch stroke {
        case .down:
            Image(systemName: "arrow.down").font(.system(size: size, weight: .bold))
        case .up:
            Image(systemName: "arrow.up").font(.system(size: size, weight: .bold))
        case .miss:
            Image(systemName: "circle.dotted").font(.system(size: size * 0.55, weight: .bold))
        case .mute:
            Image(systemName: "xmark").font(.system(size: size * 0.8, weight: .heavy))
        case .bass:
            Text("B")
                .font(.system(size: size * 0.55, weight: .heavy, design: .rounded))
                .frame(width: size * 0.95, height: size * 0.95)
                .background(Circle().stroke(lineWidth: max(2, size * 0.07)))
        case .altBass:
            Text("B")
                .font(.system(size: size * 0.55, weight: .heavy, design: .rounded))
                .frame(width: size * 0.95, height: size * 0.95)
                .background(Circle().stroke(style: StrokeStyle(lineWidth: max(2, size * 0.07), dash: [size * 0.12, size * 0.08])))
        case .string(let number):
            Text("\(number)")
                .font(.system(size: size * 0.6, weight: .heavy, design: .rounded))
                .frame(width: size * 0.9, height: size * 0.9)
                .background(RoundedRectangle(cornerRadius: size * 0.2).stroke(lineWidth: max(2, size * 0.06)))
        }
    }
}

/// A pick that travels down on the beats and up on the "ands".
/// Solid when it hits the strings, hollow when it passes over them.
struct PickMotionView: View {
    /// Slot inside the bar and progress through it; nil when stopped.
    var slot: Int?
    var fraction: Double = 0
    var hits = false

    var body: some View {
        GeometryReader { geometry in
            let height = geometry.size.height
            let pickSize: CGFloat = 40
            let travel = height - pickSize
            let goingDown = (slot ?? 0) % 2 == 0
            let progress = slot == nil ? 0 : (goingDown ? fraction : 1 - fraction)

            ZStack(alignment: .top) {
                // The six strings, seen from above.
                VStack(spacing: 0) {
                    ForEach(0..<6, id: \.self) { index in
                        Rectangle()
                            .fill(Color(red: 0.85, green: 0.80, blue: 0.68))
                            .frame(height: 1.5 + CGFloat(5 - index) * 0.5)
                            .frame(maxHeight: .infinity)
                    }
                }
                .padding(.vertical, pickSize / 2)

                Image(systemName: hits ? "triangle.fill" : "triangle")
                    .font(.system(size: 30, weight: .bold))
                    .rotationEffect(.degrees(goingDown ? 180 : 0))
                    .foregroundStyle(hits ? Color.accentColor : Color.secondary)
                    .frame(width: pickSize, height: pickSize)
                    .offset(y: travel * progress)
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.secondary.opacity(0.07)))
        .accessibilityHidden(true)
    }
}

#Preview {
    VStack(spacing: 40) {
        StrumPatternView(pattern: StrumPattern(id: "folk", name: "Folk", strokes: "D-DU-UDU", accents: [0]), activeSlot: 2)
        PickMotionView(slot: 2, fraction: 0.4, hits: true).frame(width: 70, height: 240)
    }
    .padding()
}
