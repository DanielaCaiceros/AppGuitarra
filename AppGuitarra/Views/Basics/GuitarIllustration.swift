//
//  GuitarIllustration.swift
//  AppGuitarra
//
//  An acoustic guitar drawn in code with numbered, tappable callouts for each part.
//  Drawn in a 1000 × 480 design space and scaled to fit.
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

    /// Point on the guitar the callout points to (design space).
    fileprivate var anchor: CGPoint {
        switch self {
        case .headstock: CGPoint(x: 960, y: 240)
        case .tuningPegs: CGPoint(x: 945, y: 296)
        case .nut: CGPoint(x: 884, y: 212)
        case .frets: CGPoint(x: 800, y: 212)
        case .fretboard: CGPoint(x: 720, y: 268)
        case .strings: CGPoint(x: 640, y: 222)
        case .soundHole: CGPoint(x: 500, y: 184)
        case .bridge: CGPoint(x: 195, y: 172)
        case .body: CGPoint(x: 150, y: 350)
        }
    }

    /// Where the numbered badge sits (design space).
    fileprivate var badge: CGPoint {
        switch self {
        case .headstock: CGPoint(x: 975, y: 400)
        case .tuningPegs: CGPoint(x: 905, y: 420)
        case .nut: CGPoint(x: 884, y: 110)
        case .frets: CGPoint(x: 800, y: 110)
        case .fretboard: CGPoint(x: 720, y: 400)
        case .strings: CGPoint(x: 640, y: 110)
        case .soundHole: CGPoint(x: 500, y: 40)
        case .bridge: CGPoint(x: 195, y: 30)
        case .body: CGPoint(x: 60, y: 450)
        }
    }
}

struct GuitarIllustration: View {
    @Binding var selected: GuitarPart?

    private static let designSize = CGSize(width: 1000, height: 480)

    var body: some View {
        GeometryReader { geometry in
            let scale = min(geometry.size.width / Self.designSize.width, geometry.size.height / Self.designSize.height)
            let origin = CGPoint(
                x: (geometry.size.width - Self.designSize.width * scale) / 2,
                y: (geometry.size.height - Self.designSize.height * scale) / 2
            )
            let map: (CGPoint) -> CGPoint = { CGPoint(x: origin.x + $0.x * scale, y: origin.y + $0.y * scale) }

            ZStack(alignment: .topLeading) {
                Canvas { context, _ in
                    context.translateBy(x: origin.x, y: origin.y)
                    context.scaleBy(x: scale, y: scale)
                    drawGuitar(in: context)
                    if let selected {
                        drawHighlight(for: selected, in: context)
                    }
                    for part in GuitarPart.allCases {
                        var leader = Path()
                        leader.move(to: part.badge)
                        leader.addLine(to: part.anchor)
                        let isSelected = part == selected
                        context.stroke(leader, with: isSelected ? .color(.accentColor) : .foreground,
                                       style: StrokeStyle(lineWidth: isSelected ? 3 : 1.5, dash: isSelected ? [] : [5, 4]))
                        let dot = CGRect(x: part.anchor.x - 5, y: part.anchor.y - 5, width: 10, height: 10)
                        context.fill(Path(ellipseIn: dot), with: isSelected ? .color(.accentColor) : .foreground)
                    }
                }

                ForEach(GuitarPart.allCases) { part in
                    let isSelected = part == selected
                    Button {
                        withAnimation(.snappy) { selected = isSelected ? nil : part }
                    } label: {
                        Text("\(part.number)")
                            .font(.system(size: max(13, 20 * scale), weight: .bold, design: .rounded))
                            .foregroundStyle(isSelected ? .white : .primary)
                            .frame(width: max(30, 42 * scale), height: max(30, 42 * scale))
                            .background(Circle().fill(isSelected ? Color.accentColor : Color(uiColor: .systemBackground)))
                            .overlay(Circle().stroke(isSelected ? Color.accentColor : .primary, lineWidth: 2))
                    }
                    .buttonStyle(.plain)
                    .position(map(part.badge))
                    .accessibilityLabel(part.title)
                }
            }
        }
        .aspectRatio(Self.designSize.width / Self.designSize.height, contentMode: .fit)
    }

    // MARK: - Shapes (design space)

    private var bodyPath: Path {
        var path = Path()
        path.addEllipse(in: CGRect(x: 60, y: 65, width: 380, height: 350))     // lower bout
        path.addEllipse(in: CGRect(x: 380, y: 105, width: 280, height: 270))   // upper bout
        return path
    }
    private let soundHoleRect = CGRect(x: 442, y: 182, width: 116, height: 116)
    private let bridgeRect = CGRect(x: 175, y: 170, width: 40, height: 140)
    private let fretboardRect = CGRect(x: 560, y: 210, width: 320, height: 60)
    private let nutRect = CGRect(x: 880, y: 208, width: 9, height: 64)
    private var headstockPath: Path {
        var path = Path()
        path.move(to: CGPoint(x: 889, y: 202))
        path.addLine(to: CGPoint(x: 990, y: 188))
        path.addQuadCurve(to: CGPoint(x: 990, y: 292), control: CGPoint(x: 1004, y: 240))
        path.addLine(to: CGPoint(x: 889, y: 278))
        path.closeSubpath()
        return path
    }
    private let pegXs: [CGFloat] = [915, 945, 975]
    private func pegRect(_ index: Int) -> CGRect {
        // Strings 6, 5, 4 → top pegs; 3, 2, 1 → bottom pegs.
        let x = pegXs[index % 3]
        let y: CGFloat = index < 3 ? 170 : 296
        return CGRect(x: x - 11, y: y - 14, width: 22, height: 28)
    }
    private func stringY(_ index: Int) -> CGFloat { 218 + CGFloat(index) * 8.8 }
    private func fretX(_ fret: Int) -> CGFloat { 880 - 568 * (1 - pow(2, -CGFloat(fret) / 12)) }

