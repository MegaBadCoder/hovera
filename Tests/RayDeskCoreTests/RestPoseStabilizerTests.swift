import Foundation
import Testing
import simd
@testable import RayDeskCore

private func restPoseError(_ a: simd_quatd, _ b: simd_quatd) -> Double {
    let d = a * b.inverse
    return 2 * atan2(length(d.imag), abs(d.real))
}

@Test func restStrengthControlsNoiseReductionAndMaximumCorrection() {
    var energies: [Double] = []
    for strength in RestStabilizationStrength.allCases {
        var filter = RestPoseStabilizer()
        var energy = 0.0
        for i in 0..<1200 {
            let t = Double(i) / 120
            let input = yawPitchQuat(yaw: 0.05 * .pi / 180 * sin(2 * .pi * 1.5 * t), pitch: 0)
            let output = filter.filter(input, motion: input, at: t, enabled: true, stable: true, strength: strength)
            #expect(restPoseError(output, input) <= strength.maximumCorrectionRadians + 1e-10)
            if t > 2 { energy += pow(restPoseError(output, yawPitchQuat(yaw: 0, pitch: 0)), 2) }
        }
        energies.append(energy)
    }
    #expect(energies[1] < energies[0])
    #expect(energies[2] < energies[1])
}

@Test func restIndicatorPhaseDistinguishesOffTrackingWaitingMovingAndRest() {
    var filter = RestPoseStabilizer()
    let zero = yawPitchQuat(yaw: 0, pitch: 0)
    _ = filter.filter(zero, motion: zero, at: 0, enabled: false, stable: true)
    #expect(filter.phase == .disabled)
    _ = filter.filter(zero, motion: zero, at: 0.01, enabled: true, stable: false)
    #expect(filter.phase == .unavailable)
    _ = filter.filter(zero, motion: zero, at: 0.02, enabled: true, stable: true)
    #expect(filter.phase == .waiting)
    for i in 3..<70 { _ = filter.filter(zero, motion: zero, at: Double(i) / 100, enabled: true, stable: true) }
    #expect(filter.phase == .resting)
    let turn = yawPitchQuat(yaw: 0.1, pitch: 0)
    _ = filter.filter(turn, motion: turn, at: 0.70, enabled: true, stable: true)
    #expect(filter.phase == .moving)
}

@Test(arguments: RestStabilizationStrength.allCases)
func restAllStrengthsReleaseImmediatelyOnTurn(strength: RestStabilizationStrength) {
    var filter = RestPoseStabilizer()
    let zero = yawPitchQuat(yaw: 0, pitch: 0)
    for i in 0...60 { _ = filter.filter(zero, motion: zero, at: Double(i) / 120, enabled: true, stable: true, strength: strength) }
    let turn = yawPitchQuat(yaw: 0.02, pitch: -0.01)
    let output = filter.filter(turn, motion: turn, at: 0.5083333333, enabled: true, stable: true, strength: strength)
    #expect(filter.phase == .moving)
    #expect(restPoseError(output, turn) < 1e-12)
}

@Test func restSmoothingEngagesAfterDwellAndReducesStationarySensorNoise() {
    var filter = RestPoseStabilizer()
    var inputEnergy = 0.0
    var outputEnergy = 0.0
    for i in 0..<720 {
        let t = Double(i) / 120
        let angle = 0.02 * Double.pi / 180 * sin(2 * .pi * 8 * t)
        let input = yawPitchQuat(yaw: angle, pitch: 0)
        let output = filter.filter(input, motion: input, at: t, enabled: true, stable: true)
        if t > 1 {
            inputEnergy += angle * angle
            outputEnergy += pow(restPoseError(output, yawPitchQuat(yaw: 0, pitch: 0)), 2)
        }
    }
    #expect(filter.isResting)
    #expect(outputEnergy < inputEnergy * 0.4)
}

