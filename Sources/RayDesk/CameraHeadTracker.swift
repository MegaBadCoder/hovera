import AVFoundation
import Vision
import RayDeskCore
import simd

enum CameraFrameVerdict {
    case accepted
    case learning
    case cropped
    case turned
    case tilted
    case fast
    case noFace
}

struct CameraObservation {
    var face: CGRect?
    var landmarks: [CGPoint]
    var neckOffset: SIMD3<Double>
    var turn: SIMD2<Double>
    var verdict: CameraFrameVerdict
    var glassesPoints: [CGPoint] = []
    var glassesNote: String?
}

struct CameraHeadReading {
    var position: SIMD3<Double>?
    var jitter: SIMD3<Double>?
    var framesPerSecond: Int
    var facesPerSecond: Int
    var angles: SIMD3<Double>?
    var latency: Double?
    var glassesPerSecond: Int?
    var glassesScore: Double?
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
    private var smoother = OneEuroPositionFilter(minCutoff: SIMD3(1, 1, 0.05), beta: SIMD3(2, 2, 0.3))
    private var deadband = SoftDeadband(band: SIMD3(0.0015, 0.0015, 0.015))
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
    private var cameraDirection: Double?
    private var referenceWindowStart: Double?
    private var learner = CameraReferenceLearner()
    private var glassesLearner = CameraReferenceLearner(window: 0.3, maxSpread: 25 * Double.pi / 180, minSamples: 8)
    private var latestEstimate: (time: Double, value: SIMD3<Double>)?
    private var previousEstimate: (time: Double, value: SIMD3<Double>)?
    private var latencySum = 0.0
    private var latencyCount = 0
    private var lastFaceTime = 0.0
    private var lastTurn = SIMD2<Double>(repeating: 0)
    private var lastAccepted = false
    private var lastVerdict = CameraFrameVerdict.noFace
    private var observer: (@MainActor (CameraObservation) -> Void)?
    private var glassesVision: GlassesVision?
    private var glassesFound = 0
    private var glassesScore: Double?
    private static let glassesMaxSpeed = 90 * Double.pi / 180
    private var glassesFile: FileHandle?
    private var glassesRows: [String] = []
    private static let maxOffset = 0.5
    private static let maxDepthJump = 0.12
    private static let holdYaw = 20 * Double.pi / 180
    private static let resumeYaw = 15 * Double.pi / 180
    private static let holdPitch = 38 * Double.pi / 180
    private static let maxTrackedSpeed = 30 * Double.pi / 180
    private static let referenceSpeed = 10 * Double.pi / 180
    private static let carrySeconds = 1.0
    private let orientation: @Sendable (Double) -> (orientation: simd_quatd, speed: Double)

    init(orientation: @escaping @Sendable (Double) -> (orientation: simd_quatd, speed: Double)) {
        self.orientation = orientation
    }

    var captureSession: AVCaptureSession { session }

