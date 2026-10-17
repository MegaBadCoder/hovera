import Testing
import simd
@testable import RayDeskCore

private let degree = Double.pi / 180
private let worldToCamera = simd_double3x3(simd_quatd(angle: 2.3, axis: simd_normalize(SIMD3(0.2, -0.9, 0.4))))
private let startFace = simd_double3x3(simd_quatd(angle: 0.3, axis: simd_normalize(SIMD3(1, 0.5, 0))))

private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

private func head(yaw: Double, pitch: Double) -> simd_quatd {
    yawPitchQuat(yaw: yaw * degree, pitch: pitch * degree)
}

private func face(for imu: simd_quatd) -> simd_double3x3 {
    worldToCamera * simd_double3x3(imu) * worldToCamera.transpose * startFace
}

private let sweep: [(Double, Double)] = [(0, 0), (12, 0), (25, 3), (10, -10), (-5, -20), (-20, -8), (-30, 5), (-10, 15), (5, 22),
                                          (20, 10), (0, 0), (15, -15), (-15, 15)]

@Test func alignmentLearnsHowTheCameraSeesTheGyroscope() {
    var alignment = CameraAlignment()
    for (yaw, pitch) in sweep {
        let imu = head(yaw: yaw, pitch: pitch)
        alignment.add(face: face(for: imu), imu: imu)
    }
    let learned = try! #require(alignment.rotation)
    let error = simd_quatd(learned * worldToCamera.transpose).angle
    #expect(min(error, 2 * .pi - error) < 1e-6)
}

@Test func alignmentPredictsTheFaceWhenTheCameraLosesIt() {
    var alignment = CameraAlignment()
    for (yaw, pitch) in sweep {
        let imu = head(yaw: yaw, pitch: pitch)
        alignment.add(face: face(for: imu), imu: imu)
    }
    let anchor = head(yaw: 5, pitch: 0)
    let later = head(yaw: 70, pitch: -35)
    let predicted = try! #require(alignment.predict(anchorFace: face(for: anchor), anchorIMU: anchor, imu: later))
    let difference = simd_quatd(predicted * face(for: later).transpose).angle
    #expect(min(difference, 2 * .pi - difference) < 1e-6)
}

@Test func turningOnlyLeftAndRightIsNotEnoughToLearn() {
    var alignment = CameraAlignment()
    for yaw in stride(from: -30.0, through: 30, by: 10) {
        let imu = head(yaw: yaw, pitch: 0)
        alignment.add(face: face(for: imu), imu: imu)
    }
    #expect(alignment.rotation == nil)
}

@Test func recenteringTheWorldKeepsTheAlignmentValid() {
    var alignment = CameraAlignment()
    for (yaw, pitch) in sweep {
        let imu = head(yaw: yaw, pitch: pitch)
        alignment.add(face: face(for: imu), imu: imu)
    }
    let shift = 0.7
    alignment.worldYawChanged(by: shift)
    let turn = simd_quatd(angle: shift, axis: SIMD3(0, 1, 0))
    let anchor = head(yaw: 0, pitch: 0), later = head(yaw: -40, pitch: 10)
    let predicted = try! #require(alignment.predict(anchorFace: face(for: anchor), anchorIMU: turn * anchor, imu: turn * later))
    let difference = simd_quatd(predicted * face(for: later).transpose).angle
    #expect(min(difference, 2 * .pi - difference) < 1e-6)
}

@Test func headTurnReadsYawAndPitchFromTheCameraView() {
    let yawLeft = simd_double3x3(simd_quatd(angle: -0.4, axis: SIMD3(0, 1, 0)))
    #expect(abs(headTurn(fromCameraRotation: yawLeft).x - 0.4) < 1e-12)
    let lookUp = simd_double3x3(simd_quatd(angle: -0.3, axis: SIMD3(1, 0, 0)))
    #expect(abs(headTurn(fromCameraRotation: lookUp).y - 0.3) < 1e-12)
}

