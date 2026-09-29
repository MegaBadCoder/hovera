import AVFoundation
import Vision
import RayDeskCore
import simd

struct CameraObservation {
    var face: CGRect?
    var landmarks: [CGPoint]
    var neckOffset: SIMD3<Double>
    var turn: SIMD2<Double>
    var accepted: Bool
}

struct CameraHeadReading {
    var position: SIMD3<Double>?
    var jitter: SIMD3<Double>?
    var framesPerSecond: Int
    var facesPerSecond: Int
    var angles: SIMD3<Double>?
    var latency: Double?
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
    private var smoother = OneEuroPositionFilter(minCutoff: SIMD3(1, 1, 0.3), beta: SIMD3(2, 2, 1.5))
    private var deadband = SoftDeadband(band: SIMD3(0.0015, 0.0015, 0.003))
    private var recentNecks: [SIMD3<Double>] = []
    private var lastRawZ: Double?
    private var rejectedInRow = 0
    private var lastLatency = 0.08
    private var generation = 0
    private var holding = false
    private var carry = SIMD3<Double>(repeating: 0)
    private var carryStart = 0.0
    private var referenceNeck: SIMD3<Double>?
    private var referencePitch: Double?
    private var referenceWindowStart: Double?
    private var referenceSamples: [SIMD3<Double>] = []
    private var referencePitchSamples: [Double] = []
    private var latestEstimate: (time: Double, value: SIMD3<Double>)?
    private var previousEstimate: (time: Double, value: SIMD3<Double>)?
    private var latencySum = 0.0
    private var latencyCount = 0
    private var lastFaceTime = 0.0
    private var lastTurn = SIMD2<Double>(repeating: 0)
    private var lastAccepted = false
    private var observer: (@MainActor (CameraObservation) -> Void)?
    private static let referenceWindowSeconds = 1.0
    private static let maxOffset = 0.5
    private static let maxDepthJump = 0.12
    private static let holdYaw = 20 * Double.pi / 180
    private static let resumeYaw = 15 * Double.pi / 180
    private static let holdPitch = 25 * Double.pi / 180
    private static let maxTrackedSpeed = 30 * Double.pi / 180
    private static let referenceSpeed = 10 * Double.pi / 180
    private static let referenceYaw = 10 * Double.pi / 180
    private static let carrySeconds = 1.0
    private let orientation: @Sendable (Double) -> (orientation: simd_quatd, speed: Double)

    init(orientation: @escaping @Sendable (Double) -> (orientation: simd_quatd, speed: Double)) {
        self.orientation = orientation
    }

    var captureSession: AVCaptureSession { session }

    /// Получает на главном потоке каждое распознавание: рамку, точки лица и сдвиг шеи.
    func observe(_ handler: (@MainActor (CameraObservation) -> Void)?) {
        lock.withLock { observer = handler }
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
                                        facesPerSecond: faces, angles: latestAngles,
                                        latency: latencyCount > 0 ? latencySum / Double(latencyCount) : nil)
        frames = 0
        faces = 0
        latencySum = 0
        latencyCount = 0
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
        let captured = captureUptime(sampleBuffer)
        let (head, speed) = orientation(captured)
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

        let arrival = ProcessInfo.processInfo.systemUptime
        lock.lock()
        frames += 1
        latencySum += arrival - captured
        latencyCount += 1
        lastLatency = arrival - captured
        if let face {
            faces += 1
            let position = camera.headPosition(face: face.boundingBox)
            spread.add(position, at: time)
            latestAngles = SIMD3(face.yaw?.doubleValue ?? .nan, face.pitch?.doubleValue ?? .nan, face.roll?.doubleValue ?? .nan)
            trackNeck(face: measuredBox(face), head: head, speed: speed, time: captured, arrival: arrival)
        }
        let phase = currentPhase
        let observer = observer
        let turn = lastTurn
        let accepted = lastAccepted
        lock.unlock()

