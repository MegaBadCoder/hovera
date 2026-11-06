import Foundation
import simd

/// Путь от фильтра до ориентации, по которой рисуется кадр: предсказание, ручная
/// поправка сетки и стабилизация. Один и тот же путь используют отрисовка и замеры.
public final class HeadPipeline {
    public let filter: OrientationFilter
    public var calibration = ViewCalibration()
    public var stabilizer = OrientationStabilizer(level: .off)
    /// На сколько вперёд предсказывать ориентацию, секунды; путь без времени показа кадра.
    public var predictionSeconds = 0.018
    /// Наибольший горизонт предсказания, секунды.
    public var maxPrediction = 0.020

    public init(filter: OrientationFilter) {
        self.filter = filter
    }

    /// Ориентация голова→мир для кадра, который будет показан в `presentTime`.
    ///
    /// Горизонт предсказания — разница между временем показа и временем самого нового
    /// отсчёта IMU, зажатая в [0, `maxPrediction`]: дребезг предсказания на устаревших
    /// отсчётах хуже, чем небольшое отставание.
    ///
    /// - Parameters:
    ///   - presentTime: момент, к которому кадр будет показан, секунды в шкале `ProcessInfo.systemUptime`.
    ///   - frameInterval: время с прошлого кадра, секунды.
    public func renderedOrientation(at presentTime: Double, frameInterval: Double) -> simd_quatd {
        stabilizer.filter(calibration.apply(to: filter.orientation(predictAhead: predictionHorizon(at: presentTime))), dt: frameInterval)
    }

    /// Ориентация голова→мир для кадра без известного времени показа: предсказание
    /// на `predictionSeconds` от текущего состояния фильтра.
    ///
    /// - Parameter frameInterval: время с прошлого кадра, секунды.
    public func renderedOrientation(frameInterval: Double) -> simd_quatd {
        stabilizer.filter(calibration.apply(to: filter.orientation(predictAhead: predictionSeconds)), dt: frameInterval)
    }

    /// Насколько вперёд предсказывать ориентацию для кадра в `presentTime`, секунды.
    ///
    /// - Parameter presentTime: момент, к которому кадр будет показан, секунды.
    public func predictionHorizon(at presentTime: Double) -> Double {
        guard let sampleTime = filter.latestSampleTime else { return predictionSeconds }
        return min(maxPrediction, max(0, presentTime - sampleTime))
    }
}
