import ScreenCaptureKit
import CoreMedia
import CoreVideo

final class DisplayCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "raydesk.capture", qos: .userInteractive)
    private let lock = NSLock()
    private var latest: CVPixelBuffer?
    private var generation = 0

    func start(displayID: CGDirectDisplayID, width: Int, height: Int) async throws {
        var target: SCDisplay?
        for _ in 0..<40 {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            target = content.displays.first { $0.displayID == displayID }
            if target != nil { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        guard let display = target else { throw CaptureError.displayNotFound }

        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB
        config.minimumFrameInterval = CMTime(value: 1, timescale: 120)
        config.showsCursor = true
        config.queueDepth = 5

        let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() {
        stream?.stopCapture(completionHandler: nil)
        stream = nil
    }

    func takeFrame(newerThan seen: inout Int) -> CVPixelBuffer? {
        lock.lock()
        defer { lock.unlock() }
        guard generation != seen else { return nil }
        seen = generation
        return latest
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: rawStatus) == .complete,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        else { return }
        lock.lock()
        latest = pixelBuffer
        generation &+= 1
        lock.unlock()
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("RayDesk: capture stopped: \(error)")
    }

    enum CaptureError: Error { case displayNotFound }
}
