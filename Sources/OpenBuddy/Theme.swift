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

/// OpenBuddy's mascot: a soft round blob with a happy face. Original artwork,
/// drawn in code so it can be tinted per buddy.
struct MascotView: View {
    var tint: Color = Color(red: 0.62, green: 0.80, blue: 0.98)
    var size: CGFloat = 70
    var happy = true
    /// Gentle floating motion; only for big hero mascots (it costs a redraw every frame).
    var animated = false
    @State private var bob = false

    var body: some View {
        ZStack {
            Ellipse()
                .fill(RadialGradient(colors: [tint.opacity(0.95), tint], center: .init(x: 0.35, y: 0.3), startRadius: 2, endRadius: size))
                .frame(width: size, height: size * 0.82)
                .shadow(color: tint.opacity(0.7), radius: size * 0.18)
            // Little cheeks
            HStack(spacing: size * 0.36) {
                Circle().fill(Color.pink.opacity(0.35)).frame(width: size * 0.12)
                Circle().fill(Color.pink.opacity(0.35)).frame(width: size * 0.12)
            }
            .offset(y: size * 0.1)
            // Eyes
            HStack(spacing: size * 0.2) {
                Eye(happy: happy).frame(width: size * 0.13, height: size * 0.13)
                Eye(happy: happy).frame(width: size * 0.13, height: size * 0.13)
            }
            .offset(y: -size * 0.02)
            // Smile
            Smile().stroke(Color(red: 0.15, green: 0.2, blue: 0.35), style: StrokeStyle(lineWidth: size * 0.035, lineCap: .round))
                .frame(width: size * 0.14, height: size * 0.06)
                .offset(y: size * 0.12)
        }
        .offset(y: animated ? (bob ? -2 : 2) : 0)
        .onAppear { if animated { withAnimation(.easeInOut(duration: 1.8).repeatForever()) { bob = true } } }
    }

    private struct Eye: View {
        let happy: Bool
        var body: some View {
            Circle().fill(Color(red: 0.15, green: 0.2, blue: 0.35))
                .overlay(Circle().fill(.white).frame(width: 3, height: 3).offset(x: 1.5, y: -1.5))
        }
    }

    private struct Smile: Shape {
        func path(in r: CGRect) -> Path {
            var p = Path()
            p.move(to: CGPoint(x: r.minX, y: r.minY))
            p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY), control: CGPoint(x: r.midX, y: r.maxY * 2))
            return p
        }
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
            Circle().fill(colors.0)
            MascotView(tint: colors.1, size: size * 0.62).allowsHitTesting(false)
        }
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