@Test func restSmoothingImmediatelyReleasesOnFastTurn() {
    var filter = RestPoseStabilizer()
    let zero = yawPitchQuat(yaw: 0, pitch: 0)
    for i in 0..<60 { _ = filter.filter(zero, motion: zero, at: Double(i) / 120, enabled: true, stable: true) }
    #expect(filter.isResting)
    let turn = yawPitchQuat(yaw: 0.02, pitch: 0.01)
    let result = filter.filter(turn, motion: turn, at: 0.5, enabled: true, stable: true)
    #expect(!filter.isResting)
    #expect(restPoseError(result, turn) < 1e-12)
    for i in 1...12 {
        _ = filter.filter(turn, motion: turn, at: 0.5 + Double(i) / 120, enabled: true, stable: true)
        #expect(!filter.isResting)
    }
}

@Test(arguments: [0.8, 2.0, 20.0])
func restSmoothingReleasesOnModerateTurnWithoutReengaging(rate: Double) {
    var filter = RestPoseStabilizer()
    let zero = yawPitchQuat(yaw: 0, pitch: 0)
    for i in 0...60 { _ = filter.filter(zero, motion: zero, at: Double(i) / 120, enabled: true, stable: true) }
    var releaseFrame: Int?
    for i in 1...120 {
        let input = yawPitchQuat(yaw: Double(i) / 120 * rate * .pi / 180, pitch: 0)
        let output = filter.filter(input, motion: input, at: 0.5 + Double(i) / 120, enabled: true, stable: true)
        if !filter.isResting, releaseFrame == nil { releaseFrame = i }
        if releaseFrame != nil {
            #expect(!filter.isResting)
            #expect(restPoseError(output, input) < 1e-12)
        }
    }
    #expect((releaseFrame ?? 999) <= (rate >= 2 ? 1 : 10))
}

