import simd

/// Временное увеличение одной панели без изменения сохранённой раскладки.
public struct ScreenFocus {
    /// Индекс увеличенной панели в исходной раскладке.
    public let screen: Int
    /// Положение увеличенной панели в мировых координатах.
    public let pose: ScreenPose

    /// Увеличивает панель в `scale` раз, помещая точку `uv` перед глазами и выравнивая плоскость по `head`.
    /// `origin` — положение головы в метрах; `uv` — координаты справа/вниз в диапазоне 0…1.
    public init(screen: Int, source: ScreenPose, uv: SIMD2<Double>, head: simd_quatd, origin: SIMD3<Double>, scale: Double = 2) {
        self.screen = screen
        precondition(scale.isFinite && scale > 0)
        let right = head.act(SIMD3<Double>(1, 0, 0))
        let up = head.act(SIMD3<Double>(0, 1, 0))
        let distance = max(0.4, length(source.center - origin))
        let width = source.width * scale
        let point = origin + head.act(SIMD3(0, 0, -distance))
        let center = point - right * ((uv.x - 0.5) * width) - up * ((0.5 - uv.y) * width / source.aspect)
        pose = ScreenPose(center: center, right: right, up: up, width: width, aspect: source.aspect)
    }

    /// Возвращает координаты попадания взгляда в увеличенную панель, либо `nil` вне её границ.
    /// `origin` — положение головы в мировых координатах, метры.
    public func hit(head: simd_quatd, origin: SIMD3<Double>) -> GazeHit? {
        let direction = head.act(SIMD3<Double>(0, 0, -1))
        let facing = dot(direction, pose.normal)
        guard facing < -1e-9 else { return nil }
        let t = dot(pose.center - origin, pose.normal) / facing
        guard t > 0 else { return nil }
        let point = origin + direction * t - pose.center
        let uv = SIMD2(dot(point, pose.right) / pose.width + 0.5, 0.5 - dot(point, pose.up) / pose.height)
        guard uv.x >= 0, uv.x <= 1, uv.y >= 0, uv.y <= 1 else { return nil }
        return GazeHit(screen: screen, uv: uv)
    }
}
