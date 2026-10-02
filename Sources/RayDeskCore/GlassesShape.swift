import Foundation
import simd

/// Номера точек модели лица MediaPipe (478 точек), которые нужны трекеру очков.
public enum FaceMeshPoint {
    /// Переносица между глазами.
    public static let noseBridge = 168
    /// Края лица у висков: по ним меряется ширина лица.
    public static let sides = (127, 356)
    /// Внешние уголки глаз, по ним выравнивается вырез лица.
    public static let eyeCorners = (33, 263)
    /// Точки, которые не двигаются при мимике: по ним подгоняется голова.
    public static let rigid = [1, 2, 4, 5, 6, 9, 10, 151, 168, 195, 197, 67, 109, 338, 297, 103, 332, 54, 284, 127, 356,
                               234, 454, 93, 323, 116, 345, 123, 352, 50, 280, 33, 133, 362, 263]
    /// Точки, где кожу не закрывают очки: лоб, нос, губа, подбородок, нижние щёки.
    public static let skin = [151, 4, 164, 199, 187, 411]
    /// Контур лица по кругу.
    public static let oval = [10, 338, 297, 332, 284, 251, 389, 356, 454, 323, 361, 288, 397, 365, 379, 378, 400, 377, 152,
                              148, 176, 149, 150, 136, 172, 58, 132, 93, 234, 127, 162, 21, 54, 103, 67, 109]
    /// Брови: верх окна поиска очков.
    public static let brows = [70, 300, 105, 334]
    /// Середина носа: низ окна поиска очков.
    public static let noseMiddle = 5
    /// Точки поверхности лица без радужек.
    public static let surfaceCount = 468
}

/// Кадр камеры в уменьшенном виде, RGBA по 4 байта, строки сверху вниз.
public struct RGBAImage: Sendable {
    public let width: Int
    public let height: Int
    public var pixels: [UInt8]

    public init(width: Int, height: Int, pixels: [UInt8]) {
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    /// Цвет пикселя в YCbCr: яркость 0…255 и два цветовых отклонения около нуля.
    public func color(x: Int, y: Int) -> SIMD3<Double> {
        let i = (y * width + x) * 4
        let r = Double(pixels[i]), g = Double(pixels[i + 1]), b = Double(pixels[i + 2])
        return SIMD3(0.299 * r + 0.587 * g + 0.114 * b,
                     -0.1687 * r - 0.3313 * g + 0.5 * b,
                     0.5 * r - 0.4187 * g - 0.0813 * b)
    }
}

/// Прямоугольник в пикселях уменьшенного кадра, края включительно.
public struct PixelBox: Equatable, Sendable {
    public var x0: Int, y0: Int, x1: Int, y1: Int
    public var width: Int { x1 - x0 + 1 }
    public var height: Int { y1 - y0 + 1 }

    public init(x0: Double, y0: Double, x1: Double, y1: Double, imageWidth: Int, imageHeight: Int) {
        self.x0 = max(0, Int(floor(x0)))
        self.y0 = max(0, Int(floor(y0)))
        self.x1 = min(imageWidth - 1, Int(ceil(x1)))
        self.y1 = min(imageHeight - 1, Int(ceil(y1)))
    }
}

/// Отличает кожу от очков по цвету: у кожи заметный оттенок, у оправы и линз его почти нет.
public struct SkinClassifier: Sendable {
    /// Цвет кожи в YCbCr.
    public var skin: SIMD3<Double>
    /// Во сколько отличие оттенка от кожи уже не кожа.
    public var chroma: Double = 12
    /// Пиксель темнее этой доли яркости кожи — не кожа, какого бы оттенка он ни был.
    public var deepShadow: Double = 0.3

    public init(skin: SIMD3<Double>) {
        self.skin = skin
    }

