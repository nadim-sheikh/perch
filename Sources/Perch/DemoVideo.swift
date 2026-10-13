import AppKit
import AVFoundation
import SwiftUI

/// `Perch --demo-video <folder>` renders the README demo as `perch-demo.mp4`: a scripted, fully animated
/// tour drawn with Perch's own UI pieces (notch shape, mascot, cursor) and made-up sample content.
/// Nothing from the user's screen, chats or files is used.
@MainActor
enum DemoVideo {
    static let size = CGSize(width: 1280, height: 720)
    static let fps = 30.0
    static let duration = 30.0

    static func render(to folder: URL) {
        NSApplication.shared.setActivationPolicy(.prohibited)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("perch-demo.mp4")
        try? FileManager.default.removeItem(at: url)
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mp4) else { return }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 3_500_000],
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width), kCVPixelBufferHeightKey as String: Int(size.height),
        ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        let frames = Int(duration * fps)
        for i in 0..<frames {
            let t = Double(i) / fps
            let renderer = ImageRenderer(content: DemoFrame(t: t).frame(width: size.width, height: size.height))
            renderer.scale = 1
            guard let image = renderer.cgImage, let pool = adaptor.pixelBufferPool else { continue }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { continue }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: Int(size.width), height: Int(size.height),
                                   bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                   space: CGColorSpaceCreateDeviceRGB(),
                                   bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) {
                ctx.draw(image, in: CGRect(origin: .zero, size: size))
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            while !input.isReadyForMoreMediaData { RunLoop.current.run(until: Date().addingTimeInterval(0.005)) }
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: CMTimeScale(fps)))
        }
        input.markAsFinished()
        var finished = false
        writer.finishWriting { finished = true }
        while !finished { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    }
}

// MARK: Timing helpers

/// 0…1 progress of t through [a, b].
private func prog(_ t: Double, _ a: Double, _ b: Double) -> Double { min(1, max(0, (t - a) / (b - a))) }
private func ease(_ x: Double) -> Double { x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2 }
/// Ease out with a small overshoot, for things that pop in.
private func pop(_ x: Double) -> Double { let c = 1.7; let y = x - 1; return x <= 0 ? 0 : 1 + (c + 1) * y * y * y + c * y * y }
private func lerp(_ a: Double, _ b: Double, _ x: Double) -> Double { a + (b - a) * x }
/// Fades in over [a, a+f] and out over [b-f, b].
private func window(_ t: Double, _ a: Double, _ b: Double, fade f: Double = 0.35) -> Double {
    min(ease(prog(t, a, a + f)), 1 - ease(prog(t, b - f, b)))
}
/// The first `x` share of `text`, as if typed.
private func typed(_ text: String, _ x: Double) -> String { String(text.prefix(Int((Double(text.count) * x).rounded()))) }

private let accent = Color(red: 0.23, green: 0.51, blue: 0.96)
private let pink = Color(red: 1.0, green: 0.36, blue: 0.62)

// MARK: The frame

private struct DemoFrame: View {
    let t: Double

    var body: some View {
        ZStack(alignment: .topLeading) {
            Wallpaper(t: t)
            MenuBar()
            EditorScene(t: t)
            BrowserScene(t: t)
            NotesScene(t: t)
            NotchLayer(t: t)
            Overlays(t: t)
            CursorLayer(t: t)
            TitleCards(t: t)
        }
        .frame(width: 1280, height: 720)
        .clipped()
        .environment(\.colorScheme, .dark)
    }
}

private struct Wallpaper: View {
    let t: Double
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.16, green: 0.20, blue: 0.40), Color(red: 0.42, green: 0.30, blue: 0.56),
                                    Color(red: 0.90, green: 0.58, blue: 0.50)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            // Two soft glows. They stay still so the GIF stays small (moving backgrounds change every pixel).
            Circle().fill(Color(red: 0.55, green: 0.75, blue: 1.0).opacity(0.25)).frame(width: 520).blur(radius: 90)
                .offset(x: -300, y: 120)
            Circle().fill(Color(red: 1.0, green: 0.7, blue: 0.6).opacity(0.22)).frame(width: 460).blur(radius: 90)
                .offset(x: 360, y: -60)
        }
        .frame(width: 1280, height: 720)
    }
}