@Test func alignmentToleratesAFewDegreesOfFaceModelNoise() {
    var alignment = CameraAlignment()
    var generator = SeededGenerator(seed: 7)
    for _ in 0..<4 {
        for (yaw, pitch) in sweep {
            let imu = head(yaw: yaw, pitch: pitch)
            let noise = simd_double3x3(simd_quatd(angle: Double.random(in: 0...3.5, using: &generator) * degree,
                                                  axis: simd_normalize(SIMD3(Double.random(in: -1...1, using: &generator),
                                                                             Double.random(in: -1...1, using: &generator), 0.3))))
            alignment.add(face: noise * face(for: imu), imu: imu)
        }
    }
    let learned = try! #require(alignment.rotation)
    let error = simd_quatd(learned * worldToCamera.transpose).angle
    #expect(min(error, 2 * .pi - error) < 3 * degree)
}

@Test func cameraPullsADriftedHeadingBackGently() {
    var corrector = CameraYawCorrector()
    var worldShift = 0.0
    let drift = 10 * degree
    var fastest = 0.0
    for _ in 0..<(30 * 60) {
        let step = corrector.step(headYaw: 0.2 + drift + worldShift, cameraYaw: 0.05, faceTurn: SIMD2(0.15, 0), dt: 1.0 / 30)
        fastest = max(fastest, abs(step) * 30)
        worldShift += step
    }
    #expect(abs(drift + worldShift) < corrector.stillDeadband + 0.2 * degree)
    #expect(fastest <= corrector.stillMaxRate + corrector.stillFastShare * (drift - corrector.stillFastFrom) + 0.25 * degree)
    #expect(abs(corrector.driftRate) < 0.1 * degree)
}

@Test func largeHeadingErrorComesBackWithinSecondsWhileSmallOneStaysGentle() {
    func settle(_ error: Double, seconds: Double) -> (left: Double, fastest: Double) {
        var corrector = CameraYawCorrector()
        var shift = 0.0, fastest = 0.0
        for _ in 0..<Int(seconds * 30) {
            let step = corrector.step(headYaw: error + shift, cameraYaw: 0, faceTurn: .zero, dt: 1.0 / 30, headSpeed: 1 * degree)
            fastest = max(fastest, abs(step) * 30)
            shift += step
        }
        return (abs(error + shift), fastest)
    }
    // Крупная ошибка приходит назад не рывком: в покое предел доворота снижен, чтобы ошибка модели лица
    // на повёрнутой голове не уводила мир. Двадцать секунд — плата за это.
    #expect(settle(6 * degree, seconds: 20).left < 3.2 * degree)
    #expect(settle(6 * degree, seconds: 20).fastest <= 0.5 * degree + 1e-9)
    #expect(settle(2.5 * degree, seconds: 20).fastest <= 0.5 * degree + 1e-9)
}

@Test func headTurnedFarFromTheCameraIsNotUsedForHeading() {
    var corrector = CameraYawCorrector()
    #expect(corrector.step(headYaw: 1, cameraYaw: 0, faceTurn: SIMD2(40 * degree, 0), dt: 0.033) == 0)
}

@Test func fastHeadMotionDoesNotApplyOldHeadingError() {
    var still = CameraYawCorrector(), moving = CameraYawCorrector()
    var stillShift = still.step(headYaw: 4 * degree, cameraYaw: 0, faceTurn: .zero, dt: 1.0 / 30)
    var movingShift = moving.step(headYaw: 4 * degree, cameraYaw: 0, faceTurn: .zero, dt: 1.0 / 30)
    for _ in 0..<30 {
        stillShift += still.step(headYaw: 4 * degree + stillShift, cameraYaw: 0, faceTurn: .zero, dt: 1.0 / 30)
        movingShift += moving.step(headYaw: 4 * degree + movingShift, cameraYaw: 0, faceTurn: .zero, dt: 1.0 / 30,
                                   headSpeed: 60 * degree)
    }
    #expect(abs(stillShift) <= 1.05 * degree)
    #expect(abs(movingShift) < 0.1 * degree)
    #expect(abs(movingShift) <= moving.maxMotionRate * 31 / 30 + 0.05 * degree)
}

