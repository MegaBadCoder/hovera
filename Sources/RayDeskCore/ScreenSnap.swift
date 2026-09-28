import Foundation
import simd

/// Боковая сторона экрана.
public enum ScreenSide: Sendable {
    case left, right

    var sign: Double { self == .right ? 1 : -1 }
    var opposite: ScreenSide { self == .right ? .left : .right }
}

/// Как соседние экраны стыкуются краями.
public enum ScreenJoin: String, CaseIterable, Sendable {
    /// Стык по взгляду: экраны встают вплотную по углу поворота, с общей высотой, расстоянием
    /// и наклоном; остаются ровными, но при наклоне верх и низ стыка слегка расходятся.
    case gaze
    /// Стык петлёй: экран поворачивается вокруг края соседа, край общий по всей длине;
    /// боковые экраны наклонённой дуги чуть поворачиваются в своей плоскости.
    case hinge
}

/// Итог прилипания: поза экрана и сосед, к которому он прилип (`nil` — не прилип).
public struct SnapResult: Equatable, Sendable {
    public var pose: ScreenPose
    public var neighbor: Int?
}

/// Половина угловой ширины экрана по горизонтали, видимая из головы, радианы.
public func horizontalHalfAngle(_ pose: ScreenPose) -> Double {
    atan(pose.width / 2 / (pose.distance * cos(pose.pitch)))
}

/// Середина бокового края экрана в мировых осях, метры.
public func edgeMidpoint(_ pose: ScreenPose, _ side: ScreenSide) -> SIMD3<Double> {
    pose.center + pose.right * (side.sign * pose.width / 2)
}

/// Ставит экран вплотную к стороне `side` соседа.
///
/// При стыке `.gaze` экран встаёт рядом по углу поворота и берёт у соседа высоту взгляда,
/// расстояние и наклон, без поворотов в плоскости и вокруг вертикали. При стыке `.hinge`
/// экран поворачивается вокруг края соседа, как створка на петле, пока не посмотрит на голову:
/// общий край совпадает по всей длине. Ширина и соотношение сторон экрана сохраняются.
///
/// - Parameters:
///   - pose: экран, который прикрепляется.
///   - neighbour: экран, к которому прикрепляется.
///   - side: сторона соседа, к которой прикрепляется экран.
///   - join: способ стыковки.
public func attached(_ pose: ScreenPose, to neighbour: ScreenPose, on side: ScreenSide, join: ScreenJoin) -> ScreenPose {
    switch join {
    case .gaze:
        var result = pose
        result.pitch = neighbour.pitch
        result.distance = neighbour.distance
        result.tilt = neighbour.tilt
        result.roll = 0
        result.pan = 0
        result.yaw = neighbour.yaw - side.sign * (horizontalHalfAngle(neighbour) + horizontalHalfAngle(result))
        return result
    case .hinge:
        let hinge = edgeMidpoint(neighbour, side)
        let right = neighbour.right
        let toward = neighbour.normal
        let s = side.sign
        let er = dot(hinge, right)
        let en = dot(hinge, toward)
        let ratio = max(-1, min(1, -s * pose.width / 2 / hypot(er, en)))
        let alpha = atan2(en, er)
        let turn = [acos(ratio) - alpha, -acos(ratio) - alpha].map { remainder($0, 2 * .pi) }.min { abs($0) < abs($1) }!
        let newRight = right * cos(turn) - toward * sin(turn)
        let center = hinge + newRight * (s * pose.width / 2)
        return ScreenPose(center: center, right: newRight, up: neighbour.up, width: pose.width, aspect: pose.aspect)
    }
}

/// Прилепляет экран боковым краем к ближайшему соседу, если края ближе порога.
///
/// Близость — угол между направлениями из головы на середины соседних краёв. Соседи, чьи
/// центры по высоте дальше половины высоты большего из двух экранов, не рассматриваются.
///
/// - Parameters:
///   - pose: поза экрана до прилипания.
///   - index: индекс этого экрана в `screens`; сам с собой не сравнивается.
///   - screens: позы всех экранов.
///   - threshold: наибольший угол между краями, при котором экран прилипает, радианы.
///   - join: способ стыковки.
public func snapped(_ pose: ScreenPose, index: Int, among screens: [ScreenPose], threshold: Double, join: ScreenJoin) -> SnapResult {
    var best: (gap: Double, pose: ScreenPose, neighbor: Int)?
    for (other, neighbour) in screens.enumerated() where other != index {
        let halfHeight = atan(max(pose.height, neighbour.height) / 2 / neighbour.distance)
        guard abs(pose.pitch - neighbour.pitch) < halfHeight else { continue }
        for side in [ScreenSide.left, .right] {
            let theirs = normalize(edgeMidpoint(neighbour, side))
            let mine = normalize(edgeMidpoint(pose, side.opposite))
            let gap = acos(max(-1, min(1, dot(theirs, mine))))
            guard gap < threshold, gap < (best?.gap ?? .infinity) else { continue }
            best = (gap, attached(pose, to: neighbour, on: side, join: join), other)
        }
    }
    guard let best else { return SnapResult(pose: pose, neighbor: nil) }
    return SnapResult(pose: best.pose, neighbor: best.neighbor)
}

/// Поворачивает экран вокруг вертикали на `angle` (плюс — лицо экрана влево).
///
/// Если боковой край экрана совпадает с краем соседа (стык петлёй), экран поворачивается
/// вокруг этого общего края и стык не расходится; иначе — вокруг своей вертикальной оси
/// через центр.
///
/// - Parameters:
///   - index: индекс экрана в `screens`.
///   - screens: позы всех экранов.
///   - angle: угол поворота, радианы.
public func turned(_ index: Int, among screens: [ScreenPose], by angle: Double) -> ScreenPose {
    let pose = screens[index]
    var pivot = pose.center
    search: for (other, neighbour) in screens.enumerated() where other != index {
        for side in [ScreenSide.left, .right] {
            let shared = edgeMidpoint(pose, side)
            if length(shared - edgeMidpoint(neighbour, side.opposite)) < 0.005,
               abs(dot(pose.up, neighbour.up)) > 0.9999 {
                pivot = shared
                break search
            }
        }
    }
    let spin = simd_quatd(angle: angle, axis: pose.up)
    return ScreenPose(center: pivot + spin.act(pose.center - pivot), right: spin.act(pose.right), up: pose.up,
                      width: pose.width, aspect: pose.aspect)
}
