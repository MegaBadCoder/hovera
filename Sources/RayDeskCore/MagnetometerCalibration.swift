import Foundation
import simd

/// Калибровка магнитометра очков: собственное поле очков (hard-iron) и параметры поля Земли.
///
/// Поле в сырых единицах датчика по осям тела; углы в радианах.
public struct MagnetometerCalibration: Codable, Equatable {
    /// Центр сферы показаний — постоянное поле самих очков.
    public var center: SIMD3<Double>
    /// Модуль поля Земли после вычитания `center`.
    public var radius: Double
    /// Угол между полем Земли и вертикалью вверх.
    public var dip: Double

    public init(center: SIMD3<Double>, radius: Double, dip: Double) {
        self.center = center
        self.radius = radius
        self.dip = dip
    }
}

/// Почему калибровка магнитометра отвергнута.
public enum MagnetometerCalibrationError: Error, Equatable {
    /// Собрано слишком мало отсчётов.
    case tooFewSamples(Int)
    /// Голова поворачивалась не во все стороны; значение — наименьшая дисперсия направлений поля.
    case insufficientCoverage(Double)
    /// Модуль поля слишком сильно гуляет; значение — относительный разброс радиуса.
    case noisyField(Double)
}

/// Собирает показания магнитометра, пока пользователь крутит головой, и вписывает в них сферу.
public struct HardIronFitter {
    public static let minSamples = 1500
    public static let maxRelativeSpread = 0.03
    public static let minSmallestSpread = 0.002
    public static let minMiddleSpread = 0.01

    private var fields: [SIMD3<Double>] = []
    private var ups: [SIMD3<Double>] = []

    public init() {}

    public var sampleCount: Int { fields.count }

    /// Добавляет отсчёт.
    ///
    /// - Parameters:
    ///   - magnetometer: поле по осям тела, сырые единицы.
    ///   - up: единичный вектор «вверх» по осям тела (нормированное показание акселерометра).
    public mutating func add(magnetometer: SIMD3<Double>, up: SIMD3<Double>) {
        fields.append(magnetometer)
        ups.append(up)
    }

    /// Вписывает сферу методом наименьших квадратов и проверяет качество.
    ///
    /// - Throws: `MagnetometerCalibrationError`, если отсчётов мало, охват направлений
    ///   недостаточен или модуль поля нестабилен.
    public func result() throws -> MagnetometerCalibration {
        guard fields.count >= HardIronFitter.minSamples else {
            throw MagnetometerCalibrationError.tooFewSamples(fields.count)
        }
        var normal = [[Double]](repeating: [Double](repeating: 0, count: 5), count: 4)
        for field in fields {
            let row = [2 * field.x, 2 * field.y, 2 * field.z, 1]
            let target = simd_length_squared(field)
            for i in 0..<4 {
                for j in 0..<4 { normal[i][j] += row[i] * row[j] }
                normal[i][4] += row[i] * target
            }
        }
        guard let solution = solve(normal) else {
            throw MagnetometerCalibrationError.insufficientCoverage(0)
        }
        let center = SIMD3(solution[0], solution[1], solution[2])
        let radiusSquared = solution[3] + simd_length_squared(center)
        guard radiusSquared > 0 else {
            throw MagnetometerCalibrationError.insufficientCoverage(0)
        }
        let radius = radiusSquared.squareRoot()

        let distances = fields.map { simd_length($0 - center) }
        let mean = distances.reduce(0, +) / Double(distances.count)
        let spread = (distances.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(distances.count)).squareRoot() / radius
        guard spread < HardIronFitter.maxRelativeSpread else {
            throw MagnetometerCalibrationError.noisyField(spread)
        }

        let directions = fields.map { simd_normalize($0 - center) }
        let spreads = principalVariances(directions)
        guard spreads[0] >= HardIronFitter.minSmallestSpread, spreads[1] >= HardIronFitter.minMiddleSpread else {
            throw MagnetometerCalibrationError.insufficientCoverage(spreads[0])
        }

        let dip = zip(directions, ups).map { acos(max(-1, min(1, simd_dot($0, simd_normalize($1))))) }.reduce(0, +) / Double(directions.count)
        return MagnetometerCalibration(center: center, radius: radius, dip: dip)
    }

    private func solve(_ matrix: [[Double]]) -> [Double]? {
        var m = matrix
        let n = 4
        for column in 0..<n {
            guard let pivot = (column..<n).max(by: { abs(m[$0][column]) < abs(m[$1][column]) }), abs(m[pivot][column]) > 1e-9 else { return nil }
            m.swapAt(column, pivot)
            for row in 0..<n where row != column {
                let factor = m[row][column] / m[column][column]
                for k in column...n { m[row][k] -= factor * m[column][k] }
            }
        }
        return (0..<n).map { m[$0][n] / m[$0][$0] }
    }

    private func principalVariances(_ vectors: [SIMD3<Double>]) -> [Double] {
        let count = Double(vectors.count)
        let mean = vectors.reduce(SIMD3<Double>(repeating: 0), +) / count
        var covariance = simd_double3x3(0)
        for vector in vectors {
            let d = vector - mean
            covariance += simd_double3x3(columns: (d * d.x, d * d.y, d * d.z))
        }
        return symmetricEigenvalues(covariance * (1 / count)).sorted()
    }

    private func symmetricEigenvalues(_ matrix: simd_double3x3) -> [Double] {
        var a = [[matrix[0][0], matrix[1][0], matrix[2][0]],
                 [matrix[0][1], matrix[1][1], matrix[2][1]],
                 [matrix[0][2], matrix[1][2], matrix[2][2]]]
        for _ in 0..<50 {
            var p = 0, q = 1
            for (i, j) in [(0, 1), (0, 2), (1, 2)] where abs(a[i][j]) > abs(a[p][q]) { (p, q) = (i, j) }
            guard abs(a[p][q]) > 1e-15 else { break }
            let theta = (a[q][q] - a[p][p]) / (2 * a[p][q])
            let t = (theta >= 0 ? 1.0 : -1.0) / (abs(theta) + (theta * theta + 1).squareRoot())
            let c = 1 / (t * t + 1).squareRoot()
            let s = t * c
            for k in 0..<3 {
                let akp = a[k][p], akq = a[k][q]
                a[k][p] = c * akp - s * akq
                a[k][q] = s * akp + c * akq
            }
            for k in 0..<3 {
                let apk = a[p][k], aqk = a[q][k]
                a[p][k] = c * apk - s * aqk
                a[q][k] = s * apk + c * aqk
            }
        }
        return [a[0][0], a[1][1], a[2][2]]
    }
}