    /// Медианный цвет кожи в квадратах 5×5 вокруг `FaceMeshPoint.skin`.
    ///
    /// - Parameters:
    ///   - image: уменьшенный кадр.
    ///   - landmarks: точки лица в пикселях этого кадра.
    /// - Returns: `nil`, если все точки за кадром.
    public static func sampled(from image: RGBAImage, landmarks: [SIMD3<Double>]) -> SkinClassifier? {
        var samples: [SIMD3<Double>] = []
        for index in FaceMeshPoint.skin {
            let cx = Int(landmarks[index].x.rounded()), cy = Int(landmarks[index].y.rounded())
            for dy in -2...2 {
                for dx in -2...2 {
                    let x = cx + dx, y = cy + dy
                    if x >= 0, y >= 0, x < image.width, y < image.height { samples.append(image.color(x: x, y: y)) }
                }
            }
        }
        guard !samples.isEmpty else { return nil }
        func median(_ axis: KeyPath<SIMD3<Double>, Double>) -> Double {
            samples.map { $0[keyPath: axis] }.sorted()[samples.count / 2]
        }
        return SkinClassifier(skin: SIMD3(median(\.x), median(\.y), median(\.z)))
    }

    /// `true`, если пиксель не похож на кожу.
    public func isNotSkin(_ color: SIMD3<Double>) -> Bool {
        hypot(color.y - skin.y, color.z - skin.z) > chroma || color.x < deepShadow * skin.x
    }
}

/// Подобие, переводящее одно облако точек в другое: поворот, масштаб и сдвиг.
public struct SimilarityFit: Sendable {
    /// Поворот кватернионом (w, x, y, z).
    public var quaternion: SIMD4<Double>
    /// Матрица поворота.
    public var rotation: simd_double3x3
    public var scale: Double
    public var translation: SIMD3<Double>
    /// Среднеквадратичный промах подгонки в единицах второго облака.
    public var residual: Double

    /// Переводит точку первого облака во второе.
    public func apply(_ point: SIMD3<Double>) -> SIMD3<Double> {
        scale * (rotation * point) + translation
    }

