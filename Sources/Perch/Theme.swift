import SwiftUI

/// Visual language: near-black glass surfaces, soft grey cards, and a
/// lavender-to-periwinkle "glass" accent for primary actions.
enum Theme {
    static let window = Color(red: 0.11, green: 0.11, blue: 0.12)
    static let sidebar = Color(red: 0.13, green: 0.13, blue: 0.14)
    static let card = Color.white.opacity(0.06)
    static let cardStroke = Color.white.opacity(0.07)
    static let hover = Color.white.opacity(0.08)
    static let textPrimary = Color.white
    static let textSecondary = Color.white.opacity(0.55)
    static let textTertiary = Color.white.opacity(0.35)
    static let accent = Color(red: 0.36, green: 0.52, blue: 1.0)

    static let glass = LinearGradient(
        colors: [Color(red: 0.86, green: 0.89, blue: 1.0), Color(red: 0.62, green: 0.70, blue: 1.0)],
        startPoint: .top, endPoint: .bottom
    )
    static let mint = LinearGradient(
        colors: [Color(red: 0.86, green: 0.97, blue: 0.88), Color(red: 0.66, green: 0.88, blue: 0.70)],
        startPoint: .top, endPoint: .bottom
    )
    static let userBubble = LinearGradient(
        colors: [Color(red: 0.80, green: 0.85, blue: 1.0), Color(red: 0.62, green: 0.71, blue: 1.0)],
        startPoint: .top, endPoint: .bottom
    )
}

/// Glossy pill used for the main "talk" button and other primary actions.
struct GlassPillStyle: ButtonStyle {
    var gradient = Theme.glass
    var height: CGFloat = 34

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Color(red: 0.10, green: 0.12, blue: 0.25))
            .padding(.horizontal, 16)
            .frame(height: height)
            .background(
                Capsule().fill(gradient)
                    .overlay(
                        // Top highlight gives the glass look.
                        Capsule().fill(LinearGradient(colors: [.white.opacity(0.7), .clear], startPoint: .top, endPoint: .center))
                            .padding(.horizontal, 6).padding(.top, 2).frame(maxHeight: .infinity, alignment: .top)
                            .frame(height: height * 0.45).frame(maxHeight: .infinity, alignment: .top)
                    )
            )
            .overlay(Capsule().stroke(Color(red: 0.20, green: 0.24, blue: 0.55).opacity(0.9), lineWidth: 1.5))
            .padding(2)
            .background(Capsule().stroke(Color.white.opacity(0.18), lineWidth: 1))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Dark rounded chip (e.g. "Apps +", "Retry").
struct ChipStyle: ButtonStyle {
    var light = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(light ? Color.black : Theme.textPrimary.opacity(0.85))
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(Capsule().fill(light ? Color.white.opacity(0.92) : Theme.card))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

struct IconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Theme.textSecondary)
            .frame(width: 26, height: 26)
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.5 : 1)
    }
}

/// Blue-gradient switch with a dark knob.
struct GlassToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                Capsule()
                    .fill(configuration.isOn ? AnyShapeStyle(Theme.glass) : AnyShapeStyle(Color.white.opacity(0.15)))
                    .frame(width: 34, height: 20)
                Circle().fill(configuration.isOn ? Color.black : Color.white.opacity(0.8))
                    .frame(width: 15, height: 15).padding(.horizontal, 2.5)
            }
            .animation(.spring(response: 0.25), value: configuration.isOn)
        }
        .buttonStyle(.plain)
    }
}

/// Perch's mascot: a soft round blob with a happy face. Original artwork,
/// Perch's mascot: a soft, glossy cloud puff with happy eyes. Drawn in code so it
/// can be tinted per helper and stays crisp at any size.
struct MascotView: View {
    var tint: Color = Color(red: 0.55, green: 0.80, blue: 0.98)
    var size: CGFloat = 70
    var happy = true
    /// Gentle floating motion; only for big hero mascots (it costs a redraw every frame).
    var animated = false
    var showHands = false
    @State private var bob = false

