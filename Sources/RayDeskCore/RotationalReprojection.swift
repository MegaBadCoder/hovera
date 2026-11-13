import simd

/// Обратная проекция пикселей дисплея в текстуру сцены при изменении только ориентации камеры.
public struct RotationalReprojection {
    /// Поворот луча из камеры показа в камеру, которой отрисована сцена.
    public let sceneFromDisplay: simd_float3x3
    /// Поворот луча нижней строки в камеру сцены; при обычной проекции совпадает с верхней.
    public let sceneFromDisplayBottom: simd_float3x3
    /// Тангенсы половин горизонтального и вертикального углов обзора дисплея.
    public let displayTangents: SIMD2<Float>
    /// Тангенсы половин углов обзора текстуры сцены с запасом по краям.
    public let sceneTangents: SIMD2<Float>

    /// Создаёт проекцию для ориентаций камера→мир и неизменного положения камеры.
    /// - Parameters:
    ///   - scene: ориентация камеры отрисовки.
    ///   - display: ориентация камеры показа.
    ///   - verticalFOV: вертикальный угол обзора дисплея, радианы в диапазоне (0, π).
    ///   - aspect: положительное отношение ширины дисплея к высоте.
    ///   - overscan: увеличение тангенсов углов обзора по X/Y; компоненты не меньше единицы.
    public init(scene: simd_quatd, display: simd_quatd, verticalFOV: Float,
                aspect: Float, overscan: SIMD2<Float>) {
        self.init(scene: scene, displayTop: display, displayBottom: display,
                  verticalFOV: verticalFOV, aspect: aspect, overscan: overscan)
    }

    /// Создаёт построчную проекцию для двух поз камера→мир; UV.y=0 соответствует верху.
    public init(scene: simd_quatd, displayTop: simd_quatd, displayBottom: simd_quatd, verticalFOV: Float,
                aspect: Float, overscan: SIMD2<Float>) {
        precondition(verticalFOV > 0 && verticalFOV < .pi && aspect > 0)
        precondition(overscan.x >= 1 && overscan.y >= 1)
        sceneFromDisplay = simd_float3x3(simd_quatf(vector: SIMD4<Float>((scene.inverse * displayTop).vector)))
        sceneFromDisplayBottom = simd_float3x3(simd_quatf(vector: SIMD4<Float>((scene.inverse * displayBottom).vector)))
        let vertical = tan(verticalFOV / 2)
        displayTangents = SIMD2(vertical * aspect, vertical)
        sceneTangents = displayTangents * overscan
    }

    /// Координаты выборки текстуры сцены для UV дисплея с началом сверху слева.
    /// - Returns: UV в [0, 1] либо `nil`, если луч выходит за отрисованную область или смотрит назад.
    public func textureCoordinate(at uv: SIMD2<Float>) -> SIMD2<Float>? {
        let input = SIMD3((2 * uv.x - 1) * displayTangents.x, (1 - 2 * uv.y) * displayTangents.y, -1)
        let row = min(1, max(0, uv.y))
        let ray = (sceneFromDisplay * input) * (1 - row) + (sceneFromDisplayBottom * input) * row
        guard ray.z < -0.000001 else { return nil }
        let projected = SIMD2(ray.x, ray.y) / -ray.z / sceneTangents
        let result = SIMD2(projected.x * 0.5 + 0.5, 0.5 - projected.y * 0.5)
        guard result.x >= 0, result.x <= 1, result.y >= 0, result.y <= 1 else { return nil }
        return result
    }
}
