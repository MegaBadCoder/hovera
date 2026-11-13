import Foundation
import simd

/// Ограниченное сглаживание ориентации в покое с прямым выходом при распознанном движении.
public struct RestPoseStabilizer {
    /// Наибольшее отклонение результата от входной ориентации, радианы.
    public static let maximumCorrectionRadians = RestStabilizationStrength.light.maximumCorrectionRadians
    /// Распознано ли спокойное состояние после непрерывного интервала наблюдения.
    public var isResting: Bool { phase == .resting }
    /// Состояние, определившее последний результат фильтра.
    public private(set) var phase: RestStabilizationPhase = .waiting
    /// Угловая поправка последнего результата относительно входа, радианы.
    public private(set) var correctionRadians = 0.0

    /// Допустимый коэффициент расширения угловых и скоростных порогов покоя.
    public static let toleranceRange: ClosedRange<Double> = 1...16

    private static let restDwellSeconds = 0.2
    private static let enterSpeed = 0.6 * Double.pi / 180
    private static let exitSpeed = 0.65 * Double.pi / 180
    private static let immediateExitSpeed = 1.8 * Double.pi / 180
    private static let maximumImmediateExitTolerance = 8.0
    private static let maximumRestExcursion = 0.12 * Double.pi / 180
    private static let maximumEntryExcursion = 0.03 * Double.pi / 180
    private static let motionTimeConstant = 0.04
    private var previousMotion: simd_quatd?
    private var previousTime: Double?
    private var filtered: simd_quatd?
    private var anchor: simd_quatd?
    private var directionalVelocity = SIMD3<Double>.zero
    private var quietSince: Double?
    private var quietAnchor: simd_quatd?
    private var motionMean: simd_quatd?

    public init() {}

    /// Возвращает позу с ограниченной поправкой либо исходную позу при движении или отключении.
    /// - Parameters:
    ///   - orientation: единичная ориентация голова→мир после прогноза.
    ///   - motion: исходная единичная ориентация до прогноза для детектора движения.
    ///   - time: монотонное время наблюдения, секунды.
    ///   - enabled: включён ли режим сглаживания только в покое.
    ///   - stable: достоверен ли трекинг; при `false` состояние сбрасывается.
    ///   - strength: сила сглаживания и предел угловой поправки в покое.
    ///   - tolerance: множитель порогов движения; ограничивается `toleranceRange`, нечисловое значение заменяется единицей.
    /// - Returns: ориентация с отклонением не более предела `strength`; после паузы от0.1с — исходная.
    public mutating func filter(_ orientation: simd_quatd, motion: simd_quatd, at time: Double,
                                enabled: Bool, stable: Bool, strength: RestStabilizationStrength = .light, tolerance: Double = 1) -> simd_quatd {
        let tolerance = tolerance.isFinite ? min(Self.toleranceRange.upperBound, max(Self.toleranceRange.lowerBound, tolerance)) : 1
        guard enabled, stable, time.isFinite, let previousMotion, let previousTime,
              time > previousTime, time - previousTime < 0.1 else {
            reset(orientation, motion: motion, at: time, phase: !enabled ? .disabled : !stable ? .unavailable : .waiting)
            return orientation
        }
        let dt = time - previousTime
        self.previousMotion = motion
        self.previousTime = time
        let velocity = rotationVector(motion * previousMotion.inverse) / dt
        let motionWeight = 1 - exp(-dt / Self.motionTimeConstant)
        directionalVelocity += (velocity - directionalVelocity) * motionWeight
        let mean = simd_slerp(motionMean ?? motion, motion, motionWeight)
        motionMean = mean
        let escaped = isResting && anchor.map { angularDistance(motion, $0) > Self.maximumRestExcursion * tolerance } == true
        if length(velocity) >= Self.immediateExitSpeed * min(tolerance, Self.maximumImmediateExitTolerance) || length(directionalVelocity) >= Self.exitSpeed * tolerance || escaped {
            filtered = orientation
            anchor = motion
            quietSince = nil
            quietAnchor = nil
            phase = .moving
            correctionRadians = 0
            return orientation
        }
        if !isResting {
            phase = .waiting
            if length(directionalVelocity) <= Self.enterSpeed * tolerance {
                if quietSince == nil || quietAnchor.map({ angularDistance(mean, $0) > Self.maximumEntryExcursion * tolerance }) == true {
                    quietSince = time
                    quietAnchor = mean
                }
                if time - (quietSince ?? time) >= Self.restDwellSeconds {
                    phase = .resting
                    anchor = motion
                }
            } else { quietSince = nil; quietAnchor = nil; phase = .moving }
            filtered = orientation
            correctionRadians = 0
            return orientation
        }
        let candidate = simd_slerp(filtered ?? orientation, orientation, 1 - exp(-dt / strength.timeConstant))
        let deviation = angularDistance(candidate, orientation)
        let result = deviation > strength.maximumCorrectionRadians
            ? simd_slerp(orientation, candidate, strength.maximumCorrectionRadians / deviation) : candidate
        filtered = simd_normalize(result)
        correctionRadians = angularDistance(result, orientation)
        return filtered ?? orientation
    }

    private mutating func reset(_ orientation: simd_quatd, motion: simd_quatd, at time: Double, phase: RestStabilizationPhase) {
        previousMotion = motion
        previousTime = time.isFinite ? time : nil
        filtered = orientation
        anchor = motion
        directionalVelocity = .zero
        quietSince = nil
        quietAnchor = nil
        motionMean = motion
        self.phase = phase
        correctionRadians = 0
    }

    private func rotationVector(_ quaternion: simd_quatd) -> SIMD3<Double> {
        let q = quaternion.real < 0 ? simd_quatd(vector: -quaternion.vector) : quaternion
        let magnitude = length(q.imag)
        guard magnitude > 1e-12 else { return .zero }
        return q.imag * (2 * atan2(magnitude, abs(q.real)) / magnitude)
    }

    private func angularDistance(_ a: simd_quatd, _ b: simd_quatd) -> Double {
        length(rotationVector(a * b.inverse))
    }
}
