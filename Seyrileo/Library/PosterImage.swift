import ImageIO
import SwiftUI
import UIKit

/// Bounded, memory-only poster loading: max 4 MB per image, downsampled to the display size,
/// no disk cache (artwork URLs may be provider-specific), at most 4 concurrent downloads.
actor PosterLoader {
    static let shared = PosterLoader()

    private let session: URLSession
    private let cache = NSCache<NSString, UIImage>()
    private var inFlight: [String: Task<UIImage?, Never>] = [:]
    private var active = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private static let maxBytes = 4 * 1024 * 1024
    private static let maxConcurrent = 4

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 15
        configuration.httpMaximumConnectionsPerHost = 4
        session = URLSession(configuration: configuration)
        cache.countLimit = 300
    }

    func image(for url: URL, maxPixel: CGFloat) async -> UIImage? {
        let key = "\(url.absoluteString)#\(Int(maxPixel))"
        if let cached = cache.object(forKey: key as NSString) { return cached }
        if let task = inFlight[key] { return await task.value }
        let task = Task<UIImage?, Never> { await self.download(url, maxPixel: maxPixel) }
        inFlight[key] = task
        let image = await task.value
        inFlight[key] = nil
        if let image { cache.setObject(image, forKey: key as NSString) }
        return image
    }

    private func download(_ url: URL, maxPixel: CGFloat) async -> UIImage? {
        await acquire()
        defer { release() }
        guard !Task.isCancelled,
              let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? false,
              data.count <= Self.maxBytes,
              let source = CGImageSourceCreateWithData(data as CFData, nil)
        else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    private func acquire() async {
        if active < Self.maxConcurrent {
            active += 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty {
            active -= 1
        } else {
            waiters.removeFirst().resume()
        }
    }
}

/// Provider artwork with a monogram fallback (missing URL, failed or slow download).
/// With `width: nil` the poster fills the width it is given (grid tiles) and the fallback is a
/// colour cover with the full title.
struct PosterImage: View {
    let url: URL?
    let title: String
    var width: CGFloat? = 60
    var aspect: CGFloat = 2.0 / 3.0
    @State private var image: UIImage?
    @Environment(\.displayScale) private var scale

    var body: some View {
        if let width {
            poster
                .frame(width: width, height: width / aspect)
                .clipShape(RoundedRectangle(cornerRadius: max(6, width * 0.08), style: .continuous))
        } else {
            Color.clear
                .aspectRatio(aspect, contentMode: .fit)
                .overlay { poster }
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(.white.opacity(0.1), lineWidth: 1)
                }
        }
    }

    private var poster: some View {
        ZStack {
            if width == nil {
                Self.cover(for: title)
            } else {
                Color.accent.opacity(0.14)
            }
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else if width == nil {
                Text(verbatim: title)
                    .font(.system(.subheadline, design: .rounded).weight(.heavy))
                    .foregroundStyle(.white.opacity(0.92))
                    .multilineTextAlignment(.leading)
                    .lineLimit(4)
                    .minimumScaleFactor(0.7)
                    .padding(10)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            } else {
                // Scales with Dynamic Type but always fits the fixed poster frame.
                Text(Self.initials(title))
                    .font(.title3.weight(.bold))
                    .minimumScaleFactor(0.3)
                    .lineLimit(1)
                    .padding(4)
                    .foregroundStyle(Color.accent)
            }
        }
        .accessibilityHidden(true)
        .task(id: url) {
            image = nil
            guard let url else { return }
            let side = width.map { max($0, $0 / aspect) } ?? 270
            image = await PosterLoader.shared.image(for: url, maxPixel: side * scale)
        }
    }

    /// A stable colour cover per title, in the app's night palette.
    static func cover(for title: String) -> LinearGradient {
        let palettes: [(Color, Color)] = [
            (Color(red: 0.24, green: 0.16, blue: 0.42), Color(red: 0.07, green: 0.09, blue: 0.23)),
            (Color(red: 0.48, green: 0.23, blue: 0.12), Color(red: 0.16, green: 0.07, blue: 0.02)),
            (Color(red: 0.07, green: 0.31, blue: 0.29), Color(red: 0.02, green: 0.13, blue: 0.13)),
            (Color(red: 0.05, green: 0.30, blue: 0.49), Color(red: 0.00, green: 0.09, blue: 0.24)),
            (Color(red: 0.42, green: 0.13, blue: 0.22), Color(red: 0.13, green: 0.04, blue: 0.09)),
            (Color(red: 0.36, green: 0.31, blue: 0.10), Color(red: 0.12, green: 0.10, blue: 0.03)),
        ]
        let index = title.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF } % palettes.count
        let (top, bottom) = palettes[index]
        return LinearGradient(colors: [top, bottom], startPoint: .top, endPoint: .bottom)
    }

    static func initials(_ text: String) -> String {
        let letters = text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).prefix(2).compactMap(\.first)
        return letters.isEmpty ? "•" : String(letters).uppercased()
    }
}
