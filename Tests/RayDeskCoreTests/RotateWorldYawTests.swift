import Testing
import simd
@testable import RayDeskCore

private let deg = Double.pi / 180

@Test func worldYawTurnRotatesHistoryWhateverTheCaller() {
    let filter = OrientationFilter()
    for _ in 0..<300 {
        filter.update(gyro: .zero, accel: SIMD3(0, 1, 0), dt: 0.01)
    }
    let past = filter.orientation(atUptime: 0).yawPitch
    let now = filter.orientation(predictAhead: 0).yawPitch
    filter.rotateWorldYaw(by: 2 * deg)
    let turnedPast = filter.orientation(atUptime: 0).yawPitch
    let turnedNow = filter.orientation(predictAhead: 0).yawPitch
    #expect(abs(turnedPast.yaw - past.yaw - 2 * deg) < 1e-9)
    #expect(abs(turnedNow.yaw - now.yaw - 2 * deg) < 1e-9)
    #expect(abs(turnedPast.pitch - past.pitch) < 1e-9)
}