@Test func restSmoothingReleasesOnSlowIntentionalTurnAndBoundsPhysicalMotionError() {
    var filter = RestPoseStabilizer()
    let zero = yawPitchQuat(yaw: 0, pitch: 0)
    for i in 0..<60 { _ = filter.filter(zero, motion: zero, at: Double(i) / 120, enabled: true, stable: true) }
    var released = false
    for i in 1...180 {
        let time = 0.5 + Double(i) / 120
        let angle = Double(i) / 120 * 0.3 * .pi / 180
        let input = yawPitchQuat(yaw: angle, pitch: 0)
        let output = filter.filter(input, motion: input, at: time, enabled: true, stable: true)
        #expect(restPoseError(output, input) <= RestPoseStabilizer.maximumCorrectionRadians + 1e-10)
        if !filter.isResting { released = true; #expect(restPoseError(output, input) < 1e-12) }
        if released { #expect(!filter.isResting) }
    }
    #expect(released)
}

@Test(arguments: [1.5, 8.0, 12.0])
func restSmoothingCanEnterWithSmallPeriodicNoise(frequency: Double) {
    var filter = RestPoseStabilizer()
    var restingFrames = 0
    for i in 0..<720 {
        let t = Double(i) / 120
        let amplitude = frequency < 2 ? 0.05 : 0.02
        let input = yawPitchQuat(yaw: amplitude * .pi / 180 * sin(2 * .pi * frequency * t), pitch: 0)
        _ = filter.filter(input, motion: input, at: t, enabled: true, stable: true)
        if t > 1, filter.isResting { restingFrames += 1 }
    }
    #expect(restingFrames > 400)
}

@Test func restSmoothingDisabledUnstableAndPausedReturnDirectPose() {
    for state in [0, 1, 2] {
        var filter = RestPoseStabilizer()
        let zero = yawPitchQuat(yaw: 0, pitch: 0)
        for i in 0..<60 { _ = filter.filter(zero, motion: zero, at: Double(i) / 120, enabled: true, stable: true) }
        let pose = yawPitchQuat(yaw: 0.0001, pitch: 0)
        let output = filter.filter(pose, motion: pose, at: state == 2 ? 2 : 0.5,
                                   enabled: state != 0, stable: state != 1)
        #expect(!filter.isResting)
        #expect(restPoseError(output, pose) < 1e-12)
    }
}

@Test func restSmoothingTreatsQuaternionSignAsSamePose() {
    var filter = RestPoseStabilizer()
    let pose = yawPitchQuat(yaw: 0.3, pitch: -0.2)
    for i in 0..<120 {
        let input = i.isMultiple(of: 2) ? pose : simd_quatd(vector: -pose.vector)
        let output = filter.filter(input, motion: input, at: Double(i) / 120, enabled: true, stable: true)
        #expect(restPoseError(output, pose) < 1e-10)
    }
    #expect(filter.isResting)
}

@Test func restSmoothingDoesNotClaimToEliminateRealHeartbeatRotation() {
    var filter = RestPoseStabilizer()
    for i in 0..<720 {
        let t = Double(i) / 120
        let actual = yawPitchQuat(yaw: 0.05 * .pi / 180 * sin(2 * .pi * 1.5 * t), pitch: 0)
        let compensated = filter.filter(actual, motion: actual, at: t, enabled: true, stable: true)
        #expect(restPoseError(compensated, actual) <= RestPoseStabilizer.maximumCorrectionRadians + 1e-10)
    }
}

@Test func expandedRestToleranceAcceptsRecordedSmallMotionThatPreviouslyNeverEnteredRest() throws {
    let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/viture-rest-entry.csv")
    let lines = try String(contentsOf: path, encoding: .utf8).split(separator: "\n").dropFirst()
    let samples = try lines.map { line -> (time: Double, pose: simd_quatd) in
        let values = try line.split(separator: ",").map { try #require(Double($0)) }
        return (values[0], simd_quatd(vector: SIMD4(values[1], values[2], values[3], values[4])))
    }
    let end = try #require(samples.last).time
    var filter = RestPoseStabilizer()
    var resting = 0, observed = 0
    for sample in samples {
        let output = filter.filter(sample.pose, motion: sample.pose, at: sample.time, enabled: true, stable: true, strength: .strong, tolerance: 5)
        #expect(restPoseError(output, sample.pose) <= RestStabilizationStrength.strong.maximumCorrectionRadians + 1e-10)
        if sample.time > end - 1.5 {
            observed += 1
            if filter.isResting { resting += 1 }
        }
    }
    #expect(Double(resting) / Double(observed) > 0.60)
}

@Test func expandedRestToleranceAcceptsLargerBoundedTremor() {
    var filter = RestPoseStabilizer()
    var resting = 0
    for i in 0..<720 {
        let time = Double(i) / 120
        let angle = (0.12 * sin(2 * .pi * 1.5 * time) + 0.02 * sin(2 * .pi * 12 * time)) * .pi / 180
        let input = yawPitchQuat(yaw: angle, pitch: 0)
        _ = filter.filter(input, motion: input, at: time, enabled: true, stable: true, strength: .strong, tolerance: 5)
        if i > 120, filter.isResting { resting += 1 }
    }
    #expect(resting > 500)
}

@Test(arguments: [1.0, 5.0, 8.0, 12.0, 16.0])
func restToleranceStillReleasesOnTheFirstFastTurnFrame(tolerance: Double) {
    var filter = RestPoseStabilizer()
    let zero = yawPitchQuat(yaw: 0, pitch: 0)
    for i in 0...60 { _ = filter.filter(zero, motion: zero, at: Double(i) / 120, enabled: true, stable: true, strength: .strong, tolerance: tolerance) }
    let turn = yawPitchQuat(yaw: 20 * .pi / 180 / 120, pitch: 0)
    let output = filter.filter(turn, motion: turn, at: 61.0 / 120, enabled: true, stable: true, strength: .strong, tolerance: tolerance)
    #expect(filter.phase == .moving)
    #expect(restPoseError(output, turn) < 1e-12)
}

@Test(arguments: RestStabilizationStrength.allCases)
func restDetectorRetainsMovementEvidenceInsteadOfAlternatingWithWaiting(strength: RestStabilizationStrength) {
    var filter = RestPoseStabilizer()
    let rate: Double = strength == .light ? 1 : strength == .medium ? 2.5 : 4
    for i in 0..<180 {
        let time = Double(i) / 120
        let input = yawPitchQuat(yaw: time * rate * .pi / 180, pitch: 0)
        _ = filter.filter(input, motion: input, at: time, enabled: true, stable: true, strength: strength)
        if time > 0.2 { #expect(filter.phase == .moving) }
    }
}
