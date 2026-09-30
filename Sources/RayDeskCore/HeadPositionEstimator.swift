import CoreGraphics
import Foundation
import simd

/// Как видимое лицо зависит от поворота головы: при повороте рамка лица сужается, а её центр
/// уходит по дуге вокруг шеи. Числа по умолчанию подобраны по замеру камерой MacBook в очках RayNeo.
public struct FaceTurnModel: Sendable {
    /// Доля ширины рамки, которая не зависит от поворота: ширина ≈ `sizeFloor + (1 − sizeFloor)·cos(yaw) + sizeTilt·sin(yaw)`.
    public var sizeFloor: Double
    /// Несимметричная часть: камера стоит не прямо напротив лица, поэтому поворот в одну сторону
    /// сужает рамку сильнее, чем в другую.
    public var sizeTilt: Double
    /// Ниже этой доли рамка при повороте не сужается: в профиль Vision захватывает ухо и затылок.
    public var sizeLimit: Double
    /// Как размер лица зависит от наклона головы: размер ≈ `exp(−pitchSize·pitch)`, вниз — больше.
    public var pitchSize: Double
    /// Расстояние от оси поворота головы (шеи) до центра лица, метры.
    public var pivotRadius: Double

    public init(sizeFloor: Double = 0.30, sizeTilt: Double = -0.10, sizeLimit: Double = 0.70,
                pitchSize: Double = 0.2, pivotRadius: Double = 0.05) {
        self.sizeFloor = sizeFloor
        self.sizeTilt = sizeTilt
        self.sizeLimit = sizeLimit
        self.pitchSize = pitchSize
        self.pivotRadius = pivotRadius
    }

    /// Во сколько раз рамка лица меньше, чем при взгляде прямо, при повороте головы на `yaw`
    /// и наклоне на `pitch` радиан относительно опорного положения.
    public func sizeFactor(yaw: Double, pitch: Double = 0) -> Double {
        max(sizeLimit, sizeFloor + (1 - sizeFloor) * cos(yaw) + sizeTilt * sin(yaw)) * exp(-pitchSize * pitch)
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
        let factor = turn.sizeFactor(yaw: yaw, pitch: pitch)
        let straightened = CGRect(x: face.midX - face.width / factor / 2, y: face.midY - face.height / factor / 2,
                                  width: face.width / factor, height: face.height / factor)
        let facePosition = camera.headPosition(face: straightened)
        return facePosition - SIMD3(turn.pivotRadius * sin(yaw), turn.pivotRadius * sin(pitch), 0)
    }
}

/// Где середина выученной формы очков относительно оси поворота головы в шее, метры: вперёд и вверх.
/// Та же геометрия, что у `eyesFromNeck` (глаза на 8 см впереди и 7 см выше шеи), очки на 2 см впереди глаз:
/// если бы камера и дуга глаз по гироскопу считали шею в разных местах, при кивке глаза «уезжали» бы на 4 см.
public let glassesFromNeck = (forward: 0.10, up: 0.07)

/// На сколько метров ниже очков ось, вокруг которой голова наклоняется к плечу: боковой наклон идёт
/// по всей шее, поэтому ось ниже, чем у кивка. Подобрано по записям: при наклонах к плечу на 12–60°
/// медианная ошибка шеи 9–23 мм вместо 46–52 мм без учёта наклона.
public let sideBendRadius = 0.15

/// Положение шеи в осях камеры по положению очков: очки при повороте, кивке и наклоне к плечу ходят
/// по дуге вокруг шеи.
///
/// - Parameters:
///   - glasses: середина выученной формы очков в осях камеры, метры; x — вправо по кадру (влево
///     от пользователя), y — вверх, z — от камеры.
///   - yaw: поворот головы относительно направления на камеру, радианы, плюс — влево от пользователя.
///   - pitch: наклон головы относительно опорного, радианы, плюс — вверх.
///   - roll: наклон головы к плечу относительно вертикали, радианы, плюс — к левому плечу пользователя.
/// - Returns: метры, в тех же осях.
public func neckPosition(fromGlasses glasses: SIMD3<Double>, yaw: Double, pitch: Double, roll: Double = 0) -> SIMD3<Double> {
    let forward = SIMD3(sin(yaw) * cos(pitch), sin(pitch), -cos(yaw) * cos(pitch))
    let up = SIMD3(-sin(yaw) * sin(pitch), cos(pitch), cos(yaw) * sin(pitch))
    let side = SIMD3(cos(yaw), 0, sin(yaw))
    let bend = sideBendRadius * ((cos(roll) - 1) * up + sin(roll) * side)
    return glasses - glassesFromNeck.forward * forward - glassesFromNeck.up * up - bend
}

extension simd_quatd {
    /// Наклон головы к плечу относительно вертикали, радианы, плюс — к левому плечу; не зависит от курса.
    public var sideTilt: Double {
        let right = act(SIMD3(1, 0, 0)), up = act(SIMD3(0, 1, 0))
        return atan2(right.y, up.y)
    }
}