    /// Подбирает подобие методом Хорна: поворот — главный собственный вектор матрицы 4×4.
    ///
    /// - Parameters:
    ///   - from: точки первого облака.
    ///   - to: те же точки во втором облаке, столько же.
    ///   - previous: кватернион прошлой подгонки, ускоряет сходимость.
    public init(from: [SIMD3<Double>], to: [SIMD3<Double>], previous: SIMD4<Double>? = nil) {
        let n = Double(from.count)
        let meanFrom = from.reduce(.zero, +) / n, meanTo = to.reduce(.zero, +) / n
        var s = simd_double3x3()
        var normFrom = 0.0, normTo = 0.0
        for (p, q) in zip(from, to) {
            let a = p - meanFrom, b = q - meanTo
            s += simd_double3x3(columns: (a * b.x, a * b.y, a * b.z))
            normFrom += simd_length_squared(a)
            normTo += simd_length_squared(b)
        }
        let horn = hornRotation(s, previous: previous)
        rotation = horn.matrix
        let v = horn.quaternion
        quaternion = v
        scale = sqrt(normTo / normFrom)
        translation = meanTo - scale * (rotation * meanFrom)
        var error = 0.0
        for (p, q) in zip(from, to) {
            error += simd_length_squared(scale * (rotation * p) + (meanTo - scale * (rotation * meanFrom)) - q)
        }
        residual = sqrt(error / n)
    }
}

/// Маска «внутри овала лица» по точкам контура, построчная заливка многоугольника.
///
/// - Parameters:
///   - landmarks: точки лица в пикселях кадра.
///   - width: ширина кадра.
///   - height: высота кадра.
/// - Returns: `width·height` флагов по строкам.
public func faceOvalMask(landmarks: [SIMD3<Double>], width: Int, height: Int) -> [Bool] {
    var mask = [Bool](repeating: false, count: width * height)
    let polygon = FaceMeshPoint.oval.map { SIMD2(landmarks[$0].x, landmarks[$0].y) }
    for row in 0..<height {
        let y = Double(row) + 0.5
        var crossings: [Double] = []
        for i in polygon.indices {
            let a = polygon[i], b = polygon[(i + 1) % polygon.count]
            if (a.y <= y) != (b.y <= y) {
                crossings.append(a.x + (y - a.y) / (b.y - a.y) * (b.x - a.x))
            }
        }
        crossings.sort()
        var i = 0
        while i + 1 < crossings.count {
            let from = max(0, Int(ceil(crossings[i] - 0.5))), to = min(width - 1, Int(floor(crossings[i + 1] - 0.5)))
            if from <= to { for x in from...to { mask[row * width + x] = true } }
            i += 2
        }
    }
    return mask
}

/// Пятно очков в окне кадра.
public struct GlassesMask: Sendable {
    public var box: PixelBox
    /// `box.width·box.height` флагов по строкам окна.
    public var mask: [Bool]
}

/// Окно, где ищутся очки: от висков, от чуть выше бровей до середины носа.
public func glassesSearchBox(landmarks: [SIMD3<Double>], width: Int, height: Int) -> PixelBox {
    let left = min(landmarks[FaceMeshPoint.sides.0].x, landmarks[FaceMeshPoint.sides.1].x)
    let right = max(landmarks[FaceMeshPoint.sides.0].x, landmarks[FaceMeshPoint.sides.1].x)
    let span = right - left
    let top = FaceMeshPoint.brows.map { landmarks[$0].y }.min()! - 0.04 * span
    return PixelBox(x0: left - 0.08 * span, y0: top, x1: right + 0.08 * span, y1: landmarks[FaceMeshPoint.noseMiddle].y,
                    imageWidth: width, imageHeight: height)
}

/// Находит пятно «не кожа» внутри овала лица, которое проходит через переносицу.
///
/// - Parameters:
///   - image: уменьшенный кадр.
///   - box: окно поиска.
///   - classifier: цвет кожи.
///   - anchor: переносица в пикселях кадра.
///   - oval: маска овала лица того же размера, что кадр.
/// - Returns: `nil`, если у переносицы нет пятна или оно меньше 12 пикселей.
public func findGlasses(in image: RGBAImage, box: PixelBox, classifier: SkinClassifier, anchor: SIMD2<Double>,
                        oval: [Bool]) -> GlassesMask? {
    let bw = box.width, bh = box.height
    guard bw >= 4, bh >= 4 else { return nil }
    var candidate = [Bool](repeating: false, count: bw * bh)
    for y in 0..<bh {
        for x in 0..<bw {
            let gx = box.x0 + x, gy = box.y0 + y
            candidate[y * bw + x] = oval[gy * image.width + gx] && classifier.isNotSkin(image.color(x: gx, y: gy))
        }
    }
    let ax = Int(anchor.x.rounded()) - box.x0, ay = Int(anchor.y.rounded()) - box.y0
    var seed: Int?
    search: for radius in 0...6 {
        for dy in -radius...radius {
            for dx in -radius...radius {
                let x = ax + dx, y = ay + dy
                if x >= 0, y >= 0, x < bw, y < bh, candidate[y * bw + x] {
                    seed = y * bw + x
                    break search
                }
            }
        }
    }
    guard let seed else { return nil }
    var mask = [Bool](repeating: false, count: bw * bh)
    var stack = [seed]
    mask[seed] = true
    var count = 0
    while let p = stack.popLast() {
        count += 1
        let x = p % bw, y = p / bw
        for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)] where nx >= 0 && ny >= 0 && nx < bw && ny < bh {
            let q = ny * bw + nx
            if candidate[q] && !mask[q] {
                mask[q] = true
                stack.append(q)
            }
        }
    }
    return count >= 12 ? GlassesMask(box: box, mask: mask) : nil
}

/// Выученная форма очков в системе координат опорного кадра: лист клеток перед лицом, у каждой клетки
/// девять вариантов глубины, для каждого — сколько раз клетка легла на очки и сколько на кожу.
public struct GlassesShape: Codable, Sendable {
    /// Вынос клетки перед поверхностью лица в долях ширины лица.
    public static let depths = [-0.02, 0.02, 0.06, 0.1, 0.14, 0.18, 0.22, 0.26, 0.3]
    static let cellsAcross = 100.0
    static let extent = (side: 0.62, up: 0.25, down: 0.22)
    static let surfaceRadius = 0.05
    static let minHits: UInt16 = 6
    static let share = 0.7
    static let probeGaps = [0.015, 0.04]

    /// Жёсткие точки опорного кадра, пиксели полного кадра.
    public var reference: [SIMD3<Double>]
    /// Ширина лица в опорном кадре, пиксели.
    public var faceWidth: Double
    /// Расстояние до лица в опорном кадре, метры.
    public var referenceDepth: Double
    /// Угол обзора камеры по горизонтали, с которым считалась `referenceDepth`, радианы; `nil` — 70°.
    public var fieldOfView: Double?
    public var cells: Int
    var centers: [SIMD3<Float>]
    var hits: [UInt16]
    var misses: [UInt16]
    /// Сколько кадров вошло в форму.
    public var frames: Int

