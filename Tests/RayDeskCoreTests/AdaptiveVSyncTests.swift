import Foundation
import Testing
import simd
@testable import RayDeskCore

private func adaptiveAngleError(_ first: simd_quatd, _ second: simd_quatd) -> Double {
    let delta = first * second.inverse
    return 2 * atan2(length(delta.imag), abs(delta.real))
}

@Test func adaptiveVSyncKeepsEveryMicroRotationWhileEnteringUnsynchronizedRest() {
    var control = RestPresentationController()
    var unsynchronized = 0
    for i in 0..<720 {
        let time = Double(i) / 120
        let motion = simd_quatd(angle: 0.05 * .pi / 180 * sin(2 * .pi * 1.5 * time), axis: SIMD3(0, 1, 0))
        let predicted = simd_normalize(simd_quatd(angle: 0.0001 * cos(time), axis: SIMD3(1, 0, 0)) * motion)
        let output = control.filter(predicted, motion: motion, at: time, restSmoothing: true, adaptiveVSync: true,
                                    stable: true, strength: .strong, tolerance: 5)
        #expect(adaptiveAngleError(output, predicted) < 1e-12)
        #expect(control.correctionRadians == 0)
        #expect(!control.isSmoothing)
        if time < 0.3 { #expect(control.displaySyncEnabled) }
        if time > 1, !control.displaySyncEnabled { unsynchronized += 1 }
    }
    #expect(control.phase == .resting)
    #expect(unsynchronized > 500)
}

@Test func adaptiveVSyncImmediatelySynchronizesARealTurnAndDoesNotDelayItsPose() {
    var control = RestPresentationController()
    let zero = simd_quatd(angle: 0, axis: SIMD3(0, 1, 0))
    for i in 0...120 {
        _ = control.filter(zero, motion: zero, at: Double(i) / 120, restSmoothing: true, adaptiveVSync: true,
                           stable: true, strength: .strong, tolerance: 5)
    }
    #expect(!control.displaySyncEnabled)
    let turn = simd_quatd(angle: 20 * .pi / 180 / 120, axis: SIMD3(0, 1, 0))
    let output = control.filter(turn, motion: turn, at: 121.0 / 120, restSmoothing: true, adaptiveVSync: true,
                                stable: true, strength: .strong, tolerance: 5)
    #expect(control.displaySyncEnabled)
    #expect(control.phase == .moving)
    #expect(adaptiveAngleError(output, turn) < 1e-12)
}

@Test(arguments: ["unstable", "pause", "disabled"])
func adaptiveVSyncReturnsToSynchronizedOutputWhenItsConditionsDisappear(reason: String) {
    var control = RestPresentationController()
    let zero = simd_quatd(angle: 0, axis: SIMD3(0, 1, 0))
    for i in 0...120 {
        _ = control.filter(zero, motion: zero, at: Double(i) / 120, restSmoothing: false, adaptiveVSync: true,
                           stable: true, strength: .light, tolerance: 5)
    }
    #expect(!control.displaySyncEnabled)
    _ = control.filter(zero, motion: zero, at: reason == "pause" ? 2 : 121.0 / 120,
                       restSmoothing: false, adaptiveVSync: reason != "disabled", stable: reason != "unstable",
                       strength: .light, tolerance: 5)
    #expect(control.displaySyncEnabled)
}

@Test func adaptiveVSyncDoesNotDisableSynchronizationForBriefRestBursts() {
    var control = RestPresentationController()
    let zero = simd_quatd(angle: 0, axis: SIMD3(0, 1, 0))
    for i in 0..<120 {
        _ = control.filter(zero, motion: zero, at: Double(i) / 120, restSmoothing: false, adaptiveVSync: true,
                           stable: i % 36 != 35, strength: .light, tolerance: 5)
        #expect(control.displaySyncEnabled)
    }
}

@Test func disablingAdaptiveVSyncPreservesExplicitLegacyPoseSmoothing() {
    var legacy = RestPresentationController()
    var reference = RestPoseStabilizer()
    for i in 0..<240 {
        let time = Double(i) / 120
        let pose = simd_quatd(angle: 0.05 * .pi / 180 * sin(2 * .pi * 1.5 * time), axis: SIMD3(0, 1, 0))
        let expected = reference.filter(pose, motion: pose, at: time, enabled: true, stable: true, strength: .strong, tolerance: 5)
        let output = legacy.filter(pose, motion: pose, at: time, restSmoothing: true, adaptiveVSync: false,
                                   stable: true, strength: .strong, tolerance: 5)
        #expect(adaptiveAngleError(output, expected) < 1e-12)
        #expect(legacy.displaySyncEnabled)
    }
    #expect(legacy.isSmoothing)
    #expect(legacy.correctionRadians > 0)
}
