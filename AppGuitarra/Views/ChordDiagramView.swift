//
//  ChordDiagramView.swift
//  AppGuitarra
//
//  Classic vertical chord chart drawn from `Chord` data:
//  strings are vertical (low E on the left), frets are horizontal.
//

import SwiftUI
import UIKit

struct ChordDiagramView: View {
    let chord: Chord
    var showsName = true

    var body: some View {
        VStack(spacing: 6) {
            if showsName {
                Text(chord.id)
                    .font(.title2.bold())
            }
            Canvas { context, size in
                draw(in: context, size: size)
            }
            .aspectRatio(0.85, contentMode: .fit)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(chord.name) chord diagram")
    }

    // MARK: - Drawing

    private var fretCount: Int {
        max(4, chord.highestFret - chord.baseFret + 1)
    }

    private func draw(in context: GraphicsContext, size: CGSize) {
        let leftMargin = size.width * 0.16
        let rightMargin = size.width * 0.08
        let topMargin = size.height * 0.14
        let bottomMargin = size.height * 0.04

        let gridWidth = size.width - leftMargin - rightMargin
        let gridHeight = size.height - topMargin - bottomMargin
        let stringSpacing = gridWidth / CGFloat(Chord.stringCount - 1)
        let fretSpacing = gridHeight / CGFloat(fretCount)
        let dotRadius = min(stringSpacing, fretSpacing) * 0.36
        let lineWidth = max(1, size.width * 0.008)

        func x(_ stringIndex: Int) -> CGFloat {
            leftMargin + CGFloat(stringIndex) * stringSpacing
        }
        func fretLineY(_ line: Int) -> CGFloat {
            topMargin + CGFloat(line) * fretSpacing
        }
        func noteY(_ fret: Int) -> CGFloat {
            topMargin + (CGFloat(fret - chord.baseFret) + 0.5) * fretSpacing
        }

        // Strings
        for index in 0..<Chord.stringCount {
            var path = Path()
            path.move(to: CGPoint(x: x(index), y: fretLineY(0)))
            path.addLine(to: CGPoint(x: x(index), y: fretLineY(fretCount)))
            context.stroke(path, with: .foreground, lineWidth: lineWidth)
        }

        // Frets
        for line in 0...fretCount {
            var path = Path()
            path.move(to: CGPoint(x: x(0), y: fretLineY(line)))
            path.addLine(to: CGPoint(x: x(Chord.stringCount - 1), y: fretLineY(line)))
            context.stroke(path, with: .foreground, lineWidth: lineWidth)
        }

        // Nut, or base fret label when the shape starts higher up the neck.
        if chord.baseFret == 1 {
            let nut = CGRect(
                x: x(0) - lineWidth / 2,
                y: fretLineY(0) - lineWidth * 4,
                width: gridWidth + lineWidth,
                height: lineWidth * 4
            )
            context.fill(Path(nut), with: .foreground)
        } else {
            let label = Text("\(chord.baseFret)fr").font(.system(size: fretSpacing * 0.32, weight: .medium))
            context.draw(label, at: CGPoint(x: leftMargin * 0.45, y: noteY(chord.baseFret)))
        }

        // Open (○) and muted (×) markers above the nut.
        let markerY = topMargin * 0.42
        let markerRadius = dotRadius * 0.6
        for index in 0..<Chord.stringCount {
            let center = CGPoint(x: x(index), y: markerY)
            if chord.isMuted(index) {
                var cross = Path()
                cross.move(to: CGPoint(x: center.x - markerRadius, y: center.y - markerRadius))
                cross.addLine(to: CGPoint(x: center.x + markerRadius, y: center.y + markerRadius))
                cross.move(to: CGPoint(x: center.x + markerRadius, y: center.y - markerRadius))
                cross.addLine(to: CGPoint(x: center.x - markerRadius, y: center.y + markerRadius))
                context.stroke(cross, with: .foreground, lineWidth: lineWidth * 1.4)
            } else if chord.isOpen(index) {
                let circle = Path(ellipseIn: CGRect(
                    x: center.x - markerRadius, y: center.y - markerRadius,
                    width: markerRadius * 2, height: markerRadius * 2
                ))
                context.stroke(circle, with: .foreground, lineWidth: lineWidth * 1.4)
            }
        }

        // Barre
        if let barre = chord.barre {
            let range = barre.stringIndexes
            let rect = CGRect(
                x: x(range.lowerBound) - dotRadius,
                y: noteY(barre.fret) - dotRadius,
                width: x(range.upperBound) - x(range.lowerBound) + dotRadius * 2,
                height: dotRadius * 2
            )
            context.fill(Path(roundedRect: rect, cornerRadius: dotRadius), with: .foreground)
        }

        // Finger dots
        for placement in chord.placements {
            let center = CGPoint(x: x(placement.stringIndex), y: noteY(placement.fret))
            let dot = Path(ellipseIn: CGRect(
                x: center.x - dotRadius, y: center.y - dotRadius,
                width: dotRadius * 2, height: dotRadius * 2
            ))
            context.fill(dot, with: .foreground)
            if placement.finger > 0 {
                let number = Text("\(placement.finger)")
                    .font(.system(size: dotRadius * 1.2, weight: .bold, design: .rounded))
                    .foregroundStyle(Color(uiColor: .systemBackground))
                context.draw(number, at: center)
            }
        }
    }
}

#Preview("G, C, F") {
    let chords = (try? ChordLibrary.loadChords()) ?? []
    HStack(spacing: 32) {
        ForEach(chords.filter { ["G", "C", "F"].contains($0.id) }) { chord in
            ChordDiagramView(chord: chord)
                .frame(width: 160)
        }
    }
    .padding()
}
