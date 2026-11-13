import simd

/// Выбирает синхронизацию вывода по покою и сохраняет компенсацию движения в Adaptive VSync.
public struct RestPresentationController {
    /// Фактическое состояние детектора покоя.
    public var phase: RestStabilizationPhase { detector.phase }
    /// Включена ли вертикальная синхронизация следующего кадра.
    public private(set) var displaySyncEnabled = true
    /// Применено ли сглаживание ориентации к последнему кадру.
    public private(set) var isSmoothing = false
    /// Поправка последней ориентации, радианы; в Adaptive VSync равна нулю.
    public private(set) var correctionRadians = 0.0

    private var detector = RestPoseStabilizer()
    private var restingSince: Double?
    private static let unsynchronizedRestDwell = 0.15

    public init() {}

    /// Возвращает ориентацию показа и обновляет режим синхронизации.
    /// - Parameters:
    ///   - orientation: прогнозная единичная ориентация камера→мир.
    ///   - motion: ориентация до прогноза для обнаружения движения.
    ///   - time: монотонное время, секунды.
    ///   - restSmoothing: разрешено ли сглаживание ориентации при отключённом Adaptive VSync.
    ///   - adaptiveVSync: переключать ли синхронизацию по покою, возвращая `orientation` без сглаживания.
    ///   - stable: достоверен ли свежий трекинг; при `false` синхронизация включается.
    ///   - strength: сила сглаживания вне Adaptive VSync.
    ///   - tolerance: коэффициент порогов покоя в пределах `RestPoseStabilizer.toleranceRange`.
    /// - Returns: исходная прогнозная ориентация в Adaptive VSync либо результат выбранного сглаживания.
    public mutating func filter(_ orientation: simd_quatd, motion: simd_quatd, at time: Double,
                                restSmoothing: Bool, adaptiveVSync: Bool, stable: Bool,
                                strength: RestStabilizationStrength, tolerance: Double) -> simd_quatd {
        let filtered = detector.filter(orientation, motion: motion, at: time,
                                       enabled: restSmoothing || adaptiveVSync, stable: stable,
                                       strength: strength, tolerance: tolerance)
        if adaptiveVSync, detector.isResting {
            if restingSince == nil { restingSince = time }
            displaySyncEnabled = time - (restingSince ?? time) < Self.unsynchronizedRestDwell
        } else {
            restingSince = nil
            displaySyncEnabled = true
        }
        isSmoothing = !adaptiveVSync && restSmoothing && detector.isResting
        correctionRadians = isSmoothing ? detector.correctionRadians : 0
        return adaptiveVSync ? orientation : filtered
    }
}
