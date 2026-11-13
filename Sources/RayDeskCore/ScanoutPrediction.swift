import simd

/// Ориентации верхней и нижней строки относительно уже предсказанной позы начала представления.
public struct ScanoutPrediction {
    /// Ориентация камера→мир для верхней строки.
    public let top: simd_quatd
    /// Ориентация камера→мир для нижней строки.
    public let bottom: simd_quatd
    /// Фактически разрешённая разница времён первой и последней строки, секунды.
    public let duration: Double

    /// Создаёт пару поз, добавляя к reference только время развёртки.
    /// - Parameters:
    ///   - reference: единичная поза первой сканируемой строки камера→мир.
    ///   - angularVelocity: мировая угловая скорость в рад/с.
    ///   - duration: предполагаемая длительность развёртки, секунды.
    ///   - maximumAdditionalTime: остаток разрешённого горизонта трекера, секунды.
    ///   - enabled: разрешать ли дополнительный прогноз; false сохраняет reference для обеих строк.
    ///   - bottomToTop: сканировать ли снизу вверх; reference относится к нижней строке.
    public init(reference: simd_quatd, angularVelocity: SIMD3<Double>, duration: Double,
                maximumAdditionalTime: Double, enabled: Bool, bottomToTop: Bool) {
        let speed = length(angularVelocity)
        let valid = enabled && duration.isFinite && maximumAdditionalTime.isFinite && speed.isFinite
        self.duration = valid ? max(0, min(duration, maximumAdditionalTime)) : 0
        let angle = speed * self.duration
        let last = angle > 1e-6
            ? simd_normalize(simd_quatd(angle: angle, axis: angularVelocity / speed) * reference) : reference
        top = bottomToTop ? last : reference
        bottom = bottomToTop ? reference : last
    }
}
