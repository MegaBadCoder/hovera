import Foundation
import simd

/// Ручная поправка ориентации головы, которую пользователь выставляет по сетке горизонта.
///
/// `yaw` поворачивает мир вокруг вертикали (где «вперёд»), `pitch` и `roll` — поправка
/// на угол, под которым датчик стоит относительно оптики очков. Углы в радианах.
public struct ViewCalibration: Codable, Equatable {
    public var yaw: Double
    public var pitch: Double
    public var roll: Double

    public init(yaw: Double = 0, pitch: Double = 0, roll: Double = 0) {
        self.yaw = yaw
        self.pitch = pitch
        self.roll = roll
    }

    /// Применяет поправку к ориентации головы из фильтра.
    ///
    /// - Parameter head: ориентация голова→мир из `OrientationFilter`.
    /// - Returns: ориентация, по которой строится картинка, взгляд и прыжок курсора.
    public func apply(to head: simd_quatd) -> simd_quatd {
        simd_quatd(angle: yaw, axis: SIMD3(0, 1, 0))
            * head
            * simd_quatd(angle: pitch, axis: SIMD3(1, 0, 0))
            * simd_quatd(angle: roll, axis: SIMD3(0, 0, 1))
    }
}