    /// Берёт положение головы по очкам со страницы `vision` вместо рамки лица Vision; `nil` возвращает Vision.
    func useGlasses(_ vision: GlassesVision?) {
        lock.withLock { glassesVision = vision }
    }

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
        let glasses = glassesVision != nil
        let reading = CameraHeadReading(position: spread.mean, jitter: spread.deviation, framesPerSecond: frames,
                                        facesPerSecond: faces, angles: glasses ? nil : latestAngles,
                                        latency: latencyCount > 0 ? latencySum / Double(latencyCount) : nil,
                                        glassesPerSecond: glasses ? glassesFound : nil, glassesScore: glasses ? glassesScore : nil)
        frames = 0
        faces = 0
        glassesFound = 0
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
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
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
        if let vision = lock.withLock({ glassesVision }) {
            sendToGlasses(vision, pixels: pixels, captured: captured, head: head, speed: speed)
            return
        }
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
            let box = measuredBox(face)
            trackNeck(cropped: isFaceCropped(face.boundingBox), head: head, speed: speed, time: captured, arrival: arrival) {
                [estimator] yaw, pitch in estimator.neckPosition(face: box, yaw: yaw, pitch: pitch)
            }
        }
        let phase = currentPhase
        let observer = observer
        let turn = lastTurn
        let verdict = face == nil ? CameraFrameVerdict.noFace : lastVerdict
        lock.unlock()

        if let observer {
            let observation = CameraObservation(face: face?.boundingBox, landmarks: face.map(landmarkPoints) ?? [],
                                                neckOffset: neckOffset(), turn: turn, verdict: verdict)
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

    private func sendToGlasses(_ vision: GlassesVision, pixels: CVPixelBuffer, captured: Double, head: simd_quatd, speed: Double) {
        lock.withLock { frames += 1 }
        receiveGlasses(vision.track(pixels: pixels, head: head), captured: captured, head: head, speed: speed)
    }

    private func receiveGlasses(_ frame: GlassesFrame?, captured: Double, head: simd_quatd, speed: Double) {
        let arrival = ProcessInfo.processInfo.systemUptime
        lock.lock()
        latencySum += arrival - captured
        latencyCount += 1
        lastLatency = arrival - captured
        if frame?.face == true { faces += 1 }
        glassesScore = frame?.score
        if let glasses = frame?.glasses {
            glassesFound += 1
            spread.add(glasses, at: Date().timeIntervalSinceReferenceDate)
        }
        trackNeck(cropped: false, head: head, speed: speed, time: captured, arrival: arrival,
                  cameraTurn: frame?.turn ?? SIMD2(Double.nan, .nan)) { yaw, pitch in
            frame?.glasses.map { neckPosition(fromGlasses: $0, yaw: yaw, pitch: pitch) }
        }
        let observer = observer
        let turn = lastTurn
        let verdict = lastVerdict
        lock.unlock()
        recordGlasses(frame, verdict: verdict, captured: captured, head: head, speed: speed)
        if let observer {
            let points = frame?.landmarks ?? []
            var face: CGRect?
            if let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(),
               let minY = points.map(\.y).min(), let maxY = points.map(\.y).max() {
                face = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
            }
            let note: String = if frame?.face != true { "лицо не найдено" }
                else if let frame, frame.shapePoints == 0 && frame.learnedFrames == 0 { "форма очков не выучена: меню → «Выучить форму очков»" }
                else if let frame, frame.glasses == nil && frame.shapePoints == 0 { "учу форму очков: кадров \(frame.learnedFrames)" }
                else if let score = frame?.score { String(format: "очки найдены, совпадение формы %.0f%%", score * 100) }
                else { "очки не найдены" }
            let axes = frame?.alignmentReady == true ? "оси гироскопа и камеры связаны"
                : "оси гироскопа и камеры учатся: покрутите головой влево-вправо и вверх-вниз"
            let fullNote = frame?.rotationSource.isEmpty == false ? "\(note) · поворот: \(frame!.rotationSource) · \(axes)" : note
            let observation = CameraObservation(face: face, landmarks: points, neckOffset: neckOffset(), turn: turn,
                                                verdict: verdict, glassesPoints: frame?.glassesPoints ?? [], glassesNote: fullNote)
            Task { @MainActor in observer(observation) }
        }
    }

    private func trackNeck(cropped: Bool, head: simd_quatd, speed: Double, time: Double, arrival: Double,
                           cameraTurn: SIMD2<Double>? = nil, measure: (Double, Double) -> SIMD3<Double>?) {
        let before = currentOffset()
        let wasAccepted = lastAccepted
        defer {
            if lastAccepted != wasAccepted {
                carry = before - referencedOffset()
                carryStart = ProcessInfo.processInfo.systemUptime
            }
        }
        let turn = head.yawPitch
        let learning = cameraDirection == nil
        var yaw = cameraDirection.map { remainder(turn.yaw - $0, 2 * .pi) } ?? 0
        var pitch = referencePitch.map { turn.pitch - $0 } ?? 0
        if let cameraTurn {
            yaw = cameraTurn.x.isFinite ? cameraTurn.x : yaw
            pitch = cameraTurn.y.isFinite ? cameraTurn.y : pitch
            holding = false
        } else {
            holding = !learning && (holding ? abs(yaw) > Self.resumeYaw : abs(yaw) > Self.holdYaw)
        }
        lastTurn = SIMD2(yaw, pitch)
        let maxSpeed = cameraTurn == nil ? Self.maxTrackedSpeed : Self.glassesMaxSpeed
        lastVerdict = if cropped { .cropped }
            else if speed >= (learning && cameraTurn == nil ? Self.referenceSpeed : maxSpeed) { .fast }
            else if holding { .turned }
            else if cameraTurn == nil && abs(pitch) >= Self.holdPitch { .tilted }
            else if learning { .learning }
            else { .accepted }
        lastAccepted = lastVerdict == .accepted || lastVerdict == .learning
        let measured = lastAccepted ? measure(yaw, pitch) : nil
        if lastAccepted && measured == nil {
            lastVerdict = .noFace
            lastAccepted = false
        }
        guard lastAccepted, var raw = measured else {
            lastFaceTime = time
            recentNecks.removeAll()
            lastRawZ = nil
            if learning {
                learner.reset()
                glassesLearner.reset()
            }
            return
        }
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
        guard let smoothed = smoother.value else { return }
        let value = deadband.follow(smoothed)
        previousEstimate = wasAccepted ? latestEstimate : nil
        latestEstimate = (arrival, value)
        if learning, let start = referenceWindowStart, time >= start,
           let reference = cameraTurn == nil ? learner.add(neck: value, yaw: turn.yaw, pitch: turn.pitch, time: time)
                : glassesLearner.add(neck: value, yaw: turn.yaw, pitch: turn.pitch, time: time) {
            cameraDirection = remainder(reference.cameraYaw - (cameraTurn?.x.isFinite == true ? yaw : 0), 2 * .pi)
            referencePitch = reference.pitch - (cameraTurn?.y.isFinite == true ? pitch : 0)
            referenceNeck = reference.neck
            log(String(format: "camera: reference captured, camera at yaw %.1f° pitch %.1f°",
                       reference.cameraYaw * 180 / .pi, reference.pitch * 180 / .pi))
        }
    }

    private func median(_ values: [SIMD3<Double>]) -> SIMD3<Double> {
        func middle(_ axis: [Double]) -> Double { axis.sorted()[axis.count / 2] }
        return SIMD3(middle(values.map(\.x)), middle(values.map(\.y)), middle(values.map(\.z)))
    }

    /// Запоминает опору заново: через `delay` секунд ждёт секунду, пока пользователь спокойно смотрит
    /// в камеру, и запоминает, где камера, наклон головы и положение шеи. До этого сдвиг нулевой.
    func resetReference(after delay: Double) {
        lock.withLock {
            carry = currentOffset()
            carryStart = ProcessInfo.processInfo.systemUptime
            generation += 1
            referenceNeck = nil
            referencePitch = nil
            cameraDirection = nil
            holding = false
            learner.reset()
            glassesLearner.reset()
            referenceWindowStart = ProcessInfo.processInfo.systemUptime + delay
        }
    }

    private func recordGlasses(_ frame: GlassesFrame?, verdict: CameraFrameVerdict, captured: Double, head: simd_quatd, speed: Double) {
        if glassesFile == nil {
            let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/RayDesk-imu")
            let url = directory.appendingPathComponent("glasses-\(Int(Date().timeIntervalSinceReferenceDate)).csv")
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: url.path, contents: "time,captured,face,x,y,z,score,turnyaw,turnpitch,source,aligned,neckx,necky,neckz,verdict,speed,qw,qx,qy,qz,facedepth,fqw,fqx,fqy,fqz,pairs,residual\n".data(using: .utf8))
            glassesFile = try? FileHandle(forWritingTo: url)
            glassesFile?.seekToEndOfFile()
            log("glasses recording: \(url.lastPathComponent)")
        }
        let neck = neckOffset()
        let (glasses, turn) = (frame?.glasses, frame?.turn)
        glassesRows.append(String(format: "%.4f,%.4f,%d,%.4f,%.4f,%.4f,%.3f,%.2f,%.2f,%@,%d,%.4f,%.4f,%.4f,%@,%.1f,%.5f,%.5f,%.5f,%.5f",
                                  Date().timeIntervalSinceReferenceDate, captured, frame?.face == true ? 1 : 0,
                                  glasses?.x ?? .nan, glasses?.y ?? .nan, glasses?.z ?? .nan, frame?.score ?? .nan,
                                  (turn?.x ?? .nan) * 180 / .pi, (turn?.y ?? .nan) * 180 / .pi, frame?.rotationSource ?? "",
                                  frame?.alignmentReady == true ? 1 : 0, neck.x, neck.y, neck.z, "\(verdict)", speed * 180 / .pi,
                                  head.real, head.imag.x, head.imag.y, head.imag.z)
                           + String(format: ",%.4f,%.5f,%.5f,%.5f,%.5f,%d,%.2f", frame?.faceDepth ?? .nan,
                                    frame?.faceRotation?.real ?? .nan, frame?.faceRotation?.imag.x ?? .nan,
                                    frame?.faceRotation?.imag.y ?? .nan, frame?.faceRotation?.imag.z ?? .nan,
                                    frame?.alignmentPairs ?? 0, (frame?.alignmentResidual ?? .nan) * 180 / .pi))
        if glassesRows.count >= 30 {
            glassesFile?.write((glassesRows.joined(separator: "\n") + "\n").data(using: .utf8)!)
            glassesRows.removeAll(keepingCapacity: true)
        }
    }

    /// Мир повернули на `yawChange` радиан (плюс — влево): направление на камеру поворачивается вместе
    /// с ним, положение шеи остаётся прежним.
    func worldYawChanged(by yawChange: Double) {
        let vision = lock.withLock {
            cameraDirection = cameraDirection.map { remainder($0 + yawChange, 2 * .pi) }
            generation += 1
            return glassesVision
        }
        vision?.worldYawChanged(by: yawChange)
    }

    /// Где камера в мире, радианы, плюс — влево; `nil`, пока опора не запомнена.
    var cameraYaw: Double? {
        lock.withLock { cameraDirection }
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
        return outline.equivalentBox(center: outline.center, aspect: camera.aspect)
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
