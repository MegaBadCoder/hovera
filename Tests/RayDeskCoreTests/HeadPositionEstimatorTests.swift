import Testing
import simd
@testable import RayDeskCore

private let degree = Double.pi / 180

@Test func smootherFollowsWithTheChosenTimeConstant() {
    var smoother = VectorSmoother(timeConstants: SIMD3(0.15, 0.15, 0.3))
    smoother.add(.zero, dt: 0.033)
    for _ in 0..<Int(0.15 / 0.001) { smoother.add(SIMD3(1, 1, 1), dt: 0.001) }
    let value = smoother.value!
    #expect(abs(value.x - (1 - exp(-1))) < 0.01)
    #expect(value.z < value.x)
}

@Test func cameraOffsetMapsToWorldAxes() {
    let leanBack = worldOffset(fromCamera: SIMD3(0, 0, 0.1))
    #expect(simd_length(leanBack - SIMD3(0, 0, 0.1)) < 1e-12)
    let movedToImageRight = worldOffset(fromCamera: SIMD3(0.05, 0, 0))
    #expect(simd_length(movedToImageRight - SIMD3(-0.05, 0, 0)) < 1e-12)
    let cameraOnTheLeft = worldOffset(fromCamera: SIMD3(0, 0, 0.1), cameraYaw: 90 * degree)
    #expect(simd_length(cameraOnTheLeft - SIMD3(0.1, 0, 0)) < 1e-9)
}

@Test func followerMovesSmoothlyAndNeverJumps() {
    var follower = RateLimitedFollower(timeConstant: 0.08, maxSpeed: 0.6)
    let dt = 1.0 / 120
    var previous = follower.value
    for _ in 0..<120 {
        let value = follower.follow(SIMD3(0.3, 0, 0), dt: dt)
        #expect(simd_length(value - previous) <= 0.6 * dt + 1e-12)
        previous = value
    }
    #expect(abs(previous.x - 0.3) < 0.01)
}

@Test func followerSmoothsThirtyHertzSteps() {
    var follower = RateLimitedFollower(timeConstant: 0.08, maxSpeed: 0.6)
    var target = SIMD3<Double>(repeating: 0)
    var largestStep = 0.0
    var previous = follower.value
    for frame in 0..<240 {
        if frame % 4 == 0 { target.x += 0.004 }
        let value = follower.follow(target, dt: 1.0 / 120)
        largestStep = max(largestStep, value.x - previous.x)
        previous = value
    }
    #expect(largestStep < 0.004 / 2)
}

@Test func learnerRemembersWhereTheCameraIs() {
    var learner = CameraReferenceLearner()
    var reference: CameraReferenceLearner.Reference?
    for frame in 0..<40 where reference == nil {
        let wobble = frame.isMultiple(of: 2) ? 1.0 : -1.0
        reference = learner.add(neck: SIMD3(0.01, 0.02, 0.7 + 0.005 * wobble), yaw: 26 * degree + wobble * degree,
                                pitch: -18 * degree, time: Double(frame) / 30)
    }
    let found = try! #require(reference)
    #expect(abs(found.cameraYaw - 26 * degree) < 0.1 * degree)
    #expect(abs(found.pitch + 18 * degree) < 1e-9)
    #expect(abs(found.neck.z - 0.7) < 0.001)
}

@Test func learnerRestartsWhenTheHeadMoves() {
    var learner = CameraReferenceLearner()
    for frame in 0..<25 {
        #expect(learner.add(neck: .zero, yaw: 0, pitch: 0, time: Double(frame) / 30) == nil)
    }
    #expect(learner.add(neck: .zero, yaw: 10 * degree, pitch: 0, time: 26.0 / 30) == nil)
    // Непрерывные кадры: отдельный тест проверяет сброс после потери камеры.
    for frame in 27..<56 {
        #expect(learner.add(neck: .zero, yaw: 10 * degree, pitch: 0, time: Double(frame) / 30) == nil)
    }
    let reference = learner.add(neck: .zero, yaw: 10 * degree, pitch: 0, time: 57.0 / 30)
    #expect(abs((reference?.cameraYaw ?? 0) - 10 * degree) < 1e-9)
}

@Test func learnerHandlesTheCameraBehindTheWrapAround() {
    var learner = CameraReferenceLearner()
    var reference: CameraReferenceLearner.Reference?
    for frame in 0..<40 where reference == nil {
        let yaw = frame.isMultiple(of: 2) ? 179 * degree : -179 * degree
        reference = learner.add(neck: .zero, yaw: yaw, pitch: 0, time: Double(frame) / 30)
    }
    #expect(abs(abs(try! #require(reference).cameraYaw) - .pi) < 0.01)
}

