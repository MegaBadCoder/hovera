import CoreGraphics
import CoreVideo
import Foundation
import RayDeskCore
import RayDeskLocalization
import simd

/// Что нашлось на одном кадре камеры.
struct GlassesFrame {
    /// Уменьшенный кадр для показа в окне: то же поле зрения, что у формы.
    var image: RGBAImage?
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
    /// Клетки сетки формы в кадре, доли кадра, начало внизу слева: по ним видно, что именно выучено.
    var gridPoints: [CGPoint] = []
    /// Точки выученной формы в кадре, доли кадра, начало внизу слева.
    var shapePointsInFrame: [CGPoint] = []
    /// Номер настройки камеры, при смене которой кадр пересчитывается.
    var generation: Int = 0
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
    private var autoDetect = true
    private var lastFit: SimilarityFit?
    private var tracker = GlassesTracker()
    private var classifier: SkinClassifier?
    private var alignment = CameraAlignment()
    private var savedAlignmentPairs = 0
    private static let alignmentKey = "cameraAlignment.v1"
    private var anchor: (face: simd_double3x3, imu: simd_quatd)?
    private var context: GlassesFrameContext?
    private var cameraGeneration = 0
    private var describedGrid: [CGPoint] = []
    private var describedKept: [CGPoint] = []
    private var describedAt: CGPoint?
    private var describedSize: (width: Int, height: Int)?
    private static let faceBlend = 0.15
    private static let depthBiasBlend = 0.05
    private var depthBias = 0.0
    private static let maskWidth = 320
    /// Угол обзора камеры по горизонтали, радианы: задаёт масштаб движений вперёд-назад.
    static var fieldOfView: Double {
        (UserDefaults.standard.object(forKey: "cameraFieldOfView") as? Double ?? 70) * .pi / 180
    }
    private static let templeSpan = 0.14

    /// Модель загружена и можно слать кадры.
    var isReady: Bool { lock.withLock { mesh != nil } }

