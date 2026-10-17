import Foundation
import simd

/// Пятно очков, обведённое рукой на кадре: контур в пикселях уменьшенного кадра и залитая по нему маска.
public struct GlassesOutline: Sendable {
    /// Контур в пикселях уменьшенного кадра, вершины по порядку обхода.
    public var contour: [SIMD2<Double>]
    /// Пятно очков, построенное по этому контуру.
    public var mask: GlassesMask

    /// Замыкает `contour` и заливает по правилу чётности.
    ///
    /// - Parameters:
    ///   - contour: вершины контура в пикселях уменьшенного кадра, не меньше трёх.
    ///   - width: ширина уменьшенного кадра.
    ///   - height: высота уменьшенного кадра.
    /// - Returns: `nil`, если вершин меньше трёх или залитая площадь меньше двенадцати пикселей.
    public init?(contour: [SIMD2<Double>], width: Int, height: Int) {
        guard contour.count >= 3, width > 0, height > 0 else { return nil }
        let xs = contour.map(\.x), ys = contour.map(\.y)
        let box = PixelBox(x0: xs.min()!, y0: ys.min()!, x1: xs.max()!, y1: ys.max()!, imageWidth: width, imageHeight: height)
        guard box.width >= 2, box.height >= 2 else { return nil }
        var mask = [Bool](repeating: false, count: box.width * box.height)
        var filled = 0
        for row in 0..<box.height {
            let y = Double(box.y0 + row) + 0.5
            var crossings: [Double] = []
            for i in contour.indices {
                let a = contour[i], b = contour[(i + 1) % contour.count]
                if (a.y <= y) != (b.y <= y) { crossings.append(a.x + (y - a.y) / (b.y - a.y) * (b.x - a.x)) }
            }
            crossings.sort()
            var i = 0
            while i + 1 < crossings.count {
                let from = max(box.x0, Int(ceil(crossings[i] - 0.5))), to = min(box.x1, Int(floor(crossings[i + 1] - 0.5)))
                if from <= to {
                    for x in from...to { mask[row * box.width + x - box.x0] = true }
                    filled += to - from + 1
                }
                i += 2
            }
        }
        guard filled >= 12 else { return nil }
        self.contour = contour
        self.mask = GlassesMask(box: box, mask: mask)
    }
}

/// Кадр камеры со всем, что нужно, чтобы показать форму очков и учить её по ручной обводке.
public struct GlassesFrameContext: Sendable {
    /// Уменьшенный кадр с теми же пропорциями, что полный.
    public let image: RGBAImage
    /// Точки лица в пикселях уменьшенного кадра.
    public let landmarks: [SIMD3<Double>]
    /// Подгонка опорного кадра формы к этому кадру, пиксели полного кадра.
    public let fit: SimilarityFit
    /// Во сколько полный кадр больше уменьшенного.
    public let scale: Double
    /// Расстояние до лица в этом кадре, метры.
    public let depth: Double
    /// Угол обзора камеры по горизонтали, радианы.
    public let fieldOfView: Double
    /// Ширина полного кадра.
    public let fullWidth: Double
    /// Высота полного кадра.
    public let fullHeight: Double
    /// Номер настройки камеры, при смене которой кадр пересчитывается.
    public let generation: Int
    /// Ориентация очков в момент кадра.
    public let head: simd_quatd

    public init(image: RGBAImage, landmarks: [SIMD3<Double>], fit: SimilarityFit, scale: Double, depth: Double,
                fieldOfView: Double, fullWidth: Double, fullHeight: Double, generation: Int, head: simd_quatd) {
        self.image = image
        self.landmarks = landmarks
        self.fit = fit
        self.scale = scale
        self.depth = depth
        self.fieldOfView = fieldOfView
        self.fullWidth = fullWidth
        self.fullHeight = fullHeight
        self.generation = generation
        self.head = head
    }

    /// Овал лица этого кадра, флаги по пикселям уменьшенного кадра.
    public var oval: [Bool] { faceOvalMask(landmarks: landmarks, width: image.width, height: image.height) }
    /// Окно поиска очков этого кадра.
    public var searchBox: PixelBox { glassesSearchBox(landmarks: landmarks, width: image.width, height: image.height) }

    /// Пятно очков, обведённое рукой.
    ///
    /// - Parameter contour: вершины контура в долях кадра: x вправо, y вверх.
    /// - Returns: `nil`, если контур вырожден.
    public func outline(contour: [SIMD2<Double>]) -> GlassesOutline? {
        let points = contour.map { SIMD2($0.x * Double(image.width), (1 - $0.y) * Double(image.height)) }
        return GlassesOutline(contour: points, width: image.width, height: image.height)
    }
}
