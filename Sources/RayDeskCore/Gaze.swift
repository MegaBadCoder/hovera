import simd

/// Результат пересечения взгляда с одним из экранов.
public struct GazeHit: Equatable {
    public var screen: Int
    public var uv: SIMD2<Double>

    public init(screen: Int, uv: SIMD2<Double>) {
        self.screen = screen
        self.uv = uv
    }
}

/// Находит ближайший вдоль взгляда экран из списка.
///
/// - Parameters:
///   - head: ориентация головы (взгляд — направление -Z в её системе координат).
///   - screens: позы экранов.
/// - Returns: индекс ближайшего экрана и координаты попадания, либо `nil`, если взгляд не попадает ни в один экран.
public func gazeHit(head: simd_quatd, screens: [ScreenPose]) -> GazeHit? {
    let direction = head.act(SIMD3(0, 0, -1))
    var best: (index: Int, t: Double, uv: SIMD2<Double>)?
    for (index, screen) in screens.enumerated() {
        guard let hit = screen.intersect(rayDirection: direction) else { continue }
        if best == nil || hit.t < best!.t {
            best = (index, hit.t, hit.uv)
        }
    }
    guard let best else { return nil }
    return GazeHit(screen: best.index, uv: best.uv)
}