private struct MenuBar: View {
    var body: some View {
        HStack(spacing: 18) {
            Image(systemName: "circle.hexagongrid.fill").font(.system(size: 12))
            Text("Finder").font(.system(size: 12.5, weight: .bold))
            ForEach(["File", "Edit", "View", "Go", "Window"], id: \.self) { Text($0).font(.system(size: 12.5)) }
            Spacer()
            Image(systemName: "wifi").font(.system(size: 12))
            Image(systemName: "battery.75percent").font(.system(size: 13))
            Text("Tue 9:41").font(.system(size: 12.5))
        }
        .foregroundStyle(.white.opacity(0.92))
        .padding(.horizontal, 16)
        .frame(width: 1280, height: 32)
        .background(Color.black.opacity(0.22))
    }
}

// MARK: Notch

private enum NotchState: Equatable {
    case docked, listening, thinking, talking, handoff, working, done, fixed

    var size: CGSize {
        switch self {
        case .docked: return CGSize(width: 264, height: 32)
        case .listening, .thinking, .talking, .handoff, .fixed: return CGSize(width: 430, height: 32)
        case .working: return CGSize(width: 470, height: 196)
        case .done: return CGSize(width: 470, height: 128)
        }
    }
}

/// When each notch state starts.
private let notchTimeline: [(Double, NotchState)] = [
    (0, .docked), (4.6, .listening), (7.3, .thinking), (8.5, .talking), (12.4, .docked),
    (13.2, .listening), (15.4, .thinking), (16.1, .handoff), (16.9, .working), (21.0, .done), (22.6, .docked),
    (23.2, .listening), (24.6, .docked), (25.4, .fixed), (26.6, .docked),
]

private struct NotchLayer: View {
    let t: Double

    private var current: (state: NotchState, start: Double, previous: NotchState) {
        var prev = NotchState.docked, cur = NotchState.docked, start = 0.0
        for (time, state) in notchTimeline where time <= t { prev = cur; cur = state; start = time }
        return (cur, start, prev)
    }

    var body: some View {
        let (state, start, previous) = current
        let k = ease(prog(t, start, start + 0.38))
        let w = lerp(previous.size.width, state.size.width, k)
        let h = lerp(previous.size.height, state.size.height, k)
        let isCard = state.size.height > 40
        ZStack(alignment: .top) {
            Color.black
            NotchContent(state: state, t: t, since: t - start)
                .opacity(ease(prog(t, start + 0.12, start + 0.4)))
        }
        .frame(width: w, height: h, alignment: .top)
        .clipShape(NotchShape(radius: isCard ? 24 : 11))
        .compositingGroup()
        .shadow(color: .black.opacity(isCard ? 0.45 : 0), radius: 18, y: 6)
        .position(x: 640, y: h / 2)
    }
}

private struct NotchContent: View {
    let state: NotchState
    let t: Double
    let since: Double

    var body: some View {
        switch state {
        case .docked:
            strip {
                MascotView(size: 18, happy: true).scaleEffect(1 + 0.04 * sin(t * 2.4))
            } right: {
                Circle().fill(accent).frame(width: 6, height: 6).shadow(color: accent.opacity(0.9), radius: 4)
            }
        case .listening:
            strip { MascotView(size: 18, happy: true); label("Listening…") } right: { wave }
        case .thinking:
            strip { MascotView(size: 18, happy: true); label("Hmm, thinking…") } right: { dots }
        case .talking:
            strip { MascotView(size: 18, happy: true); label("Talking") } right: { equalizer }
        case .handoff:
            strip { AvatarView(seed: "shippy", size: 18); label("Shippy is on it") } right: { spinner(12) }
        case .fixed:
            strip { MascotView(size: 18, happy: true); label("Fixed it ✨") } right: {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 13)).foregroundStyle(.green)
            }
        case .working:
            WorkingCard(t: t, since: since)
        case .done:
            DoneCard()
        }
    }

    private func label(_ s: String) -> some View {
        Text(s).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.88)).fixedSize()
    }

    /// Left ear | the camera notch | right ear.
    private func strip<L: View, R: View>(@ViewBuilder left: () -> L, @ViewBuilder right: () -> R) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: 7) { left() }.frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 14)
            Color.clear.frame(width: 195)
            HStack(spacing: 7) { right() }.frame(maxWidth: .infinity, alignment: .trailing).padding(.trailing, 14)
        }
        .frame(height: 32)
    }

    private var wave: some View {
        HStack(spacing: 2.5) {
            ForEach(0..<5) { i in
                Capsule().fill(accent).frame(width: 3, height: waveHeight(i))
            }
        }
    }

    private func waveHeight(_ i: Int) -> CGFloat {
        let d = Double(i)
        let level: Double = 0.35 + 0.65 * abs(sin(t * 7 + d * 1.3) * cos(t * 3.1 + d))
        return CGFloat(4 + 14 * level)
    }

    private func dotPhase(_ i: Int) -> Double {
        let angle: Double = (t - Double(i) * 0.2) * Double.pi * 2 / 1.2
        return (sin(angle) + 1) / 2
    }

    private var dots: some View {
        HStack(spacing: 3.5) {
            ForEach(0..<3) { i in
                Circle().fill(accent).frame(width: 5, height: 5)
                    .opacity(0.3 + 0.7 * dotPhase(i)).scaleEffect(0.8 + 0.2 * dotPhase(i))
            }
        }
    }

    private func barHeight(_ i: Int) -> CGFloat {
        let periods: [Double] = [0.9, 1.1, 1.3, 1.0]
        let angle: Double = t * Double.pi * 2 / periods[i] + Double(i)
        return CGFloat(5 + 11 * (sin(angle) + 1) / 2)
    }

    private var equalizer: some View {
        HStack(spacing: 2.5) {
            ForEach(0..<4) { i in
                Capsule().fill(accent).frame(width: 3, height: barHeight(i))
            }
        }
    }

    private func spinner(_ s: CGFloat) -> some View {
        Circle().trim(from: 0, to: 0.7).stroke(accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .frame(width: s, height: s).rotationEffect(.degrees(t * 360))
    }
}

