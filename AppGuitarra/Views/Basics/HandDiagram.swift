//
//  HandDiagram.swift
//  AppGuitarra
//
//  Fretting hand (left hand, palm facing you) with the finger numbers
//  used in every chord diagram: 1 index, 2 middle, 3 ring, 4 pinky, T thumb.
//
//  Uses the "HandIllustration" image (AI-generated, no numbers) when it is in the
//  asset catalog; the numbers are always drawn by code so they are exact.
//  Falls back to a simple drawn hand if the image is missing.
//

import SwiftUI
import UIKit

struct HandDiagram: View {
    /// Finger to emphasize (1...4), or nil.
    var highlighted: Int?

    private static let designSize = CGSize(width: 320, height: 330)

    private struct Finger {
        let label: String
        let number: Int?
        let rect: CGRect
    }

    // Left hand seen palm-up: pinky on the left, thumb on the right.
    private let fingers: [Finger] = [
        Finger(label: "4", number: 4, rect: CGRect(x: 52, y: 92, width: 38, height: 120)),
        Finger(label: "3", number: 3, rect: CGRect(x: 96, y: 48, width: 40, height: 160)),
        Finger(label: "2", number: 2, rect: CGRect(x: 142, y: 30, width: 40, height: 178)),
        Finger(label: "1", number: 1, rect: CGRect(x: 188, y: 54, width: 40, height: 156)),
    ]

    /// Fingertip positions in the illustration, as fractions of its width and height.
    private struct Tip {
        let label: String
        let number: Int?
        let point: CGPoint
    }

    private static let fingertips: [Tip] = [
        Tip(label: "4", number: 4, point: CGPoint(x: 0.205, y: 0.28)),
        Tip(label: "3", number: 3, point: CGPoint(x: 0.32, y: 0.17)),
        Tip(label: "2", number: 2, point: CGPoint(x: 0.465, y: 0.11)),
        Tip(label: "1", number: 1, point: CGPoint(x: 0.62, y: 0.165)),
        Tip(label: "T", number: nil, point: CGPoint(x: 0.78, y: 0.45)),
    ]

    var body: some View {
        if let image = UIImage(named: "HandIllustration") {
            illustrated(image)
        } else {
            drawn
        }
    }

    private func illustrated(_ image: UIImage) -> some View {
        Image(uiImage: image)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .overlay {
                GeometryReader { geometry in
                    let size = geometry.size
                    ForEach(Self.fingertips, id: \.label) { tip in
                        FingerBadge(label: tip.label, isOn: isOn(tip), width: size.width)
                            .position(x: tip.point.x * size.width, y: tip.point.y * size.height)
                    }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Left hand finger numbers: 1 index, 2 middle, 3 ring, 4 pinky, T thumb")
    }

    private func isOn(_ tip: Tip) -> Bool {
        guard let number = tip.number else { return false }
        return highlighted == nil || number == highlighted
    }

    private var drawn: some View {
        Canvas { context, size in
            let scale = min(size.width / Self.designSize.width, size.height / Self.designSize.height)
            context.translateBy(x: (size.width - Self.designSize.width * scale) / 2,
                                y: (size.height - Self.designSize.height * scale) / 2)
            context.scaleBy(x: scale, y: scale)

            let skin = Color(red: 0.97, green: 0.82, blue: 0.69)
            let outline = Color(red: 0.62, green: 0.42, blue: 0.30)

            // Thumb
            var thumb = Path()
            thumb.move(to: CGPoint(x: 222, y: 250))
            thumb.addLine(to: CGPoint(x: 284, y: 178))
            context.stroke(thumb, with: .color(outline), style: StrokeStyle(lineWidth: 46, lineCap: .round))
            context.stroke(thumb, with: .color(skin), style: StrokeStyle(lineWidth: 42, lineCap: .round))

            // Fingers
            for finger in fingers {
                let shape = Path(roundedRect: finger.rect, cornerRadius: finger.rect.width / 2)
                let isHighlighted = finger.number == highlighted
                context.fill(shape, with: .color(isHighlighted ? Color.accentColor.opacity(0.35) : skin))
                context.stroke(shape, with: .color(outline), lineWidth: 2)
            }

            // Palm
            let palm = Path(roundedRect: CGRect(x: 48, y: 170, width: 190, height: 150), cornerRadius: 50)
            context.fill(palm, with: .color(skin))
            context.stroke(palm, with: .color(outline), lineWidth: 2)

            // Number badges on the fingertips
            for finger in fingers {
                let center = CGPoint(x: finger.rect.midX, y: finger.rect.minY + 24)
                drawBadge(finger.label, at: center, filled: finger.number == highlighted || highlighted == nil, in: context)
            }
            drawBadge("T", at: CGPoint(x: 280, y: 182), filled: false, in: context)
        }
        .aspectRatio(Self.designSize.width / Self.designSize.height, contentMode: .fit)
        .accessibilityLabel("Left hand finger numbers: 1 index, 2 middle, 3 ring, 4 pinky, T thumb")
    }

    private func drawBadge(_ text: String, at center: CGPoint, filled: Bool, in context: GraphicsContext) {
        let rect = CGRect(x: center.x - 15, y: center.y - 15, width: 30, height: 30)
        context.fill(Path(ellipseIn: rect), with: .color(filled ? Color.accentColor : .white))
        context.stroke(Path(ellipseIn: rect), with: .color(Color.accentColor), lineWidth: 2)
        context.draw(
            Text(text).font(.system(size: 17, weight: .bold, design: .rounded))
                .foregroundStyle(filled ? Color.white : Color.accentColor),
            at: center
        )
    }
}

/// Numbered circle drawn over a fingertip.
private struct FingerBadge: View {
    let label: String
    let isOn: Bool
    /// Width of the hand illustration; the badge scales with it.
    let width: CGFloat

    var body: some View {
        let diameter: CGFloat = max(24, width * 0.11)
        let fontSize: CGFloat = max(14, width * 0.06)
        let fill: Color = isOn ? .accentColor : .white
        let textColor: Color = isOn ? .white : .accentColor
        return Text(label)
            .font(.system(size: fontSize, weight: .bold, design: .rounded))
            .foregroundStyle(textColor)
            .frame(width: diameter, height: diameter)
            .background(Circle().fill(fill))
            .overlay(Circle().stroke(Color.accentColor, lineWidth: 2))
            .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
    }
}

#Preview {
    HandDiagram(highlighted: 2)
        .frame(width: 280)
        .padding()
}