    /// Загружает модель лица и выученную форму; `ready` вызывается сразу после.
    func start(ready: (() -> Void)? = nil) {
        lock.withLock {
            if mesh == nil {
                if let saved = UserDefaults.standard.array(forKey: Self.alignmentKey) as? [Double], saved.count == 4 {
                    alignment = CameraAlignment(prior: simd_double3x3(simd_quatd(ix: saved[1], iy: saved[2], iz: saved[3], r: saved[0])))
                    log("glasses vision: gyro-camera alignment restored from the last launch")
                }
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

    /// Кадр, на котором можно рисовать: последний, где лицо нашлось и идёт обучение.
    ///
    /// - Parameter generation: номер настройки камеры, который ждёт окно.
    /// - Returns: `nil`, если обучение выключено, лица не было или камера перенастроена.
    func freeze(generation: Int) -> GlassesFrameContext? {
        lock.withLock { learning && cameraGeneration == generation ? context : nil }
    }

    /// Учитывает обведённый контур как эталонный кадр и сводит вынос линзы.
    ///
    /// - Parameters:
    ///   - contour: вершины контура в долях кадра, начало внизу слева.
    ///   - context: кадр, на котором рисовали.
    /// - Returns: сколько точек в форме после приёма обводки; `nil`, если контур вырожден или обучение выключено.
    @discardableResult
    func applyOutline(_ contour: [SIMD2<Double>], on context: GlassesFrameContext) -> Int? {
        lock.withLock {
            guard learning, var learned = shape, let outline = context.outline(contour: contour) else { return nil }
            learned.commitOutline(outline, oval: context.oval, fit: context.fit, scale: context.scale, width: context.image.width)
            learned.resolveStandoff()
            shape = learned
            use(learned)
            log(String(format: "glasses vision: outline taken, shape %d points at standoff %@, %d cells framed",
                       kept.count, learned.lensStandoff.map { String(format: "%.2f", $0) } ?? "-", learned.frames))
            return kept.count
        }
    }

    /// Оставляет в форме клетки, попавшие под курсор, или убирает их.
    ///
    /// - Parameters:
    ///   - points: точки в долях кадра, начало внизу слева.
    ///   - adding: `true` — клетки под точками считаются очками, `false` — кожей.
    /// - Returns: сколько клеток затронуто.
    @discardableResult
    func markCells(at points: [CGPoint], adding: Bool, on context: GlassesFrameContext) -> Int {
        lock.withLock {
            guard learning, var learned = shape, !points.isEmpty else { return 0 }
            let depth = learned.standoffDepth
            var touched: Set<Int> = []
            for point in points {
                let at = SIMD2(point.x * Double(context.image.width), (1 - point.y) * Double(context.image.height))
                guard let cell = learned.cell(at: at, fit: context.fit, scale: context.scale, width: context.image.width,
                                              depth: depth) else { continue }
                touched.insert(cell)
            }
            guard !touched.isEmpty else { return 0 }
            learned.mark(Array(touched), onGlasses: adding, weight: GlassesShape.frameWeight(learned.frames))
            shape = learned
            use(learned)
            return touched.count
        }
    }

    /// Обрабатывает кадр камеры в формате BGRA.
    ///
    /// - Parameters:
    ///   - pixels: кадр.
    ///   - head: ориентация очков по гироскопу в момент съёмки кадра.
    ///   - generation: номер настройки камеры.
    ///   - cameraMoving: камера едет вместе с ноутбуком, поэтому связь осей гироскопа и камеры
    ///     по этому кадру не учить и опору для предсказания не сбивать.
    func track(pixels: CVPixelBuffer, head: simd_quatd, generation: Int = 0, cameraMoving: Bool = false) -> GlassesFrame? {
        lock.lock()
        defer { lock.unlock() }
        guard let mesh else { return nil }
        cameraGeneration = generation
        let width = Double(CVPixelBufferGetWidth(pixels)), height = Double(CVPixelBufferGetHeight(pixels))
        let focal = width / 2 / tan(Self.fieldOfView / 2)
        let landmarks = mesh.landmarks(in: pixels)
        let image = Self.downscale(pixels, width: Self.maskWidth)
        let scale = width / Double(image.width)
        var frame = GlassesFrame(image: image, face: landmarks != nil, glasses: nil, score: nil,
                                 learnedFrames: shape?.frames ?? 0, shapePoints: kept.count, landmarks: [], glassesPoints: [])
        frame.generation = generation
        guard let landmarks else {
            lastFit = nil
            return trackWithoutFace(image: image, scale: scale, head: head, width: width, height: height, focal: focal, frame: frame)
        }
        frame.landmarks = landmarks.prefix(FaceMeshPoint.surfaceCount).map { CGPoint(x: $0.x / width, y: 1 - $0.y / height) }
        let small = landmarks.map { $0 / scale }
        classifier = SkinClassifier.sampled(from: image, landmarks: small) ?? classifier
        if learning {
            guard !cameraMoving else { return frame }
            if shape == nil {
                let span = simd_distance(landmarks[FaceMeshPoint.sides.0], landmarks[FaceMeshPoint.sides.1])
                shape = GlassesShape(landmarks: landmarks, depth: focal * Self.templeSpan / span, fieldOfView: Self.fieldOfView)
            }
            guard var learned = shape, let classifier else { return frame }
            let fit = learned.fit(landmarks: landmarks, previous: lastFit)
            lastFit = fit
            learnAlignment(face: fit.rotation, imu: head)
            let oval = faceOvalMask(landmarks: small, width: image.width, height: image.height)
            let box = glassesSearchBox(landmarks: small, width: image.width, height: image.height)
            let bridge = small[FaceMeshPoint.noseBridge]
            context = GlassesFrameContext(image: image, landmarks: small, fit: fit, scale: scale,
                                          depth: focal * Self.templeSpan / simd_distance(landmarks[FaceMeshPoint.sides.0],
                                                                                         landmarks[FaceMeshPoint.sides.1]),
                                          fieldOfView: Self.fieldOfView, fullWidth: width, fullHeight: height,
                                          generation: generation, head: head)
            if autoDetect, let glasses = findGlasses(in: image, box: box, classifier: classifier, anchor: SIMD2(bridge.x, bridge.y), oval: oval) {
                learned.accumulate(fit: fit, glasses: glasses, oval: oval, scale: scale, width: image.width)
                shape = learned
            }
            frame.learnedFrames = learned.frames
            let described = describeShape(width: width, height: height, mask: Self.maskWidth)
            frame.gridPoints = described.grid
            frame.shapePointsInFrame = described.kept
            return frame
        }
        guard let shape, let classifier, !kept.isEmpty else { return frame }
        let fit = shape.fit(landmarks: landmarks, previous: lastFit)
        lastFit = fit
        if !cameraMoving {
            learnAlignment(face: fit.rotation, imu: head)
        }
        var rotation = fit.rotation
        frame.rotationSource = t(.rotationSourceFace)
        if let anchor, let predicted = alignment.predict(anchorFace: anchor.face, anchorIMU: anchor.imu, imu: head) {
            rotation = simd_double3x3(simd_slerp(simd_quatd(predicted), simd_quatd(fit.rotation), Self.faceBlend))
            frame.rotationSource = t(.rotationSourceGyroAndFace)
        }
        if !cameraMoving {
            anchor = (rotation, head)
        }
        frame.turn = headTurn(fromCameraRotation: fit.rotation)
        frame.faceRotation = simd_quatd(fit.rotation)
        frame.faceDepth = shape.referenceDepth / fit.scale * shape.depthScale(fieldOfView: Self.fieldOfView)
        describeAlignment(&frame)
        let oval = faceOvalMask(landmarks: small, width: image.width, height: image.height)
        tracker.seed(fit)
        let score = tracker.track(image: image, scale: scale, rotation: fit.rotation, start: fit, kept: kept, probes: probes,
                                  classifier: classifier, probeArea: oval)?.score
        tracker.seed(fit)
        let projected = kept.map { point -> SIMD2<Double> in let p = fit.apply(point); return SIMD2(p.x, p.y) }
        let byFace = GlassesTracker.Result(center: projected.reduce(.zero, +) / Double(projected.count), scale: fit.scale,
                                           score: score ?? 0, projected: projected)
        return place(byFace, shape: shape, width: width, height: height, focal: focal, frame: frame)
    }

    /// Клетки и точки формы в долях кадра, начало внизу слева: окно показывает по ним, что именно выучено.
    ///
    /// Проекция всей сетки стоит тысячи умножений, поэтому повторяется только когда лицо заметно сдвинулось
    /// или сменился размер уменьшенного кадра.
    ///
    /// - Parameters:
    ///   - width: ширина полного кадра.
    ///   - height: высота полного кадра.
    ///   - mask: ширина уменьшенного кадра, с которой считались точки.
    private func describeShape(width: Double, height: Double, mask: Int) -> (grid: [CGPoint], kept: [CGPoint]) {
        guard let shape, let fit = lastFit else { return ([], []) }
        let scale = width / Double(mask)
        let anchor = CGPoint(x: fit.translation.x / scale, y: fit.translation.y / scale)
        let moved = describedAt.map { hypot(anchor.x - $0.x, anchor.y - $0.y) > 1.5 } ?? true
        guard moved || describedSize == nil || describedSize! != (mask, shape.cells) || describedGrid.isEmpty else {
            return (describedGrid, describedKept)
        }
        let grid: [SIMD2<Double>] = shape.gridCells(fit: fit, scale: scale, width: mask)
        let points: [SIMD2<Double>] = kept.isEmpty ? [] : kept.map { point in let p = fit.apply(point); return SIMD2(p.x, p.y) }
        func normalized(_ points: [SIMD2<Double>]) -> [CGPoint] {
            points.map { CGPoint(x: $0.x / width, y: 1 - $0.y / height) }
        }
        describedGrid = normalized(grid)
        describedKept = normalized(points)
        describedAt = anchor
        describedSize = (mask, shape.cells)
        return (describedGrid, describedKept)
    }

    private func learnAlignment(face: simd_double3x3, imu: simd_quatd) {        alignment.add(face: face, imu: imu)
        guard let rotation = alignment.rotation, !alignment.usesPrior, alignment.pairCount != savedAlignmentPairs else { return }
        savedAlignmentPairs = alignment.pairCount
        let q = simd_quatd(rotation)
        UserDefaults.standard.set([q.real, q.imag.x, q.imag.y, q.imag.z], forKey: Self.alignmentKey)
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
        frame.rotationSource = t(.rotationSourceGyro)
        frame.turn = headTurn(fromCameraRotation: rotation)
        describeAlignment(&frame)
        return place(tracker.track(image: image, scale: scale, rotation: rotation, start: nil, kept: kept, probes: probes,
                                   classifier: classifier), shape: shape, width: width, height: height, focal: focal, frame: frame)
    }

    private func place(_ result: GlassesTracker.Result?, shape: GlassesShape, width: Double, height: Double, focal: Double,
                       frame: GlassesFrame) -> GlassesFrame {
        var frame = frame
        guard let result else { return frame }
        let glassesDepth = shape.referenceDepth / result.scale * shape.depthScale(fieldOfView: Self.fieldOfView)
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
        describedGrid = []
        describedKept = []
        describedAt = nil
        describedSize = nil
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
