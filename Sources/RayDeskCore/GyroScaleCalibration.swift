import Foundation
import simd

/// Калибровка масштаба гироскопа полными оборотами: очки лежат на столе, пока ноль гироскопа
/// усредняется, потом их поворачивают на `turns` полных оборотов и возвращают к тому же упору.
/// Масштаб — отношение точного угла к тому, что насчитал гироскоп вокруг вертикали.
public struct GyroScaleCalibration: Sendable {
    public enum Stage: Equatable, Sendable {
        /// Ждём, пока очки полежат неподвижно.
        case waitingForRest
        /// Ноль измерен — можно поворачивать.
        case readyToTurn
        /// Очки поворачивают.
        case turning
        /// Готово: во сколько раз умножать показания гироскопа вокруг вертикальной оси очков.
        case finished(scale: Double, measuredDegrees: Double)
        /// Не получилось.
        case failed(Failure)
    }

    public enum Failure: Equatable, Sendable {
        /// Очки лежат не так, как на голове: вертикальная ось очков не смотрит вверх.
        case notUpright
        /// Насчитанный угол слишком далёк от заданного числа оборотов.
        case wrongTurnCount(measuredDegrees: Double)
    }

    /// Сколько полных оборотов нужно сделать.
    public let turns: Int
    public private(set) var stage = Stage.waitingForRest

    private var restSeconds = 0.0
    private var restGyro = SIMD3<Double>(repeating: 0)
    private var restAccel = SIMD3<Double>(repeating: 0)
    private var restSamples = 0
    private var bias = SIMD3<Double>(repeating: 0)
    private var up = SIMD3<Double>(0, 1, 0)
    private var angle = 0.0
    private var moved = false
    private var stillAfterMove = 0.0

    private static let restNeeded = 3.0
    private static let stillAfterMoveNeeded = 2.0
    private static let stillRate = 3 * Double.pi / 180
    private static let movingRate = 10 * Double.pi / 180
    private static let tolerance = 0.12

    public init(turns: Int = 2) {
        self.turns = turns
    }

    /// Добавляет отсчёт датчика и возвращает текущую стадию.
    ///
    /// - Parameters:
    ///   - gyro: угловая скорость по осям очков, рад/с, без поправки масштаба.
    ///   - accel: ускорение по осям очков, g.
    ///   - dt: время с прошлого отсчёта, секунды.
    @discardableResult
    public mutating func add(gyro: SIMD3<Double>, accel: SIMD3<Double>, dt: Double) -> Stage {
        guard dt > 0, dt < 0.1 else { return stage }
        switch stage {
        case .waitingForRest:
            let still = length(gyro) < Self.stillRate && abs(length(accel) - 1) < 0.05
            guard still else {
                restSeconds = 0; restGyro = .zero; restAccel = .zero; restSamples = 0
                return stage
            }
            restSeconds += dt
            restGyro += gyro
            restAccel += accel
            restSamples += 1
            if restSeconds >= Self.restNeeded {
                bias = restGyro / Double(restSamples)
                up = normalize(restAccel / Double(restSamples))
                stage = up.y > 0.85 ? .readyToTurn : .failed(.notUpright)
            }
        case .readyToTurn, .turning:
            let rate = dot(gyro - bias, up)
            angle += rate * dt
            if abs(rate) > Self.movingRate {
                moved = true
                stage = .turning
                stillAfterMove = 0
            } else if moved, abs(rate) < Self.stillRate {
                stillAfterMove += dt
                if stillAfterMove >= Self.stillAfterMoveNeeded {
                    let measured = abs(angle)
                    let expected = Double(turns) * 2 * .pi
                    let degrees = measured * 180 / .pi
                    stage = abs(measured / expected - 1) < Self.tolerance
                        ? .finished(scale: expected / measured, measuredDegrees: degrees)
                        : .failed(.wrongTurnCount(measuredDegrees: degrees))
                }
            }
        case .finished, .failed:
            break
        }
        return stage
    }
}
