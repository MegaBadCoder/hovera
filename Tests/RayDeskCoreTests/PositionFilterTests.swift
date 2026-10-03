import Testing
import simd
@testable import RayDeskCore

@Test func turningTheHeadSwingsTheEyesAroundTheNeck() {
    let straight = simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)
    let left = simd_quatd(angle: .pi / 2, axis: SIMD3(0, 1, 0))
    let arc = eyeArcOffset(head: left, reference: straight)
    #expect(abs(arc.x - (-0.08)) < 1e-12)
    #expect(abs(arc.z - 0.08) < 1e-12)
    #expect(abs(arc.y) < 1e-12)
    #expect(eyeArcOffset(head: straight, reference: straight) == .zero)
}