    /// Заводит пустой лист перед лицом опорного кадра.
    ///
    /// - Parameters:
    ///   - landmarks: все точки лица в пикселях полного кадра, z в тех же единицах.
    ///   - depth: расстояние до лица, метры.
    ///   - fieldOfView: угол обзора камеры по горизонтали, с которым посчитано `depth`, радианы.
    public init(landmarks: [SIMD3<Double>], depth: Double, fieldOfView: Double) {
        self.fieldOfView = fieldOfView
        let bridge = landmarks[FaceMeshPoint.noseBridge]
        faceWidth = simd_distance(landmarks[FaceMeshPoint.sides.0], landmarks[FaceMeshPoint.sides.1])
        let step = faceWidth / Self.cellsAcross
        let x0 = bridge.x - Self.extent.side * faceWidth, y0 = bridge.y - Self.extent.up * faceWidth
        let nx = Int(ceil(2 * Self.extent.side * Self.cellsAcross))
        let ny = Int(ceil((Self.extent.up + Self.extent.down) * Self.cellsAcross))
        let radius = Self.surfaceRadius * faceWidth
        let surfacePoints = landmarks.prefix(FaceMeshPoint.surfaceCount)
        var centers: [SIMD3<Float>] = []
        centers.reserveCapacity(nx * ny * Self.depths.count)
        for iy in 0..<ny {
            for ix in 0..<nx {
                let x = x0 + (Double(ix) + 0.5) * step, y = y0 + (Double(iy) + 0.5) * step
                var front = Double.infinity, nearest = Double.infinity, nearestZ = 0.0
                for p in surfacePoints {
                    let d = hypot(p.x - x, p.y - y)
                    if d < radius && p.z < front { front = p.z }
                    if d < nearest { nearest = d; nearestZ = p.z }
                }
                let surface = front.isFinite ? front : nearestZ
                for standoff in Self.depths {
                    centers.append(SIMD3(Float(x), Float(y), Float(surface - standoff * faceWidth)))
                }
            }
        }
        reference = FaceMeshPoint.rigid.map { landmarks[$0] }
        referenceDepth = depth
        cells = nx * ny
        self.centers = centers
        hits = [UInt16](repeating: 0, count: centers.count)
        misses = hits
        frames = 0
    }

    /// Во сколько раз пересчитать глубину, если сейчас задан другой угол обзора камеры, чем при обучении:
    /// глубина по размеру в кадре пропорциональна фокусному расстоянию.
    public func depthScale(fieldOfView current: Double) -> Double {
        tan((fieldOfView ?? 70 * .pi / 180) / 2) / tan(current / 2)
    }

    /// Подгоняет опорный кадр к текущим точкам лица.
    public func fit(landmarks: [SIMD3<Double>], previous: SimilarityFit?) -> SimilarityFit {
        SimilarityFit(from: reference, to: FaceMeshPoint.rigid.map { landmarks[$0] }, previous: previous?.quaternion)
    }

    /// Добавляет кадр: каждая клетка каждой глубины проецируется в кадр и получает попадание,
    /// если легла на пятно очков, и промах, если легла на другое место овала лица.
    ///
    /// - Parameters:
    ///   - fit: подгонка опорного кадра к текущему, пиксели полного кадра.
    ///   - glasses: пятно очков в уменьшенном кадре.
    ///   - oval: маска овала лица уменьшенного кадра.
    ///   - scale: во сколько полный кадр больше уменьшенного.
    ///   - width: ширина уменьшенного кадра.
    public mutating func accumulate(fit: SimilarityFit, glasses: GlassesMask, oval: [Bool], scale: Double, width: Int) {
        let r = fit.rotation, t = fit.translation, k = fit.scale
        let box = glasses.box
        for i in centers.indices {
            let p = SIMD3<Double>(centers[i])
            let gx = Int(floor((k * (r[0][0] * p.x + r[1][0] * p.y + r[2][0] * p.z) + t.x) / scale))
            let gy = Int(floor((k * (r[0][1] * p.x + r[1][1] * p.y + r[2][1] * p.z) + t.y) / scale))
            guard gx >= box.x0, gx <= box.x1, gy >= box.y0, gy <= box.y1, oval[gy * width + gx] else { continue }
            if glasses.mask[(gy - box.y0) * box.width + gx - box.x0] {
                if hits[i] < .max { hits[i] += 1 }
            } else if misses[i] < .max {
                misses[i] += 1
            }
        }
        frames += 1
    }

