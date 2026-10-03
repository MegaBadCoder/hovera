import Foundation
import simd

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
