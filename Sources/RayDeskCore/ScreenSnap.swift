import Foundation
import simd

/// Боковая сторона экрана.
public enum ScreenSide: Sendable {
    case left, right

    var sign: Double { self == .right ? 1 : -1 }
    var opposite: ScreenSide { self == .right ? .left : .right }
}

/// Итог прилипания: поза экрана и сосед, к которому он прилип (`nil` — не прилип).
public struct SnapResult: Equatable, Sendable {
    public var pose: ScreenPose
    public var neighbor: Int?
}

/// Середина бокового края экрана в мировых осях, метры.
public func edgeMidpoint(_ pose: ScreenPose, _ side: ScreenSide) -> SIMD3<Double> {
    pose.center + pose.right * (side.sign * pose.width / 2)
}

/// Ставит экран вплотную к стороне `side` соседа, как створку на петле: общий край совпадает
/// по всей длине, экран повёрнут вокруг этого края так, чтобы смотреть на голову.
/// Ширина и соотношение сторон экрана сохраняются, по высоте он центрируется на крае соседа.
///
/// - Parameters:
///   - pose: экран, который прикрепляется.
///   - neighbour: экран, к которому прикрепляется.
///   - side: сторона соседа, к которой прикрепляется экран.
public func attached(_ pose: ScreenPose, to neighbour: ScreenPose, on side: ScreenSide) -> ScreenPose {
    let hinge = edgeMidpoint(neighbour, side)
    let right = neighbour.right
    let toward = neighbour.normal
    let up = neighbour.up
    let s = side.sign
    let er = dot(hinge, right)
    let en = dot(hinge, toward)
    let radius = hypot(er, en)
    let ratio = max(-1, min(1, -s * pose.width / 2 / radius))
    let alpha = atan2(en, er)
    let candidates = [acos(ratio) - alpha, -acos(ratio) - alpha].map { remainder($0, 2 * .pi) }
    let turn = candidates.min { abs($0) < abs($1) }!
    let newRight = right * cos(turn) - toward * sin(turn)
    let center = hinge + newRight * (s * pose.width / 2)
    return ScreenPose(center: center, right: newRight, up: up, width: pose.width, aspect: pose.aspect)
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
public func snapped(_ pose: ScreenPose, index: Int, among screens: [ScreenPose], threshold: Double) -> SnapResult {
    var best: (gap: Double, pose: ScreenPose, neighbor: Int)?
    for (other, neighbour) in screens.enumerated() where other != index {
        let halfHeight = atan(max(pose.height, neighbour.height) / 2 / neighbour.distance)
        guard abs(pose.pitch - neighbour.pitch) < halfHeight else { continue }
        for side in [ScreenSide.left, .right] {
            let theirs = normalize(edgeMidpoint(neighbour, side))
            let mine = normalize(edgeMidpoint(pose, side.opposite))
            let gap = acos(max(-1, min(1, dot(theirs, mine))))
            guard gap < threshold, gap < (best?.gap ?? .infinity) else { continue }
            best = (gap, attached(pose, to: neighbour, on: side), other)
        }
    }
    guard let best else { return SnapResult(pose: pose, neighbor: nil) }
    return SnapResult(pose: best.pose, neighbor: best.neighbor)
}