    /// Клетки формы на лучшей глубине: те, что легли на очки хотя бы в 70 % кадров.
    public func keptPoints() -> [SIMD3<Double>] {
        let depths = Self.depths.count
        var kept: [SIMD3<Double>] = []
        for cell in 0..<cells {
            var best = -1, bestShare = Self.share
            for d in 0..<depths {
                let h = hits[cell * depths + d], m = misses[cell * depths + d]
                guard h >= Self.minHits else { continue }
                let share = Double(h) / Double(h + m)
                if share > bestShare { best = d; bestShare = share }
            }
            if best >= 0 { kept.append(SIMD3<Double>(centers[cell * depths + best])) }
        }
        return kept
    }

    /// Точки над и под формой в каждом её столбце, ближнее и дальнее кольцо: там должна быть кожа.
    public func probes(for kept: [SIMD3<Double>]) -> [SIMD3<Double>] {
        let step = faceWidth / Self.cellsAcross
        var columns: [Int: (top: SIMD3<Double>, bottom: SIMD3<Double>, count: Int)] = [:]
        for p in kept {
            let key = Int((p.x / step).rounded())
            if var column = columns[key] {
                column.count += 1
                if p.y < column.top.y { column.top = p }
                if p.y > column.bottom.y { column.bottom = p }
                columns[key] = column
            } else {
                columns[key] = (p, p, 1)
            }
        }
        return columns.values.filter { $0.count >= 3 }.flatMap { column in
            Self.probeGaps.flatMap { share in
                [column.top - SIMD3(0, share * faceWidth, 0), column.bottom + SIMD3(0, share * faceWidth, 0)]
            }
        }
    }
}

/// Положение очков в кадре по выученной форме, без модели лица: поворот берётся со стороны,
/// сдвиг и масштаб подбираются так, чтобы внутри формы была «не кожа», а над и под ней — кожа.
public struct GlassesTracker: Sendable {
    /// Ниже этой доли совпадения очки считаются потерянными.
    public static let lostBelow = 0.6
    static let margin = 0.25
    static let stride = 2

    /// Масштаб и сдвиг от опорного кадра к текущему, пиксели полного кадра.
    public private(set) var scale = 1.0
    public private(set) var shift = SIMD2<Double>(0, 0)
    public private(set) var ready = false

    public init() {}

    /// Забывает прошлое положение: следующий кадр начнёт с подгонки по лицу.
    public mutating func reset() {
        ready = false
    }

    /// Ставит трекер туда, где форму видит модель лица, без поиска: пока лицо видно, трекер только
    /// следует за ним, чтобы при потере лица продолжить с того же места.
    public mutating func seed(_ fit: SimilarityFit) {
        scale = fit.scale
        shift = SIMD2(fit.translation.x, fit.translation.y)
        ready = true
    }

    /// Результат одного кадра.
    public struct Result: Sendable {
        /// Середина формы в пикселях полного кадра.
        public var center: SIMD2<Double>
        /// Масштаб от опорного кадра: во сколько раз очки сейчас крупнее.
        public var scale: Double
        /// Доля совпадения от 0 до 1.
        public var score: Double
        /// Точки формы в пикселях полного кадра.
        public var projected: [SIMD2<Double>]

        public init(center: SIMD2<Double>, scale: Double, score: Double, projected: [SIMD2<Double>]) {
            self.center = center
            self.scale = scale
            self.score = score
            self.projected = projected
        }
    }

