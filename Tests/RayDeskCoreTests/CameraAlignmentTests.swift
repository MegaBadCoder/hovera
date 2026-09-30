import Testing
import simd
@testable import RayDeskCore

private let degree = Double.pi / 180
private let worldToCamera = simd_double3x3(simd_quatd(angle: 2.3, axis: simd_normalize(SIMD3(0.2, -0.9, 0.4))))
private let startFace = simd_double3x3(simd_quatd(angle: 0.3, axis: simd_normalize(SIMD3(1, 0.5, 0))))

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
    var generator = SystemRandomNumberGenerator()
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
    #expect(abs(drift + worldShift) < 0.2 * degree)
    #expect(fastest <= corrector.maxRate + 1e-12)
}

@Test func headTurnedFarFromTheCameraIsNotUsedForHeading() {
    var corrector = CameraYawCorrector()
    #expect(corrector.step(headYaw: 1, cameraYaw: 0, faceTurn: SIMD2(40 * degree, 0), dt: 0.033) == 0)
}

@Test func headingIsFixedFasterWhileTheHeadIsTurning() {
    var still = CameraYawCorrector(), moving = CameraYawCorrector()
    var stillShift = 0.0, movingShift = 0.0
    for _ in 0..<30 {
        stillShift += still.step(headYaw: 4 * degree + stillShift, cameraYaw: 0, faceTurn: .zero, dt: 1.0 / 30)
        movingShift += moving.step(headYaw: 4 * degree + movingShift, cameraYaw: 0, faceTurn: .zero, dt: 1.0 / 30,
                                   headSpeed: 60 * degree)
    }
    #expect(abs(stillShift) <= 1 * degree + 1e-9)
    #expect(abs(4 * degree + movingShift) < 1.5 * degree)
}
