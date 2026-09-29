import Foundation
import Testing
import simd
@testable import RayDeskCore

private struct Noise {
    var state: UInt64
    mutating func gaussian() -> Double {
        func uniform() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double((state >> 11) + 1) / Double(1 << 53)
        }
        return sqrt(-2 * log(uniform())) * cos(2 * .pi * uniform())
    }
}

private let cameraRate = 1.0 / 30

@Test func stillHeadNoiseIsSmoothedAway() {
    var filter = OneEuroPositionFilter(minCutoff: SIMD3(1, 1, 0.3), beta: SIMD3(2, 2, 1.5))
    var noise = Noise(state: 7)
    var outputs: [SIMD3<Double>] = []
    for _ in 0..<300 {
        filter.add(SIMD3(0.012 * noise.gaussian(), 0.001 * noise.gaussian(), 0.8 + 0.014 * noise.gaussian()), dt: cameraRate)
        outputs.append(filter.value!)
    }
    let settled = outputs.suffix(200)
    let meanZ = settled.map(\.z).reduce(0, +) / Double(settled.count)
    let spreadZ = sqrt(settled.map { ($0.z - meanZ) * ($0.z - meanZ) }.reduce(0, +) / Double(settled.count))
    #expect(spreadZ < 0.004)
}

@Test func realLeanIsFollowedQuickly() {
    var filter = OneEuroPositionFilter(minCutoff: SIMD3(1, 1, 0.3), beta: SIMD3(2, 2, 1.5))
    for _ in 0..<30 { filter.add(SIMD3(0, 0, 0.8), dt: cameraRate) }
    var reached: Double?
    for frame in 1...30 {
        let target = 0.8 - min(Double(frame) * cameraRate, 0.5) * 0.3
        filter.add(SIMD3(0, 0, target), dt: cameraRate)
        if reached == nil, 0.8 - filter.value!.z > 0.8 * 0.15 { reached = Double(frame) * cameraRate }
    }
    #expect(reached != nil)
    #expect(reached! < 0.75)
}

@Test func deadbandIgnoresSmallWobbleAndFollowsRealMoves() {
    var band = SoftDeadband(band: SIMD3(0.0015, 0.0015, 0.003))
    _ = band.follow(SIMD3(0, 0, 0.8))
    #expect(band.follow(SIMD3(0.001, -0.001, 0.802)) == SIMD3(0, 0, 0.8))
    let moved = band.follow(SIMD3(0, 0, 0.75))
    #expect(abs(moved.z - 0.753) < 1e-12)
    let back = band.follow(SIMD3(0, 0, 0.7535))
    #expect(abs(back.z - 0.753) < 1e-12)
}

@Test func leadIsOnlyAddedWhileMoving() {
    let still = leadCompensated(SIMD3(0, 0, 0.8), speed: SIMD3(0.01, 0, -0.03), lead: 0.12)
    #expect(still == SIMD3(0, 0, 0.8))
    let leaning = leadCompensated(SIMD3(0, 0, 0.8), speed: SIMD3(0, 0, -0.3), lead: 0.12)
    #expect(abs(leaning.z - (0.8 - 0.036)) < 1e-12)
}

@Test func turningTheHeadSwingsTheEyesAroundTheNeck() {
    let straight = simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)
    let left = simd_quatd(angle: .pi / 2, axis: SIMD3(0, 1, 0))
    let arc = eyeArcOffset(head: left, reference: straight)
    #expect(abs(arc.x - (-0.08)) < 1e-12)
    #expect(abs(arc.z - 0.08) < 1e-12)
    #expect(abs(arc.y) < 1e-12)
    #expect(eyeArcOffset(head: straight, reference: straight) == .zero)
}