/// The helper's live progress, dropping down from the notch.
private struct WorkingCard: View {
    let t: Double
    let since: Double

    static let steps: [(String, Double)] = [
        ("Planning the page", 17.6), ("Writing index.html", 18.6), ("Adding the menu and photos", 19.6),
        ("Checking it in the browser", 20.5),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Color.clear.frame(height: 26)
            HStack(spacing: 8) {
                AvatarView(seed: "shippy", size: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Shippy").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.white)
                    Text("Web builder · working").font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.5))
                }
                Spacer()
                Text(String(format: "0:%02d", Int(max(0, t - 16.1)))).font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.5))
            }
            ForEach(Array(Self.steps.enumerated()), id: \.offset) { i, step in
                let started = i == 0 ? 16.9 : Self.steps[i - 1].1
                let shown = ease(prog(t, started, started + 0.3))
                HStack(spacing: 9) {
                    if t >= step.1 {
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 13)).foregroundStyle(.green)
                            .scaleEffect(pop(prog(t, step.1, step.1 + 0.3)))
                    } else {
                        Circle().trim(from: 0, to: 0.7).stroke(accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                            .frame(width: 12, height: 12).rotationEffect(.degrees(t * 360)).padding(.horizontal, 0.5)
                    }
                    Text(step.0).font(.system(size: 12)).foregroundStyle(.white.opacity(t >= step.1 ? 0.6 : 0.95))
                }
                .opacity(shown).offset(y: 6 * (1 - shown))
            }
        }
        .padding(.horizontal, 26)
    }
}

private struct DoneCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Color.clear.frame(height: 24)
            HStack(spacing: 8) {
                AvatarView(seed: "shippy", size: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Bakery landing page is ready").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.white)
                    Text("index.html · 4 sections · opened in your browser").font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.5))
                }
                Spacer()
            }
            HStack(spacing: 6) {
                chip("Open", "safari")
                chip("Make it pink", "paintbrush")
                chip("Add a contact form", "plus")
            }
        }
        .padding(.horizontal, 26)
    }

    private func chip(_ s: String, _ icon: String) -> some View {
        Label(s, systemImage: icon).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.9))
            .padding(.horizontal, 10).frame(height: 24).background(Capsule().fill(Color.white.opacity(0.1)))
    }
}

// MARK: Scenes

