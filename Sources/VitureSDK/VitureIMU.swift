import Foundation
import simd

/// Пересчёт сырого IMU VITURE в оси позы.
///
/// SDK отдаёт IMU в осях NWU: X — вперёд (север), Y — влево (запад), Z — вверх.
/// Поза `get_gl_pose_carina` и наш рендер живут в осях OpenGL: X — вправо,
/// Y — вверх, Z — назад. Без этого пересчёта гироскоп крутит мир вокруг чужих
/// осей, и при поворотах головы картинка кренится и кивает не туда.
public enum VitureIMU {
    /// Угловая скорость в осях позы: X вправо, Y вверх, Z назад.
    ///
    /// - Parameter raw: `[gx, gy, gz]` в осях NWU, как их отдал SDK.
    /// - Returns: вектор в осях OpenGL; единицы сохраняются.
    public static func bodyAngularVelocity(_ raw: SIMD3<Double>) -> SIMD3<Double> {
        SIMD3(-raw.y, raw.z, -raw.x)
    }

    /// Ускорение в осях позы: X вправо, Y вверх, Z назад.
    ///
    /// - Parameter raw: `[ax, ay, az]` в осях NWU, как их отдал SDK.
    /// - Returns: вектор в осях OpenGL; единицы сохраняются.
    public static func bodyAcceleration(_ raw: SIMD3<Double>) -> SIMD3<Double> {
        SIMD3(-raw.y, raw.z, -raw.x)
    }

    /// Приводит угловую скорость к радианам в секунду.
    ///
    /// Единицы IMU-колбэка в документации не заданы: если значения приходят
    /// в градусах, они выходят за разумный диапазон радиан и пересчитываются.
    ///
    /// - Parameter values: угловая скорость в осях тела.
    /// - Returns: та же скорость в рад/с.
    public static func radiansPerSecond(_ values: SIMD3<Double>) -> SIMD3<Double> {
        let magnitude = length(values)
        guard magnitude.isFinite, magnitude > 0.001 else { return values }
        return magnitude > 20 ? values * .pi / 180 : values
    }
}
