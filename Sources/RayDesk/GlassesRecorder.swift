import AVFoundation
import ScreenCaptureKit

final class GlassesRecorder: NSObject, SCStreamDelegate, SCRecordingOutputDelegate {
    private var stream: SCStream?
    private(set) var fileURL: URL?

    var isRecording: Bool { stream != nil }

    func start(displayID: CGDirectDisplayID) async throws -> URL {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw RecorderError.displayNotFound
        }
        let config = SCStreamConfiguration()
        config.width = 1920
        config.height = 1080
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.showsCursor = false

        let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false).timeSeparator(.omitted))
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies/RayDesk-\(stamp).mov")
        let recordingConfig = SCRecordingOutputConfiguration()
        recordingConfig.outputURL = url
        recordingConfig.outputFileType = .mov
        recordingConfig.videoCodecType = .hevc

        let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: config, delegate: self)
        try stream.addRecordingOutput(SCRecordingOutput(configuration: recordingConfig, delegate: self))
        try await stream.startCapture()
        self.stream = stream
        fileURL = url
        return url
    }

    func stop() async throws {
        guard let stream else { return }
        self.stream = nil
        try await stream.stopCapture()
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        log("glasses recording stopped: \(error)")
        self.stream = nil
    }

    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        log("glasses recording failed: \(error)")
    }

    enum RecorderError: Error { case displayNotFound }
}