/// A made-up video editor where Perch marks the File menu.
private struct EditorScene: View {
    let t: Double
    var body: some View {
        let shown = window(t, 3.6, 12.9, fade: 0.5)
        AppWindow(title: "Video Editor", width: 760, height: 430) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 20) {
                    ForEach(["File", "Edit", "Clip", "Sequence", "Effects", "View"], id: \.self) {
                        Text($0).font(.system(size: 13)).foregroundStyle(.white.opacity(0.85))
                    }
                }
                .padding(.horizontal, 18).padding(.vertical, 10)
                HStack(spacing: 10) {
                    VStack(spacing: 8) {
                        ForEach(0..<4) { i in
                            RoundedRectangle(cornerRadius: 6).fill(LinearGradient(colors: [[Color.orange, .pink, .purple, .teal][i].opacity(0.6), .black.opacity(0.3)],
                                                                                   startPoint: .top, endPoint: .bottom))
                                .frame(height: 52)
                        }
                    }
                    .frame(width: 150)
                    ZStack {
                        RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.55))
                        Image(systemName: "play.fill").font(.system(size: 30)).foregroundStyle(.white.opacity(0.6))
                    }
                }
                .padding(.horizontal, 14)
                // A timeline.
                HStack(spacing: 4) {
                    ForEach(0..<9) { i in
                        RoundedRectangle(cornerRadius: 4).fill([accent, pink, Color.teal][i % 3].opacity(0.55))
                            .frame(width: CGFloat([60, 90, 45, 70, 110, 50, 80, 40, 66][i]))
                    }
                }
                .frame(height: 34).padding(14)
            }
        }
        .opacity(shown).scaleEffect(0.96 + 0.04 * shown)
        .position(x: 640, y: 400)
    }
}

/// The page Shippy builds, appearing piece by piece.
private struct BrowserScene: View {
    let t: Double
    var body: some View {
        let shown = window(t, 17.2, 22.9, fade: 0.5)
        AppWindow(title: "Rise & Shine Bakery — index.html", width: 700, height: 400) {
            VStack(spacing: 14) {
                piece(18.6) {
                    HStack {
                        Text("🥐 Rise & Shine").font(.system(size: 17, weight: .bold, design: .serif)).foregroundStyle(Color(red: 0.36, green: 0.2, blue: 0.1))
                        Spacer()
                        ForEach(["Menu", "Visit", "Order"], id: \.self) { Text($0).font(.system(size: 12)).foregroundStyle(.brown) }
                    }
                }
                piece(19.6) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12).fill(LinearGradient(colors: [Color(red: 1, green: 0.85, blue: 0.62), Color(red: 0.96, green: 0.62, blue: 0.45)],
                                                                               startPoint: .leading, endPoint: .trailing))
                        VStack(spacing: 4) {
                            Text("Fresh bread every morning").font(.system(size: 22, weight: .bold, design: .serif)).foregroundStyle(Color(red: 0.3, green: 0.15, blue: 0.08))
                            Text("Baked at 5am, gone by noon.").font(.system(size: 12)).foregroundStyle(.brown)
                        }
                    }
                    .frame(height: 130)
                }
                piece(20.5) {
                    HStack(spacing: 12) {
                        ForEach([("Sourdough", "$6", "🍞"), ("Croissant", "$3", "🥐"), ("Cinnamon roll", "$4", "🧁")], id: \.0) { item in
                            VStack(spacing: 4) {
                                Text(item.2).font(.system(size: 26))
                                Text(item.0).font(.system(size: 12, weight: .semibold)).foregroundStyle(Color(red: 0.3, green: 0.15, blue: 0.08))
                                Text(item.1).font(.system(size: 11)).foregroundStyle(.brown)
                            }
                            .frame(maxWidth: .infinity).padding(.vertical, 10)
                            .background(RoundedRectangle(cornerRadius: 10).fill(Color.white)
                                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.brown.opacity(0.15))))
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(18)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(red: 1, green: 0.97, blue: 0.92))
        }
        .opacity(shown).scaleEffect(0.96 + 0.04 * shown)
        .position(x: 640, y: 450)
    }

    @ViewBuilder private func piece<V: View>(_ at: Double, @ViewBuilder _ content: () -> V) -> some View {
        let x = ease(prog(t, at - 0.5, at))
        content().opacity(x).offset(y: 10 * (1 - x))
    }
}

/// A notes window for dictation and fix-spelling.
private struct NotesScene: View {
    let t: Double
    static let raw = "teh new menu is redy for tomorow, the croisants are back"
    static let fixed = "The new menu is ready for tomorrow. The croissants are back!"

