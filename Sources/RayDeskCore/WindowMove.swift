import CoreGraphics

/// Рамка окна после переноса с одного дисплея на другой.
///
/// Окно сохраняет своё относительное место: доля свободного места слева и сверху на исходном
/// дисплее переносится на целевой (прижатое к краю остаётся у края, по центру — по центру).
/// Окно, которое больше целевого дисплея, ужимается до его размера. Все рамки — в одних
/// глобальных координатах (начало слева сверху).
///
/// - Parameters:
///   - window: рамка окна.
///   - source: рабочая область дисплея, на котором окно сейчас.
///   - target: рабочая область дисплея, куда окно переносится.
public func movedWindowFrame(_ window: CGRect, from source: CGRect, to target: CGRect) -> CGRect {
    let size = CGSize(width: min(window.width, target.width), height: min(window.height, target.height))
    func share(_ offset: CGFloat, free: CGFloat) -> CGFloat {
        free > 0 ? min(1, max(0, offset / free)) : 0.5
    }
    let x = share(window.minX - source.minX, free: source.width - window.width)
    let y = share(window.minY - source.minY, free: source.height - window.height)
    return CGRect(x: target.minX + x * (target.width - size.width),
                  y: target.minY + y * (target.height - size.height),
                  width: size.width, height: size.height)
}
