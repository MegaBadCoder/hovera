import simd

/// Предсказывает ориентацию по скорости между кадрами, сохраняя текущую позу без сглаживания.
public struct WorldLockPrediction {
    private var previousOrientation: simd_quatd?
    private var previousTime: Double?
    private var previousReadTime: Double?
    private var angularVelocity = SIMD3<Double>.zero

    public init() {}

    /// Последняя оценка мировой угловой скорости, рад/с; обнуляется при недостоверном времени или паузе.
    public var predictionAngularVelocity: SIMD3<Double> { angularVelocity }

    /// Возвращает ориентацию голова→мир на заданный горизонт от текущей позы.
    /// - Parameters:
    ///   - orientation: текущий единичный quaternion голова→мир.
    ///   - time: монотонное время обновления перепроекции в секундах.
    ///   - sampleTime: время исходной позы в той же шкале; `nil` использует время перепроекции.
    ///   - horizon: неотрицательный горизонт прогноза в секундах.
    ///   - smoothing: применять к скорости формулу `0,4 × новая + 0,6 × предыдущая`.
    /// - Returns: текущая ориентация с прогнозом; после паузы от 100 мс прогноз обнуляется.
    public mutating func predict(_ orientation: simd_quatd, at time: Double, sampleTime: Double? = nil,
                                 horizon: Double, smoothing: Bool = true) -> simd_quatd {
        let readTime = time
        let time = sampleTime ?? readTime
        defer { previousReadTime = readTime }
        guard time.isFinite, readTime.isFinite, readTime - time < 0.1, time - readTime < 0.005,
              previousReadTime.map({ readTime - $0 < 0.1 && readTime >= $0 }) ?? true else {
            previousOrientation = orientation
            previousTime = time
            angularVelocity = .zero
            return orientation
        }
        if time == previousTime {
            if let previousOrientation, abs(simd_dot(previousOrientation.vector, orientation.vector)) < 1 - 1e-12 {
                self.previousOrientation = orientation
                angularVelocity = .zero
            }
            return extrapolated(orientation, horizon: horizon)
        }
        defer {
            previousOrientation = orientation
            previousTime = time
        }
        guard let previousOrientation, let previousTime else { return orientation }
        let dt = time - previousTime
        guard dt > 0.0005, dt < 0.1 else {
            angularVelocity = .zero
            return orientation
        }
        var delta = orientation * previousOrientation.inverse
        if delta.real < 0 { delta = simd_quatd(vector: -delta.vector) }
        let magnitude = length(delta.imag)
        let angle = 2 * atan2(magnitude, abs(delta.real))
        let measured = angle > 0.00001 ? delta.imag * (angle / (magnitude * dt)) : .zero
        angularVelocity = smoothing ? measured * 0.4 + angularVelocity * 0.6 : measured
        return extrapolated(orientation, horizon: horizon)
    }

    private func extrapolated(_ orientation: simd_quatd, horizon: Double) -> simd_quatd {
        let speed = length(angularVelocity)
        let predictedAngle = speed * max(0, horizon)
        guard predictedAngle > 0.000001 else { return orientation }
        return simd_normalize(simd_quatd(angle: predictedAngle, axis: angularVelocity / speed) * orientation)
    }
}
