import CoreGraphics

private let maxPitch = 80 * Double.pi / 180
private let minDistance = 0.4
private let maxDistance = 6.0

/// Возвращает позу экрана после перетаскивания мышью на `delta` точек экрана.
///
/// Экран сдвигается так, чтобы точка под курсором осталась под курсором:
/// угловая скорость перетаскивания равна `angularWidth / displayPointWidth`.
/// Pitch ограничен диапазоном ±80°.
///
/// - Parameters:
///   - pose: исходная поза экрана.
///   - delta: смещение курсора в точках экрана дисплея (x вправо, y вниз).
///   - displayPointWidth: ширина экрана дисплея в точках, на котором происходит перетаскивание.
public func dragged(_ pose: ScreenPose, byPoints delta: CGVector, displayPointWidth: Double) -> ScreenPose {
    let k = pose.angularWidth / displayPointWidth
    var result = pose
    result.yaw -= Double(delta.dx) * k
    result.pitch = min(maxPitch, max(-maxPitch, result.pitch - Double(delta.dy) * k))
    return result
}

/// Возвращает позу экрана после прокрутки на `delta` (положительное значение приближает экран).
///
/// Дистанция умножается на `1.05^(-delta)` и ограничивается диапазоном 0.4…6 м.
public func scrolled(_ pose: ScreenPose, by delta: Double) -> ScreenPose {
    var result = pose
    result.distance = min(maxDistance, max(minDistance, result.distance * pow(1.05, -delta)))
    return result
}