    /// Ищет очки в кадре.
    ///
    /// - Parameters:
    ///   - image: уменьшенный кадр.
    ///   - scale: во сколько полный кадр больше уменьшенного.
    ///   - rotation: поворот головы от опорного кадра.
    ///   - start: подгонка по лицу, с которой начать, если прошлого положения нет.
    ///   - kept: точки формы из `GlassesShape.keptPoints()`.
    ///   - probes: точки над и под формой из `GlassesShape.probes(for:)`.
    ///   - classifier: цвет кожи.
    ///   - probeArea: где пробам можно верить, флаги по пикселям уменьшенного кадра, обычно овал лица;
    ///     пробы за его пределами (фон, волосы) не учитываются. `nil` — учитывать все.
    /// - Returns: `nil`, если формы нет или совпадение ниже `lostBelow`.
    public mutating func track(image: RGBAImage, scale imageScale: Double, rotation: simd_double3x3, start: SimilarityFit?,
                               kept: [SIMD3<Double>], probes: [SIMD3<Double>], classifier: SkinClassifier,
                               probeArea: [Bool]? = nil) -> Result? {
        guard !kept.isEmpty, !probes.isEmpty else { return nil }
        if !ready {
            guard let start else { return nil }
            scale = start.scale
            shift = SIMD2(start.translation.x, start.translation.y)
            ready = true
        }
        func flat(_ points: [SIMD3<Double>]) -> [SIMD2<Double>] {
            points.map { let q = rotation * $0; return SIMD2(q.x, q.y) }
        }
        let inside = flat(Swift.stride(from: 0, to: kept.count, by: Self.stride).map { kept[$0] })
        let outside = flat(probes)
        let predicted = outside.map { (scale * $0 + shift) / imageScale }
        let minX = predicted.map(\.x).min()!, maxX = predicted.map(\.x).max()!
        let minY = predicted.map(\.y).min()!, maxY = predicted.map(\.y).max()!
        let margin = Self.margin * (maxX - minX)
        let box = PixelBox(x0: minX - margin, y0: minY - margin, x1: maxX + margin, y1: maxY + margin,
                           imageWidth: image.width, imageHeight: image.height)
        guard box.width >= 8, box.height >= 4 else {
            ready = false
            return nil
        }
        var notSkin = [Double](repeating: 0, count: box.width * box.height)
        for y in 0..<box.height {
            for x in 0..<box.width {
                notSkin[y * box.width + x] = classifier.isNotSkin(image.color(x: box.x0 + x, y: box.y0 + y)) ? 1 : 0
            }
        }
        func share(_ points: [SIMD2<Double>], _ s: Double, _ t: SIMD2<Double>, want: Bool, area: [Bool]?) -> Double {
            var seen = 0, good = 0.0
            for p in points {
                let g = (s * p + t) / imageScale - SIMD2(Double(box.x0) + 0.5, Double(box.y0) + 0.5)
                let x0 = Int(floor(g.x)), y0 = Int(floor(g.y))
                guard x0 >= 0, y0 >= 0, x0 + 1 < box.width, y0 + 1 < box.height else { continue }
                if let area, !area[(y0 + box.y0) * image.width + x0 + box.x0] { continue }
                let fx = g.x - Double(x0), fy = g.y - Double(y0)
                let i = y0 * box.width + x0
                let value = (notSkin[i] * (1 - fx) + notSkin[i + 1] * fx) * (1 - fy)
                    + (notSkin[i + box.width] * (1 - fx) + notSkin[i + box.width + 1] * fx) * fy
                seen += 1
                good += want ? value : 1 - value
            }
            return seen > 0 ? good / Double(seen) : 0
        }
        func score(_ s: Double, _ t: SIMD2<Double>) -> Double {
            (share(inside, s, t, want: true, area: nil) + share(outside, s, t, want: false, area: probeArea)) / 2
        }
        var bestScale = scale, bestShift = shift
        var best = score(bestScale, bestShift)
        var dt = 2 * imageScale, ds = 0.02 * bestScale
        for _ in 0..<4 {
            for _ in 0..<12 {
                var moved = false
                for (a, b, c) in [(dt, 0.0, 0.0), (-dt, 0, 0), (0, dt, 0), (0, -dt, 0), (0, 0, ds), (0, 0, -ds)] {
                    let s = bestScale + c, t = bestShift + SIMD2(a, b)
                    let value = score(s, t)
                    if value > best + 1e-4 {
                        best = value
                        bestScale = s
                        bestShift = t
                        moved = true
                    }
                }
                if !moved { break }
            }
            dt /= 2
            ds /= 2
        }
        scale = bestScale
        shift = bestShift
        if best < Self.lostBelow { ready = false }
        let projected = flat(kept).map { bestScale * $0 + bestShift }
        let center = projected.reduce(.zero, +) / Double(projected.count)
        return best < Self.lostBelow ? nil : Result(center: center, scale: bestScale, score: best, projected: projected)
    }
}
