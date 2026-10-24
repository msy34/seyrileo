import AVFoundation
import AVKit
import CoreMedia
import CoreVideo
import Darwin
import UIKit

/// Routes VLC's decoded pictures into `AVSampleBufferDisplayLayer`s instead of letting VLC draw
/// into a view. Only a sample-buffer layer can be shown in Picture in Picture, so this is what
/// makes PiP possible for VLC content (MKV, MP2-audio live channels).
///
/// Uses libvlc's public C API (`libvlc_video_set_format_callbacks`, `libvlc_video_set_callbacks`,
/// documented in the bundled `vlc/libvlc_media_player.h`), resolved with `dlsym` from the
/// embedded MobileVLCKit binary. Frames are requested as NV12, the pixel format VideoToolbox and
/// Core Animation use natively, so VLC does no extra colour conversion. If anything is missing
/// the engine keeps VLC's own drawing (no PiP) — playback never depends on this path.
nonisolated final class VLCFrameOutput: @unchecked Sendable {
    /// The layer shown in the app and used for PiP.
    let primaryLayer = AVSampleBufferDisplayLayer()
    private let lock = NSLock()
    private var extraLayers: [AVSampleBufferDisplayLayer] = []
    /// Source pixel aspect ratio (anamorphic SD/DVB video has non-square pixels).
    private var pixelAspect: (Int, Int) = (1, 1)
    private var hasShownFrame = false
    /// Called once on the main thread when the first picture is on screen (PiP becomes possible).
    var onFirstFrame: (@MainActor @Sendable () -> Void)?

    init() {
        primaryLayer.videoGravity = .resizeAspect
        primaryLayer.backgroundColor = UIColor.black.cgColor
    }

    /// What libvlc's callbacks point at. VLCKit's `stop()` finishes asynchronously, so VLC's video
    /// thread can still call back after the engine and this output are released (seen as a
    /// crash in `show` when a VLC title was closed right after it started). The target is
    /// therefore never freed (a few bytes per VLC session): it owns the pixel-buffer pool and
    /// only forwards pictures while the output is still alive.
    private final class CallbackTarget: @unchecked Sendable {
        weak var output: VLCFrameOutput?
        let lock = NSLock()
        var pool: CVPixelBufferPool?
    }

    // MARK: - libvlc C API

    private typealias FormatCallback = @convention(c) (
        UnsafeMutablePointer<UnsafeMutableRawPointer?>?, UnsafeMutablePointer<CChar>?,
        UnsafeMutablePointer<UInt32>?, UnsafeMutablePointer<UInt32>?,
        UnsafeMutablePointer<UInt32>?, UnsafeMutablePointer<UInt32>?
    ) -> UInt32
    private typealias CleanupCallback = @convention(c) (UnsafeMutableRawPointer?) -> Void
    private typealias LockCallback = @convention(c) (
        UnsafeMutableRawPointer?, UnsafeMutablePointer<UnsafeMutableRawPointer?>?
    ) -> UnsafeMutableRawPointer?
    private typealias UnlockCallback = @convention(c) (
        UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafePointer<UnsafeMutableRawPointer?>?
    ) -> Void
    private typealias DisplayCallback = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void

    private typealias SetFormatCallbacks = @convention(c) (
        UnsafeMutableRawPointer?, FormatCallback?, CleanupCallback?
    ) -> Void
    private typealias SetCallbacks = @convention(c) (
        UnsafeMutableRawPointer?, LockCallback?, UnlockCallback?, DisplayCallback?, UnsafeMutableRawPointer?
    ) -> Void

    private static func symbol<T>(_ name: String, as type: T.Type) -> T? {
        guard let pointer = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) else { return nil }  // RTLD_DEFAULT
        return unsafeBitCast(pointer, to: type)
    }

    /// Installs the callbacks on a `libvlc_media_player_t`. Must be called before playback starts.
    /// Returns false (and changes nothing) when the API is unavailable.
    func attach(toPlayer player: UnsafeMutableRawPointer) -> Bool {
        guard let setFormat = Self.symbol("libvlc_video_set_format_callbacks", as: SetFormatCallbacks.self),
              let setCallbacks = Self.symbol("libvlc_video_set_callbacks", as: SetCallbacks.self)
        else { return false }
        let target = CallbackTarget()
        target.output = self
        // Deliberately retained for the life of the process; see CallbackTarget.
        let opaque = Unmanaged.passRetained(target).toOpaque()
        setCallbacks(player, Self.lockFrame, Self.unlockFrame, Self.displayFrame, opaque)
        setFormat(player, Self.configure, Self.cleanup)
        return true
    }

    // MARK: - Layers

    func addLayer(_ layer: AVSampleBufferDisplayLayer) {
        lock.withLock { extraLayers.append(layer) }
    }

    func removeLayer(_ layer: AVSampleBufferDisplayLayer) {
        lock.withLock { extraLayers.removeAll { $0 === layer } }
    }

    /// Set from the media's track information once known.
    func setPixelAspect(_ numerator: Int, _ denominator: Int) {
        guard numerator > 0, denominator > 0 else { return }
        lock.withLock { pixelAspect = (numerator, denominator) }
    }

    func flush() {
        primaryLayer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
    }

    // MARK: - Callbacks (called on VLC's video output thread)

    /// VLC tells us the decoded size; we ask for NV12 in pixel buffers we own.
    private static let configure: FormatCallback = { opaque, chroma, width, height, pitches, lines in
        guard let context = opaque?.pointee, let chroma, let width, let height, let pitches, let lines else { return 0 }
        let target = Unmanaged<CallbackTarget>.fromOpaque(context).takeUnretainedValue()
        // Even dimensions (4:2:0 chroma planes).
        let w = Int(width.pointee) & ~1
        let h = Int(height.pointee) & ~1
        guard w > 0, h > 0 else { return 0 }
        "NV12".utf8CString.withUnsafeBufferPointer { source in
            for index in 0..<4 { chroma[index] = source[index] }
        }
        width.pointee = UInt32(w)
        height.pointee = UInt32(h)
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey: w,
            kCVPixelBufferHeightKey: h,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool)
        guard let pool else { return 0 }
        // VLC writes rows at the pitch we report, so report the pool's real row lengths.
        var probe: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &probe)
        guard let probe else { return 0 }
        pitches[0] = UInt32(CVPixelBufferGetBytesPerRowOfPlane(probe, 0))
        pitches[1] = UInt32(CVPixelBufferGetBytesPerRowOfPlane(probe, 1))
        lines[0] = UInt32(h)
        lines[1] = UInt32(h / 2)
        target.lock.withLock { target.pool = pool }
        return 3
    }

    private static let cleanup: CleanupCallback = { opaque in
        guard let opaque else { return }
        let target = Unmanaged<CallbackTarget>.fromOpaque(opaque).takeUnretainedValue()
        target.lock.withLock { target.pool = nil }
    }

    private static let lockFrame: LockCallback = { opaque, planes in
        guard let opaque, let planes else { return nil }
        let target = Unmanaged<CallbackTarget>.fromOpaque(opaque).takeUnretainedValue()
        guard let pool = target.lock.withLock({ target.pool }) else { return nil }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        guard let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        planes[0] = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)
        planes[1] = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)
        return Unmanaged.passRetained(buffer).toOpaque()
    }

    private static let unlockFrame: UnlockCallback = { _, picture, _ in
        guard let picture else { return }
        let buffer = Unmanaged<CVPixelBuffer>.fromOpaque(picture).takeUnretainedValue()
        CVPixelBufferUnlockBaseAddress(buffer, [])
    }

    private static let displayFrame: DisplayCallback = { opaque, picture in
        guard let opaque, let picture else { return }
        let target = Unmanaged<CallbackTarget>.fromOpaque(opaque).takeUnretainedValue()
        let buffer = Unmanaged<CVPixelBuffer>.fromOpaque(picture).takeRetainedValue()
        // The player was closed: drop the late picture (the buffer is released here).
        target.output?.show(buffer)
    }

    private func show(_ buffer: CVPixelBuffer) {
        let aspect = lock.withLock { pixelAspect }
        if aspect.0 != aspect.1 {
            let ratio = [kCVImageBufferPixelAspectRatioHorizontalSpacingKey: aspect.0,
                         kCVImageBufferPixelAspectRatioVerticalSpacingKey: aspect.1] as CFDictionary
            CVBufferSetAttachment(buffer, kCVImageBufferPixelAspectRatioKey, ratio, .shouldPropagate)
        }
        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: buffer, formatDescriptionOut: &format)
        guard let format else { return }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .invalid, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(
            allocator: nil, imageBuffer: buffer, formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sample)
        guard let sample else { return }
        // VLC already paced the frame; show it now.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(
                dictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        let first = lock.withLock { () -> Bool in
            defer { hasShownFrame = true }
            return !hasShownFrame
        }
        if first, let onFirstFrame { Task { @MainActor in onFirstFrame() } }
        let layers = [primaryLayer] + lock.withLock { extraLayers }
        for layer in layers {
            let renderer = layer.sampleBufferRenderer
            if renderer.status == .failed { renderer.flush() }
            renderer.enqueue(sample)
        }
    }
}

/// A view backed by a sample-buffer layer (in-app picture, TV output).
final class SampleBufferView: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
    var displayLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }
}

/// Hosts the frame output's primary layer so it follows the view's size.
final class PrimaryLayerView: UIView {
    let hosted: CALayer

    init(hosting layer: CALayer) {
        hosted = layer
        super.init(frame: .zero)
        backgroundColor = .black
        isUserInteractionEnabled = false
        self.layer.addSublayer(layer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hosted.frame = bounds
        CATransaction.commit()
    }
}
