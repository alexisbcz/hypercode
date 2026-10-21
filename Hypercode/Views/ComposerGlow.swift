import SwiftUI

/// A soft rainbow halo that slowly shifts color around the message box, in the style of Apple Intelligence.
///
/// The blurred strokes are flattened into one texture and only their tint animates, at 15 frames a second
/// rather than on every screen refresh.
struct ComposerGlow: View {
    let cornerRadius: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Seconds for the colors to go all the way around.
    private static let period: TimeInterval = 10

    /// A slow drift still looks smooth at this rate.
    private static let framesPerSecond = 15.0

    /// Thin strokes, each blurred a bit more than the one before, so the edge stays crisp and fades outward.
    private static let rim: [(width: CGFloat, blur: CGFloat)] = [(1, 0), (2, 1), (3, 3), (5, 6)]

    /// Room around the box for the blur to spread into.
    private static let bleed: CGFloat = 24

    private static let gradient = AngularGradient(
        stops: [
            (200, 160, 240), (235, 200, 230), (170, 180, 245), (245, 150, 160), (245, 205, 160), (210, 165, 240),
        ].enumerated().map { index, rgb in
            .init(color: Color(red: rgb.0 / 255, green: rgb.1 / 255, blue: rgb.2 / 255).opacity(0.7), location: Double(index) / 5)
        },
        center: .center
    )

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: cornerRadius, style: .continuous) }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / Self.framesPerSecond, paused: reduceMotion)) { timeline in
            glow.hueRotation(.degrees(Self.hue(at: timeline.date)))
        }
        .allowsHitTesting(false)
    }

    private static func hue(at date: Date) -> Double {
        date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period * 360
    }

    private var glow: some View {
        ZStack {
            // A faint wash, so the glass in front of the glow picks up its color as well.
            shape.fill(Self.gradient.opacity(0.1)).blur(radius: 8)
            shape.strokeBorder(Self.gradient.opacity(0.3), lineWidth: 20).blur(radius: 12)

            ForEach(Self.rim.indices, id: \.self) { index in
                shape
                    .strokeBorder(Self.gradient, lineWidth: Self.rim[index].width)
                    .blur(radius: Self.rim[index].blur)
            }
        }
        .padding(Self.bleed)
        .drawingGroup()
        .padding(-Self.bleed)
    }
}
