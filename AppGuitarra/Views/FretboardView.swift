//
//  FretboardView.swift
//  AppGuitarra
//
//  Horizontal neck as the player sees it when looking down at the guitar:
//  thick low E string on top, thin high E at the bottom, nut on the left.
//  A downstroke therefore moves top to bottom on screen.
//  Finger dots are SwiftUI views so they can animate in.
//

import SwiftUI

struct FretboardView: View {
    let chord: Chord
    /// Fingers currently shown (1...4). Placements with other fingers stay hidden.
    var visibleFingers: Set<Int> = [1, 2, 3, 4]
    /// Strings drawn as vibrating (strum highlight).
    var strummedStrings: Set<Int> = []
    /// Finger that was just placed; drawn slightly larger.
    var highlightedFinger: Int?

    private var firstFret: Int { chord.baseFret }
    private var fretCount: Int { max(5, chord.highestFret - chord.baseFret + 1) }

    var body: some View {
        GeometryReader { geometry in
            let layout = Layout(size: geometry.size, fretCount: fretCount)

            ZStack(alignment: .topLeading) {
                Canvas { context, _ in
                    drawBoard(in: context, layout: layout)
                }

                if let barre = chord.barre, visibleFingers.contains(barre.finger) {
                    let range = barre.stringIndexes
                    let top = min(layout.stringY(range.lowerBound), layout.stringY(range.upperBound))
                    let bottom = max(layout.stringY(range.lowerBound), layout.stringY(range.upperBound))
                    Capsule()
                        .fill(Color.accentColor.opacity(0.85))
                        .frame(width: layout.dotRadius * 2, height: bottom - top + layout.dotRadius * 2)
                        .position(x: layout.noteX(barre.fret - firstFret), y: (top + bottom) / 2)
                        .transition(.scale(scale: 0.2).combined(with: .opacity))
                }

                ForEach(chord.placements.filter { visibleFingers.contains($0.finger) }, id: \.self) { placement in
                    FingerDot(finger: placement.finger, radius: layout.dotRadius)
                        .scaleEffect(highlightedFinger == placement.finger ? 1.15 : 1)
                        .position(
                            x: layout.noteX(placement.fret - firstFret),
                            y: layout.stringY(placement.stringIndex)
                        )
                        .transition(.scale(scale: 0.2).combined(with: .opacity))
                }
            }
        }
        .aspectRatio(2.6, contentMode: .fit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(chord.name) on the fretboard")
    }

    // MARK: - Layout

    private struct Layout {
        let size: CGSize
        let fretCount: Int

        var labelWidth: CGFloat { size.width * 0.1 }
        var boardRect: CGRect {
            CGRect(x: labelWidth, y: size.height * 0.06,
                   width: size.width - labelWidth - size.width * 0.02,
                   height: size.height * 0.88)
        }
        var fretWidth: CGFloat { boardRect.width / CGFloat(fretCount) }
        var stringSpacing: CGFloat { boardRect.height / CGFloat(Chord.stringCount) }
        var dotRadius: CGFloat { min(stringSpacing, fretWidth) * 0.4 }

        /// Low E (index 0) on top, like looking down at the guitar.
        func stringY(_ stringIndex: Int) -> CGFloat {
            boardRect.minY + (CGFloat(stringIndex) + 0.5) * stringSpacing
        }
        /// x of fret wire `line` (0 = nut).
        func fretLineX(_ line: Int) -> CGFloat {
            boardRect.minX + CGFloat(line) * fretWidth
        }
        /// Finger position for a fret, just behind the fret wire. `offset` 0 = first fret shown.
        func noteX(_ offset: Int) -> CGFloat {
            boardRect.minX + (CGFloat(offset) + 0.6) * fretWidth
        }
    }

    // MARK: - Board

    private func drawBoard(in context: GraphicsContext, layout: Layout) {
        let board = layout.boardRect
        let wood = Gradient(colors: [
            Color(red: 0.42, green: 0.26, blue: 0.15),
            Color(red: 0.30, green: 0.18, blue: 0.10),
        ])
        context.fill(
            Path(roundedRect: board, cornerRadius: 6),
            with: .linearGradient(wood, startPoint: CGPoint(x: 0, y: board.minY), endPoint: CGPoint(x: 0, y: board.maxY))
        )

        // Inlays
        let inlayRadius = layout.stringSpacing * 0.22
        for offset in 0..<layout.fretCount {
            let fret = firstFret + offset
            let centerX = (layout.fretLineX(offset) + layout.fretLineX(offset + 1)) / 2
            let ys: [CGFloat]
            switch fret {
            case 3, 5, 7, 9, 15, 17: ys = [board.midY]
            case 12: ys = [board.minY + board.height * 0.3, board.minY + board.height * 0.7]
            default: ys = []
            }
            for y in ys {
                let rect = CGRect(x: centerX - inlayRadius, y: y - inlayRadius, width: inlayRadius * 2, height: inlayRadius * 2)
                context.fill(Path(ellipseIn: rect), with: .color(.white.opacity(0.35)))
            }
        }

        // Fret wires (thick nut when starting at the first fret)
        for line in 0...layout.fretCount {
            let x = layout.fretLineX(line)
            var path = Path()
            path.move(to: CGPoint(x: x, y: board.minY))
            path.addLine(to: CGPoint(x: x, y: board.maxY))
            let isNut = line == 0 && firstFret == 1
            context.stroke(path, with: .color(isNut ? Color(white: 0.92) : Color(white: 0.75)), lineWidth: isNut ? 8 : 3)
        }

        // Fret numbers under the board
        for offset in 0..<layout.fretCount {
            let centerX = (layout.fretLineX(offset) + layout.fretLineX(offset + 1)) / 2
            let label = Text("\(firstFret + offset)")
                .font(.system(size: layout.stringSpacing * 0.32))
                .foregroundStyle(.secondary)
            context.draw(label, at: CGPoint(x: centerX, y: board.maxY + layout.size.height * 0.03))
        }

        // Strings (thicker for lower strings), plus labels and open/muted markers
        for index in 0..<Chord.stringCount {
            let y = layout.stringY(index)
            let isStrummed = strummedStrings.contains(index)
            let baseWidth = 1.2 + CGFloat(Chord.stringCount - 1 - index) * 0.5
            var path = Path()
            path.move(to: CGPoint(x: board.minX, y: y))
            path.addLine(to: CGPoint(x: board.maxX, y: y))
            context.stroke(
                path,
                with: .color(isStrummed ? .yellow : Color(red: 0.85, green: 0.80, blue: 0.68)),
                lineWidth: isStrummed ? baseWidth + 2.5 : baseWidth
            )

            let labelX = layout.labelWidth * 0.36
            let markerX = layout.labelWidth * 0.8
            let info = StringInfo.all[index]
            context.draw(
                Text("\(info.number) ").font(.system(size: layout.stringSpacing * 0.3)).foregroundStyle(.secondary)
                    + Text(info.shortName).font(.system(size: layout.stringSpacing * 0.42, weight: .semibold)),
                at: CGPoint(x: labelX, y: y)
            )
            let markerText: String? = chord.isMuted(index) ? "×" : (chord.isOpen(index) ? "○" : nil)
            if let markerText {
                context.draw(
                    Text(markerText)
                        .font(.system(size: layout.stringSpacing * 0.5, weight: .bold))
                        .foregroundStyle(chord.isMuted(index) ? Color.red : Color.green),
                    at: CGPoint(x: markerX, y: y)
                )
            }
        }
    }
}

private struct FingerDot: View {
    let finger: Int
    let radius: CGFloat

    var body: some View {
        Circle()
            .fill(Color.accentColor)
            .overlay {
                Text("\(finger)")
                    .font(.system(size: radius * 1.1, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            }
            .overlay(Circle().stroke(.white.opacity(0.8), lineWidth: 2))
            .frame(width: radius * 2, height: radius * 2)
            .shadow(radius: 3, y: 2)
    }
}

#Preview {
    if let g = (try? ChordLibrary.loadChords())?.first(where: { $0.id == "F" }) {
        FretboardView(chord: g, strummedStrings: [2, 3])
            .padding()
    }
}
