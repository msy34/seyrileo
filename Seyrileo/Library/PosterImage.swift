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
struct PosterImage: View {
    let url: URL?
    let title: String
    var width: CGFloat = 60
    var aspect: CGFloat = 2.0 / 3.0
    @State private var image: UIImage?
    @Environment(\.displayScale) private var scale

    var body: some View {
        let height = width / aspect
        ZStack {
            Color.accent.opacity(0.14)
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Text(Self.initials(title))
                    .font(.system(size: max(12, width * 0.28), weight: .semibold))
                    .foregroundStyle(Color.accent)
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: max(6, width * 0.08), style: .continuous))
        .accessibilityHidden(true)
        .task(id: url) {
            image = nil
            guard let url else { return }
            image = await PosterLoader.shared.image(for: url, maxPixel: max(width, height) * scale)
        }
    }

    static func initials(_ text: String) -> String {
        let letters = text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).prefix(2).compactMap(\.first)
        return letters.isEmpty ? "•" : String(letters).uppercased()
    }
}
