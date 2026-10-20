import AVFoundation
import RayDeskCore
import RayDeskLocalization
import simd

enum CameraFrameVerdict {
    case accepted
    case learning
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
    /// Уменьшенный кадр камеры для окна обводки.
    var frameImage: RGBAImage?
    /// Клетки сетки выученной формы в долях кадра, начало внизу слева.
    var gridPoints: [CGPoint] = []
    /// Точки выученной формы в долях кадра, начало внизу слева.
    var shapePoints: [CGPoint] = []
    /// Сколько кадров вошло в форму очков.
    var learnedFrames = 0
    var glassesNote: String?
    var calibrationSample: GuidedCameraCalibration.Sample?
    var referenceGeneration: Int = 0
}

struct CameraHeadReading {
    var position: SIMD3<Double>?
    var jitter: SIMD3<Double>?
    var framesPerSecond: Int
    var facesPerSecond: Int
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
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "raydesk.camera-head", qos: .userInitiated)
    private let lock = NSLock()
    private var spread = RollingSpread(window: 1)
    private var frames = 0
    private var faces = 0
    private var lastReadingTime = ProcessInfo.processInfo.systemUptime
    private var settledNeck = SettledPosition()
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
    private var observers: [Int: @MainActor (CameraObservation) -> Void] = [:]
    private var calibrationObserver: (@MainActor (CameraObservation) -> Void)?
    private var guidedCalibrationActive = false
    private var glassesVision: GlassesVision?
    private var glassesFound = 0
    private var glassesScore: Double?
    private static let glassesMaxSpeed = 90 * Double.pi / 180
    /// Позиция держится, пока очки видны: модель шеи валидна до 60° поворота, качество кадра
    /// страхует порог совпадения формы, поэтому пороги угла щедрые — боковые экраны должны трекаться.
    private static let glassesHold = SIMD2(60 * Double.pi / 180, 60 * Double.pi / 180)
    private static let glassesResume = SIMD2(55 * Double.pi / 180, 55 * Double.pi / 180)
    private var headingCorrector = CameraYawCorrector()
    private var faceYawScale = FaceYawScale()
    private var lastRotationSource: String?
    private var lastHeadingFrame: Double?
    private var lastFaceHeading = -Double.infinity
    private static let coastSeconds = 1.0
    private var headingCorrection = 0.0
    private var motionDetector = CameraMotionDetector()
    private var motionFrameCounter = 0
    private var cameraMovingUntil = 0.0
    private var cameraMovingFlag = false
    private var motionHits = 0
    private var lastHeadSpeed = 0.0
    private var cameraWasMoving = false
    private var lastCameraMotionLog = 0.0
    private static let cameraMotionHold = 0.7
    /// Сколько подряд замеров должны показать движение фона, чтобы считать, что поехала камера.
    private static let cameraMotionConfirm = 2
    /// Быстрее этой скорости головы движение фона — это поворот головы и перекрытие лица, а не поездка камеры.
    private static let cameraMotionHeadSpeed = 12 * Double.pi / 180
    private var headingPausedForCamera = false
    private var pendingHeadingReanchor = false
    private var lastFaceBox: (minX: Double, minY: Double, maxX: Double, maxY: Double)?
    private var lastFaceBoxTime = 0.0
    /// Доворачивает мир вокруг вертикали на заданный угол, радианы; так камера поправляет уплывание курса.
    var turnWorld: ((Double) -> Void)?
    private var recording = false
    /// Писать ли покадровые записи камеры (`glasses-*.csv`) в `~/Library/Logs/RayDesk-imu`.
    var recordsFrames: Bool {
        get { lock.withLock { recording } }
        set { lock.withLock { recording = newValue } }
    }
    private var glassesFile: FileHandle?
    private var glassesRows: [String] = []
    private static let maxOffset = 0.5
    private static let maxDepthJump = 0.12
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
    ///
    /// - Parameters:
    ///   - id: имя подписчика: повторная подписка под тем же именем заменяет прежнюю.
    ///   - handler: что делать с распознаванием.
    func addObserver(_ id: String, _ handler: @escaping @MainActor (CameraObservation) -> Void) {
        lock.withLock { observers[id.hashValue] = handler }
    }

    /// Отписывает одного подписчика.
    ///
    /// - Parameter id: имя, под которым подписывались.
    func removeObserver(_ id: String) {
        lock.withLock { observers[id.hashValue] = nil }
    }

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
            headingPausedForCamera = false
            pendingHeadingReanchor = false
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
            glassesLearner.reset()
            faceYawScale = FaceYawScale(scale: result.yawScale)
            headingCorrector = CameraYawCorrector()
            lastHeadingFrame = nil
            lastFaceHeading = -.infinity
            headingPausedForCamera = false
            pendingHeadingReanchor = false
            generation += 1
            guidedCalibrationActive = false
            if result.checkedTurns {
                log(String(format: "camera guided calibration applied: scale %.3f return error %.2f°", result.yawScale, result.returnError * 180 / .pi))
            } else {
                log("camera guided calibration applied: center reference; yaw scale 1.000, turns not measured")
            }
        }
    }

    var isRunning: Bool { session.isRunning }

    /// Двигается ли камера вместе с ноутбуком прямо сейчас: видно по сдвигу фона в кадре.
    ///
    /// Пока это `true`, камерные оценки курса и положения головы не применяются: они
    /// описывают движение ноутбука, а не головы.
    var cameraIsMoving: Bool { lock.withLock { cameraMovingFlag } }

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
            try? self.glassesFile?.close()
            self.glassesFile = nil
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
                                        facesPerSecond: rate(faces),
                                        latency: latencyCount > 0 ? latencySum / Double(latencyCount) : nil,
                                        glassesPerSecond: glasses ? rate(glassesFound) : nil, glassesScore: glasses ? glassesScore : nil,
                                        headingDrift: now - lastFaceHeading < 0.2 ? headingCorrector.drift : nil,
                                        headingAge: now - lastFaceHeading, headingCorrection: headingCorrection,
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
        configureCamera()
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
        log(String(format: "camera: %@ %dx%d", device.localizedName, dimensions.width, dimensions.height))
    }

    /// Настраивает камеру под неподвижный кадр: без Center Stage. Иначе система сама кадрирует
    /// и двигает зум под лицо, и на каждом повороте головы кадр пересобирается — лицо теряется,
    /// а оценка позы уезжает.
    private func configureCamera() {
        if #available(macOS 12.3, *) {
            AVCaptureDevice.centerStageControlMode = .app
            AVCaptureDevice.isCenterStageEnabled = false
            log("camera: center stage off")
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let captured = captureUptime(sampleBuffer)
        updateCameraMotion(pixels)
        let (head, speed) = orientation(captured)
        lock.withLock { lastHeadSpeed = speed }
        guard let vision = lock.withLock({ glassesVision }) else { return }
        sendToGlasses(vision, pixels: pixels, captured: captured, head: head, speed: speed)
    }

    /// Раз в несколько кадров сравнивает фон с предыдущим кадром: пока голова поворачивается,
    /// комната в кадре стоит, а когда едет ноутбук — сдвигается весь фон.
    private func updateCameraMotion(_ pixels: CVPixelBuffer) {
        motionFrameCounter += 1
        guard motionFrameCounter % 3 == 0, let samples = lumaSamples(pixels) else { return }
        guard lock.withLock({ lastHeadSpeed }) < Self.cameraMotionHeadSpeed else {
            motionHits = 0
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        var excluding: MotionRegion?
        if let box = lastFaceBox, now - lastFaceBoxTime < 1.5 {
            let width = Double(CameraMotionDetector.width), height = Double(CameraMotionDetector.height)
            let pad = 6
            excluding = MotionRegion(minX: max(0, Int(box.minX * width) - pad),
                                     minY: max(0, Int((1 - box.maxY) * height) - pad),
                                     maxX: min(CameraMotionDetector.width, Int(box.maxX * width) + pad),
                                     maxY: min(CameraMotionDetector.height, Int((1 - box.minY) * height) + pad))
        }
        let moved = motionDetector.update(luma: samples, excluding: excluding)
        motionHits = moved ? motionHits + 1 : 0
        if motionHits >= Self.cameraMotionConfirm { cameraMovingUntil = now + Self.cameraMotionHold }
        let moving = now < cameraMovingUntil
        if moving != cameraWasMoving {
            cameraWasMoving = moving
            log(moving
                ? String(format: "camera motion: background moves, shift %d,%d, improvement %.2f", motionDetector.shift.x, motionDetector.shift.y, motionDetector.improvement)
                : "camera motion: background still")
        } else if moving, now - lastCameraMotionLog > 1 {
            lastCameraMotionLog = now
            log(String(format: "camera motion: shift %d,%d, improvement %.2f, still difference %.2f",
                       motionDetector.shift.x, motionDetector.shift.y, motionDetector.improvement, motionDetector.stillDifference))
        }
        lock.withLock { cameraMovingFlag = moving }
    }

    /// Уменьшает кадр камеры до `CameraMotionDetector` и переводит в яркость.
    private func lumaSamples(_ pixels: CVPixelBuffer) -> [UInt8]? {
        guard CVPixelBufferGetPixelFormatType(pixels) == kCVPixelFormatType_32BGRA else { return nil }
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixels) else { return nil }
        let width = CVPixelBufferGetWidth(pixels)
        let height = CVPixelBufferGetHeight(pixels)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixels)
        let targetWidth = CameraMotionDetector.width
        let targetHeight = CameraMotionDetector.height
        guard width >= targetWidth, height >= targetHeight else { return nil }
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        var samples = [UInt8](repeating: 0, count: targetWidth * targetHeight)
        for y in 0..<targetHeight {
            let sourceRow = bytes + (y * height / targetHeight) * bytesPerRow
            for x in 0..<targetWidth {
                let pixel = sourceRow + (x * width / targetWidth) * 4
                let blue = Int(pixel[0]), green = Int(pixel[1]), red = Int(pixel[2])
                samples[y * targetWidth + x] = UInt8((77 * red + 150 * green + 29 * blue) >> 8)
            }
        }
        return samples
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
        let cameraMoving = lock.withLock { cameraMovingFlag }
        receiveGlasses(vision.track(pixels: pixels, head: head, generation: lock.withLock { generation },
                                    cameraMoving: cameraMoving),
                       captured: captured, head: head, speed: speed)
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
        let reliableFace = frame?.face == true && (frame?.score ?? 0) >= 0.75 && lastLatency >= 0 && lastLatency < 0.2
        let cameraMoving = cameraMovingFlag
        if let points = frame?.landmarks, let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(),
           let minY = points.map(\.y).min(), let maxY = points.map(\.y).max() {
            lastFaceBox = (minX, minY, maxX, maxY)
            lastFaceBoxTime = captured
        }
        if !guidedCalibrationActive && (frame?.rotationSource != lastRotationSource || !reliableFace) {
            faceYawScale.interrupt()
        }
        lastRotationSource = frame?.rotationSource
        var faceTurn: SIMD2<Double>?
        if let faceRotation = frame?.faceRotation {
            var turn = headTurn(fromCameraRotation: simd_double3x3(faceRotation))
            if !guidedCalibrationActive, !cameraMoving, reliableFace, cameraDirection != nil, abs(turn.y) < 20 * Double.pi / 180 {
                faceYawScale.add(time: captured, gyroYaw: head.yawPitch.yaw, faceYaw: turn.x)
            } else if !guidedCalibrationActive { faceYawScale.interrupt() }
            turn.x /= faceYawScale.scale
            faceTurn = turn
        }
        if !guidedCalibrationActive {
            trackNeck(head: head, speed: speed, time: captured, arrival: arrival, cameraMoving: cameraMoving,
                      cameraTurn: faceTurn ?? frame?.turn ?? SIMD2(Double.nan, .nan)) { yaw, pitch in
                (cameraDirection != nil || reliableFace) ? frame?.glasses.map { neckPosition(fromGlasses: $0, yaw: yaw, pitch: pitch, roll: head.sideTilt) } : nil
            }
        }
        if !guidedCalibrationActive, cameraMoving {
            if !headingPausedForCamera {
                headingPausedForCamera = true
                pendingHeadingReanchor = true
                headingCorrector.reset()
                lastHeadingFrame = nil
                lastFaceHeading = -.infinity
                faceYawScale.interrupt()
                log("camera motion: heading and parallax frozen")
            }
        } else if headingPausedForCamera {
            headingPausedForCamera = false
        }
        var headingStep = 0.0
        if !guidedCalibrationActive, headingPausedForCamera || pendingHeadingReanchor {
            if !cameraMoving, pendingHeadingReanchor, reliableFace, let faceTurn, cameraDirection != nil,
               lastVerdict == .accepted, speed < headingCorrector.stillSpeed,
               abs(faceTurn.x) < headingCorrector.maxTurn, abs(faceTurn.y) < headingCorrector.maxTurn {
                let anchored = remainder(head.yawPitch.yaw - faceTurn.x, 2 * .pi)
                cameraDirection = anchored
                headingCorrector.reset()
                lastHeadingFrame = captured
                lastFaceHeading = captured
                pendingHeadingReanchor = false
                rebaseNeck()
                log(String(format: "camera motion: heading re-anchored, camera at yaw %.1f°", anchored * 180 / .pi))
            } else {
                lastHeadingFrame = nil
            }
        } else if !guidedCalibrationActive, reliableFace, let faceTurn, let cameraDirection, lastVerdict == .accepted,
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
        let observers = self.observers
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
        if observer != nil || calibrationObserver != nil || !observers.isEmpty {
            let points = frame?.landmarks ?? []
            var face: CGRect?
            if let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(),
               let minY = points.map(\.y).min(), let maxY = points.map(\.y).max() {
                face = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
            }
            let note: String = if frame?.face != true { t(.cameraNoteNoFace) }
                else if let frame, frame.shapePoints == 0 && frame.learnedFrames == 0 { t(.cameraNoteShapeNotLearned) }
                else if let frame, frame.glasses == nil && frame.shapePoints == 0 { String(format: t(.cameraNoteLearningShape), frame.learnedFrames) }
                else if let score = frame?.score { String(format: t(.cameraNoteGlassesFound), score * 100) }
                else { t(.cameraNoteGlassesNotFound) }
            let axes = frame?.alignmentReady == true ? t(.cameraNoteAxesLinked) : t(.cameraNoteAxesLearning)
            let fullNote = frame?.rotationSource.isEmpty == false ? String(format: t(.cameraNoteRotation), note, frame!.rotationSource, axes) : note
            var observation = CameraObservation(face: face, landmarks: points, neckOffset: neckOffset(), turn: turn,
                                                verdict: verdict, glassesPoints: frame?.glassesPoints ?? [],
                                                frameImage: frame?.image,
                                                gridPoints: frame?.gridPoints ?? [], shapePoints: frame?.shapePointsInFrame ?? [],
                                                learnedFrames: frame?.learnedFrames ?? 0,
                                                glassesNote: fullNote)
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
            Task { @MainActor in
                observer?(update)
                calibrationObserver?(update)
                for handler in observers.values { handler(update) }
            }
        }
    }

    private func trackNeck(head: simd_quatd, speed: Double, time: Double, arrival: Double, cameraMoving: Bool,
                           cameraTurn: SIMD2<Double>, measure: (Double, Double) -> SIMD3<Double>?) {
        let before = currentOffset()
        let wasAccepted = lastAccepted
        defer {
            if lastAccepted != wasAccepted {
                carry = before - referencedOffset()
                carryStart = ProcessInfo.processInfo.systemUptime
            }
        }
        let turn = head.yawPitch
        let learning = cameraDirection == nil && !cameraMoving
        var yaw = cameraDirection.map { remainder(turn.yaw - $0, 2 * .pi) } ?? 0
        var pitch = referencePitch.map { turn.pitch - $0 } ?? 0
        yaw = cameraTurn.x.isFinite ? cameraTurn.x : yaw
        pitch = cameraTurn.y.isFinite ? cameraTurn.y : pitch
        let limit = holding ? Self.glassesResume : Self.glassesHold
        holding = learning ? abs(yaw) > 15 * .pi / 180 : (abs(yaw) > limit.x || abs(pitch) > limit.y)
        lastTurn = SIMD2(yaw, pitch)
        lastVerdict = if learning, !cameraTurn.x.isFinite || !cameraTurn.y.isFinite { .noFace }
            else if speed >= (learning ? 5 * Double.pi / 180 : Self.glassesMaxSpeed) { .fast }
            else if learning && abs(pitch) > 25 * Double.pi / 180 { .tilted }
            else if holding { .turned }
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
        let dt = lastFaceTime > 0 ? min(time - lastFaceTime, 0.05) : 0.033
        lastFaceTime = time
        let value = settledNeck.add(neck, time: time, headSpeed: speed)
        previousEstimate = wasAccepted ? latestEstimate : nil
        latestEstimate = (arrival, value)
        if learning, let start = referenceWindowStart, time >= start,
           let reference = glassesLearner.add(neck: neck, yaw: turn.yaw - yaw, pitch: turn.pitch - pitch, time: time) {
            cameraDirection = reference.cameraYaw
            referencePitch = reference.pitch
            referenceNeck = reference.neck
            settledNeck.reset(to: reference.neck)
            previousEstimate = nil
            latestEstimate = (arrival, reference.neck)
            log(String(format: "camera: reference captured, camera at yaw %.1f° pitch %.1f°",
                       reference.cameraYaw * 180 / .pi, reference.pitch * 180 / .pi))
        }
    }

    private func median(_ values: [SIMD3<Double>]) -> SIMD3<Double> {
        func middle(_ axis: [Double]) -> Double { axis.sorted()[axis.count / 2] }
        return SIMD3(middle(values.map(\.x)), middle(values.map(\.y)), middle(values.map(\.z)))
    }

    /// Перезапоминает положение шеи после того, как камера поехала: смещение от старой опоры
    /// плавно уходит в ноль, а не дёргает мир.
    private func rebaseNeck() {
        carry = currentOffset()
        carryStart = ProcessInfo.processInfo.systemUptime
        if let latest = latestEstimate {
            referenceNeck = latest.value
            settledNeck.reset(to: latest.value)
        } else {
            referenceNeck = nil
        }
        previousEstimate = nil
        recentNecks.removeAll()
        lastRaw = nil
        lastRawZ = nil
    }

    /// Запоминает опору заново: через `delay` секунд ждёт секунду, пока пользователь спокойно смотрит
    /// в камеру, и запоминает, где камера, наклон головы и положение шеи. До этого сдвиг нулевой.
    func resetReference(after delay: Double, geometryChanged: Bool = false) {
        lock.withLock {
            carry = currentOffset()
            carryStart = ProcessInfo.processInfo.systemUptime
            generation += 1
            referenceNeck = nil
            referencePitch = nil
            cameraDirection = nil
            holding = false
            glassesLearner.reset()
            settledNeck.reset()
            headingPausedForCamera = false
            pendingHeadingReanchor = false
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
            cameraDirection = cameraDirection.map { remainder($0 + yawChange, 2 * .pi) }
            generation += 1
            faceYawScale.interrupt()
            glassesLearner.reset()
            return glassesVision
        }
        vision?.worldYawChanged(by: yawChange)
    }

    /// Camera owns the heading reference until it is reset or tracking stops.
    /// Losing a visual sample must not hand the world to a different magnetic reference.
    /// Freshness still gates the camera correction itself in receiveGlasses.
    var correctsHeading: Bool {
        lock.withLock { guidedCalibrationActive || cameraDirection != nil }
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
        let offset = current - referenceNeck
        let length = simd_length(offset)
        return length > Self.maxOffset ? offset * (Self.maxOffset / length) : offset
    }

    enum CameraError: Error {
        case accessDenied
        case noCamera
    }
}