/// Насколько занижена глубина по точкам лица MediaPipe при повороте головы влево-вправо: ось вглубь
/// у модели растянута, и повёрнутое лицо кажется крупнее. Доля на (1 − cos поворота).
public let turnDepthStretch = 0.20
/// То же для наклона вверх-вниз: симметричная часть на (1 − cos наклона) и несимметричная на sin наклона.
public let tiltDepthStretch = (symmetric: 0.0, asymmetric: -0.10)

/// Исправляет глубину, измеренную по точкам лица или по выученной форме очков, на поворот и наклон головы.
///
/// Коэффициенты подобраны по записям так, чтобы при чистом повороте или наклоне головы шея оставалась
/// на месте: разброс шеи по поворотам до 60° сократился с 69 до 12 мм, по наклонам от −30° до +20° —
/// с 17–64 до 4–24 мм на трёх записях с одинаковыми коэффициентами.
///
/// - Parameters:
///   - depth: измеренная глубина, любые единицы.
///   - turn: поворот головы от положения «лицом к камере», радианы: x — влево, y — вверх.
/// - Returns: глубина в тех же единицах.
public func depthCorrectedForTurn(_ depth: Double, turn: SIMD2<Double>) -> Double {
    depth * (1 + turnDepthStretch * (1 - cos(turn.x)) + tiltDepthStretch.symmetric * (1 - cos(turn.y))
                 + tiltDepthStretch.asymmetric * sin(turn.y))
}

/// Плавное приближение к цели с ограничением скорости: убирает ступеньки от редких измерений
/// и не даёт картинке прыгнуть, когда измерение резко меняется.
public struct RateLimitedFollower: Sendable {
    /// Постоянная времени приближения, секунды.
    public var timeConstant: Double
    /// Наибольшая скорость движения, единицы в секунду.
    public var maxSpeed: Double
    /// Текущее значение.
    public private(set) var value = SIMD3<Double>(repeating: 0)

    public init(timeConstant: Double, maxSpeed: Double) {
        self.timeConstant = timeConstant
        self.maxSpeed = maxSpeed
    }

    /// Сдвигает значение к цели за время `dt` секунд и возвращает новое значение.
    public mutating func follow(_ target: SIMD3<Double>, dt: Double) -> SIMD3<Double> {
        var step = (target - value) * (1 - exp(-dt / timeConstant))
        let limit = maxSpeed * dt
        let length = simd_length(step)
        if length > limit { step *= limit / length }
        value += step
        return value
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

/// Запоминает опорное положение, пока пользователь спокойно смотрит в камеру: куда в этот момент
/// повёрнуты очки (там и стоит камера), их наклон и положение шеи.
public struct CameraReferenceLearner: Sendable {
    /// Что запомнено.
    public struct Reference: Equatable, Sendable {
        /// Поворот очков на камеру, радианы, плюс — влево.
        public var cameraYaw: Double
        /// Наклон очков при взгляде в камеру, радианы, плюс — вверх.
        public var pitch: Double
        /// Среднее положение шеи в осях камеры, метры.
        public var neck: SIMD3<Double>
    }

    /// Сколько секунд голова должна стоять спокойно.
    public var window: Double
    /// Наибольший разброс поворота и наклона очков за окно, радианы.
    public var maxSpread: Double
    /// Наименьшее число кадров в окне.
    public var minSamples: Int
    private var samples: [(neck: SIMD3<Double>, yaw: Double, pitch: Double, time: Double)] = []

    public init(window: Double = 1, maxSpread: Double = 5 * .pi / 180, minSamples: Int = 10) {
        self.window = window
        self.maxSpread = maxSpread
        self.minSamples = minSamples
    }

    /// Добавляет кадр; если голова шевельнулась сильнее `maxSpread`, окно начинается заново с этого кадра.
    ///
    /// - Parameters:
    ///   - neck: положение шеи в осях камеры, метры.
    ///   - yaw: поворот очков в мире, радианы.
    ///   - pitch: наклон очков, радианы.
    ///   - time: время кадра, секунды, по возрастанию.
    /// - Returns: опора, когда окно набрано; до этого `nil`.
    public mutating func add(neck: SIMD3<Double>, yaw: Double, pitch: Double, time: Double) -> Reference? {
        let unwrapped = samples.first.map { $0.yaw + remainder(yaw - $0.yaw, 2 * .pi) } ?? yaw
        samples.append((neck, unwrapped, pitch, time))
        let yaws = samples.map(\.yaw)
        let pitches = samples.map(\.pitch)
        if yaws.max()! - yaws.min()! > maxSpread || pitches.max()! - pitches.min()! > maxSpread {
            samples = [(neck, unwrapped, pitch, time)]
            return nil
        }
        guard time - samples[0].time >= window, samples.count >= minSamples else { return nil }
        let count = Double(samples.count)
        let meanYaw = yaws.reduce(0, +) / count
        return Reference(cameraYaw: remainder(meanYaw, 2 * .pi), pitch: pitches.reduce(0, +) / count,
                         neck: samples.map(\.neck).reduce(.zero, +) / count)
    }

    /// Забывает набранные кадры.
    public mutating func reset() {
        samples = []
    }
}
