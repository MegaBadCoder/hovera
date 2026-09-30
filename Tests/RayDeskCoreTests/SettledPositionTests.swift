import Testing
import simd
@testable import RayDeskCore

private let degree = Double.pi / 180

@Test func depthNoiseOfAStillHeadDoesNotMoveTheScreens() {
    var settled = SettledPosition()
    var noise: UInt64 = 1
    var first: SIMD3<Double>?
    var farthest = 0.0
    for frame in 0..<(30 * 20) {
        noise = noise &* 6364136223846793005 &+ 1442695040888963407
        let wobble = Double(noise >> 11) / Double(1 << 53) - 0.5
        let position = SIMD3(0.002 * wobble, 0.002 * wobble, 0.03 * wobble)
        let value = settled.add(position, time: Double(frame) / 30, headSpeed: 2 * degree)
        first = first ?? value
        farthest = max(farthest, simd_length(value - first!))
    }
    #expect(farthest < 1e-9)
}

@Test func nodMeasuredWrongByTheCameraIsIgnored() {
    var settled = SettledPosition()
    _ = settled.add(.zero, time: 0, headSpeed: 0)
    for frame in 1...15 {
        let value = settled.add(SIMD3(0, 0, 0.06), time: Double(frame) / 30, headSpeed: 80 * degree)
        #expect(value == .zero)
    }
    var value = SIMD3<Double>(repeating: 1)
    for frame in 16...60 { value = settled.add(.zero, time: Double(frame) / 30, headSpeed: 3 * degree) }
    #expect(value == .zero)
}

@Test func realLeanIsFollowedOnceTheHeadSettles() {
    var settled = SettledPosition()
    _ = settled.add(.zero, time: 0, headSpeed: 0)
    let leaned = SIMD3(0.0, 0.0, -0.08)
    var value = SIMD3<Double>.zero
    var time = 0.0
    for _ in 0..<(30 * 3) {
        time += 1.0 / 30
        value = settled.add(leaned, time: time, headSpeed: 2 * degree)
    }
    #expect(simd_length(value - leaned) < settled.band.z * settled.settledShare + 1e-3)
}

@Test func resetPlacesThePositionWithoutGliding() {
    var settled = SettledPosition()
    _ = settled.add(SIMD3(0.1, 0, 0), time: 0, headSpeed: 0)
    settled.reset(to: SIMD3(0, 0.05, 0))
    #expect(settled.value == SIMD3(0, 0.05, 0))
}

@Test func shortPausesInAHeadShakeDoNotMoveTheScreens() {
    var settled = SettledPosition()
    _ = settled.add(.zero, time: 0, headSpeed: 0)
    var value = SIMD3<Double>.zero
    for frame in 1...90 {
        let wrong = frame % 2 == 0 ? SIMD3(0.0, 0.0, 0.09) : SIMD3(0.0, 0.0, -0.02)
        value = settled.add(wrong, time: Double(frame) / 30, headSpeed: 5 * degree)
    }
    #expect(value == .zero)
}
