//
//  GuitarIllustration.swift
//  AppGuitarra
//
//  Guitar illustration from Wikimedia Commons with numbered, tappable callouts
//  for each part, drawn on top in code.
//

import SwiftUI
import UIKit

nonisolated enum GuitarPart: Int, CaseIterable, Identifiable {
    case headstock, tuningPegs, nut, frets, fretboard, strings, soundHole, bridge, body

    var id: Int { rawValue }
    var number: Int { rawValue + 1 }

    var title: String {
        switch self {
        case .headstock: "Headstock"
        case .tuningPegs: "Tuning pegs"
        case .nut: "Nut"
        case .frets: "Frets"
        case .fretboard: "Fretboard (neck)"
        case .strings: "Strings"
        case .soundHole: "Sound hole"
        case .bridge: "Bridge"
        case .body: "Body"
        }
    }

    var explanation: String {
        switch self {
        case .headstock:
            "The end of the neck that holds the tuning pegs."
        case .tuningPegs:
            "Turn these to tune. Tightening a string makes it sound higher; loosening makes it lower. Use the Tuner tab while you turn them."
        case .nut:
            "The small white bar where the strings leave the headstock. In chord diagrams it's the thick line at the top."
        case .frets:
            "The metal strips across the neck. \"Fret 2\" means the space just before the 2nd metal strip, counting from the nut. Press close to the strip, not on top of it."
        case .fretboard:
            "The front of the neck where your fingers press the strings. Your fretting hand (usually the left) goes here."
        case .strings:
            "Six strings. The thickest is string 6 (low E) and sits on top when you hold the guitar; the thinnest is string 1 (high E)."
        case .soundHole:
            "Lets the sound out. Strum with your other hand roughly over this spot."
        case .bridge:
            "Holds the strings to the body. Don't strum here: the sound gets thin."
        case .body:
            "The hollow wooden box that makes the sound louder. Rest it on your leg."
        }
    }

    /// Point on the guitar the callout points to (design space, see `GuitarIllustration`).
    fileprivate var anchor: CGPoint {
        switch self {
        case .headstock: CGPoint(x: 262, y: 80)
        case .tuningPegs: CGPoint(x: 305, y: 110)
        case .nut: CGPoint(x: 246, y: 163)
        case .frets: CGPoint(x: 246, y: 315.5)
        case .fretboard: CGPoint(x: 215, y: 420)
        case .strings: CGPoint(x: 196, y: 630)
        case .soundHole: CGPoint(x: 207, y: 548)
        case .bridge: CGPoint(x: 150, y: 685)
        case .body: CGPoint(x: 285, y: 720)
        }
    }

    /// Where the numbered badge sits: left column x = 36, right column x = 404.
    fileprivate var badge: CGPoint {
        switch self {
        case .headstock: CGPoint(x: 36, y: 80)
        case .tuningPegs: CGPoint(x: 404, y: 110)
        case .nut: CGPoint(x: 404, y: 175)
        case .frets: CGPoint(x: 404, y: 315)
        case .fretboard: CGPoint(x: 36, y: 420)
        case .strings: CGPoint(x: 36, y: 630)
        case .soundHole: CGPoint(x: 404, y: 548)
        case .bridge: CGPoint(x: 36, y: 740)
        case .body: CGPoint(x: 404, y: 720)
        }
    }
}

/// Guitar illustration ("Acoustic guitar (mul).svg" by William Crochot, Wikimedia Commons,
/// CC BY-SA 4.0, labels removed) with numbered, tappable callouts drawn on top.
///
/// Coordinates use the SVG's own space, widened to make room for the badges:
/// the image occupies x 77.9…361.3, y 30.3…822.4 inside a 440 × 810 canvas starting at y = 20.
struct GuitarIllustration: View {
    @Binding var selected: GuitarPart?

    private static let design = CGRect(x: 0, y: 20, width: 440, height: 810)
    private static let imageRect = CGRect(x: 77.9, y: 30.3, width: 283.4, height: 792.1)
    static let credit = "Guitar illustration: William Crochot (Wikimedia Commons), CC BY-SA 4.0"

    var body: some View {
        GeometryReader { geometry in
            let scale = min(geometry.size.width / Self.design.width, geometry.size.height / Self.design.height)
            let origin = CGPoint(
                x: (geometry.size.width - Self.design.width * scale) / 2,
                y: (geometry.size.height - Self.design.height * scale) / 2
            )
            let map: (CGPoint) -> CGPoint = {
                CGPoint(x: origin.x + ($0.x - Self.design.minX) * scale,
                        y: origin.y + ($0.y - Self.design.minY) * scale)
            }
            let imageOrigin = map(Self.imageRect.origin)

            ZStack(alignment: .topLeading) {
                Image("GuitarParts")
                    .resizable()
                    .frame(width: Self.imageRect.width * scale, height: Self.imageRect.height * scale)
                    .offset(x: imageOrigin.x, y: imageOrigin.y)
                    .accessibilityHidden(true)

                Canvas { context, _ in
                    for part in GuitarPart.allCases {
                        let isSelected = part == selected
                        let start = map(part.badge)
                        let end = map(part.anchor)
                        var leader = Path()
                        leader.move(to: start)
                        leader.addLine(to: end)
                        context.stroke(
                            leader,
                            with: isSelected ? .color(.accentColor) : .color(.primary.opacity(0.55)),
                            style: StrokeStyle(lineWidth: isSelected ? 3 : 1.5, lineCap: .round, dash: isSelected ? [] : [4, 4])
                        )
                        let radius: CGFloat = isSelected ? 9 : 5
                        let dot = CGRect(x: end.x - radius, y: end.y - radius, width: radius * 2, height: radius * 2)
                        context.fill(Path(ellipseIn: dot), with: isSelected ? .color(.accentColor) : .color(.white))
                        context.stroke(Path(ellipseIn: dot), with: .color(isSelected ? .white : .accentColor), lineWidth: 2)
                    }
                }
                .allowsHitTesting(false)

                ForEach(GuitarPart.allCases) { part in
                    let isSelected = part == selected
                    Button {
                        withAnimation(.snappy) { selected = isSelected ? nil : part }
                    } label: {
                        Text("\(part.number)")
                            .font(.system(size: 18, weight: .bold, design: .rounded))
                            .foregroundStyle(isSelected ? .white : Color.accentColor)
                            .frame(width: 40, height: 40)
                            .background(Circle().fill(isSelected ? Color.accentColor : Color(uiColor: .systemBackground)))
                            .overlay(Circle().stroke(Color.accentColor, lineWidth: 2))
                            .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
                    }
                    .buttonStyle(.plain)
                    .position(map(part.badge))
                    .accessibilityLabel(part.title)
                }
            }
        }
        .aspectRatio(Self.design.width / Self.design.height, contentMode: .fit)
    }
}