@Test func glassesStraightAtTheCameraSitInFrontOfAndAboveTheNeck() {
    let glasses = SIMD3<Double>(0.01, 0.02, 0.55)
    let neck = neckPosition(fromGlasses: glasses, yaw: 0, pitch: 0)
    #expect(simd_length(neck - SIMD3(0.01, 0.02 - glassesFromNeck.up, 0.55 + glassesFromNeck.forward)) < 1e-12)
}

@Test func turningAndTiltingTheHeadDoesNotMoveTheNeckFoundByGlasses() {
    let neck = SIMD3<Double>(-0.03, 0.01, 0.62)
    for (yaw, pitch) in [(0.4, 0.0), (-0.7, 0.2), (0.3, -0.35), (0.0, -0.5)] {
        let head = simd_quatd(angle: -yaw, axis: SIMD3(0, 1, 0)) * simd_quatd(angle: pitch, axis: SIMD3(1, 0, 0))
        let facing = SIMD3(0.0, glassesFromNeck.up, -glassesFromNeck.forward)
        let glasses = neck + head.act(facing)
        #expect(simd_length(neckPosition(fromGlasses: glasses, yaw: yaw, pitch: pitch) - neck) < 1e-12)
    }
}

@Test func glassesAndEyeArcAgreeOnWhereTheNeckIs() {
    let reference = simd_quatd(angle: 0, axis: SIMD3(0, 1, 0))
    let nod = simd_quatd(angle: -0.5, axis: SIMD3(1, 0, 0))
    let eyeMove = eyeArcOffset(head: nod, reference: reference)
    let glassesBefore = SIMD3(0.0, glassesFromNeck.up, -glassesFromNeck.forward)
    let glassesMove = nod.act(glassesBefore) - glassesBefore
    #expect(simd_length(eyeMove - glassesMove) < 0.012)
}

@Test func depthIsNotCorrectedWhenFacingTheCamera() {
    #expect(depthCorrectedForTurn(0.8, turn: .zero) == 0.8)
}

@Test func turnedHeadIsPushedBackByTheMeasuredStretch() {
    let corrected = depthCorrectedForTurn(0.8, turn: SIMD2(52 * Double.pi / 180, 0))
    #expect(abs(corrected - 0.8 * (1 + turnDepthStretch * (1 - cos(52 * Double.pi / 180)))) < 1e-12)
    #expect(corrected > 0.85)
}

@Test func tiltChangesTheMeasuredDepthOnlySlightly() {
    let down = depthCorrectedForTurn(0.8, turn: SIMD2(0, -35 * Double.pi / 180))
    let up = depthCorrectedForTurn(0.8, turn: SIMD2(0, 20 * Double.pi / 180))
    #expect(abs(down - 0.8 * (1 + 0.10 * sin(35 * Double.pi / 180))) < 1e-12)
    #expect(abs(up / 0.8 - 1) < 0.04)
}

@Test func tiltingTheHeadToAShoulderDoesNotMoveTheNeckFoundByGlasses() {
    let neck = SIMD3<Double>(0.02, -0.01, 0.9)
    for (yaw, pitch, roll) in [(0.0, 0.0, 0.5), (-0.45, 0.3, 0.85), (0.5, 0.2, -0.8)] {
        let turn = simd_quatd(angle: -yaw, axis: SIMD3(0, 1, 0)) * simd_quatd(angle: pitch, axis: SIMD3(1, 0, 0))
        let pivot = neck + turn.act(SIMD3(0, glassesFromNeck.up - sideBendRadius, -glassesFromNeck.forward))
        let glasses = pivot + (turn * simd_quatd(angle: -roll, axis: SIMD3(0, 0, 1))).act(SIMD3(0, sideBendRadius, 0))
        #expect(simd_length(neckPosition(fromGlasses: glasses, yaw: yaw, pitch: pitch, roll: roll) - neck) < 1e-12)
    }
}

@Test func sideTiltIgnoresWhereTheHeadIsTurned() {
    let tilt = simd_quatd(angle: 0.4, axis: SIMD3(0, 0, 1))
    for yaw in [-1.2, 0.0, 0.7, 2.5] {
        let head = simd_quatd(angle: yaw, axis: SIMD3(0, 1, 0)) * simd_quatd(angle: -0.2, axis: SIMD3(1, 0, 0)) * tilt
        #expect(abs(head.sideTilt - 0.4) < 1e-12)
    }
}
