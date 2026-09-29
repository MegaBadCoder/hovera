import CoreGraphics
import Testing
import simd
@testable import RayDeskCore

private let degree = Double.pi / 180
private let camera = FaceCamera(horizontalFieldOfView: 70 * degree, aspect: 16.0 / 9)
private let estimator = HeadPositionEstimator(camera: camera)

private func box(centerX: Double, centerY: Double = 0.5, width: Double) -> CGRect {
    let height = width * camera.aspect
    return CGRect(x: centerX - width / 2, y: centerY - height / 2, width: width, height: height)
}

private func turnedFace(from rest: CGRect, yaw: Double, pitch: Double = 0) -> CGRect {
    let neck = estimator.neckPosition(face: rest, yaw: 0, pitch: 0)
    let face = neck + SIMD3(estimator.turn.pivotRadius * sin(yaw), estimator.turn.pivotRadius * sin(pitch), 0)
    let focal = 0.5 / tan(camera.horizontalFieldOfView / 2)
    let width = camera.faceWidth * focal / face.z * estimator.turn.sizeFactor(yaw: yaw, pitch: pitch)
    return box(centerX: 0.5 + face.x * focal / face.z, centerY: 0.5 + face.y * focal / face.z * camera.aspect, width: width)
}

@Test func lookingAtTheCameraNeedsNoCorrection() {
    let face = box(centerX: 0.48, width: 0.123)
    let neck = estimator.neckPosition(face: face, yaw: 0, pitch: 0)
    #expect(simd_length(neck - camera.headPosition(face: face)) < 1e-12)
}

@Test func turningTheHeadDoesNotMoveTheNeck() {
    let rest = box(centerX: 0.48, width: 0.123)
    let neck = estimator.neckPosition(face: rest, yaw: 0, pitch: 0)
    for (yaw, pitch) in [(46.0, -4.0), (-39.0, -12.0), (20.0, 8.0)] {
        let turned = turnedFace(from: rest, yaw: yaw * degree, pitch: pitch * degree)
        let estimate = estimator.neckPosition(face: turned, yaw: yaw * degree, pitch: pitch * degree)
        #expect(simd_length(estimate - neck) < 0.003)
    }
}

@Test func measuredTurnWithoutCorrectionLooksLikeMovingAway() {
    let rest = box(centerX: 0.478, width: 0.123)
    let turned = box(centerX: 0.523, width: 0.123 / 1.315)
    let uncorrected = camera.headPosition(face: turned).z - camera.headPosition(face: rest).z
    let corrected = estimator.neckPosition(face: turned, yaw: 46 * degree, pitch: 0).z - estimator.neckPosition(face: rest, yaw: 0, pitch: 0).z
    #expect(uncorrected > 0.2)
    #expect(abs(corrected) < 0.06)
}

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

@Test func faceStopsNarrowingPastAboutFortyDegrees() {
    let turn = FaceTurnModel()
    #expect(turn.sizeFactor(yaw: 60 * degree) == 0.7)
    #expect(turn.sizeFactor(yaw: 90 * degree) == 0.7)
    #expect(turn.sizeFactor(yaw: 20 * degree) > 0.8)
}

@Test func lookingDownMakesTheFaceLookBigger() {
    let turn = FaceTurnModel()
    #expect(turn.sizeFactor(yaw: 0, pitch: -20 * degree) > 1.15)
    #expect(turn.sizeFactor(yaw: 0, pitch: 20 * degree) < 0.9)
}
