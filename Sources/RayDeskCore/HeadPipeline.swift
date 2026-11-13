import Foundation
import simd

/// Предсказание и калибровка ориентации для отрисовки и замеров.
/// Закреплённый режим сохраняет реальные повороты; остальные методы допускают сглаживание.
public final class HeadPipeline {
    public let filter: OrientationFilter
    public var calibration = ViewCalibration()
    public var stabilizer = OrientationStabilizer(level: .off)
    /// Предсказание по умолчанию, секунды: путь без времени показа и точка отсчёта ручной поправки.
    public static let defaultPredictionSeconds = 0.018
    /// На сколько вперёд предсказывать ориентацию, секунды; путь без времени показа кадра.
    public var predictionSeconds = HeadPipeline.defaultPredictionSeconds
    /// Наибольший горизонт предсказания, секунды.
    ///
    /// Измеренная задержка показа на этих очках — 25–30 мс, плюс кадр до следующей
    /// вертикальной синхронизации: потолок 20 мс обрезал предсказание и картинка
    /// отставала от головы.
    public var maxPrediction = 0.045
    /// Поправка к горизонту от фактической ошибки предсказания, секунды; плюс — дальше.
    public var predictionBias = 0.0

    public init(filter: OrientationFilter) {
        self.filter = filter
    }

    /// Предсказывает поворот к моменту показа без сглаживания реального движения головы.
    /// - Parameter presentTime: время показа в шкале `ProcessInfo.systemUptime`, секунды.
    /// - Returns: откалиброванная ориентация голова→мир, горизонт в секундах и скорость по осям головы в рад/с.
    public func worldLockedSample(at presentTime: Double)
        -> (orientation: simd_quatd, horizon: Double, angularVelocity: SIMD3<Double>) {
        let sample = filter.prediction(at: presentTime, bias: predictionBias,
                                       limit: maxPrediction, fallback: predictionSeconds)
        return (calibration.apply(to: sample.orientation), sample.horizon, sample.angularVelocity)
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
        stabilizer.filter(calibration.apply(to: filter.orientation(predictAhead: predictionSeconds + predictionBias)), dt: frameInterval)
    }

    /// Стабилизирует внешнюю ориентацию (VITURE) тем же фильтром, что и свой трекинг.
    ///
    /// Применяет ручную поправку вида. Дополнительного предсказания нет: его выполняет внешний трекер.
    ///
    /// - Parameters:
    ///   - orientation: ориентация от внешнего трекера.
    ///   - dt: время с прошлого кадра, секунды.
    public func stabilizedExternal(_ orientation: simd_quatd, dt: Double) -> simd_quatd {
        stabilizer.filter(calibration.apply(to: orientation), dt: dt)
    }

    /// Насколько вперёд предсказывать ориентацию для кадра в `presentTime`, секунды.
    ///
    /// - Parameter presentTime: момент, к которому кадр будет показан, секунды.
    public func predictionHorizon(at presentTime: Double) -> Double {
        guard let sampleTime = filter.latestSampleTime else { return predictionSeconds + predictionBias }
        return min(maxPrediction, max(0, presentTime - sampleTime + predictionBias))
    }
}
