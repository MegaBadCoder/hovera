import Foundation
import simd

/// Куда может попасть курсор: виртуальная панель по индексу или встроенный экран Mac.
public enum CursorTarget: Hashable, Codable, Sendable {
    case virtual(Int)
    case mac
}

/// Цель курсора под взглядом и точка на ней (u вправо, v вниз, [0,1]²).
public struct CursorHit: Equatable {
    public var target: CursorTarget
    public var uv: SIMD2<Double>

    public init(target: CursorTarget, uv: SIMD2<Double>) {
        self.target = target
        self.uv = uv
    }
}

/// Цель курсора под взглядом: ближайшая панель, иначе — экран MacBook.
///
/// Панели проверяются первыми: пока луч попадает в панель, курсор остаётся на ней.
/// Взгляд ниже `lookDownPitch`, не попавший ни в одну панель, считается взглядом
/// в центр экрана MacBook — без запомненной точки и без маркера в пространстве,
/// потому что без камер окружения такая точка всё равно плывёт.
///
/// - Parameters:
///   - head: ориентация головы голова→мир.
///   - screens: позы виртуальных панелей, индекс — номер панели.
///   - origin: положение головы в мировых координатах, метры; то же, что используется при отрисовке.
///   - lookDownPitch: порог наклона взгляда вниз, радианы.
public func cursorHit(head: simd_quatd, screens: [ScreenPose], origin: SIMD3<Double> = .zero, lookDownPitch: Double = -30 * .pi / 180) -> CursorHit? {
    if let hit = gazeHit(head: head, screens: screens, origin: origin) {
        return CursorHit(target: .virtual(hit.screen), uv: hit.uv)
    }
    if head.yawPitch.pitch < lookDownPitch {
        return CursorHit(target: .mac, uv: SIMD2(0.5, 0.5))
    }
    return nil
}
