import Foundation

/// Удерживает курс при возвращении к запомненному положению лица. Нос относительно
/// глаз различает небольшие повороты, которые грубая оценка yaw Vision может пропустить.
public struct CameraYawAnchor: Sendable {
    public struct Pose: Sendable {
        public var yaw: Double
        public var pitch: Double
        public var roll: Double
        public var nose: Double
        public init(yaw: Double, pitch: Double, roll: Double, nose: Double) {
            self.yaw = yaw; self.pitch = pitch; self.roll = roll; self.nose = nose
        }
        var isFinite: Bool { yaw.isFinite && pitch.isFinite && roll.isFinite && nose.isFinite }
    }
    private var reference: (pose: Pose, yaw: Double)?
    private var candidate: (pose: Pose, yaw: Double, start: Double)?
    private var previousTime: Double?
    private var settledSince: Double?
    private static let degree = Double.pi / 180

    public init() {}

    public mutating func reset() { self = Self() }

    public mutating func worldYawChanged(by delta: Double) {
        reference?.yaw += delta
        candidate = nil
        previousTime = nil
        settledSince = nil
    }

    /// nil/некачественный кадр сразу прерывает накопление спокойного интервала.
    public mutating func update(pose: Pose?, headYaw: Double, speed: Double,
                                time: Double, latency: Double) -> Double {
        let dt = previousTime.map { time - $0 } ?? 0
        previousTime = time
        guard let pose, pose.isFinite, headYaw.isFinite, speed.isFinite,
              time.isFinite, latency.isFinite, latency >= 0, latency < 0.2,
              speed < 5 * Self.degree, abs(pose.yaw) < 20 * Self.degree,
              abs(pose.pitch) < 25 * Self.degree, abs(pose.roll) < 15 * Self.degree,
              dt > 0, dt < 0.2 else {
            candidate = nil; settledSince = nil
            return 0
        }
        guard let reference else {
            if let value = candidate, matches(pose, value.pose),
               abs(remainder(headYaw - value.yaw, 2 * .pi)) < Self.degree {
                if time - value.start >= 1 {
                    reference = (value.pose, value.yaw)
                    candidate = nil
                }
            } else {
                candidate = (pose, headYaw, time)
            }
            return 0
        }
        guard matches(pose, reference.pose) else {
            settledSince = nil
            return 0
        }
        if settledSince == nil { settledSince = time }
        guard time - settledSince! >= 0.6 else { return 0 }
        let error = remainder(reference.yaw - headYaw, 2 * .pi)
        // Большое расхождение может означать новое лицо или перемещение камеры.
        guard abs(error) < 10 * Self.degree else { return 0 }
        let outsideBand = max(0, abs(error) - 0.3 * Self.degree)
        let rate = min(0.25 * Self.degree, outsideBand / 6)
        return (error < 0 ? -1 : 1) * rate * dt
    }

    private func matches(_ a: Pose, _ b: Pose) -> Bool {
        abs(a.yaw - b.yaw) < 2 * Self.degree &&
        abs(a.pitch - b.pitch) < 5 * Self.degree &&
        abs(a.roll - b.roll) < 5 * Self.degree && abs(a.nose - b.nose) < 0.025
    }
}
