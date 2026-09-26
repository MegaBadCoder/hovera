import Testing
import CoreGraphics
@testable import RayDeskCore

private let degree = Double.pi / 180

@Test func draggingRightDecreasesYawByAngularWidth() {
    let pose = ScreenPose(yaw: 0, pitch: 0, distance: 1.5, width: 1.0, aspect: 1.0)
    let displayPointWidth = 1000.0
    let dragged1 = dragged(pose, byPoints: CGVector(dx: displayPointWidth, dy: 0), displayPointWidth: displayPointWidth)
    #expect(abs((pose.yaw - dragged1.yaw) - pose.angularWidth) < 1e-9)
}

@Test func draggingDownLowersPitch() {
    let pose = ScreenPose(yaw: 0, pitch: 0, distance: 1.5, width: 1.0, aspect: 1.0)
    let dragged1 = dragged(pose, byPoints: CGVector(dx: 0, dy: 50), displayPointWidth: 1000)
    #expect(dragged1.pitch < pose.pitch)
}

@Test func draggingClampsPitchTo80Degrees() {
    let pose = ScreenPose(yaw: 0, pitch: 79 * degree, distance: 1.5, width: 1.0, aspect: 1.0)
    let dragged1 = dragged(pose, byPoints: CGVector(dx: 0, dy: 100_000), displayPointWidth: 1000)
    #expect(dragged1.pitch >= -80 * degree - 1e-9)
    #expect(dragged1.pitch <= 80 * degree + 1e-9)
    #expect(abs(dragged1.pitch - (-80 * degree)) < 1e-6)
}

@Test func draggingClampsPitchToNegative80Degrees() {
    let pose = ScreenPose(yaw: 0, pitch: -79 * degree, distance: 1.5, width: 1.0, aspect: 1.0)
    let dragged1 = dragged(pose, byPoints: CGVector(dx: 0, dy: -100_000), displayPointWidth: 1000)
    #expect(abs(dragged1.pitch - (80 * degree)) < 1e-6)
}

@Test func scrollingPositiveDeltaMovesScreenCloser() {
    let pose = ScreenPose(yaw: 0, pitch: 0, distance: 1.5, width: 1.0, aspect: 1.0)
    let result = scrolled(pose, by: 1)
    let expected = pose.distance * pow(1.05, -1)
    #expect(abs(result.distance - expected) < 1e-9)
}

@Test func scrollingNegativeDeltaMovesScreenFarther() {
    let pose = ScreenPose(yaw: 0, pitch: 0, distance: 1.5, width: 1.0, aspect: 1.0)
    let result = scrolled(pose, by: -1)
    let expected = pose.distance * pow(1.05, 1)
    #expect(abs(result.distance - expected) < 1e-9)
}

@Test func scrollingClampsDistanceToMinimum() {
    let pose = ScreenPose(yaw: 0, pitch: 0, distance: 0.4, width: 1.0, aspect: 1.0)
    let result = scrolled(pose, by: 100)
    #expect(abs(result.distance - 0.4) < 1e-9)
}

@Test func scrollingClampsDistanceToMaximum() {
    let pose = ScreenPose(yaw: 0, pitch: 0, distance: 6.0, width: 1.0, aspect: 1.0)
    let result = scrolled(pose, by: -100)
    #expect(abs(result.distance - 6.0) < 1e-9)
}
