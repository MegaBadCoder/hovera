import CoreGraphics
import CoreVideo
import Foundation
import RayDeskCore
import simd

/// Что нашлось на одном кадре камеры.
struct GlassesFrame {
    /// Модель лица нашла лицо.
    var face: Bool
    /// Середина выученной формы очков в осях камеры, метры: x — вправо по кадру, y — вверх, z — от камеры.
    /// `nil`, если формы нет, идёт обучение или очки потеряны.
    var glasses: SIMD3<Double>?
    /// Доля совпадения формы с кадром от 0 до 1.
    var score: Double?
    /// Сколько кадров вошло в форму очков при обучении.
    var learnedFrames: Int
    /// Сколько точек в выученной форме.
    var shapePoints: Int
    /// Точки лица для окна отладки, доли кадра, начало внизу слева.
    var landmarks: [CGPoint]
    /// Точки формы очков там, где их нашёл трекер, доли кадра, начало внизу слева.
    var glassesPoints: [CGPoint]
    /// Поворот головы от положения «лицом к камере», радианы: x — влево, y — вверх.
    var turn: SIMD2<Double>? = nil
    /// Откуда взят поворот головы: модель лица, гироскоп или оба.
    var rotationSource = ""
    /// Связь осей гироскопа и камеры выучена.
    var alignmentReady = false
    /// Сколько пар поворотов накоплено для связи осей и их расхождение, радианы.
    var alignmentPairs = 0
    var alignmentResidual = Double.nan
    /// Поворот головы по модели лица от опорного кадра формы.
    var faceRotation: simd_quatd?
    /// Глубина по модели лица, метры.
    var faceDepth: Double?
}

/// Положение очков по кадру камеры: модель лица, выученная форма очков и трекер по ней.
///
/// `track` вызывается в потоке камеры, обучение включается с главного. Форма очков хранится
/// в `~/Library/Application Support/RayDesk/glasses-shape.plist`.
final class GlassesVision: @unchecked Sendable {
    private let lock = NSLock()
    private var mesh: FaceMesh?
    private var shape: GlassesShape?
    private var kept: [SIMD3<Double>] = []
    private var probes: [SIMD3<Double>] = []
    private var learning = false
    private var lastFit: SimilarityFit?
    private var tracker = GlassesTracker()
    private var classifier: SkinClassifier?
    private var alignment = CameraAlignment()
    private var anchor: (face: simd_double3x3, imu: simd_quatd)?
    private static let faceBlend = 0.15
    private static let depthBiasBlend = 0.05
    private var depthBias = 0.0
    private static let maskWidth = 320
    private static let fieldOfView = 70 * Double.pi / 180
    private static let templeSpan = 0.14

    /// Модель загружена и можно слать кадры.
    var isReady: Bool { lock.withLock { mesh != nil } }

    /// Загружает модель лица и выученную форму; `ready` вызывается сразу после.
    func start(ready: (() -> Void)? = nil) {
        lock.withLock {
            if mesh == nil {
                mesh = FaceMesh()
                log(mesh == nil ? "glasses vision: face model not found" : "glasses vision: face model ready (CoreML)")
                if let data = try? Data(contentsOf: Self.shapeURL),
                   let saved = try? PropertyListDecoder().decode(GlassesShape.self, from: data) {
                    use(saved)
                    log("glasses vision: shape loaded, \(kept.count) points")
                } else {
                    log("glasses vision: no learned glasses shape yet")
                }
            }
        }
        ready?()
    }

    /// Начинает учить форму очков заново: пользователь смотрит в камеру и медленно крутит головой.
    func startLearning() async {
        lock.withLock {
            learning = true
            shape = nil
            kept = []
            probes = []
            tracker.reset()
        }
    }

