import Foundation
import simd

/// Учит смещение нуля гироскопа по всем трём осям: сравнивает поворот по гироскопу с поворотом
/// векторов тяжести и магнитного поля в осях очков за несколько секунд почти неподвижной головы.
///
/// Поле у головы может быть искажено железом, но, пока голова стоит на месте, оно не меняется,
/// поэтому поворот векторов верен и при помехе. Так видно и смещение по вертикали, которого не
/// показывает тяжесть. Окно пропускается, если голова повернулась больше `maxRotation`, двигалась
/// с ускорением или поле изменилось само (сила или угол между полем и тяжестью): в таких окнах
/// ошибки калибровки компаса, толчки и поднесённый магнит испортили бы оценку.
public struct VectorBiasLearner {
    /// Длина блока, по которому усредняются векторы, секунды.
    public static let blockSeconds = 0.5
    /// Сколько блоков от первого до последнего в окне сравнения.
    public static let windowBlocks = 6
    /// Наибольший поворот за окно по векторам, при котором окно принимается, радианы.
    public static let maxRotation = 5 * Double.pi / 180
    /// Наибольший разброс модуля ускорения внутри окна, g.
    public static let maxAccelSpread = 0.01
    /// Наибольшее отличие среднего модуля ускорения от 1 g, g.
    public static let maxAccelDeviation = 0.03
    /// Наибольшее относительное изменение силы поля между началом и концом окна.
    public static let maxFieldChange = 0.02
    /// Наибольшее изменение угла между полем и тяжестью между началом и концом окна, радианы.
    public static let maxDipChange = 1 * Double.pi / 180
    /// Постоянная времени обучения по принятым окнам, секунды.
    public static let learningSeconds = 5.0

    /// Текущая оценка смещения нуля по осям тела, рад/с.
    public private(set) var bias: SIMD3<Double>

    /// Сдвигает оценку нуля, не сбрасывая накопленное окно: так она переезжает вместе
    /// с поправкой восстановителя, в чьей системе координат живёт.
    ///
    /// - Parameter delta: приращение оценки, рад/с по осям тела.
    public mutating func shiftBias(by delta: SIMD3<Double>) {
        bias += delta
    }

    private var blocks: [Block] = []
    private var current = Block()

    /// - Parameter bias: начальная оценка, например сохранённая с прошлого запуска, рад/с.
    public init(bias: SIMD3<Double> = SIMD3(repeating: 0)) {
        self.bias = bias
    }

    /// Добавляет отсчёт IMU.
    ///
    /// - Parameters:
    ///   - gyro: угловая скорость по осям тела без вычета смещения, рад/с.
    ///   - accel: ускорение по осям тела, g.
    ///   - field: магнитное поле по осям тела за вычетом поля самих очков (центра калибровки)
    ///     или `nil`, если в отсчёте его нет.
    ///   - dt: время с прошлого отсчёта, секунды.
    public mutating func add(gyro: SIMD3<Double>, accel: SIMD3<Double>, field: SIMD3<Double>?, dt: Double) {
        current.add(gyro: gyro, accel: accel, field: field, dt: dt)
        guard current.duration >= VectorBiasLearner.blockSeconds else { return }
        blocks.append(current)
        current = Block()
        if blocks.count > VectorBiasLearner.windowBlocks + 1 { blocks.removeFirst() }
        guard blocks.count == VectorBiasLearner.windowBlocks + 1, let error = windowError() else { return }
        bias += (error - bias) * min(1, VectorBiasLearner.blockSeconds / VectorBiasLearner.learningSeconds)
    }

    private func windowError() -> SIMD3<Double>? {
        let first = blocks[0], last = blocks[blocks.count - 1]
        let samples = blocks.reduce(0) { $0 + $1.count }
        let meanNorm = blocks.reduce(0) { $0 + $1.normSum } / Double(samples)
        let normSpread = max(0, blocks.reduce(0) { $0 + $1.normSquares } / Double(samples) - meanNorm * meanNorm).squareRoot()
        guard normSpread < VectorBiasLearner.maxAccelSpread, abs(meanNorm - 1) < VectorBiasLearner.maxAccelDeviation,
              first.fieldCount > 0, last.fieldCount > 0 else { return nil }

        let fieldBefore = first.fieldSum / Double(first.fieldCount)
        let fieldAfter = last.fieldSum / Double(last.fieldCount)
        let upBefore = normalize(first.accelSum), upAfter = normalize(last.accelSum)
        let northBefore = normalize(fieldBefore), northAfter = normalize(fieldAfter)
        guard abs(length(fieldAfter) / length(fieldBefore) - 1) < VectorBiasLearner.maxFieldChange,
              abs(acos(max(-1, min(1, dot(upBefore, northBefore)))) - acos(max(-1, min(1, dot(upAfter, northAfter))))) < VectorBiasLearner.maxDipChange
        else { return nil }

        let identity = matrix_identity_double3x3
        let normal = (identity - outer(upBefore, upBefore)) + (identity - outer(northBefore, northBefore))
        guard abs(normal.determinant) > 1e-6 else { return nil }
        let seen = normal.inverse * (cross(upAfter, upBefore) + cross(northAfter, northBefore))
        guard length(seen) < VectorBiasLearner.maxRotation else { return nil }

        let middle = blocks.dropFirst().dropLast()
        let turned = (first.rotation + last.rotation) / 2 + middle.reduce(SIMD3<Double>(repeating: 0)) { $0 + $1.rotation }
        let span = (first.duration + last.duration) / 2 + middle.reduce(0) { $0 + $1.duration }
        return (turned - seen) / span
    }

    private func outer(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> simd_double3x3 {
        simd_double3x3(columns: (a * b.x, a * b.y, a * b.z))
    }

    private struct Block {
        var count = 0
        var duration = 0.0
        var rotation = SIMD3<Double>(repeating: 0)
        var accelSum = SIMD3<Double>(repeating: 0)
        var normSum = 0.0
        var normSquares = 0.0
        var fieldSum = SIMD3<Double>(repeating: 0)
        var fieldCount = 0

        mutating func add(gyro: SIMD3<Double>, accel: SIMD3<Double>, field: SIMD3<Double>?, dt: Double) {
            count += 1
            duration += dt
            rotation += gyro * dt
            accelSum += accel
            let norm = length(accel)
            normSum += norm
            normSquares += norm * norm
            if let field {
                fieldSum += field
                fieldCount += 1
            }
        }
    }
}
