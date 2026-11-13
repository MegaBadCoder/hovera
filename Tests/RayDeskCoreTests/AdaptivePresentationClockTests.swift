import Foundation
import Testing
import simd
@testable import RayDeskCore

@Test func immediatePresentationPredictsTheMeasuredQueueDelay() {
    let clock = AdaptivePresentationClock()
    #expect(clock.targetTime(now: 100, displayTarget: 100.025, synchronized: false) == 100)
    clock.observe(now: 100, displayTarget: 100.025, presented: 100.0166, synchronized: false)
    #expect(abs(clock.targetTime(now: 200, displayTarget: 200.025, synchronized: false) - 200.0166) < 1e-9)
}

@Test func adaptivePresentationKeepsSeparateTimingForBothSyncModes() {
    let clock = AdaptivePresentationClock()
    clock.observe(now: 100, displayTarget: 100.025, presented: 100.0333, synchronized: true)
    clock.observe(now: 100, displayTarget: 100.025, presented: 100.0166, synchronized: false)
    #expect(abs(clock.targetTime(now: 200, displayTarget: 200.025, synchronized: true) - 200.0333) < 1e-9)
    #expect(abs(clock.targetTime(now: 200, displayTarget: 200.025, synchronized: false) - 200.0166) < 1e-9)
}

@Test func adaptivePresentationIgnoresUnpresentedFramesAndStartsNewSessionsWithoutOldTiming() {
    let clock = AdaptivePresentationClock()
    clock.observe(now: 100, displayTarget: 100.025, presented: 100.0166, synchronized: false)
    clock.observe(now: 200, displayTarget: 200.025, presented: 0, synchronized: false)
    #expect(abs(clock.targetTime(now: 300, displayTarget: 300.025, synchronized: false) - 300.0166) < 1e-9)
    let restarted = AdaptivePresentationClock()
    #expect(restarted.targetTime(now: 300, displayTarget: 300.025, synchronized: false) == 300)
}

@Test func measuredPresentationTimeReducesKnownMicroMotionErrorWithoutFilteringThePose() {
    let clock = AdaptivePresentationClock()
    clock.observe(now: 100, displayTarget: 100.025, presented: 100.0166, synchronized: false)
    var predictor = WorldLockPrediction()
    var measuredError = 0.0, immediateError = 0.0
    let amplitude = 0.05 * Double.pi / 180
    for index in 0..<1200 {
        let now = 100 + Double(index) / 120
        let sampleTime = now - 0.001
        let sourceAngle = amplitude * sin(2 * .pi * 1.5 * sampleTime)
        let actualAngle = amplitude * sin(2 * .pi * 1.5 * (now + 0.0166))
        let target = clock.targetTime(now: now, displayTarget: now + 0.025, synchronized: false)
        let source = simd_quatd(angle: sourceAngle, axis: SIMD3(0, 1, 0))
        let output = predictor.predict(source, at: now, horizon: target - sampleTime, smoothing: true)
        if index > 120 {
            measuredError += pow(actualAngle - 2 * atan2(output.imag.y, output.real), 2)
            immediateError += pow(actualAngle - sourceAngle, 2)
        }
    }
    #expect(measuredError < immediateError * 0.25)
}
