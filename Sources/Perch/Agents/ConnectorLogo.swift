import AppKit
import SwiftUI

/// Loads a service's real logo from its own website (apple-touch-icon, then favicon) and caches it.
@MainActor
final class LogoCache: ObservableObject {
    static let shared = LogoCache()
    @Published private(set) var images: [String: NSImage] = [:]
    private var inFlight: Set<String> = []
    private let dir = AgentPaths.root.appendingPathComponent("Connectors/logos", isDirectory: true)

    func image(for domain: String) -> NSImage? {
        if let img = images[domain] { return img }
        let file = dir.appendingPathComponent("\(domain).png")
        if let img = NSImage(contentsOf: file) { images[domain] = img; return img }
        load(domain)
        return nil
    }

    private func load(_ domain: String) {
        guard !inFlight.contains(domain) else { return }
        inFlight.insert(domain)
        Task {
            let candidates = ["https://\(domain)/apple-touch-icon.png", "https://www.\(domain)/apple-touch-icon.png",
                              "https://\(domain)/favicon.ico", "https://www.\(domain)/favicon.ico"]
            for url in candidates.compactMap(URL.init(string:)) {
                guard let (data, resp) = try? await URLSession.shared.data(from: url),
                      (resp as? HTTPURLResponse)?.statusCode == 200,
                      let img = NSImage(data: data), img.size.width >= 16 else { continue }
                images[domain] = img
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                if let tiff = img.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                    try? png.write(to: dir.appendingPathComponent("\(domain).png"))
                }
                break
            }
            inFlight.remove(domain)
        }
    }
}

/// A connector's logo tile: the real logo when we have it, otherwise a coloured symbol.
struct ConnectorLogo: View {
    let def: ConnectorDefinition
    var size: CGFloat = 30
    @ObservedObject private var cache = LogoCache.shared

    var body: some View {
        Group {
            if let domain = def.domain, let img = cache.image(for: domain) {
                Image(nsImage: img).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                    .padding(size * 0.12)
                    .background(Color.white)
            } else {
                (Color(hex: def.colorHex) ?? .gray)
                    .overlay(Image(systemName: def.symbol).font(.system(size: size * 0.45, weight: .semibold)).foregroundStyle(.white))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.26, style: .continuous))
    }
}