@Test func headSwingsDoNotRotateTheWorldWhenTheCameraLags() {
    var corrector = CameraYawCorrector()
    var shift = 0.0
    let dt = 1.0 / 30
    for frame in 0..<(30 * 20) {
        let time = Double(frame) * dt
        let yaw = 25 * degree * sin(2 * .pi * time / 2)
        let speed = abs(25 * degree * 2 * .pi / 2 * cos(2 * .pi * time / 2))
        let lagged = 25 * degree * sin(2 * .pi * (time - 0.08) / 2) * 1.1
        shift += corrector.step(headYaw: yaw + shift, cameraYaw: 0, faceTurn: SIMD2(lagged, 0), dt: dt, headSpeed: speed)
    }
    #expect(abs(shift) < 1.5 * degree)
}

@Test func steadyGyroDriftIsLearnedButCoastingStopsWithoutFreshEvidence() {
    var corrector = CameraYawCorrector()
    let rate = 0.4 * degree
    var gyroError = 0.0, worldShift = 0.0
    let dt = 1.0 / 30
    for _ in 0..<(30 * 180) {
        gyroError += rate * dt
        worldShift += corrector.step(headYaw: gyroError + worldShift, cameraYaw: 0, faceTurn: .zero, dt: dt)
    }
    #expect(abs(corrector.driftRate - rate) < 0.1 * degree)
    let before = gyroError + worldShift
    for _ in 0..<(30 * 10) {
        gyroError += rate * dt
        worldShift += corrector.coast(dt: dt)
    }
    #expect(abs((gyroError + worldShift - before) - rate * 10) < 0.25 * degree)
    #expect(corrector.coast(dt: dt) == 0)
}

private func angleBetween(_ a: simd_double3x3, _ b: simd_double3x3) -> Double {
    let angle = simd_quatd(a * b.transpose).angle
    return min(angle, 2 * .pi - angle)
}

@Test func savedAlignmentWorksForLeftRightTurnsRightAway() throws {
    let worldShift = simd_quatd(angle: 1.1, axis: SIMD3(0, 1, 0))
    let alignment = CameraAlignment(prior: worldToCamera)
    let anchor = head(yaw: 0, pitch: 0), later = head(yaw: 60, pitch: 0)
    let predicted = try #require(alignment.predict(anchorFace: face(for: anchor), anchorIMU: worldShift * anchor,
                                                   imu: worldShift * later))
    #expect(angleBetween(predicted, face(for: later)) < 1e-9)
}

@Test func savedAlignmentLearnsTheMissingAngleFromANod() throws {
    let worldShift = simd_quatd(angle: 1.1, axis: SIMD3(0, 1, 0))
    var alignment = CameraAlignment(prior: worldToCamera)
    for (yaw, pitch) in [(0.0, 0.0), (0, 20), (0, -5)] {
        let imu = head(yaw: yaw, pitch: pitch)
        alignment.add(face: face(for: imu), imu: worldShift * imu)
    }
    #expect(alignment.usesPrior)
    let learned = try #require(alignment.rotation)
    #expect(angleBetween(learned, worldToCamera * simd_double3x3(worldShift.inverse)) < 1e-6)
}

@Test func savedAlignmentIsDroppedWhenTheCameraMoved() {
    let moved = simd_double3x3(simd_quatd(angle: 0.5, axis: SIMD3(1, 0, 0))) * worldToCamera
    var alignment = CameraAlignment(prior: moved)
    for (yaw, pitch) in [(0.0, 0.0), (0, 20), (25, 0)] {
        let imu = head(yaw: yaw, pitch: pitch)
        alignment.add(face: face(for: imu), imu: imu)
    }
    #expect(!alignment.usesPrior)
    #expect(alignment.rotation == nil)
}

