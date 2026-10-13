import AppKit
import SwiftUI

/// Something Perch draws on the screen to show you where to look or click.
struct ScreenMark: Identifiable, Equatable {
    enum Kind: Equatable {
        case highlight(CGRect)          // global AppKit rect
        case circle(CGPoint, CGFloat)   // global centre + radius
        case arrow(CGPoint, CGPoint)    // global from → to
    }
    let id = UUID()
    let kind: Kind
    let label: String?

    /// Where the buddy should fly to point at this mark.
    var anchor: CGPoint {
        switch kind {
        case .highlight(let r): return CGPoint(x: r.midX, y: r.midY)
        case .circle(let c, _): return c
        case .arrow(_, let to): return to
        }
    }
}

/// Parses the drawing tags the model may add to its reply.
/// Coordinates are screenshot pixels (top-left origin) on the given screen.
enum MarkTags {
    private static let regex = try! NSRegularExpression(
        pattern: #"\[(HIGHLIGHT|CIRCLE|ARROW):\s*([\d.,\s]+?)\s*(?::\s*screen\s*(\d+))?\s*(?::\s*([^\]]*))?\]"#,
        options: [.caseInsensitive])

    static func parse(_ text: String, screens: [CapturedScreen]) -> [ScreenMark] {
        let ns = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: ns).compactMap { m in
            guard let kindR = Range(m.range(at: 1), in: text), let numsR = Range(m.range(at: 2), in: text) else { return nil }
            let nums = text[numsR].split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }.map { CGFloat($0) }
            let screenIndex = Range(m.range(at: 3), in: text).flatMap { Int(text[$0]) } ?? 1
            let label = Range(m.range(at: 4), in: text).map { text[$0].trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 }
            guard let screen = screens.first(where: { $0.index == screenIndex }) ?? screens.first else { return nil }
            let scale = screen.appKitFrame.width / screen.imageSize.width
            switch text[kindR].uppercased() {
            case "HIGHLIGHT" where nums.count >= 4:
                let topLeft = screen.globalPoint(fromImagePoint: CGPoint(x: nums[0], y: nums[1]))
                let w = nums[2] * scale, h = nums[3] * scale
                return ScreenMark(kind: .highlight(CGRect(x: topLeft.x, y: topLeft.y - h, width: w, height: h)), label: label)
            case "CIRCLE" where nums.count >= 3:
                return ScreenMark(kind: .circle(screen.globalPoint(fromImagePoint: CGPoint(x: nums[0], y: nums[1])), nums[2] * scale), label: label)
            case "ARROW" where nums.count >= 4:
                return ScreenMark(kind: .arrow(screen.globalPoint(fromImagePoint: CGPoint(x: nums[0], y: nums[1])),
                                               screen.globalPoint(fromImagePoint: CGPoint(x: nums[2], y: nums[3]))), label: label)
            default:
                return nil
            }
        }
    }

    private static let anyTag = try! NSRegularExpression(
        pattern: #"\[(POINT|HIGHLIGHT|CIRCLE|ARROW|DO|AGENT|NEW_AGENT)\s*:[^\]]*\]"#, options: [.caseInsensitive])

    /// Removes every control tag, and hides a half-streamed one at the end.
    static func stripAll(_ text: String) -> String {
        var out = anyTag.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
        // Turn dash-as-punctuation into a comma pause; leave hyphenated words alone.
        out = out.replacingOccurrences(of: " — ", with: ", ")
                 .replacingOccurrences(of: " – ", with: ", ")
                 .replacingOccurrences(of: " - ", with: ", ")
                 .replacingOccurrences(of: "—", with: ", ")
        if let open = out.range(of: "[", options: .backwards), !out[open.lowerBound...].contains("]") {
            out = String(out[..<open.lowerBound])
        }
        return out.replacingOccurrences(of: "  ", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Draws marks on one screen: strokes trace themselves in, then fade out.
struct MarksLayer: View {
    let screenFrame: CGRect
    let marks: [ScreenMark]
    let color: Color

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(marks) { mark in
                MarkView(mark: mark, screenFrame: screenFrame, color: color)
            }
        }
        .frame(width: screenFrame.width, height: screenFrame.height, alignment: .topLeading)
        .allowsHitTesting(false)
    }
}

private struct MarkView: View {
    let mark: ScreenMark
    let screenFrame: CGRect
    let color: Color
    @State private var progress: CGFloat = 0
    @State private var pulse = false

    private func local(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x - screenFrame.minX, y: screenFrame.maxY - p.y) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            switch mark.kind {
            case .highlight(let r):
                let origin = local(CGPoint(x: r.minX, y: r.maxY))
                let rect = CGRect(x: origin.x - 4, y: origin.y - 4, width: r.width + 8, height: r.height + 8)
                RoundedRectangle(cornerRadius: 8)
                    .fill(color.opacity(0.12 * progress))
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
                RoundedRectangle(cornerRadius: 8)
                    .trim(from: 0, to: progress)
                    .stroke(color, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .frame(width: rect.width, height: rect.height)
                    .scaleEffect(pulse ? 1.0 : 1.06)
                    .position(x: rect.midX, y: rect.midY)
                labelView(at: CGPoint(x: rect.midX, y: rect.minY - 16))
            case .circle(let c, let radius):
                let p = local(c)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(color, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .frame(width: radius * 2 + 10, height: radius * 2 + 10)
                    .rotationEffect(.degrees(-90))
                    .position(p)
                labelView(at: CGPoint(x: p.x, y: p.y - radius - 20))
            case .arrow(let from, let to):
                let a = local(from), b = local(to)
                ArrowShape(from: a, to: b)
                    .trim(from: 0, to: progress)
                    .stroke(color, style: StrokeStyle(lineWidth: 3.5, lineCap: .round, lineJoin: .round))
                labelView(at: CGPoint(x: a.x, y: a.y - 16))
            }
        }
        .shadow(color: color.opacity(0.5), radius: 6)
        .onAppear {
            withAnimation(.easeOut(duration: 0.7)) { progress = 1 }
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { pulse = true }
        }
    }

    @ViewBuilder private func labelView(at p: CGPoint) -> some View {
        if let label = mark.label {
            Text(label)
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Capsule().fill(color))
                .position(p)
                .opacity(Double(progress))
        }
    }
}

struct ArrowShape: Shape {
    let from: CGPoint
    let to: CGPoint
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: from)
        let mid = CGPoint(x: (from.x + to.x) / 2, y: min(from.y, to.y) - 30)
        p.addQuadCurve(to: to, control: mid)
        let angle = atan2(to.y - mid.y, to.x - mid.x)
        let head: CGFloat = 12
        p.move(to: to)
        p.addLine(to: CGPoint(x: to.x - head * cos(angle - .pi / 6), y: to.y - head * sin(angle - .pi / 6)))
        p.move(to: to)
        p.addLine(to: CGPoint(x: to.x - head * cos(angle + .pi / 6), y: to.y - head * sin(angle + .pi / 6)))
        return p
    }
}
