import AVFoundation
import Vision
import RayDeskCore
import AprilTagTracking
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
    var calibrationSample: GuidedCameraCalibration.Sample?
    var referenceGeneration: Int = 0
    var headingOnly = false
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
    var headingDrift: Double?
    var headingAge: Double
    var headingCorrection: Double
    var headingRate: Double
    var faceYawScale: Double
}

final class CameraHeadTracker: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private var aprilEnabled = false
    private var aprilSize = 0.025
    private var aprilFOV = 70.0
    private let aprilCapture = AprilTagCapture()
    private var aprilRig = AprilTagRig()
    private var aprilAnchor = AprilTagAnchor()
    private var aprilMotion = AprilTagMotionGate()
    private var aprilComparison: (time: Double, tag: Double, head: Double, face: Double?)?
    private var aprilNote = "AprilTag: покажите ID 0"

    var aprilTagEnabled: Bool { lock.withLock { aprilEnabled } }
    var aprilTagStatus: String? { lock.withLock { aprilEnabled ? aprilNote : nil } }
    var aprilTagWorldOffset: SIMD3<Double>? { lock.withLock { aprilEnabled ? .zero : nil } }

    func useAprilTags(_ enabled: Bool, sizeMillimeters: Int, fieldOfView: Double) {
        lock.withLock {
            aprilEnabled = enabled
            aprilFOV = fieldOfView.isFinite && (40...120).contains(fieldOfView) ? fieldOfView : 70
            aprilSize = Double([15,20,25,30].contains(sizeMillimeters) ? sizeMillimeters : 25)/1000
            aprilNote = "AprilTag: покажите ID 0 и замрите на секунду"
        }
        resetReference(after: 0, geometryChanged: true)
        log("camera mode: \(enabled ? "apriltag" : "face/glasses"), tag36h11 black edge \(sizeMillimeters) mm")
    }

    private func receiveAprilTags(_ sample: CMSampleBuffer, captured: Double, head: simd_quatd, speed: Double,
                                  size: Double, fieldOfView: Double, expectedGeneration: Int) {
        let frame = aprilCapture.detect(sample, size: size, fieldOfView: fieldOfView)
        let arrival = ProcessInfo.processInfo.systemUptime
        lock.lock()
        guard aprilEnabled, generation == expectedGeneration else { lock.unlock(); return }
        frames += 1; latencySum += arrival-captured; latencyCount += 1; lastLatency = arrival-captured
        let fresh = lastLatency >= 0 && lastLatency < 0.2 && captured >= (referenceWindowStart ?? 0)
        let root = aprilRig.update(fresh ? frame.observations : [], time: captured)
        let motionAccepted = root.map { aprilMotion.accept(tag:$0.pose.rotation,head:head,time:captured) } ?? false
        let wasReady = aprilAnchor.ready
        let reading = aprilAnchor.update(pose: motionAccepted ? root?.pose : nil, time: captured, arrival: arrival, head: head, speed: speed)
        if root != nil { faces += 1 }
        if let root { spread.add(root.pose.position, at: Date().timeIntervalSinceReferenceDate) }
        if !wasReady && aprilAnchor.ready {
            log("apriltag diagnostic reference captured; known IDs \(aprilRig.knownIDs.sorted())")
        }
        // Diagnostic mode must never send optical estimates to the renderer or IMU.
        lastHeadingFrame = nil
        headingCorrector.reset()
        let target = reading?.targetYaw ?? .nan
        let error = remainder(target - head.yawPitch.yaw, 2 * .pi)
        var agreement = root != nil && !motionAccepted ? "поворот тега не подтверждён IMU" : "нет непрерывного замера"
        let residual = aprilMotion.residualDegrees ?? .nan
        log(String(format:"APRIL_GATE t=%.6f visible=%d accepted=%d residual3D=%.3f headQ=%.6f,%.6f,%.6f,%.6f applied=0",
                   captured,root != nil ? 1 : 0,motionAccepted ? 1 : 0,root != nil ? residual : .nan,
                   head.vector.x,head.vector.y,head.vector.z,head.vector.w))
        var tagDelta = Double.nan, imuDelta = Double.nan, faceDelta = Double.nan
        if let reading {
            if let previous = aprilComparison, captured > previous.time, captured-previous.time < 0.2 {
                tagDelta = remainder(reading.targetYaw-previous.tag,2 * .pi) * 180 / .pi
                imuDelta = remainder(head.yawPitch.yaw-previous.head,2 * .pi) * 180 / .pi
                if let face = frame.faceYaw, let oldFace = previous.face {
                    faceDelta = remainder(face-oldFace,2 * .pi) * 180 / .pi
                }
                let gyroAgrees = abs(tagDelta-imuDelta) <= 3
                // Face yaw sign/scale is not calibrated yet: compare motion magnitude only.
                let faceAgrees = faceDelta.isFinite && abs(abs(faceDelta)-abs(imuDelta)) <= 3
                agreement = !gyroAgrees ? "скачок тега — отклонить" :
                    faceAgrees ? "движение согласовано с IMU и лицом" : "IMU согласован · лицо не подтверждает"
            }
            aprilComparison = (captured,reading.targetYaw,head.yawPitch.yaw,frame.faceYaw)
        } else { aprilComparison = nil }
        log(String(format:"APRIL_COMPARE t=%.6f faceYaw=%.3f facePitch=%.3f faceConfidence=%.2f tagDelta=%.3f imuDelta=%.3f faceDelta=%.3f applied=0",
                   captured,(frame.faceYaw ?? .nan)*180 / .pi,(frame.facePitch ?? .nan)*180 / .pi,
                   frame.faceConfidence,tagDelta,imuDelta,faceDelta))
        let raw = root?.pose
        let q = raw?.rotation.vector ?? SIMD4<Double>(repeating: .nan)
        let position = raw?.position ?? SIMD3<Double>(repeating: .nan)
        log(String(format: "APRIL_DIAG t=%.6f fresh=%d ready=%d accepted=%d id=%d headYaw=%.3f targetYaw=%.3f error=%.3f speed=%.3f q=%.6f,%.6f,%.6f,%.6f p=%.4f,%.4f,%.4f applied=0",
                   captured, fresh ? 1 : 0, aprilAnchor.ready ? 1 : 0, reading != nil ? 1 : 0, root?.id ?? -1,
                   head.yawPitch.yaw * 180 / .pi, target * 180 / .pi, error * 180 / .pi, speed * 180 / .pi,
                   q.x,q.y,q.z,q.w,position.x,position.y,position.z))
        let visible = frame.observations.map(\.id).sorted()
        let state: String
        if !fresh { state = "кадр устарел — поправки остановлены" }
        else if root == nil { state = aprilAnchor.ready ? "опора не видна — положение удерживается" : "покажите ID 0" }
        else if !aprilAnchor.ready { state = "ID 0: замрите на секунду" }
        else if reading == nil { state = "замер отклонён — положение удерживается" }
        else { state = "слежение по ID \(root!.id)" }
        aprilNote = "AprilTag: ДИАГНОСТИКА · поправки выключены\nВидны: \(visible) · \(state) · \(agreement)\nОшибка курса: \(error.isFinite ? String(format: "%.1f°", error * 180 / .pi) : "—") · \(Int(size*1000)) мм · \(frame.intrinsics)"
        let observer = observer
        let note = aprilNote
        let offset = aprilAnchor.offset
        lock.unlock()
        if let observer {
            let observation = CameraObservation(face:nil,landmarks:[],neckOffset:offset,turn:.zero,
                verdict:reading != nil ? .accepted : .learning,glassesPoints:frame.points,glassesNote:note)
            Task { @MainActor in observer(observation) }
        }
    }

    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "raydesk.camera-head", qos: .userInitiated)
    private let lock = NSLock()
    private var spread = RollingSpread(window: 1)
    private var latestAngles: SIMD3<Double>?
    private var frames = 0
    private var faces = 0
    private var lastReadingTime = ProcessInfo.processInfo.systemUptime
    private var camera = FaceCamera(horizontalFieldOfView: CameraHeadTracker.assumedFieldOfView, aspect: 16.0 / 9)
    private var file: FileHandle?
    private var pending: [String] = []
    private var currentPhase = ""
    private var estimator = HeadPositionEstimator(camera: FaceCamera(horizontalFieldOfView: CameraHeadTracker.assumedFieldOfView, aspect: 16.0 / 9))
    private var smoother = OneEuroPositionFilter(minCutoff: SIMD3(1, 1, 0.05), beta: SIMD3(2, 2, 0.3))
    private var deadband = SoftDeadband(band: SIMD3(0.0015, 0.0015, 0.015))
    private var settledNeck = SettledPosition()
    private var smoothingGlasses = false
    private var recentNecks: [SIMD3<Double>] = []
    private var lastRawZ: Double?
    private var lastRaw: (time: Double, value: SIMD3<Double>)?
    private var jumpsInRow = 0
    private static let maxHeadSpeed = 1.5
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
    private var yawAnchor = CameraYawAnchor()
    private var yawCorrectionEnabled = false
    private var yawCorrectionTotal = 0.0
    private var glassesLearner = CameraReferenceLearner(window: 1, maxSpread: 3 * Double.pi / 180, minSamples: 20, maxPositionSpread: 0.02)
    private var latestEstimate: (time: Double, value: SIMD3<Double>)?
    private var previousEstimate: (time: Double, value: SIMD3<Double>)?
    private var latencySum = 0.0
    private var latencyCount = 0
    private var lastFaceTime = 0.0
    private var lastTurn = SIMD2<Double>(repeating: 0)
    private var lastAccepted = false
    private var lastVerdict = CameraFrameVerdict.noFace
    private var observer: (@MainActor (CameraObservation) -> Void)?
    private var calibrationObserver: (@MainActor (CameraObservation) -> Void)?
    private var guidedCalibrationActive = false
    private var glassesVision: GlassesVision?
    private var glassesFound = 0
    private var glassesScore: Double?
    private static let glassesMaxSpeed = 90 * Double.pi / 180
    private static let glassesHold = SIMD2(30 * Double.pi / 180, 35 * Double.pi / 180)
    private static let glassesResume = SIMD2(25 * Double.pi / 180, 30 * Double.pi / 180)
    private var faceHeading = FaceHeadingAnchor()
    private var holdsCenter = false
    var faceCentreEnabled: Bool { lock.withLock { !aprilEnabled && glassesVision == nil } }
    func setCenterHolding(_ enabled: Bool) {
        lock.withLock { holdsCenter = enabled; faceHeading.reset() }
    }
    var faceCentreStatus: String? {
        lock.withLock { !aprilEnabled && glassesVision == nil ? faceCentreNote : nil }
    }
    private var faceCentreNote: String {
        guard holdsCenter else { return "Лицо: только измерение" }
        switch faceHeading.state {
        case .waiting, .learning: return "Лицо: ожидаю устойчивый взгляд на камеру"
        case .holding: return "Лицо: удержание центра"
        case .missing: return "Лицо не видно однозначно — поправки остановлены"
        case .moving: return "Поворот головы — поправки остановлены"
        case .turned: return "Лицо отвёрнуто от опоры — поправки остановлены"
        case .stale: return "Кадр запоздал — поправки остановлены"
        case .recenter: return "Большое расхождение — выровняйте мир через R"
        }
    }
    private var headingCorrector = CameraYawCorrector()
    private var faceYawScale = FaceYawScale()
    private var lastRotationSource: String?
    private var lastHeadingFrame: Double?
    private var lastFaceHeading = -Double.infinity
    private static let coastSeconds = 1.0
    private var headingCorrection = 0.0
    /// Доворачивает мир вокруг вертикали на заданный угол, радианы; так камера поправляет уплывание курса.
    var turnWorld: ((Double) -> Void)?
    private var recording = false
    /// Писать ли покадровые записи камеры (`camera-*.csv`, `glasses-*.csv`) в `~/Library/Logs/RayDesk-imu`.
    var recordsFrames: Bool {
        get { lock.withLock { recording } }
        set { lock.withLock { recording = newValue } }
    }
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

    private let correctYaw: @Sendable (Double) -> Void

    init(orientation: @escaping @Sendable (Double) -> (orientation: simd_quatd, speed: Double),
         correctYaw: @escaping @Sendable (Double) -> Void) {
        self.orientation = orientation
        self.correctYaw = correctYaw
    }

    func disableYawCorrection() {
        lock.withLock {
            yawCorrectionEnabled = false
            yawAnchor.reset()
        }
    }

    var captureSession: AVCaptureSession { session }

    var yawCorrectionDegrees: Double { lock.withLock { yawCorrectionTotal * 180 / .pi } }

    /// Берёт положение головы по очкам со страницы `vision` вместо рамки лица Vision; `nil` возвращает Vision.
    func useGlasses(_ vision: GlassesVision?) {
        lock.withLock { glassesVision = vision }
    }

    /// Получает на главном потоке каждое распознавание: рамку, точки лица и сдвиг шеи.
    func observe(_ handler: (@MainActor (CameraObservation) -> Void)?) {
        lock.withLock { observer = handler }
    }

    func observeCalibration(_ handler: (@MainActor (CameraObservation) -> Void)?) {
        lock.withLock { calibrationObserver = handler }
    }

    func beginGuidedCalibration() -> Int {
        lock.withLock {
            guidedCalibrationActive = true
            lastHeadingFrame = nil
            return generation
        }
    }

    func cancelGuidedCalibration() {
        lock.withLock {
            guidedCalibrationActive = false
            lastHeadingFrame = nil
            lastFaceHeading = -.infinity
            faceYawScale.interrupt()
        }
    }

    func applyGuidedCalibration(_ result: GuidedCameraCalibration.Result) {
        lock.withLock {
            carry = currentOffset()
            carryStart = ProcessInfo.processInfo.systemUptime
            cameraDirection = result.cameraYaw
            referencePitch = result.cameraPitch
            referenceNeck = result.neck
            settledNeck.reset(to: result.neck)
            latestEstimate = (ProcessInfo.processInfo.systemUptime, result.neck)
            previousEstimate = nil
            recentNecks.removeAll()
            lastRaw = nil
            lastRawZ = nil
            holding = false
            learner.reset()
            glassesLearner.reset()
            faceYawScale = FaceYawScale(scale: result.yawScale)
            headingCorrector = CameraYawCorrector()
            lastHeadingFrame = nil
            lastFaceHeading = -.infinity
            generation += 1
            guidedCalibrationActive = false
            if result.checkedTurns {
                log(String(format: "camera guided calibration applied: scale %.3f return error %.2f°", result.yawScale, result.returnError * 180 / .pi))
            } else {
                log("camera guided calibration applied: center reference; yaw scale 1.000, turns not measured")
            }
        }
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
                    if self.recordsFrames { self.openFile() }
                    self.session.startRunning()
                    Task { @MainActor in completion(nil) }
                } catch {
                    Task { @MainActor in completion(error) }
                }
            }
        }
    }

    func stop() {
        disableYawCorrection()
        setCenterHolding(false)
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
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = max(now - lastReadingTime, 0.001)
        lastReadingTime = now
        func rate(_ count: Int) -> Int { Int((Double(count) / elapsed).rounded()) }
        let glasses = glassesVision != nil
        let reading = CameraHeadReading(position: spread.mean, jitter: spread.deviation, framesPerSecond: rate(frames),
                                        facesPerSecond: rate(faces), angles: glasses ? nil : latestAngles,
                                        latency: latencyCount > 0 ? latencySum / Double(latencyCount) : nil,
                                        glassesPerSecond: glasses ? rate(glassesFound) : nil, glassesScore: glasses ? glassesScore : nil,
                                        headingDrift: now - lastFaceHeading < 0.2 ? (glasses ? headingCorrector.drift : faceHeading.error) : nil, headingAge: now - lastFaceHeading, headingCorrection: headingCorrection,
                                        headingRate: headingCorrector.driftRate, faceYawScale: faceYawScale.scale)
        headingCorrection = 0
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
        let tagConfig = lock.withLock { (aprilEnabled, aprilSize, generation, aprilFOV) }
        if tagConfig.0 {
            receiveAprilTags(sampleBuffer, captured: captured, head: head, speed: speed,
                             size: tagConfig.1, fieldOfView: tagConfig.3, expectedGeneration: tagConfig.2)
            return
        }
        if let vision = lock.withLock({ glassesVision }) {
            sendToGlasses(vision, pixels: pixels, captured: captured, head: head, speed: speed)
            return
        }
        let handler = VNImageRequestHandler(cvPixelBuffer: pixels, options: [:])
        let rectangles = VNDetectFaceRectanglesRequest()
        try? handler.perform([rectangles])
        let time = Date().timeIntervalSinceReferenceDate
        var face = rectangles.results?.count == 1 ? rectangles.results?.first : nil
        if let found = face {
            let landmarks = VNDetectFaceLandmarksRequest()
            landmarks.inputFaceObservations = [found]
            try? handler.perform([landmarks])
            face = landmarks.results?.first ?? found
        }

        let arrival = ProcessInfo.processInfo.systemUptime
        lock.lock()
        guard !aprilEnabled, glassesVision == nil, generation == tagConfig.2 else { lock.unlock(); return }
        frames += 1
        latencySum += arrival - captured
        latencyCount += 1
        lastLatency = arrival - captured
        if let face {
            faces += 1
            let position = camera.headPosition(face: face.boundingBox)
            spread.add(position, at: time)
            latestAngles = SIMD3(face.yaw?.doubleValue ?? .nan, face.pitch?.doubleValue ?? .nan, face.roll?.doubleValue ?? .nan)
        }
        let eligible = face.map { $0.confidence >= 0.8 && !isFaceCropped($0.boundingBox) } ?? false
        let measuredTurn = eligible ? face.flatMap { observation -> SIMD2<Double>? in
            guard let yaw = observation.yaw?.doubleValue, let pitch = observation.pitch?.doubleValue else { return nil }
            return SIMD2(yaw,pitch)
        } : nil
        let wasReady = faceHeading.ready
        let headingStep = holdsCenter && captured >= (referenceWindowStart ?? 0)
            ? faceHeading.update(face:measuredTurn,headYaw:head.yawPitch.yaw,speed:speed,time:captured,arrival:arrival) : 0
        headingCorrection += headingStep
        if faceHeading.state == .holding { lastFaceHeading = captured }
        if !wasReady && faceHeading.ready { log("face centre reference captured") }
        lastTurn = measuredTurn ?? .zero
        lastVerdict = switch faceHeading.state {
        case .holding: .accepted
        case .waiting, .learning: .learning
        case .moving: .fast
        case .turned, .recenter: .turned
        case .missing, .stale: .noFace
        }
        let note = faceCentreNote
        let measured = measuredTurn ?? SIMD2<Double>(repeating:.nan)
        if recording {
            log(String(format:"FACE_CENTER t=%.6f faceYaw=%.3f facePitch=%.3f headYaw=%.3f error=%.3f step=%.5f state=%@",
                       captured,measured.x*180 / .pi,measured.y*180 / .pi,head.yawPitch.yaw*180 / .pi,
                       (faceHeading.error ?? .nan)*180 / .pi,headingStep*180 / .pi,faceHeading.state.rawValue))
        }
        let phase = currentPhase
        let observer = observer
        let turn = lastTurn
        let verdict = face == nil ? CameraFrameVerdict.noFace : lastVerdict
        lock.unlock()

        if headingStep != 0 { turnWorld?(headingStep) }
        if let observer {
            let observation = CameraObservation(face: face?.boundingBox, landmarks: face.map(landmarkPoints) ?? [],
                                                neckOffset: .zero, turn: turn, verdict: verdict, glassesNote: note, headingOnly: true)
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
        guard !aprilEnabled else { lock.unlock(); return }
        latencySum += arrival - captured
        latencyCount += 1
        lastLatency = arrival - captured
        if frame?.face == true { faces += 1 }
        glassesScore = frame?.score
        if let glasses = frame?.glasses {
            glassesFound += 1
            spread.add(glasses, at: Date().timeIntervalSinceReferenceDate)
        }
        let reliableFace = frame?.face == true && (frame?.score ?? 0) >= 0.75 && lastLatency >= 0 && lastLatency < 0.2
        if !guidedCalibrationActive && (frame?.rotationSource != lastRotationSource || !reliableFace) {
            faceYawScale.interrupt()
        }
        lastRotationSource = frame?.rotationSource
        var faceTurn: SIMD2<Double>?
        if let faceRotation = frame?.faceRotation {
            var turn = headTurn(fromCameraRotation: simd_double3x3(faceRotation))
            if !guidedCalibrationActive, reliableFace, cameraDirection != nil, abs(turn.y) < 20 * Double.pi / 180 {
                faceYawScale.add(time: captured, gyroYaw: head.yawPitch.yaw, faceYaw: turn.x)
            } else if !guidedCalibrationActive { faceYawScale.interrupt() }
            turn.x /= faceYawScale.scale
            faceTurn = turn
        }
        if !guidedCalibrationActive {
            trackNeck(cropped: false, head: head, speed: speed, time: captured, arrival: arrival,
                      cameraTurn: faceTurn ?? frame?.turn ?? SIMD2(Double.nan, .nan)) { yaw, pitch in
                (cameraDirection != nil || reliableFace) ? frame?.glasses.map { neckPosition(fromGlasses: $0, yaw: yaw, pitch: pitch, roll: head.sideTilt) } : nil
            }
        }
        var headingStep = 0.0
        if !guidedCalibrationActive, reliableFace, let faceTurn, let cameraDirection, lastVerdict == .accepted,
           abs(faceTurn.x) < headingCorrector.maxTurn, abs(faceTurn.y) < headingCorrector.maxTurn,
           speed < headingCorrector.measureSpeed {
            let dt = lastHeadingFrame.map { min(captured - $0, 0.2) } ?? 0
            headingStep = headingCorrector.step(headYaw: head.yawPitch.yaw, cameraYaw: cameraDirection,
                                                faceTurn: faceTurn, dt: dt, headSpeed: speed)
            headingCorrection += headingStep
            lastHeadingFrame = captured
            if abs(faceTurn.x) < headingCorrector.maxTurn,
               abs(faceTurn.y) < headingCorrector.maxTurn, speed < headingCorrector.measureSpeed {
                lastFaceHeading = captured
            }
        } else if !guidedCalibrationActive, cameraDirection != nil, let last = lastHeadingFrame, captured - lastFaceHeading < Self.coastSeconds {
            headingStep = headingCorrector.coast(dt: min(captured - last, 0.2))
            headingCorrection += headingStep
            lastHeadingFrame = captured
        } else {
            lastHeadingFrame = nil
        }
        faceYawScale.worldYawChanged(by: headingStep)
        let observer = observer
        let calibrationObserver = calibrationObserver
        let referenceGeneration = generation
        let turn = lastTurn
        let verdict = lastVerdict
        let vision = glassesVision
        let turnWorld = turnWorld
        lock.unlock()
        if headingStep != 0 {
            turnWorld?(headingStep)
            vision?.worldYawChanged(by: headingStep)
        }
        recordGlasses(frame, verdict: verdict, captured: captured, head: head, speed: speed, headingStep: headingStep)
        if observer != nil || calibrationObserver != nil {
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
            var observation = CameraObservation(face: face, landmarks: points, neckOffset: neckOffset(), turn: turn,
                                                verdict: verdict, glassesPoints: frame?.glassesPoints ?? [], glassesNote: fullNote)
            observation.referenceGeneration = referenceGeneration
            if let faceRotation = frame?.faceRotation, let position = frame?.glasses, frame?.face == true {
                let rawTurn = headTurn(fromCameraRotation: simd_double3x3(faceRotation))
                let headTurn = head.yawPitch
                observation.calibrationSample = .init(time: captured, face: face, turn: rawTurn,
                    head: SIMD2(headTurn.yaw, headTurn.pitch),
                    neck: neckPosition(fromGlasses: position, yaw: rawTurn.x, pitch: rawTurn.y, roll: head.sideTilt),
                    speed: speed, quality: frame?.score ?? 0, latency: arrival - captured)
            }
            let update = observation
            Task { @MainActor in observer?(update); calibrationObserver?(update) }
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
            let limit = holding ? Self.glassesResume : Self.glassesHold
            holding = learning ? abs(yaw) > 15 * .pi / 180 : (abs(yaw) > limit.x || abs(pitch) > limit.y)
        } else {
            holding = !learning && (holding ? abs(yaw) > Self.resumeYaw : abs(yaw) > Self.holdYaw)
        }
        lastTurn = SIMD2(yaw, pitch)
        let maxSpeed = cameraTurn == nil ? Self.maxTrackedSpeed : Self.glassesMaxSpeed
        lastVerdict = if cropped { .cropped }
            else if learning, let cameraTurn, !cameraTurn.x.isFinite || !cameraTurn.y.isFinite { .noFace }
            else if speed >= (learning ? 5 * Double.pi / 180 : maxSpeed) { .fast }
            else if learning && abs(pitch) > 25 * Double.pi / 180 { .tilted }
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
            lastRaw = nil
            settledNeck.interrupt()
            if learning {
                learner.reset()
                glassesLearner.reset()
            }
            return
        }
        if let lastRaw, simd_distance(raw, lastRaw.value) > Self.maxHeadSpeed * max(time - lastRaw.time, 1.0 / 30), jumpsInRow < 3 {
            raw = lastRaw.value
            jumpsInRow += 1
        } else {
            lastRaw = (time, raw)
            jumpsInRow = 0
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
        smoothingGlasses = cameraTurn != nil
        let dt = lastFaceTime > 0 ? min(time - lastFaceTime, 0.05) : 0.033
        lastFaceTime = time
        let value: SIMD3<Double>
        if smoothingGlasses {
            value = settledNeck.add(neck, time: time, headSpeed: speed)
        } else {
            smoother.add(neck, dt: dt)
            guard let smoothed = smoother.value else { return }
            value = deadband.follow(smoothed)
        }
        previousEstimate = wasAccepted ? latestEstimate : nil
        latestEstimate = (arrival, value)
        if learning, let start = referenceWindowStart, time >= start,
           let reference = cameraTurn == nil ? learner.add(neck: value, yaw: turn.yaw, pitch: turn.pitch, time: time)
                : glassesLearner.add(neck: neck, yaw: turn.yaw - yaw, pitch: turn.pitch - pitch, time: time) {
            cameraDirection = reference.cameraYaw
            referencePitch = reference.pitch
            referenceNeck = reference.neck
            if cameraTurn != nil {
                settledNeck.reset(to: reference.neck)
                previousEstimate = nil
                latestEstimate = (arrival, reference.neck)
            }
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
    func resetReference(after delay: Double, geometryChanged: Bool = false) {
        lock.withLock {
            carry = currentOffset()
            carryStart = ProcessInfo.processInfo.systemUptime
            generation += 1
            yawAnchor.reset()
            yawCorrectionTotal = 0
            faceHeading.reset()
            aprilRig.reset(); aprilAnchor = AprilTagAnchor(); aprilComparison = nil; aprilMotion = AprilTagMotionGate()
            referenceNeck = nil
            referencePitch = nil
            cameraDirection = nil
            holding = false
            learner.reset()
            glassesLearner.reset()
            settledNeck.reset()
            if geometryChanged {
                faceYawScale = FaceYawScale()
                headingCorrector = CameraYawCorrector()
            } else {
                faceYawScale.interrupt()
                headingCorrector.reset()
            }
            lastRotationSource = nil
            lastFaceHeading = -.infinity
            lastHeadingFrame = nil
            referenceWindowStart = ProcessInfo.processInfo.systemUptime + delay
        }
    }

    private func recordGlasses(_ frame: GlassesFrame?, verdict: CameraFrameVerdict, captured: Double, head: simd_quatd, speed: Double, headingStep: Double) {
        guard recordsFrames else { return }
        if glassesFile == nil {
            let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/RayDesk-imu")
            let url = directory.appendingPathComponent("glasses-\(Int(Date().timeIntervalSinceReferenceDate)).csv")
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: url.path, contents: "time,captured,face,x,y,z,score,turnyaw,turnpitch,source,aligned,neckx,necky,neckz,verdict,speed,qw,qx,qy,qz,facedepth,fqw,fqx,fqy,fqz,pairs,residual,cameraYawStep,faceYawScale,headingAge,headingError,referenceID,cameraFOV\n".data(using: .utf8))
            glassesFile = try? FileHandle(forWritingTo: url)
            glassesFile?.seekToEndOfFile()
            log("glasses recording: \(url.lastPathComponent)")
        }
        let diagnostics = lock.withLock {
            String(format: ",%.5f,%.5f,%.4f,%.4f,%d,%.1f", headingStep * 180 / .pi,
                   faceYawScale.scale, captured - lastFaceHeading,
                   (headingCorrector.drift ?? .nan) * 180 / .pi, generation, GlassesVision.fieldOfView * 180 / .pi)
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
                                    frame?.alignmentPairs ?? 0, (frame?.alignmentResidual ?? .nan) * 180 / .pi) + diagnostics)
        if glassesRows.count >= 30 {
            glassesFile?.write((glassesRows.joined(separator: "\n") + "\n").data(using: .utf8)!)
            glassesRows.removeAll(keepingCapacity: true)
        }
    }

    /// Мир повернули на `yawChange` радиан (плюс — влево): направление на камеру поворачивается вместе
    /// с ним, положение шеи остаётся прежним.
    func worldYawChanged(by yawChange: Double) {
        let vision = lock.withLock {
            // Manual alignment establishes a new face reference, rather than undoing R afterwards.
            if !aprilEnabled && glassesVision == nil {
                faceHeading.reset()
                referenceWindowStart = ProcessInfo.processInfo.systemUptime + 0.3
            }
            cameraDirection = cameraDirection.map { remainder($0 + yawChange, 2 * .pi) }
            yawAnchor.worldYawChanged(by: yawChange)
            aprilAnchor.rotateWorld(by: yawChange)
            aprilMotion.rotateWorld(by: yawChange)
            generation += 1
            faceYawScale.interrupt()
            learner.reset()
            glassesLearner.reset()
            return glassesVision
        }
        vision?.worldYawChanged(by: yawChange)
    }

    /// Camera owns the heading reference until it is reset or tracking stops.
    /// Losing a visual sample must not hand the world to a different magnetic reference.
    /// Freshness still gates the camera correction itself in receiveGlasses.
    var correctsHeading: Bool {
        lock.withLock { !aprilEnabled && (glassesVision == nil ? holdsCenter : (guidedCalibrationActive || cameraDirection != nil)) }
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
        if !holding && !smoothingGlasses {
            current = leadCompensated(current, speed: smoother.speed, lead: lastLatency + min(interval, 0.1))
        }
        let offset = current - referenceNeck
        let length = simd_length(offset)
        return length > Self.maxOffset ? offset * (Self.maxOffset / length) : offset
    }

    /// Подпись поворота лица не зависит от сдвига рамки и её масштаба.
    private func yawPose(_ face: VNFaceObservation) -> CameraYawAnchor.Pose? {
        guard !isFaceCropped(face.boundingBox), face.confidence >= 0.9,
              face.boundingBox.width > 0.12,
              let yaw = face.yaw?.doubleValue, let pitch = face.pitch?.doubleValue,
              let roll = face.roll?.doubleValue,
              let left = face.landmarks?.leftEye, let right = face.landmarks?.rightEye,
              let nose = face.landmarks?.noseCrest else { return nil }
        func center(_ region: VNFaceLandmarkRegion2D) -> SIMD2<Double>? {
            guard region.pointCount > 0 else { return nil }
            return region.normalizedPoints.reduce(SIMD2<Double>.zero) {
                $0 + SIMD2(Double($1.x), Double($1.y))
            } / Double(region.pointCount)
        }
        guard let l = center(left), let r = center(right), let n = center(nose) else { return nil }
        let eyeLine = r - l
        let squared = simd_length_squared(eyeLine)
        guard squared > 0.01 else { return nil }
        let relativeNose = simd_dot(n - (l + r) / 2, eyeLine) / squared
        return .init(yaw: yaw, pitch: pitch, roll: roll, nose: relativeNose)
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