@Test func faceYawScaleIsLearnedAgainstTheGyro() {
    var scale = FaceYawScale()
    var time = 0.0
    for _ in 0..<60 {
        for yaw in Array(stride(from: -20.0, through: 20, by: 1)) + Array(stride(from: 20.0, through: -20, by: -1)) {
            scale.add(time: time, gyroYaw: yaw * degree + 0.3, faceYaw: 1.15 * yaw * degree)
            time += 1.0 / 30
        }
    }
    #expect(abs(scale.scale - 1.15) < 0.01)
}

@Test func stillHeadIsNotSwayedByFaceModelNoise() {
    var corrector = CameraYawCorrector()
    var generator = SeededGenerator(seed: 11)
    var travelled = 0.0, shift = 0.0
    for _ in 0..<(30 * 20) {
        let noise = Double.random(in: -1...1, using: &generator) * degree
        let step = corrector.step(headYaw: shift, cameraYaw: 0, faceTurn: SIMD2(noise, 0), dt: 1.0 / 30, headSpeed: 1 * degree)
        travelled += abs(step)
        shift += step
    }
    #expect(travelled < 0.5 * degree)
}

@Test func overreadFaceTurnsStillLearnTheAlignment() {
    var alignment = CameraAlignment()
    for (yaw, pitch) in sweep {
        let imu = head(yaw: yaw, pitch: pitch)
        let seen = simd_quatd(face(for: imu) * startFace.transpose)
        let overread = simd_quatd(angle: seen.angle * 1.15, axis: seen.axis)
        alignment.add(face: simd_double3x3(overread) * startFace, imu: imu)
    }
    let learned = try! #require(alignment.rotation)
    #expect(angleBetween(learned, worldToCamera) < 2 * degree)
    #expect(alignment.residual < 1 * degree)
}

@Test func fixedFaceModelOffsetDoesNotBecomeAnInventedDriftRate() {
    var corrector = CameraYawCorrector()
    var shift = 0.0
    for _ in 0..<5400 {
        shift += corrector.step(headYaw: 1 * degree + shift, cameraYaw: 0, faceTurn: .zero, dt: 1.0 / 30)
    }
    #expect(abs(corrector.driftRate) < 1e-10)
    #expect(abs(shift) < 1e-10)
}

@Test func smallCameraErrorDoesNotTurnWorldWhenHeadStartsMoving() {
    var corrector = CameraYawCorrector()
    var shift = 0.0
    for frame in 0..<900 {
        let speed = (frame % 2 == 0 ? 4.9 : 5.1) * degree
        shift += corrector.step(headYaw: shift, cameraYaw: 0,
                                faceTurn: SIMD2(-1 * degree, 0), dt: 1.0 / 30, headSpeed: speed)
    }
    #expect(abs(shift) < 1e-12)
}

@Test func learnedRateDoesNotMoveWorldInsideCameraNoiseBand() {
    var corrector = CameraYawCorrector()
    var shift = 0.0
    for frame in 0..<5400 {
        shift += corrector.step(headYaw: Double(frame) / 30 * 0.4 * degree + shift,
                                cameraYaw: 0, faceTurn: .zero, dt: 1.0 / 30)
    }
    #expect(abs(corrector.driftRate) > 0.1 * degree)
    // Let the filtered measurement settle before checking the noise band.
    for _ in 0..<600 {
        _ = corrector.step(headYaw: 0, cameraYaw: 0, faceTurn: .zero, dt: 1.0 / 30)
    }
    let step = corrector.step(headYaw: 0, cameraYaw: 0, faceTurn: .zero, dt: 1.0 / 30)
    #expect(abs(step) < 1e-12)
}
