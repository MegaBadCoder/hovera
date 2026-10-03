import Foundation
import simd

/// Где глаза головы относительно оси поворота в шее, метры в осях головы (X вправо, Y вверх,
/// вперёд — −Z): при повороте головы глаза ходят по дуге вокруг шеи.
public let eyesFromNeck = SIMD3<Double>(0, 0.07, -0.08)

/// Сдвиг глаз из-за поворота головы относительно опорной ориентации, мировые оси, метры.
public func eyeArcOffset(head: simd_quatd, reference: simd_quatd, eyes: SIMD3<Double> = eyesFromNeck) -> SIMD3<Double> {
    head.act(eyes) - reference.act(eyes)
}
