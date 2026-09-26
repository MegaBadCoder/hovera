import CoreGraphics

/// Переводит координаты `uv` (u вправо, v вниз, [0,1]²) в глобальную точку внутри `bounds`.
public func globalPoint(uv: SIMD2<Double>, in bounds: CGRect) -> CGPoint {
    CGPoint(x: bounds.minX + uv.x * bounds.width, y: bounds.minY + uv.y * bounds.height)
}

/// Переводит глобальную точку в координаты `uv` относительно `bounds`.
///
/// - Returns: `uv`, либо `nil`, если точка лежит вне `bounds`.
public func uv(of point: CGPoint, in bounds: CGRect) -> SIMD2<Double>? {
    guard point.x >= bounds.minX, point.x < bounds.maxX, point.y >= bounds.minY, point.y < bounds.maxY else {
        return nil
    }
    return SIMD2((point.x - bounds.minX) / bounds.width, (point.y - bounds.minY) / bounds.height)
}

/// Раскладка виртуальных дисплеев macOS в глобальных координатах.
///
/// Виртуальные экраны выстраиваются в ряд над `main` слева направо по убыванию
/// `screenYaws`, вплотную друг к другу, по центру над `main`. Дисплей очков
/// ставится вплотную под `main`, выровненный по левому краю.
///
/// - Parameters:
///   - screenYaws: yaw каждого экрана (радианы), в исходном порядке.
///   - screenSizes: размер каждого экрана в точках, в исходном порядке.
///   - main: границы основного дисплея (MacBook).
///   - glasses: размер дисплея очков в точках.
/// - Returns: origin каждого виртуального экрана (в исходном порядке) и origin дисплея очков.
public func arrangeDisplays(screenYaws: [Double], screenSizes: [CGSize], main: CGRect, glasses: CGSize) -> (screens: [CGPoint], glasses: CGPoint) {
    let order = screenYaws.indices.sorted { screenYaws[$0] > screenYaws[$1] }
    let totalWidth = order.reduce(0) { $0 + screenSizes[$1].width }
    var origins = [CGPoint](repeating: .zero, count: screenYaws.count)
    var x = main.midX - totalWidth / 2
    for index in order {
        let size = screenSizes[index]
        let y = main.minY - size.height
        origins[index] = CGPoint(x: (x).rounded(), y: y.rounded())
        x += size.width
    }
    let glassesOrigin = CGPoint(x: main.minX.rounded(), y: main.maxY.rounded())
    return (origins, glassesOrigin)
}
