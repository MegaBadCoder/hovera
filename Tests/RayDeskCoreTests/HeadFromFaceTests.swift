import Testing
import simd
@testable import RayDeskCore

@Test func spreadMeasuresJitterOverTheWindow() {
    var spread = RollingSpread(window: 1)
    #expect(spread.deviation == nil)
    for i in 0..<31 {
        spread.add(SIMD3(i.isMultiple(of: 2) ? 0.01 : -0.01, 0, 0.6), at: Double(i) / 30)
    }
    #expect(spread.count == 31)
    #expect(abs(spread.mean!.z - 0.6) < 1e-12)
    #expect(abs(spread.deviation!.x - 0.01) < 0.001)
    #expect(spread.deviation!.z < 1e-12)
}

@Test func spreadForgetsOldSamples() {
    var spread = RollingSpread(window: 1)
    spread.add(SIMD3(1, 1, 1), at: 0)
    spread.add(SIMD3(0, 0, 0), at: 2)
    spread.add(SIMD3(0, 0, 0), at: 2.5)
    #expect(spread.count == 2)
    #expect(spread.deviation! == SIMD3(repeating: 0))
}