    var body: some View {
        ZStack {
            CloudShape()
                .fill(
                    LinearGradient(colors: [tint.mix(with: .white, by: 0.45), tint, tint.mix(with: .black, by: 0.08)],
                                   startPoint: .top, endPoint: .bottom))
                .overlay(
                    // glossy highlight
                    CloudShape().fill(LinearGradient(colors: [.white.opacity(0.55), .clear], startPoint: .top, endPoint: .center))
                        .scaleEffect(x: 0.82, y: 0.7, anchor: .top)
                        .offset(y: size * 0.04)
                        .blendMode(.screen)
                )
                .frame(width: size, height: size * 0.78)
                .shadow(color: tint.opacity(0.75), radius: size * 0.16)

            if happy {
                HStack(spacing: size * 0.16) {
                    HappyEye().stroke(.white, style: StrokeStyle(lineWidth: max(1.5, size * 0.05), lineCap: .round))
                        .frame(width: size * 0.15, height: size * 0.08)
                    HappyEye().stroke(.white, style: StrokeStyle(lineWidth: max(1.5, size * 0.05), lineCap: .round))
                        .frame(width: size * 0.15, height: size * 0.08)
                }
                .offset(y: size * 0.04)
            }

            if showHands {
                HStack(spacing: size * 0.32) {
                    Capsule().fill(tint.mix(with: .white, by: 0.25)).frame(width: size * 0.2, height: size * 0.13)
                    Capsule().fill(tint.mix(with: .white, by: 0.25)).frame(width: size * 0.2, height: size * 0.13)
                }
                .offset(y: size * 0.38)
                .shadow(color: tint.opacity(0.5), radius: 3)
            }
        }
        .scaleEffect(x: animated && bob ? 1.02 : 1, y: animated && bob ? 0.98 : 1, anchor: .bottom)
        .offset(y: animated ? (bob ? -2 : 1) : 0)
        .onAppear { if animated { withAnimation(.easeInOut(duration: 1.8).repeatForever()) { bob = true } } }
    }

    private struct HappyEye: Shape {
        func path(in r: CGRect) -> Path {
            var p = Path()
            p.move(to: CGPoint(x: r.minX, y: r.maxY))
            p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.maxY), control: CGPoint(x: r.midX, y: r.minY - r.height))
            return p
        }
    }
}

/// A puffy cloud silhouette built from overlapping circles.
struct CloudShape: Shape {
    func path(in r: CGRect) -> Path {
        let w = r.width, h = r.height
        var p = Path()
        let bumps: [(CGFloat, CGFloat, CGFloat)] = [   // centre x, centre y, radius (fractions of width)
            (0.30, 0.48, 0.26), (0.52, 0.34, 0.30), (0.74, 0.46, 0.25), (0.18, 0.66, 0.18), (0.84, 0.66, 0.17),
        ]
        for (x, y, rad) in bumps {
            p.addEllipse(in: CGRect(x: r.minX + w * (x - rad), y: r.minY + h * y - w * rad, width: w * rad * 2, height: w * rad * 2))
        }
        p.addRoundedRect(in: CGRect(x: r.minX + w * 0.06, y: r.minY + h * 0.52, width: w * 0.88, height: h * 0.46),
                         cornerSize: CGSize(width: h * 0.23, height: h * 0.23))
        return p
    }
}

extension Color {
    func mix(with other: Color, by amount: Double) -> Color {
        let a = NSColor(self).usingColorSpace(.deviceRGB) ?? .white
        let b = NSColor(other).usingColorSpace(.deviceRGB) ?? .white
        return Color(red: a.redComponent + (b.redComponent - a.redComponent) * amount,
                     green: a.greenComponent + (b.greenComponent - a.greenComponent) * amount,
                     blue: a.blueComponent + (b.blueComponent - a.blueComponent) * amount)
    }
}

/// Small circular avatar for a conversation row.
struct AvatarView: View {
    let seed: String
    var size: CGFloat = 30

    static let palette: [(Color, Color)] = [
        (Color(red: 0.98, green: 0.93, blue: 0.70), Color(red: 0.72, green: 0.64, blue: 0.95)),
        (Color(red: 0.75, green: 0.88, blue: 0.98), Color(red: 0.96, green: 0.78, blue: 0.66)),
        (Color(red: 0.85, green: 0.96, blue: 0.86), Color(red: 0.55, green: 0.78, blue: 0.95)),
        (Color(red: 0.99, green: 0.84, blue: 0.88), Color(red: 0.70, green: 0.85, blue: 0.60)),
    ]

    var body: some View {
        let colors = Self.palette[abs(seed.hashValue) % Self.palette.count]
        ZStack {
            Circle().fill(RadialGradient(colors: [colors.0.mix(with: .white, by: 0.3), colors.0], center: .topLeading, startRadius: 1, endRadius: size))
            MascotView(tint: colors.1, size: size * 0.66).allowsHitTesting(false).offset(y: size * 0.03)
        }
        .overlay(Circle().stroke(Color.white.opacity(0.18), lineWidth: 1))
        .frame(width: size, height: size)
    }
}

extension Date {
    var shortTime: String {
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDateInToday(self) ? "h:mm a" : "MMM d"
        return f.string(from: self)
    }
}
