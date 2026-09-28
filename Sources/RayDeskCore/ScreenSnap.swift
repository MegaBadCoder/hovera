import Foundation

/// Половина угловой ширины экрана по горизонтали, видимая из головы, радианы.
public func horizontalHalfAngle(_ pose: ScreenPose) -> Double {
    atan(pose.width / 2 / (pose.distance * cos(pose.pitch)))
}

/// Итог прилипания: поза экрана и сосед, к которому он прилип (`nil` — не прилип).
public struct SnapResult: Equatable, Sendable {
    public var pose: ScreenPose
    public var neighbor: Int?
}

/// Прилепляет экран боковым краем к ближайшему соседу, если зазор между краями меньше порога.
///
/// Прилипший экран встаёт вплотную (в угловой мере из головы) и берёт у соседа pitch,
/// расстояние и наклон; ширина и соотношение сторон остаются свои. Соседи, чьи центры
/// по высоте дальше половины высоты большего из двух экранов, не рассматриваются.
///
/// - Parameters:
///   - pose: поза экрана до прилипания.
///   - index: индекс этого экрана в `screens`; сам с собой не сравнивается.
///   - screens: позы всех экранов.
///   - threshold: наибольший зазор или перекрытие краёв, при котором экран прилипает, радианы.
public func snapped(_ pose: ScreenPose, index: Int, among screens: [ScreenPose], threshold: Double) -> SnapResult {
    var best: (gap: Double, pose: ScreenPose, neighbor: Int)?
    for (other, neighbour) in screens.enumerated() where other != index {
        let halfHeight = atan(max(pose.height, neighbour.height) / 2 / neighbour.distance)
        guard abs(pose.pitch - neighbour.pitch) < halfHeight else { continue }
        var candidate = pose
        candidate.pitch = neighbour.pitch
        candidate.distance = neighbour.distance
        candidate.tilt = neighbour.tilt
        let touching = horizontalHalfAngle(neighbour) + horizontalHalfAngle(candidate)
        let offset = remainder(pose.yaw - neighbour.yaw, 2 * .pi)
        let side: Double = offset >= 0 ? 1 : -1
        let gap = abs(abs(offset) - touching)
        guard gap < threshold, gap < (best?.gap ?? .infinity) else { continue }
        candidate.yaw = neighbour.yaw + side * touching
        best = (gap, candidate, other)
    }
    guard let best else { return SnapResult(pose: pose, neighbor: nil) }
    return SnapResult(pose: best.pose, neighbor: best.neighbor)
}
