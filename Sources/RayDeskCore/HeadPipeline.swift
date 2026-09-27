import Foundation
import simd

/// Путь от фильтра до ориентации, по которой рисуется кадр: предсказание, ручная
/// поправка сетки и стабилизация. Один и тот же путь используют отрисовка и замеры.
public final class HeadPipeline {
    public let filter: OrientationFilter
    public var calibration = ViewCalibration()
    public var stabilizer = OrientationStabilizer(level: .off)
    /// На сколько вперёд предсказывать ориентацию, секунды.
    public var predictionSeconds = 0.018

    public init(filter: OrientationFilter) {
        self.filter = filter
    }

    /// Ориентация голова→мир для кадра.
    ///
    /// - Parameter frameInterval: время с прошлого кадра, секунды.
    public func renderedOrientation(frameInterval: Double) -> simd_quatd {
        stabilizer.filter(calibration.apply(to: filter.orientation(predictAhead: predictionSeconds)), dt: frameInterval)
    }
}
