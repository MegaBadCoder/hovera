import Testing
import simd
@testable import RayDesk

private func readyPositionGuard() -> ViturePositionGuard {
    var guardrail = ViturePositionGuard()
    for step in 0...120 {
        _ = guardrail.update(.zero, stable: true, at: Double(step) / 120)
    }
    return guardrail
}

@Test func positionGuardRejectsStableSDKRunawayAndRecoversWithoutJump() {
    var guardrail = readyPositionGuard()
    var held = SIMD3<Double>.zero
    for step in 1...240 {
        let time = 1 + Double(step) / 120
        held = guardrail.update(SIMD3(0, -1.5, -1.7) * (time - 1), stable: true, at: time)
        #expect(length(held) < 0.5)
    }
    #expect(guardrail.isHolding)
    let recovery = SIMD3<Double>(-2.34, -5.36, -6.76)
    for step in 1...120 {
        let output = guardrail.update(recovery, stable: true, at: 3 + Double(step) / 120)
        #expect(length(output - held) < 1e-9)
    }
    #expect(!guardrail.isHolding)
    let moved = guardrail.update(recovery + SIMD3(0.01, 0, 0), stable: true, at: 4.01)
    #expect(length(moved - held - SIMD3(0.01, 0, 0)) < 1e-9)
}

@Test func positionGuardPreservesOrdinaryLeaningAndFreezesMissingOrUnstableSamples() {
    var guardrail = readyPositionGuard()
    for step in 1...120 {
        let position = SIMD3<Double>(0.3 * Double(step) / 120, 0, 0)
        #expect(length(guardrail.update(position, stable: true, at: 1 + Double(step) / 120) - position) < 1e-9)
    }
    let held = SIMD3<Double>(0.3, 0, 0)
    #expect(guardrail.update(SIMD3(10, 10, 10), stable: false, at: 2.01) == held)
    #expect(guardrail.update(nil, stable: false, at: 2.02) == held)
    #expect(guardrail.isHolding)
}

@Test func positionGuardRejectsNonfiniteValuesAndLongGapTeleports() {
    var guardrail = readyPositionGuard()
    #expect(guardrail.update(SIMD3(.nan, 0, 0), stable: true, at: 1.01) == .zero)
    #expect(guardrail.update(SIMD3(3, 0, 0), stable: true, at: 20) == .zero)
    #expect(guardrail.isHolding)
    for step in 1...60 {
        #expect(guardrail.update(SIMD3(3, 0, 0), stable: step % 10 != 0, at: 20 + Double(step) / 120) == .zero)
    }
    #expect(guardrail.isHolding)
}

@Test func positionGuardContainsRecordedDarkRoomRunaway() {
    let positions: [SIMD3<Double>] = [
        SIMD3(0.12, 0.02, -0.01), SIMD3(0.12, -0.02, -0.04),
        SIMD3(0.51, 0.17, -0.17), SIMD3(1.18, 0.80, -0.49),
        SIMD3(1.76, 1.65, -0.85), SIMD3(1.79, 2.13, -0.96),
        SIMD3(1.10, 1.69, -0.51), SIMD3(1.07, 1.50, -0.48),
        SIMD3(0.73, 0.86, -1.22), SIMD3(0.16, -0.22, -2.48)
    ]
    var guardrail = ViturePositionGuard()
    for step in 0...120 {
        _ = guardrail.update(positions[0], stable: true, at: Double(step) / 120)
    }
    for segment in 0..<(positions.count - 1) {
        for step in 1...120 {
            let fraction = Double(step) / 120
            let interpolated = positions[segment] * (1 - fraction) + positions[segment + 1] * fraction
            let output = guardrail.update(interpolated, stable: true, at: 1 + Double(segment) + fraction)
            #expect(length(output) < 1)
        }
    }
    #expect(guardrail.isHolding)
}
