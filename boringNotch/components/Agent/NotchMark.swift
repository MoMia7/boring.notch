//
//  NotchMark.swift
//  boringNotch
//
//  The agent's mark: a tiny notch-shaped creature whose eyes show what it's doing.
//  Drawn as vector shapes so it stays crisp at tab-icon size and can animate.
//

import SwiftUI

enum NotchMood: Equatable {
    case idle        // occasional blink
    case thinking    // glances side to side
    case working     // focused squint, small bob
    case attention   // wide eyes, needs the user
    case listening   // big round eyes that pulse, hearing you
    case offline     // flat eyes
}

/// Notch silhouette: flared shoulders at the top, rounded bottom corners.
struct NotchSilhouette: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        let flare = w * 0.12          // concave shoulder radius
        let corner = min(h * 0.42, w * 0.22)
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - flare, y: rect.minY + flare),
                       control: CGPoint(x: rect.maxX - flare, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX - flare, y: rect.maxY - corner))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - flare - corner, y: rect.maxY),
                       control: CGPoint(x: rect.maxX - flare, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX + flare + corner, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.minX + flare, y: rect.maxY - corner),
                       control: CGPoint(x: rect.minX + flare, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX + flare, y: rect.minY + flare))
        p.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.minY),
                       control: CGPoint(x: rect.minX + flare, y: rect.minY))
        p.closeSubpath()
        return p
    }
}

struct NotchMark<Fill: ShapeStyle>: View {
    var mood: NotchMood = .idle
    var fill: Fill
    /// Color of the eyes; the notch sits on black, so black eyes read as cut-outs.
    var eyeColor: Color = .black
    var animated = true

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            if animated && mood != .offline {
                TimelineView(.animation(minimumInterval: 1 / 30)) { context in
                    figure(size: size, t: context.date.timeIntervalSinceReferenceDate)
                }
            } else {
                figure(size: size, t: 1)
            }
        }
        .aspectRatio(1.55, contentMode: .fit)
    }

    private func figure(size: CGSize, t: Double) -> some View {
        let bob = mood == .working ? sin(t * 5) * size.height * 0.04 : 0
        return ZStack {
            NotchSilhouette().fill(fill)
            eyes(size: size, t: t)
        }
        .offset(y: bob)
    }

    private func eyes(size: CGSize, t: Double) -> some View {
        let w = size.width, h = size.height
        var eyeW = w * 0.13
        var eyeH = h * 0.36
        var dx: CGFloat = 0
        var scaleY: CGFloat = 1

        switch mood {
        case .idle:
            // Blink for ~0.14 s every 4 s.
            let phase = t.truncatingRemainder(dividingBy: 4)
            if phase < 0.14 { scaleY = 0.12 }
        case .thinking:
            dx = CGFloat(sin(t * 2.2)) * w * 0.07
            let phase = t.truncatingRemainder(dividingBy: 3.2)
            if phase < 0.12 { scaleY = 0.15 }
        case .working:
            eyeH = h * 0.18
        case .attention:
            eyeW = w * 0.16
            eyeH = h * 0.44
        case .listening:
            let pulse = CGFloat(1 + 0.12 * sin(t * 6))
            eyeW = w * 0.17 * pulse
            eyeH = h * 0.30 * pulse
        case .offline:
            eyeH = h * 0.07
            eyeW = w * 0.15
        }

        let y = h * 0.44
        return ZStack {
            Capsule().fill(eyeColor)
                .frame(width: eyeW, height: eyeH * scaleY)
                .position(x: w * 0.38 + dx, y: y)
            Capsule().fill(eyeColor)
                .frame(width: eyeW, height: eyeH * scaleY)
                .position(x: w * 0.62 + dx, y: y)
        }
    }
}

extension NotchMark where Fill == ForegroundStyle {
    /// Uses the current foreground style (e.g. white/gray in the tab bar).
    init(mood: NotchMood = .idle, eyeColor: Color = .black, animated: Bool = true) {
        self.init(mood: mood, fill: ForegroundStyle(), eyeColor: eyeColor, animated: animated)
    }
}

/// The mark with the agent's gradient and a soft glow, for headers and the closed notch.
struct NotchMarkBadge: View {
    var mood: NotchMood
    var tint: Color = .accentColor

    var body: some View {
        let gradient = LinearGradient(
            colors: mood == .attention ? [.yellow, .orange]
                : mood == .listening ? [Color(red: 1.0, green: 0.45, blue: 0.55), Color(red: 1.0, green: 0.62, blue: 0.3)]
                : mood == .offline ? [.gray, .gray.opacity(0.6)]
                : [Color(red: 0.55, green: 0.85, blue: 1.0), tint, Color(red: 0.72, green: 0.45, blue: 1.0)],
            startPoint: .topLeading, endPoint: .bottomTrailing)
        NotchMark(mood: mood, fill: gradient)
            .shadow(color: (mood == .attention ? Color.yellow : tint).opacity(mood == .offline ? 0 : 0.55), radius: 5)
    }
}

/// Live microphone bars driven by the input level.
struct VoiceWaveform: View {
    var level: Float
    var bars = 5
    var color: Color = Color(red: 1.0, green: 0.5, blue: 0.5)

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<bars, id: \.self) { i in
                    let wobble = 0.55 + 0.45 * sin(t * 9 + Double(i) * 1.3)
                    let height = 0.18 + 0.82 * CGFloat(level) * CGFloat(wobble)
                    Capsule()
                        .fill(color)
                        .frame(width: 2.5)
                        .frame(maxHeight: .infinity)
                        .scaleEffect(y: max(0.18, height), anchor: .center)
                }
            }
        }
        .animation(.easeOut(duration: 0.08), value: level)
    }
}