    private func stringsPath(for index: Int) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 200, y: stringY(index)))
        path.addLine(to: CGPoint(x: 884, y: stringY(index)))
        let peg = pegRect(index)
        path.addLine(to: CGPoint(x: peg.midX, y: index < 3 ? 222 : 258))
        return path
    }

    private func drawGuitar(in context: GraphicsContext) {
        let wood = Color(red: 0.86, green: 0.62, blue: 0.36)
        let darkWood = Color(red: 0.36, green: 0.20, blue: 0.10)

        context.fill(bodyPath, with: .color(wood))
        context.stroke(bodyPath, with: .color(darkWood.opacity(0.35)), lineWidth: 3)

        // Sound hole with rosette
        context.stroke(Path(ellipseIn: soundHoleRect.insetBy(dx: -10, dy: -10)), with: .color(darkWood.opacity(0.6)), lineWidth: 6)
        context.fill(Path(ellipseIn: soundHoleRect), with: .color(Color(white: 0.1)))

        // Bridge
        context.fill(Path(roundedRect: bridgeRect, cornerRadius: 8), with: .color(darkWood))
        context.fill(Path(CGRect(x: 198, y: 205, width: 4, height: 70)), with: .color(Color(white: 0.95)))

        // Neck, fretboard, frets and inlays
        context.fill(Path(fretboardRect), with: .color(darkWood))
        for fret in 1...14 {
            var line = Path()
            line.move(to: CGPoint(x: fretX(fret), y: fretboardRect.minY))
            line.addLine(to: CGPoint(x: fretX(fret), y: fretboardRect.maxY))
            context.stroke(line, with: .color(Color(white: 0.8)), lineWidth: 2.5)
        }
        for fret in [3, 5, 7, 9] {
            let x = (fretX(fret) + fretX(fret - 1)) / 2
            context.fill(Path(ellipseIn: CGRect(x: x - 5, y: 235, width: 10, height: 10)), with: .color(.white.opacity(0.8)))
        }

        // Headstock, nut, pegs
        context.fill(headstockPath, with: .color(darkWood))
        context.fill(Path(nutRect), with: .color(Color(white: 0.95)))
        for index in 0..<6 {
            let peg = pegRect(index)
            context.fill(Path(roundedRect: peg, cornerRadius: 8), with: .color(Color(white: 0.85)))
            context.stroke(Path(roundedRect: peg, cornerRadius: 8), with: .color(Color(white: 0.55)), lineWidth: 1.5)
        }

        // Strings: thicker for lower strings
        for index in 0..<6 {
            context.stroke(stringsPath(for: index), with: .color(Color(white: 0.92)), lineWidth: 2.6 - CGFloat(index) * 0.32)
        }
    }

    private func drawHighlight(for part: GuitarPart, in context: GraphicsContext) {
        let accent = Color.accentColor
        let glow = GraphicsContext.Shading.color(accent.opacity(0.35))
        switch part {
        case .body:
            context.fill(bodyPath, with: glow)
        case .soundHole:
            context.stroke(Path(ellipseIn: soundHoleRect), with: .color(accent), lineWidth: 6)
        case .bridge:
            context.fill(Path(roundedRect: bridgeRect, cornerRadius: 8), with: glow)
            context.stroke(Path(roundedRect: bridgeRect, cornerRadius: 8), with: .color(accent), lineWidth: 4)
        case .fretboard:
            context.fill(Path(fretboardRect), with: glow)
            context.stroke(Path(fretboardRect), with: .color(accent), lineWidth: 4)
        case .frets:
            for fret in 1...14 {
                var line = Path()
                line.move(to: CGPoint(x: fretX(fret), y: fretboardRect.minY - 4))
                line.addLine(to: CGPoint(x: fretX(fret), y: fretboardRect.maxY + 4))
                context.stroke(line, with: .color(accent), lineWidth: 4)
            }
        case .nut:
            context.stroke(Path(nutRect.insetBy(dx: -3, dy: -3)), with: .color(accent), lineWidth: 4)
        case .headstock:
            context.fill(headstockPath, with: glow)
            context.stroke(headstockPath, with: .color(accent), lineWidth: 4)
        case .tuningPegs:
            for index in 0..<6 {
                context.stroke(Path(roundedRect: pegRect(index).insetBy(dx: -3, dy: -3), cornerRadius: 10), with: .color(accent), lineWidth: 4)
            }
        case .strings:
            for index in 0..<6 {
                context.stroke(stringsPath(for: index), with: .color(accent), lineWidth: 3)
            }
        }
    }
}
