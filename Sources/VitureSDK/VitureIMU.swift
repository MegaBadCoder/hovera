import Foundation
import simd

/// Пересчёт сырого IMU VITURE Carina (Luma Ultra) в локальные оси позы OpenGL.
/// Сырые оси: X — влево, Y — назад, Z — вверх; оси позы: X — вправо, Y — вверх, Z — назад.
public enum VitureIMU {
    /// Угловая скорость в осях позы: X вправо, Y вверх, Z назад.
    ///
    /// - Parameter raw: `[gx, gy, gz]` в сырых осях Carina, как их отдал SDK.
    /// - Returns: вектор в осях OpenGL; единицы сохраняются.
    public static func bodyAngularVelocity(_ raw: SIMD3<Double>) -> SIMD3<Double> {
        SIMD3(-raw.x, raw.z, raw.y)
    }

    /// Ускорение в осях позы: X вправо, Y вверх, Z назад.
    ///
    /// - Parameter raw: `[ax, ay, az]` в сырых осях Carina, как их отдал SDK.
    /// - Returns: вектор в осях OpenGL; единицы сохраняются.
    public static func bodyAcceleration(_ raw: SIMD3<Double>) -> SIMD3<Double> {
        SIMD3(-raw.x, raw.z, raw.y)
    }

    /// Единицы угловой скорости источника, одинаковые для всех отсчётов сессии.
    public enum AngularVelocityUnit: String, Sendable {
        case radians
        case degrees
    }

    /// Приводит угловую скорость к рад/с по явно выбранным единицам, без оценки по величине.
    /// По умолчанию вход уже задан в рад/с; для источников в градусах укажите `.degrees`.
    public static func radiansPerSecond(_ values: SIMD3<Double>, unit: AngularVelocityUnit = .radians) -> SIMD3<Double> {
        unit == .degrees ? values * .pi / 180 : values
    }
}
