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
/// ставится слева от самого левого экрана, по его верхнему краю: нижний край `main`
/// остаётся свободным, и Dock не уезжает на дисплей очков.
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
    let leftmost = origins[order[0]]
    let glassesOrigin = CGPoint(x: (leftmost.x - glasses.width).rounded(), y: leftmost.y)
    return (origins, glassesOrigin)
}

/// Куда на самом деле поставить курсор после движения мыши.
///
/// Раскладка дисплеев macOS не совпадает с тем, что пользователь видит в пространстве,
/// поэтому переходы между панелями и экраном Mac делаются пропорционально ширине, а
/// на дисплей очков курсор не пускается. Боковые переходы панель↔панель и обычные
/// движения не трогаются.
///
/// - Parameters:
///   - previous: где курсор был до события, глобальные точки.
///   - proposed: куда его поставила macOS.
///   - delta: сырое смещение мыши в событии (по `y` вниз положительно).
///   - panels: границы виртуальных панелей по индексу.
///   - main: границы встроенного экрана Mac.
///   - glasses: границы дисплея очков.
///   - preferredPanel: панель под взглядом, куда вести курсор с экрана Mac.
/// - Returns: новая точка курсора, либо `nil`, если вмешиваться не нужно.
public func remappedCursor(previous: CGPoint, proposed: CGPoint, delta: CGVector,
                           panels: [CGRect], main: CGRect, glasses: CGRect, preferredPanel: Int?) -> CGPoint? {
    if glasses.contains(proposed) {
        return previous
    }
    if let panel = panels.first(where: { $0.contains(previous) }) {
        let atBottom = previous.y >= panel.maxY - 1 && delta.dy > 0 && panel.contains(proposed)
        guard main.contains(proposed) || atBottom else { return nil }
        let u = (previous.x - panel.minX) / panel.width
        return CGPoint(x: main.minX + u * main.width, y: main.minY + 1)
    }
    if main.contains(previous) {
        let enteredPanel = panels.firstIndex(where: { $0.contains(proposed) })
        let atTop = previous.y <= main.minY + 1 && delta.dy < 0 && main.contains(proposed)
        guard enteredPanel != nil || atTop, let index = preferredPanel ?? enteredPanel, panels.indices.contains(index) else { return nil }
        let panel = panels[index]
        let u = (previous.x - main.minX) / main.width
        return CGPoint(x: panel.minX + u * panel.width, y: panel.maxY - 1)
    }
    return nil
}
