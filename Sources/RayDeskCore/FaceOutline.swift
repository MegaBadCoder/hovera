import CoreGraphics
import Foundation
import simd

/// Размер и центр лица по верхней, жёсткой его части: ширина — между краями контура у ушей
/// вдоль линии глаз, центр — середина между глазами. В отличие от рамки Vision, они не меняются,
/// когда голова наклоняется к плечу или открывается рот.
public struct FaceOutline: Equatable, Sendable {
    /// Ширина лица вдоль линии глаз в долях ширины кадра.
    public var width: Double
    /// Середина между глазами в долях кадра, начало внизу слева.
    public var center: CGPoint
    /// Наклон линии глаз в кадре, радианы, плюс — против часовой стрелки.
    public var roll: Double

    /// Во сколько раз рамка Vision уже контура лица, измеренного вдоль линии глаз.
    public static let boxToContour = 0.93

    /// Строит ширину лица по точкам глаз и контура.
    ///
    /// - Parameters:
    ///   - leftEye: точки одного глаза в долях кадра (начало внизу слева).
    ///   - rightEye: точки другого глаза.
    ///   - contour: точки контура лица.
    ///   - aspect: отношение ширины кадра к высоте.
    /// - Returns: `nil`, если точек не хватает или глаза совпадают.
    public init?(leftEye: [CGPoint], rightEye: [CGPoint], contour: [CGPoint], aspect: Double) {
        guard !leftEye.isEmpty, !rightEye.isEmpty, contour.count >= 3 else { return nil }
        func widthUnits(_ p: CGPoint) -> SIMD2<Double> { SIMD2(Double(p.x), Double(p.y) / aspect) }
        func centre(_ points: [CGPoint]) -> SIMD2<Double> { points.map(widthUnits).reduce(.zero, +) / Double(points.count) }
        let eyeLine = centre(rightEye) - centre(leftEye)
        guard simd_length(eyeLine) > 1e-6 else { return nil }
        let axis = simd_normalize(eyeLine)
        func span(_ a: CGPoint, _ b: CGPoint) -> Double { abs(simd_dot(widthUnits(a) - widthUnits(b), axis)) }
        width = (span(contour[0], contour[contour.count - 1]) + span(contour[1], contour[contour.count - 2])) / 2
        let middle = (centre(leftEye) + centre(rightEye)) / 2
        center = CGPoint(x: middle.x, y: middle.y * aspect)
        roll = atan2(axis.y, axis.x)
        if roll > .pi / 2 { roll -= .pi } else if roll < -.pi / 2 { roll += .pi }
    }

    /// Рамка того же размера, что дала бы Vision для лица без наклона, с центром `center`.
    public func equivalentBox(center: CGPoint, aspect: Double) -> CGRect {
        let boxWidth = width * Self.boxToContour
        let boxHeight = boxWidth * aspect
        return CGRect(x: Double(center.x) - boxWidth / 2, y: Double(center.y) - boxHeight / 2, width: boxWidth, height: boxHeight)
    }
}
