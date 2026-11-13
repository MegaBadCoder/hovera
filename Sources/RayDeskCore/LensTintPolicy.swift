import Foundation
import simd

/// Направление на физический монитор в координатах трекинга, углы в радианах.
public struct PhysicalMonitorDirection: Equatable, Sendable {
    public var yaw: Double
    public var pitch: Double

    public init(yaw: Double, pitch: Double) {
        self.yaw = yaw
        self.pitch = pitch
    }

    /// Проверяет попадание направления головы в область монитора шириной 36° и высотой 24°.
    public func contains(head: simd_quatd) -> Bool {
        let direction = head.yawPitch
        return abs(remainder(direction.yaw - yaw, 2 * .pi)) <= 18 * .pi / 180
            && abs(direction.pitch - pitch) <= 12 * .pi / 180
    }
}

/// Переключает затемнение после устойчивого взгляда на виртуальный или физический экран.
public struct LensTintPolicy: Sendable {
    private var applied: Bool?
    private var candidate: Bool?
    private var candidateSince = 0.0
    private var lastObservation: Double?
    public init() {}

    /// Возвращает новое затемнение: `true` для виртуального экрана, `false` для физического.
    /// `nil` означает отсутствие команды; время задаётся монотонными секундами.
    public mutating func update(target: CursorTarget?, time: Double) -> Bool? {
        defer { lastObservation = time }
        let desired = target.map { $0 != .mac }
        guard let desired else {
            candidate = nil
            return nil
        }
        if let previous = lastObservation, time < previous || time - previous > 0.5 {
            candidate = nil
        }
        guard desired != applied else {
            candidate = nil
            return nil
        }
        if candidate != desired {
            candidate = desired
            candidateSince = time
        }
        guard time - candidateSince >= 0.35 else { return nil }
        applied = desired
        candidate = nil
        return desired
    }
}