    var body: some View {
        let shown = window(t, 23.0, 26.9, fade: 0.4)
        let fix = ease(prog(t, 25.3, 25.7))
        let selected = t > 24.9 && t < 25.5
        AppWindow(title: "Notes", width: 620, height: 230) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Shop update").font(.system(size: 18, weight: .bold)).foregroundStyle(.white)
                ZStack(alignment: .topLeading) {
                    Text(typed(Self.raw, prog(t, 23.4, 24.5)) + (t < 24.6 && Int(t * 2) % 2 == 0 ? "|" : ""))
                        .opacity(1 - fix)
                        .background(selected ? accent.opacity(0.45) : .clear)
                    Text(Self.fixed).opacity(fix)
                        .shadow(color: Color.green.opacity(0.9 * (1 - prog(t, 25.5, 26.3))), radius: 8)
                }
                .font(.system(size: 15)).foregroundStyle(.white.opacity(0.92))
                Spacer()
            }
            .padding(22)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .opacity(shown).scaleEffect(0.96 + 0.04 * shown)
        .position(x: 640, y: 380)
    }
}

private struct AppWindow<Content: View>: View {
    let title: String
    let width: CGFloat
    let height: CGFloat
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                ForEach([Color.red, .yellow, .green], id: \.self) { Circle().fill($0.opacity(0.85)).frame(width: 11, height: 11) }
                Spacer()
                Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.6))
                Spacer()
                Color.clear.frame(width: 50)
            }
            .padding(.horizontal, 13).frame(height: 34)
            content
        }
        .frame(width: width, height: height)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(red: 0.13, green: 0.13, blue: 0.15)))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.08)))
        .compositingGroup()
        .shadow(color: .black.opacity(0.35), radius: 30, y: 14)
    }
}

// MARK: Overlays: captions, keycaps, chapter labels, mark and bubble

private struct Overlays: View {
    let t: Double

    var body: some View {
        ZStack(alignment: .topLeading) {
            // The mark Perch draws on "File" in the editor (window origin 260,185; File at about 288,233).
            let mark = window(t, 9.25, 12.5, fade: 0.3)
            RoundedRectangle(cornerRadius: 7).stroke(pink, lineWidth: 2.5)
                .background(RoundedRectangle(cornerRadius: 7).fill(pink.opacity(0.14)))
                .frame(width: 48, height: 28)
                .shadow(color: pink.opacity(0.75), radius: 8)
                .scaleEffect(1 + 0.35 * (1 - pop(prog(t, 9.25, 9.6))))
                .opacity(mark)
                .position(x: 293, y: 236)

            // The speech bubble, word by word.
            let bubble = window(t, 9.5, 12.5, fade: 0.3)
            Bubble(text: "Click File up here, then Export → Media. I'll guide you through the rest.", revealed: prog(t, 9.55, 11.6))
                .opacity(bubble).scaleEffect(0.92 + 0.08 * pop(prog(t, 9.5, 9.85)), anchor: .topLeading)
                .position(x: 470, y: 300)

            caption("“How do I export this at 1080p?”", from: 4.8, typing: 6.9, until: 8.6)
            caption("“Make a landing page for my bakery”", from: 13.4, typing: 15.0, until: 16.4)

            keycaps(["⌃ control", "⌥ option"], "Hold to talk", from: 4.2, until: 7.4)
            keycaps(["⌃ control", "⌥ option"], "Hold to talk", from: 12.9, until: 15.5)
            keycaps(["⌃ control", "⇧ shift"], "Hold to dictate in any text box", from: 23.0, until: 24.7)
            keycaps(["⌥ option", "⇧ shift", "U"], "Fix spelling", from: 24.8, until: 26.4)

            chapter("Guide mode", "Ask how, and Perch shows you on your screen.", from: 3.8, until: 12.8)
            chapter("Agent mode", "Ask for it, and a helper agent does the work.", from: 13.0, until: 22.8)
            chapter("Dictation & fix spelling", "Works in any app.", from: 23.0, until: 26.8)
        }
        .frame(width: 1280, height: 720, alignment: .topLeading)
    }

    private func caption(_ text: String, from a: Double, typing b: Double, until c: Double) -> some View {
        Text(typed(text, prog(t, a + 0.2, b)))
            .font(.system(size: 17, weight: .medium)).foregroundStyle(.white)
            .padding(.horizontal, 18).padding(.vertical, 10)
            .background(Capsule().fill(Color.black.opacity(0.55)))
            .opacity(window(t, a, c))
            .position(x: 640, y: 92)
    }