    /// Заканчивает обучение и сохраняет форму.
    ///
    /// - Returns: число точек в форме; `nil`, если форма не набралась.
    func stopLearning() async -> Int? {
        let learned: GlassesShape? = lock.withLock {
            learning = false
            guard let shape else { return nil }
            use(shape)
            return shape
        }
        guard let learned else { return nil }
        do {
            try FileManager.default.createDirectory(at: Self.shapeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            try encoder.encode(learned).write(to: Self.shapeURL)
        } catch {
            log("glasses vision: saving shape failed: \(error)")
        }
        return lock.withLock { kept.count }
    }

    /// Мир повернули на `angle` радиан вокруг вертикали: связь осей гироскопа и камеры поворачивается следом.
    func worldYawChanged(by angle: Double) {
        lock.withLock {
            alignment.worldYawChanged(by: angle)
            let turn = simd_quatd(angle: angle, axis: SIMD3(0, 1, 0))
            anchor = anchor.map { ($0.face, turn * $0.imu) }
        }
    }

    /// Обрабатывает кадр камеры в формате BGRA.
    ///
    /// - Parameters:
    ///   - pixels: кадр.
    ///   - head: ориентация очков по гироскопу в момент съёмки кадра.
    func track(pixels: CVPixelBuffer, head: simd_quatd) -> GlassesFrame? {
        lock.lock()
        defer { lock.unlock() }
        guard let mesh else { return nil }
        let width = Double(CVPixelBufferGetWidth(pixels)), height = Double(CVPixelBufferGetHeight(pixels))
        let focal = width / 2 / tan(Self.fieldOfView / 2)
        let landmarks = mesh.landmarks(in: pixels)
        let image = Self.downscale(pixels, width: Self.maskWidth)
        let scale = width / Double(image.width)
        var frame = GlassesFrame(face: landmarks != nil, glasses: nil, score: nil, learnedFrames: shape?.frames ?? 0,
                                 shapePoints: kept.count, landmarks: [], glassesPoints: [])
        guard let landmarks else {
            lastFit = nil
            return trackWithoutFace(image: image, scale: scale, head: head, width: width, height: height, focal: focal, frame: frame)
        }
        frame.landmarks = landmarks.prefix(FaceMeshPoint.surfaceCount).map { CGPoint(x: $0.x / width, y: 1 - $0.y / height) }
        let small = landmarks.map { $0 / scale }
        classifier = SkinClassifier.sampled(from: image, landmarks: small) ?? classifier
        if learning {
            if shape == nil {
                let span = simd_distance(landmarks[FaceMeshPoint.sides.0], landmarks[FaceMeshPoint.sides.1])
                shape = GlassesShape(landmarks: landmarks, depth: focal * Self.templeSpan / span)
            }
            guard var learned = shape, let classifier else { return frame }
            let fit = learned.fit(landmarks: landmarks, previous: lastFit)
            lastFit = fit
            alignment.add(face: fit.rotation, imu: head)
            let oval = faceOvalMask(landmarks: small, width: image.width, height: image.height)
            let box = glassesSearchBox(landmarks: small, width: image.width, height: image.height)
            let bridge = small[FaceMeshPoint.noseBridge]
            if let glasses = findGlasses(in: image, box: box, classifier: classifier, anchor: SIMD2(bridge.x, bridge.y), oval: oval) {
                learned.accumulate(fit: fit, glasses: glasses, oval: oval, scale: scale, width: image.width)
                shape = learned
            }
            frame.learnedFrames = learned.frames
            return frame
        }
        guard let shape, let classifier, !kept.isEmpty else { return frame }
        let fit = shape.fit(landmarks: landmarks, previous: lastFit)
        lastFit = fit
        alignment.add(face: fit.rotation, imu: head)
        var rotation = fit.rotation
        frame.rotationSource = "лицо"
        if let anchor, let predicted = alignment.predict(anchorFace: anchor.face, anchorIMU: anchor.imu, imu: head) {
            rotation = simd_double3x3(simd_slerp(simd_quatd(predicted), simd_quatd(fit.rotation), Self.faceBlend))
            frame.rotationSource = "гироскоп + лицо"
        }
        anchor = (rotation, head)
        frame.turn = headTurn(fromCameraRotation: rotation)
        frame.faceRotation = simd_quatd(fit.rotation)
        frame.faceDepth = shape.referenceDepth / fit.scale
        describeAlignment(&frame)
        let oval = faceOvalMask(landmarks: small, width: image.width, height: image.height)
        return place(tracker.track(image: image, scale: scale, rotation: rotation, start: fit, kept: kept, probes: probes,
                                   classifier: classifier, probeArea: oval),
                     shape: shape, width: width, height: height, focal: focal, frame: frame)
    }

    private func describeAlignment(_ frame: inout GlassesFrame) {
        frame.alignmentReady = alignment.rotation != nil
        frame.alignmentPairs = alignment.pairCount
        frame.alignmentResidual = alignment.residual
    }

    private func trackWithoutFace(image: RGBAImage, scale: Double, head: simd_quatd, width: Double, height: Double,
                                  focal: Double, frame: GlassesFrame) -> GlassesFrame {
        var frame = frame
        guard !learning, let shape, let classifier, !kept.isEmpty, let anchor,
              let rotation = alignment.predict(anchorFace: anchor.face, anchorIMU: anchor.imu, imu: head)
        else { return frame }
        frame.rotationSource = "гироскоп"
        frame.turn = headTurn(fromCameraRotation: rotation)
        describeAlignment(&frame)
        return place(tracker.track(image: image, scale: scale, rotation: rotation, start: nil, kept: kept, probes: probes,
                                   classifier: classifier), shape: shape, width: width, height: height, focal: focal, frame: frame)
    }

    private func place(_ result: GlassesTracker.Result?, shape: GlassesShape, width: Double, height: Double, focal: Double,
                       frame: GlassesFrame) -> GlassesFrame {
        var frame = frame
        guard let result else { return frame }
        let glassesDepth = shape.referenceDepth / result.scale
        var depth = glassesDepth + depthBias
        if let faceDepth = frame.faceDepth {
            depthBias += (faceDepth - glassesDepth - depthBias) * Self.depthBiasBlend
            depth = faceDepth
        }
        if let turn = frame.turn { depth = depthCorrectedForTurn(depth, turn: turn) }
        frame.glasses = SIMD3((result.center.x - width / 2) * depth / focal, -(result.center.y - height / 2) * depth / focal, depth)
        frame.score = result.score
        frame.glassesPoints = Swift.stride(from: 0, to: result.projected.count, by: 3).map {
            CGPoint(x: result.projected[$0].x / width, y: 1 - result.projected[$0].y / height)
        }
        return frame
    }

    private func use(_ learned: GlassesShape) {
        shape = learned
        kept = learned.keptPoints()
        probes = learned.probes(for: kept)
        lastFit = nil
        anchor = nil
        tracker.reset()
    }

    private static func downscale(_ pixels: CVPixelBuffer, width: Int) -> RGBAImage {
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        let sourceWidth = CVPixelBufferGetWidth(pixels), sourceHeight = CVPixelBufferGetHeight(pixels)
        let step = Double(sourceWidth) / Double(width)
        let height = Int((Double(sourceHeight) / step).rounded())
        var out = [UInt8](repeating: 255, count: width * height * 4)
        guard let source = CVPixelBufferGetBaseAddress(pixels)?.assumingMemoryBound(to: UInt8.self) else {
            return RGBAImage(width: width, height: height, pixels: out)
        }
        let row = CVPixelBufferGetBytesPerRow(pixels)
        for y in 0..<height {
            for x in 0..<width {
                var sum = SIMD3<Int>(0, 0, 0)
                for (dx, dy) in [(0.25, 0.25), (0.75, 0.25), (0.25, 0.75), (0.75, 0.75)] {
                    let sx = min(sourceWidth - 1, Int((Double(x) + dx) * step)), sy = min(sourceHeight - 1, Int((Double(y) + dy) * step))
                    let p = source + sy * row + sx * 4
                    sum &+= SIMD3(Int(p[2]), Int(p[1]), Int(p[0]))
                }
                let i = (y * width + x) * 4
                out[i] = UInt8(sum.x / 4)
                out[i + 1] = UInt8(sum.y / 4)
                out[i + 2] = UInt8(sum.z / 4)
            }
        }
        return RGBAImage(width: width, height: height, pixels: out)
    }

    private static var shapeURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/RayDesk/glasses-shape.plist")
    }
}