        if let observer {
            let observation = CameraObservation(face: face?.boundingBox, landmarks: face.map(landmarkPoints) ?? [],
                                                neckOffset: neckOffset(), turn: turn, accepted: face != nil && accepted)
            Task { @MainActor in observer(observation) }
        }

        let headColumns = String(format: "%.5f,%.5f,%.5f,%.5f", head.real, head.imag.x, head.imag.y, head.imag.z)
        guard let face else {
            record("\(String(format: "%.4f", time)),\(phase),,,,,,,,,,,,,,,,,,,\(headColumns)")
            return
        }
        let box = face.boundingBox
        let position = camera.headPosition(face: box)
        let degree = 180 / Double.pi
        let features = landmarkColumns(face)
        let outline = faceOutline(face)
        record(String(format: "%.4f,%@,%.5f,%.5f,%.5f,%.5f,%.4f,%.4f,%.4f,%.1f,%.1f,%.1f,%.3f,%@,%@,%.5f,%.1f", time, phase,
                      box.midX, box.midY, box.width, box.height, position.x, position.y, position.z,
                      (face.yaw?.doubleValue ?? .nan) * degree, (face.pitch?.doubleValue ?? .nan) * degree,
                      (face.roll?.doubleValue ?? .nan) * degree, face.confidence, features, headColumns,
                      outline?.width ?? .nan, (outline?.roll ?? .nan) * degree))
    }

    private func captureUptime(_ sampleBuffer: CMSampleBuffer) -> Double {
        let now = ProcessInfo.processInfo.systemUptime
        let stamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let host = CMSyncConvertTime(stamp, from: session.synchronizationClock ?? CMClockGetHostTimeClock(), to: CMClockGetHostTimeClock())
        let seconds = CMTimeGetSeconds(host)
        guard seconds.isFinite, now - seconds >= 0, now - seconds < 0.5 else { return now }
        return seconds
    }

    private func trackNeck(face: CGRect, head: simd_quatd, speed: Double, time: Double, arrival: Double) {
        let turn = head.yawPitch
        let yaw = remainder(turn.yaw, 2 * .pi)
        let pitch = referencePitch.map { turn.pitch - $0 } ?? 0
        lastTurn = SIMD2(yaw, pitch)
        lastAccepted = false
        holding = holding ? abs(yaw) > Self.resumeYaw : abs(yaw) > Self.holdYaw
        guard speed < Self.maxTrackedSpeed, !holding, abs(pitch) < Self.holdPitch else {
            lastFaceTime = time
            recentNecks.removeAll()
            lastRawZ = nil
            return
        }
        var raw = estimator.neckPosition(face: face, yaw: yaw, pitch: pitch)
        if let lastRawZ, abs(raw.z / lastRawZ - 1) > Self.maxDepthJump, rejectedInRow < 3 {
            raw.z = lastRawZ
            rejectedInRow += 1
        } else {
            lastRawZ = raw.z
            rejectedInRow = 0
        }
        recentNecks.append(raw)
        if recentNecks.count > 3 { recentNecks.removeFirst() }
        let neck = median(recentNecks)
        smoother.add(neck, dt: lastFaceTime > 0 ? min(time - lastFaceTime, 0.05) : 0.033)
        lastFaceTime = time
        lastAccepted = true
        guard let smoothed = smoother.value else { return }
        let value = deadband.follow(smoothed)
        previousEstimate = latestEstimate
        latestEstimate = (arrival, value)
        if speed < Self.referenceSpeed, abs(yaw) < Self.referenceYaw {
            captureReference(value, pitch: turn.pitch, time: time)
        }
    }

    private func median(_ values: [SIMD3<Double>]) -> SIMD3<Double> {
        func middle(_ axis: [Double]) -> Double { axis.sorted()[axis.count / 2] }
        return SIMD3(middle(values.map(\.x)), middle(values.map(\.y)), middle(values.map(\.z)))
    }

    private func captureReference(_ value: SIMD3<Double>, pitch: Double, time: Double) {
        guard referenceNeck == nil, let start = referenceWindowStart, time >= start else { return }
        referenceSamples.append(value)
        referencePitchSamples.append(pitch)
        guard time >= start + Self.referenceWindowSeconds, referenceSamples.count >= 10 else { return }
        referenceNeck = referenceSamples.reduce(.zero, +) / Double(referenceSamples.count)
        referencePitch = referencePitchSamples.reduce(0, +) / Double(referencePitchSamples.count)
        log(String(format: "camera: reference captured from %d frames", referenceSamples.count))
    }

    /// Запоминает опорное положение головы заново: через `delay` секунд усредняет оценку за секунду.
    /// Кадры во время быстрых поворотов в опору не попадают.
    func resetReference(after delay: Double) {
        lock.withLock {
            carry = currentOffset()
            carryStart = ProcessInfo.processInfo.systemUptime
            generation += 1
            referenceNeck = nil
            referencePitch = nil
            referenceSamples = []
            referencePitchSamples = []
            referenceWindowStart = ProcessInfo.processInfo.systemUptime + delay
        }
    }

    /// Сдвиг шеи от опорного положения в осях камеры, метры; ноль, пока опоры нет. Между кадрами
    /// камеры значение плавно ведётся от предыдущей оценки к последней за один интервал кадра.
    func neckOffset() -> SIMD3<Double> {
        lock.withLock { currentOffset() }
    }

    /// Растёт при каждой смене опоры: по нему отрисовка понимает, от какого поворота головы считать дугу глаз.
    var referenceGeneration: Int {
        lock.withLock { generation }
    }

    private func currentOffset() -> SIMD3<Double> {
        let fade = max(0, 1 - (ProcessInfo.processInfo.systemUptime - carryStart) / Self.carrySeconds)
        return carry * fade + referencedOffset()
    }

    private func referencedOffset() -> SIMD3<Double> {
        guard let referenceNeck, let latest = latestEstimate else { return .zero }
        var current = latest.value
        var interval = 1.0 / 30
        if let previous = previousEstimate, latest.time > previous.time {
            interval = latest.time - previous.time
            let fraction = min(max((ProcessInfo.processInfo.systemUptime - latest.time) / interval, 0), 1)
            current = previous.value + (latest.value - previous.value) * fraction
        }
        if !holding {
            current = leadCompensated(current, speed: smoother.speed, lead: lastLatency + min(interval, 0.1))
        }
        let offset = current - referenceNeck
        let length = simd_length(offset)
        return length > Self.maxOffset ? offset * (Self.maxOffset / length) : offset
    }

    private func faceOutline(_ face: VNFaceObservation) -> FaceOutline? {
        let box = face.boundingBox
        func points(_ region: VNFaceLandmarkRegion2D?) -> [CGPoint] {
            (region?.normalizedPoints ?? []).map { CGPoint(x: box.minX + $0.x * box.width, y: box.minY + $0.y * box.height) }
        }
        return FaceOutline(leftEye: points(face.landmarks?.leftEye), rightEye: points(face.landmarks?.rightEye),
                           contour: points(face.landmarks?.faceContour), aspect: camera.aspect)
    }

    private func measuredBox(_ face: VNFaceObservation) -> CGRect {
        let box = face.boundingBox
        guard let outline = faceOutline(face) else { return box }
        return outline.equivalentBox(center: CGPoint(x: box.midX, y: box.midY), aspect: camera.aspect)
    }

    private func landmarkPoints(_ face: VNFaceObservation) -> [CGPoint] {
        let box = face.boundingBox
        return (face.landmarks?.allPoints?.normalizedPoints ?? []).map {
            CGPoint(x: box.minX + $0.x * box.width, y: box.minY + $0.y * box.height)
        }
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
                                           contents: "time,phase,cx,cy,w,h,x,y,z,yaw,pitch,roll,confidence,eyes,contour,nosex,nosey,eyex,eyey,qw,qx,qy,qz,outline,outlineroll\n".data(using: .utf8))
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