    private func keycaps(_ keys: [String], _ label: String, from a: Double, until b: Double) -> some View {
        HStack(spacing: 8) {
            ForEach(keys, id: \.self) { k in
                Text(k).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 12).frame(height: 34)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.14)))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.25)))
            }
            Text(label).font(.system(size: 14, weight: .medium)).foregroundStyle(.white.opacity(0.85)).padding(.leading, 4)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.black.opacity(0.45)))
        .scaleEffect(0.9 + 0.1 * pop(prog(t, a, a + 0.35)))
        .opacity(window(t, a, b, fade: 0.25))
        .position(x: 640, y: 664)
    }

    private func chapter(_ title: String, _ subtitle: String, from a: Double, until b: Double) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 20, weight: .bold)).foregroundStyle(.white)
            Text(subtitle).font(.system(size: 13)).foregroundStyle(.white.opacity(0.75))
        }
        .opacity(window(t, a, b, fade: 0.45))
        .offset(x: -14 * (1 - ease(prog(t, a, a + 0.45))))
        .position(x: 190, y: 80)
        .frame(width: 400, alignment: .leading)
    }
}

private struct Bubble: View {
    let text: String
    let revealed: Double

    var body: some View {
        let words = text.split(separator: " ")
        let n = Double(words.count) * revealed
        // Each word fades and rises in as it arrives.
        WrapText(words: words.map(String.init), visible: n)
            .frame(width: 290, alignment: .leading)
            .padding(.horizontal, 13).padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(red: 0.12, green: 0.125, blue: 0.145).opacity(0.96))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(accent.opacity(0.55), lineWidth: 1)))
            .shadow(color: .black.opacity(0.3), radius: 12)
    }
}

/// Words laid out as text, with the not-yet-arrived ones transparent so the bubble keeps its size.
private struct WrapText: View {
    let words: [String]
    let visible: Double

    var body: some View {
        words.enumerated().reduce(Text("")) { acc, item in
            let (i, w) = item
            let a = min(1, max(0, visible - Double(i)))
            return acc + Text(w + " ").foregroundColor(.white.opacity(a))
        }
        .font(.system(size: 14, weight: .medium))
        .lineSpacing(2)
    }
}

// MARK: Cursor

private struct CursorLayer: View {
    let t: Double

    /// Rests bottom right, flies to the File menu while Perch answers, then returns.
    private var position: CGPoint {
        let rest = CGPoint(x: 980 + 8 * sin(t * 1.3), y: 560 + 6 * cos(t * 1.7))
        let target = CGPoint(x: 312, y: 252)
        let go = ease(prog(t, 8.5, 9.4)), back = ease(prog(t, 12.4, 13.2))
        let x = go * (1 - back)
        // A gentle arc on the way.
        let arc = sin(x * .pi) * -60
        return CGPoint(x: lerp(rest.x, target.x, x), y: lerp(rest.y, target.y, x) + arc)
    }

    var body: some View {
        CloudCursor(color: accent)
            .frame(width: 30, height: 30)
            .position(x: position.x + 15, y: position.y + 15)
            .opacity(window(t, 3.4, 27.0, fade: 0.4))
    }
}

// MARK: Title cards

private struct TitleCards: View {
    let t: Double
    var body: some View {
        ZStack {
            let intro = window(t, 0.4, 3.5, fade: 0.6)
            VStack(spacing: 10) {
                MascotView(size: 92, happy: true, showHands: true).offset(y: -6 * sin(t * 2.2))
                Text("Meet Perch").font(.system(size: 44, weight: .bold)).foregroundStyle(.white)
                Text("An AI buddy that lives in your Mac's notch").font(.system(size: 19)).foregroundStyle(.white.opacity(0.8))
            }
            .scaleEffect(0.94 + 0.06 * ease(prog(t, 0.4, 1.0)))
            .opacity(intro)

            let outro = ease(prog(t, 27.1, 27.8))
            ZStack {
                Color.black.opacity(0.35 * outro)
                VStack(spacing: 12) {
                    MascotView(size: 92, happy: true, showHands: true).offset(y: -6 * sin(t * 2.2))
                    Text("Perch").font(.system(size: 46, weight: .bold)).foregroundStyle(.white)
                    Text("Talk · Guide · Agents · Dictation").font(.system(size: 19)).foregroundStyle(.white.opacity(0.85))
                    Text("Free and open source. Bring your own Anthropic, OpenAI or xAI key.")
                        .font(.system(size: 15)).foregroundStyle(.white.opacity(0.65))
                }
                .scaleEffect(0.94 + 0.06 * outro)
                .opacity(outro)
            }
        }
        .frame(width: 1280, height: 720)
    }
}
