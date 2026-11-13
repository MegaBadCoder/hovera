import CoreGraphics

/// Семейство очков, которые Hovera умеет выводить на экран.
///
/// Семейство определяет, какое разрешение панели считать родным: у RayNeo Air
/// это 1920×1080, у VITURE — 1920×1200.
public enum GlassesDisplayFamily: String, Sendable {
    case rayNeo
    case viture

    /// Родное разрешение панели в пикселях.
    public var nativePixelSize: (width: Int, height: Int) {
        switch self {
        case .rayNeo: (1920, 1080)
        case .viture: (1920, 1200)
        }
    }

    /// Предпочтительная частота панели, Гц; конкретный режим выбирается из доступных устройству.
    public var targetRefreshRate: Double {
        switch self {
        case .rayNeo: 120
        case .viture: 120
        }
    }
}

/// Один режим дисплея очков, как его видит macOS.
public struct DisplayModeOption: Equatable, Sendable {
    public var pointWidth: Int
    public var pointHeight: Int
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var refreshRate: Double
    public var usableForDesktop: Bool

    public init(pointWidth: Int, pointHeight: Int, pixelWidth: Int, pixelHeight: Int, refreshRate: Double, usableForDesktop: Bool = true) {
        self.pointWidth = pointWidth
        self.pointHeight = pointHeight
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.refreshRate = refreshRate
        self.usableForDesktop = usableForDesktop
    }
}

/// Семейство очков по имени дисплея, которое даёт macOS.
///
/// - Parameter name: `localizedName` дисплея (`NSScreen.localizedName`).
/// - Returns: семейство, либо `nil`, если имя не похоже ни на одни поддерживаемые очки.
public func glassesDisplayFamily(forDisplayName name: String) -> GlassesDisplayFamily? {
    let lowered = name.lowercased()
    if lowered.contains("viture") { return .viture }
    if lowered.contains("rayneo") || lowered.contains("smartglasses") { return .rayNeo }
    return nil
}

/// Семейство очков, с которыми сейчас работает приложение.
///
/// VITURE важнее остальных признаков: его поза приходит в рендер и перекрывает
/// ориентацию RayNeo-фильтра. HID-устройство RayNeo важнее имени дисплея: имя
/// остаётся в системе при смене режима панели и после отключения очков.
///
/// - Parameters:
///   - vitureConnected: в USB есть очки VITURE.
///   - rayNeoConnected: открыто HID-устройство RayNeo.
///   - displayName: `localizedName` дисплея очков, если он есть.
/// - Returns: семейство либо `nil`, если очков не видно.
public func activeGlassesFamily(vitureConnected: Bool, rayNeoConnected: Bool, displayName: String?) -> GlassesDisplayFamily? {
    if vitureConnected { return .viture }
    if rayNeoConnected { return .rayNeo }
    guard let displayName else { return nil }
    return glassesDisplayFamily(forDisplayName: displayName)
}

/// Выбирает режим дисплея очков, в котором картинка выводится без масштабирования.
///
/// Режим должен быть без HiDPI и дублей: точки совпадают с пикселями, родное
/// разрешение панели, частота ближе к целевой для семейства. Масштабированные режимы macOS
/// (когда точек меньше, чем пикселей) не годятся: картинка прошла бы через
/// даунсемплинг системы и потеряла резкость.
///
/// - Parameters:
///   - modes: режимы, которые macOS предлагает для дисплея очков.
///   - family: семейство очков, задаёт родное разрешение.
/// - Returns: подходящий режим, либо `nil`, если такого нет.
public func chooseGlassesDisplayMode(_ modes: [DisplayModeOption], family: GlassesDisplayFamily) -> DisplayModeOption? {
    let native = family.nativePixelSize
    return modes
        .filter { mode in
            mode.usableForDesktop
                && mode.pointWidth == mode.pixelWidth
                && mode.pointHeight == mode.pixelHeight
                && mode.pixelWidth == native.width
                && mode.pixelHeight == native.height
        }
        .min { abs($0.refreshRate - family.targetRefreshRate) < abs($1.refreshRate - family.targetRefreshRate) }
}
