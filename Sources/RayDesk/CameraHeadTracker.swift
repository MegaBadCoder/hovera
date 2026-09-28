import AVFoundation
import Vision
import RayDeskCore

struct CameraHeadReading {
    var position: SIMD3<Double>?
    var jitter: SIMD3<Double>?
    var framesPerSecond: Int
    var facesPerSecond: Int
    var angles: SIMD3<Double>?
}

final class CameraHeadTracker: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "raydesk.camera-head", qos: .userInitiated)
    private let lock = NSLock()
    private var spread = RollingSpread(window: 1)
    private var latestAngles: SIMD3<Double>?
    private var frames = 0
    private var faces = 0
    private var camera = FaceCamera(horizontalFieldOfView: CameraHeadTracker.assumedFieldOfView, aspect: 16.0 / 9)
    private var file: FileHandle?
    private var pending: [String] = []

    private static let assumedFieldOfView = 70 * Double.pi / 180

    var isRunning: Bool { session.isRunning }

    func start(completion: @escaping @MainActor (Error?) -> Void) {
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            guard let self else { return }
            guard granted else {
                Task { @MainActor in completion(CameraError.accessDenied) }
                return
            }
            queue.async {
                do {
                    try self.configure()
                    self.openFile()
                    self.session.startRunning()
                    Task { @MainActor in completion(nil) }
                } catch {
                    Task { @MainActor in completion(error) }
                }
            }
        }
    }

    func stop() {
        queue.async {
            self.session.stopRunning()
            self.flush()
            try? self.file?.close()
            self.file = nil
        }
    }

    func takeReading() -> CameraHeadReading {
        lock.lock()
        defer { lock.unlock() }
        let reading = CameraHeadReading(position: spread.mean, jitter: spread.deviation, framesPerSecond: frames,
                                        facesPerSecond: faces, angles: latestAngles)
        frames = 0
        faces = 0
        return reading
    }

    private func configure() throws {
        guard session.inputs.isEmpty else { return }
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .unspecified)
            ?? AVCaptureDevice.default(for: .video)
        else { throw CameraError.noCamera }
        let input = try AVCaptureDeviceInput(device: device)
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        session.beginConfiguration()
        session.sessionPreset = .high
        guard session.canAddInput(input), session.canAddOutput(output) else { throw CameraError.noCamera }
        session.addInput(input)
        session.addOutput(output)
        session.commitConfiguration()
        let dimensions = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        camera.aspect = Double(dimensions.width) / Double(max(dimensions.height, 1))
        log(String(format: "camera: %@ %dx%d, assumed field of view %.0f°", device.localizedName,
                   dimensions.width, dimensions.height, Self.assumedFieldOfView * 180 / .pi))
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let request = VNDetectFaceRectanglesRequest()
        try? VNImageRequestHandler(cvPixelBuffer: pixels, options: [:]).perform([request])
        let time = Date().timeIntervalSinceReferenceDate
        let face = request.results?.max { $0.boundingBox.width < $1.boundingBox.width }

        lock.lock()
        frames += 1
        if let face {
            faces += 1
            let position = camera.headPosition(face: face.boundingBox)
            spread.add(position, at: time)
            latestAngles = SIMD3(face.yaw?.doubleValue ?? .nan, face.pitch?.doubleValue ?? .nan, face.roll?.doubleValue ?? .nan)
        }
        lock.unlock()

        guard let face else {
            record(String(format: "%.4f,,,,,,,,,,,", time))
            return
        }
        let box = face.boundingBox
        let position = camera.headPosition(face: box)
        let degree = 180 / Double.pi
        record(String(format: "%.4f,%.5f,%.5f,%.5f,%.5f,%.4f,%.4f,%.4f,%.1f,%.1f,%.1f,%.3f", time,
                      box.midX, box.midY, box.width, box.height, position.x, position.y, position.z,
                      (face.yaw?.doubleValue ?? .nan) * degree, (face.pitch?.doubleValue ?? .nan) * degree,
                      (face.roll?.doubleValue ?? .nan) * degree, face.confidence))
    }

    private func record(_ line: String) {
        pending.append(line)
        if pending.count >= 30 { flush() }
    }

    private func flush() {
        guard !pending.isEmpty else { return }
        file?.write((pending.joined(separator: "\n") + "\n").data(using: .utf8)!)
        pending.removeAll(keepingCapacity: true)
    }

    private func openFile() {
        let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/RayDesk-imu")
        let url = directory.appendingPathComponent("camera-\(Int(Date().timeIntervalSinceReferenceDate)).csv")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: url.path,
                                           contents: "time,cx,cy,w,h,x,y,z,yaw,pitch,roll,confidence\n".data(using: .utf8))
            file = try FileHandle(forWritingTo: url)
            file?.seekToEndOfFile()
            log("camera recording: \(url.lastPathComponent)")
        } catch {
            log("camera recording failed: \(error)")
        }
    }

    enum CameraError: Error {
        case accessDenied
        case noCamera
    }
}
