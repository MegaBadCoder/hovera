import CoreGraphics
import Foundation
import simd

/// Встроенная камера для оценки положения головы по рамке лица.
public struct FaceCamera: Sendable {
    /// Угол обзора камеры по горизонтали, радианы.
    public var horizontalFieldOfView: Double
    /// Отношение ширины кадра к высоте.
    public var aspect: Double
    /// Средняя ширина лица, по которой оценивается расстояние, метры.
    public var faceWidth: Double

    public init(horizontalFieldOfView: Double, aspect: Double, faceWidth: Double = 0.15) {
        self.horizontalFieldOfView = horizontalFieldOfView
        self.aspect = aspect
        self.faceWidth = faceWidth
    }

    /// Положение головы относительно камеры по рамке лица.
    ///
    /// Модель — точечная камера: глубина обратно пропорциональна ширине рамки, боковое смещение —
    /// положению центра рамки. Абсолютный масштаб зависит от `faceWidth` (у разных людей ±15 %),
    /// изменения положения — нет.
    ///
    /// - Parameter face: рамка лица в долях кадра, начало внизу слева (как в Vision).
    /// - Returns: метры; x — вправо по кадру, y — вверх по кадру, z — от камеры к лицу.
    public func headPosition(face: CGRect) -> SIMD3<Double> {
        let focal = 0.5 / tan(horizontalFieldOfView / 2)
        let depth = faceWidth * focal / Double(face.width)
        let x = (Double(face.midX) - 0.5) * depth / focal
        let y = (Double(face.midY) - 0.5) / aspect * depth / focal
        return SIMD3(x, y, depth)
    }
}

/// Скользящая оценка разброса измерений за последние `window` секунд.
public struct RollingSpread: Sendable {
    /// Длина окна, секунды.
    public let window: Double
    private var samples: [(time: Double, value: SIMD3<Double>)] = []

    public init(window: Double) {
        self.window = window
    }

    /// Добавляет измерение и выбрасывает те, что старше окна.
    ///
    /// - Parameters:
    ///   - value: измерение.
    ///   - time: время измерения, секунды; вызовы должны идти по возрастанию времени.
    public mutating func add(_ value: SIMD3<Double>, at time: Double) {
        samples.append((time, value))
        samples.removeAll { time - $0.time > window }
    }

    /// Сколько измерений в окне.
    public var count: Int { samples.count }

    /// Среднее по окну; `nil`, если измерений нет.
    public var mean: SIMD3<Double>? {
        guard !samples.isEmpty else { return nil }
        return samples.reduce(SIMD3<Double>(repeating: 0)) { $0 + $1.value } / Double(samples.count)
    }

    /// Стандартное отклонение по каждой оси; `nil`, если измерений меньше двух.
    public var deviation: SIMD3<Double>? {
        guard samples.count > 1, let mean else { return nil }
        let squares = samples.reduce(SIMD3<Double>(repeating: 0)) { $0 + ($1.value - mean) * ($1.value - mean) }
        return (squares / Double(samples.count - 1)).squareRoot()
    }
}

/// Лицо обрезано краем кадра: рамка Vision подходит к краю ближе чем на `margin`.
///
/// По обрезанному лицу Vision дорисовывает глаза и контур наугад, и размер с центром лица врут.
///
/// - Parameters:
///   - box: рамка лица в долях кадра, начало внизу слева.
///   - margin: запас до края в долях кадра.
public func isFaceCropped(_ box: CGRect, margin: Double = 0.03) -> Bool {
    Double(box.minX) < margin || Double(box.minY) < margin || Double(box.maxX) > 1 - margin || Double(box.maxY) > 1 - margin
}
