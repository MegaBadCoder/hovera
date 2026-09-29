import AVFoundation
import Vision
import RayDeskCore
import simd

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
    private var currentPhase = ""
    private var estimator = HeadPositionEstimator(camera: FaceCamera(horizontalFieldOfView: CameraHeadTracker.assumedFieldOfView, aspect: 16.0 / 9))
    private var smoother = VectorSmoother(timeConstants: SIMD3(0.15, 0.15, 0.3))
    private var referenceTurn: (yaw: Double, pitch: Double)?
    private var referenceNeck: SIMD3<Double>?
    private var referenceSince: Double?
    private var lastFaceTime = 0.0
    private static let referenceSettleSeconds = 0.5
    private static let maxOffset = 0.5
    private static let maxDepthJump = 0.12
    private static let depthTrustYaw = 25 * Double.pi / 180
    private let orientation: @Sendable () -> simd_quatd

    init(orientation: @escaping @Sendable () -> simd_quatd) {
        self.orientation = orientation
    }

    var phase: String {
        get { lock.withLock { currentPhase } }
        set { lock.withLock { currentPhase = newValue } }
    }

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
        lock.withLock { estimator.camera = camera }
        log(String(format: "camera: %@ %dx%d, assumed field of view %.0f°", device.localizedName,
                   dimensions.width, dimensions.height, Self.assumedFieldOfView * 180 / .pi))
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let head = orientation()
        let handler = VNImageRequestHandler(cvPixelBuffer: pixels, options: [:])
        let rectangles = VNDetectFaceRectanglesRequest()
        try? handler.perform([rectangles])
        let time = Date().timeIntervalSinceReferenceDate
        var face = rectangles.results?.max { $0.boundingBox.width < $1.boundingBox.width }
        if let found = face {
            let landmarks = VNDetectFaceLandmarksRequest()
            landmarks.inputFaceObservations = [found]
            try? handler.perform([landmarks])
            face = landmarks.results?.first ?? found
        }

        lock.lock()
        frames += 1
        if let face {
            faces += 1
            let position = camera.headPosition(face: face.boundingBox)
            spread.add(position, at: time)
            latestAngles = SIMD3(face.yaw?.doubleValue ?? .nan, face.pitch?.doubleValue ?? .nan, face.roll?.doubleValue ?? .nan)
            trackNeck(face: face.boundingBox, head: head, time: time)
        }
        let phase = currentPhase
        lock.unlock()

        let headColumns = String(format: "%.5f,%.5f,%.5f,%.5f", head.real, head.imag.x, head.imag.y, head.imag.z)
        guard let face else {
            record("\(String(format: "%.4f", time)),\(phase),,,,,,,,,,,,,,,,,,,\(headColumns)")
            return
        }
        let box = face.boundingBox
        let position = camera.headPosition(face: box)
        let degree = 180 / Double.pi
        let features = landmarkColumns(face)
        record(String(format: "%.4f,%@,%.5f,%.5f,%.5f,%.5f,%.4f,%.4f,%.4f,%.1f,%.1f,%.1f,%.3f,%@,%@", time, phase,
                      box.midX, box.midY, box.width, box.height, position.x, position.y, position.z,
                      (face.yaw?.doubleValue ?? .nan) * degree, (face.pitch?.doubleValue ?? .nan) * degree,
                      (face.roll?.doubleValue ?? .nan) * degree, face.confidence, features, headColumns))
    }

    private func trackNeck(face: CGRect, head: simd_quatd, time: Double) {
        let turn = head.yawPitch
        if referenceTurn == nil {
            referenceTurn = turn
            referenceSince = time
            smoother.reset()
        }
        guard let referenceTurn, let referenceSince else { return }
        let yaw = remainder(turn.yaw - referenceTurn.yaw, 2 * .pi)
        var neck = estimator.neckPosition(face: face, yaw: yaw, pitch: turn.pitch - referenceTurn.pitch)
        if let previous = smoother.value, time - lastFaceTime < 0.1 {
            guard abs(neck.z / previous.z - 1) < Self.maxDepthJump else { return }
            if abs(yaw) > Self.depthTrustYaw {
                neck.z = previous.z
            }
        }
        smoother.add(neck, dt: lastFaceTime > 0 ? min(time - lastFaceTime, 0.2) : 0.033)
        lastFaceTime = time
        if time - referenceSince < Self.referenceSettleSeconds {
            referenceNeck = smoother.value
        }
    }

    /// Начинает отсчёт сдвига головы заново от текущего положения и поворота.
    func resetReference() {
        lock.withLock {
            referenceTurn = nil
            referenceNeck = nil
            referenceSince = nil
        }
    }

    /// Сдвиг шеи от опорного положения в осях камеры, метры; ноль, пока опоры нет.
    func neckOffset() -> SIMD3<Double> {
        lock.lock()
        defer { lock.unlock() }
        guard let referenceNeck, let current = smoother.value else { return .zero }
        let offset = current - referenceNeck
        let length = simd_length(offset)
        return length > Self.maxOffset ? offset * (Self.maxOffset / length) : offset
    }

    private func landmarkColumns(_ face: VNFaceObservation) -> String {
        let box = face.boundingBox
        let aspect = camera.aspect
        func points(_ region: VNFaceLandmarkRegion2D?) -> [SIMD2<Double>] {
            guard let region else { return [] }
            return region.normalizedPoints.map {
                SIMD2(Double(box.minX + $0.x * box.width), Double(box.minY + $0.y * box.height) / aspect)
            }
        }
        func centre(_ list: [SIMD2<Double>]) -> SIMD2<Double>? {
            list.isEmpty ? nil : list.reduce(.zero, +) / Double(list.count)
        }
        let left = centre(points(face.landmarks?.leftEye))
        let right = centre(points(face.landmarks?.rightEye))
        let contour = points(face.landmarks?.faceContour).map(\.x)
        let nose = centre(points(face.landmarks?.nose))
        let eyes = left.flatMap { l in right.map { r in (distance: simd_length(l - r), middle: (l + r) / 2) } }
        let contourWidth = contour.isEmpty ? Double.nan : contour.max()! - contour.min()!
        return String(format: "%.5f,%.5f,%.5f,%.5f,%.5f,%.5f",
                      eyes?.distance ?? .nan, contourWidth, nose?.x ?? .nan, nose?.y ?? .nan,
                      eyes?.middle.x ?? .nan, eyes?.middle.y ?? .nan)
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
                                           contents: "time,phase,cx,cy,w,h,x,y,z,yaw,pitch,roll,confidence,eyes,contour,nosex,nosey,eyex,eyey,qw,qx,qy,qz\n".data(using: .utf8))
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
