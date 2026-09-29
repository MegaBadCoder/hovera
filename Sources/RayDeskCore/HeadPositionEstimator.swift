import CoreGraphics
import Foundation
import simd

/// Как видимое лицо зависит от поворота головы: при повороте рамка лица сужается, а её центр
/// уходит по дуге вокруг шеи. Числа по умолчанию подобраны по замеру камерой MacBook в очках RayNeo.
public struct FaceTurnModel: Sendable {
    /// Доля ширины рамки, которая не зависит от поворота: ширина ≈ `sizeFloor + (1 − sizeFloor)·cos(yaw)`.
    public var sizeFloor: Double
    /// Расстояние от оси поворота головы (шеи) до центра лица, метры.
    public var pivotRadius: Double

    public init(sizeFloor: Double = 0.30, pivotRadius: Double = 0.10) {
        self.sizeFloor = sizeFloor
        self.pivotRadius = pivotRadius
    }

    /// Во сколько раз рамка лица уже, чем при взгляде в камеру, при повороте головы на `yaw` радиан.
    public func sizeFactor(yaw: Double) -> Double {
        sizeFloor + (1 - sizeFloor) * cos(yaw)
    }
}

/// Положение шеи относительно камеры по рамке лица с поправкой на поворот головы.
///
/// Поворот головы берётся из датчика очков относительно опорного — того, при котором лицо
/// смотрит на камеру. Без поправки поворот к боковому монитору выглядит для камеры как
/// отъезд и сдвиг вбок.
public struct HeadPositionEstimator: Sendable {
    public var camera: FaceCamera
    public var turn: FaceTurnModel

    public init(camera: FaceCamera, turn: FaceTurnModel = FaceTurnModel()) {
        self.camera = camera
        self.turn = turn
    }

    /// Положение шеи в осях камеры.
    ///
    /// - Parameters:
    ///   - face: рамка лица в долях кадра, начало внизу слева (как в Vision).
    ///   - yaw: поворот головы относительно опорного, радианы, плюс — влево от пользователя.
    ///   - pitch: наклон головы относительно опорного, радианы, плюс — вверх.
    /// - Returns: метры; x — вправо по кадру (влево от пользователя), y — вверх, z — от камеры.
    public func neckPosition(face: CGRect, yaw: Double, pitch: Double) -> SIMD3<Double> {
        let factor = max(turn.sizeFactor(yaw: yaw), 0.2)
        let straightened = CGRect(x: face.midX - face.width / factor / 2, y: face.midY - face.height / factor / 2,
                                  width: face.width / factor, height: face.height / factor)
        let facePosition = camera.headPosition(face: straightened)
        return facePosition - SIMD3(turn.pivotRadius * sin(yaw), turn.pivotRadius * sin(pitch), 0)
    }
}

/// Экспоненциальное сглаживание вектора с разной постоянной времени по осям.
public struct VectorSmoother: Sendable {
    /// Постоянные времени по осям, секунды.
    public var timeConstants: SIMD3<Double>
    /// Текущее сглаженное значение; `nil` до первого измерения.
    public private(set) var value: SIMD3<Double>?

    public init(timeConstants: SIMD3<Double>) {
        self.timeConstants = timeConstants
    }

    /// Добавляет измерение.
    ///
    /// - Parameters:
    ///   - sample: измерение.
    ///   - dt: время с прошлого измерения, секунды.
    public mutating func add(_ sample: SIMD3<Double>, dt: Double) {
        guard let current = value else {
            value = sample
            return
        }
        let blend = SIMD3<Double>(1, 1, 1) - SIMD3(exp(-dt / timeConstants.x), exp(-dt / timeConstants.y), exp(-dt / timeConstants.z))
        value = current + (sample - current) * blend
    }

    /// Забывает накопленное значение.
    public mutating func reset() {
        value = nil
    }
}

/// Сдвиг головы из осей камеры в мировые оси очков (X вправо, Y вверх, Z назад).
///
/// Камера смотрит на пользователя, поэтому её «вправо по кадру» — это влево от пользователя,
/// а «от камеры» — назад. `cameraYaw` — где камера в мире (0 — прямо впереди, плюс — левее).
public func worldOffset(fromCamera offset: SIMD3<Double>, cameraYaw: Double = 0) -> SIMD3<Double> {
    let facingCamera = SIMD3(-offset.x, offset.y, offset.z)
    return simd_quatd(angle: cameraYaw, axis: SIMD3(0, 1, 0)).act(facingCamera)
}
