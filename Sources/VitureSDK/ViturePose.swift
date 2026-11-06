import Foundation
import simd

/// Поза очков VITURE в осях OpenGL: X вправо, Y вверх, Z назад (вперёд — −Z).
///
/// SDK отдаёт позу как 7 чисел `[px, py, pz, qw, qx, qy, qz]` и переводит её
/// в мировые оси мира, относительно которых VIO считает гравитацию и курс.
public struct ViturePose: Equatable, Sendable {
    /// Положение в метрах.
    public var position: SIMD3<Double>
    /// Ориентация «мир → устройство».
    public var orientation: simd_quatd
    /// Монотонная метка времени SDK, секунды.
    public var timestamp: Double
    /// Трекинг стабилен; после старта устройства короткое время бывает неустойчивым.
    public var isStable: Bool

    public init(position: SIMD3<Double>, orientation: simd_quatd, timestamp: Double, isStable: Bool) {
        self.position = position
        self.orientation = simd_normalize(orientation)
        self.timestamp = timestamp
        self.isStable = isStable
    }

    /// Читает позу из массива SDK: `[px, py, pz, qw, qx, qy, qz]`.
    ///
    /// - Parameters:
    ///   - floats: указатель на 7 чисел, как их отдаёт SDK.
    ///   - timestamp: метка времени, секунды.
    ///   - isStable: статус трекинга из SDK.
    public init(floats: UnsafePointer<Float>, timestamp: Double, isStable: Bool) {
        self.init(position: SIMD3(Double(floats[0]), Double(floats[1]), Double(floats[2])),
                  orientation: simd_quatd(ix: Double(floats[4]), iy: Double(floats[5]),
                                          iz: Double(floats[6]), r: Double(floats[3])),
                  timestamp: timestamp,
                  isStable: isStable)
    }

    /// Поза в виде массива для `xr_device_provider_reset_origin_carina`.
    public var floats: [Float] {
        [Float(position.x), Float(position.y), Float(position.z),
         Float(orientation.real), Float(orientation.imag.x), Float(orientation.imag.y), Float(orientation.imag.z)]
    }
}
