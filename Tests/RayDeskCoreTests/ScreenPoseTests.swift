import Testing
import simd
@testable import RayDeskCore

private let degree = Double.pi / 180

@Test func heightDerivedFromWidthAndAspect() {
    let pose = ScreenPose(yaw: 0, pitch: 0, distance: 1.5, width: 1.0, aspect: 2.0)
    #expect(abs(pose.height - 0.5) < 1e-9)
}

@Test func angularWidthMatchesTrigonometry() {
    let pose = ScreenPose(yaw: 0, pitch: 0, distance: 1.0, width: 2.0, aspect: 1.0)
    let expected = 2 * atan(1.0 / 1.0)
    #expect(abs(pose.angularWidth - expected) < 1e-9)
}

@Test func rotationMatchesYawPitchQuat() {
    let pose = ScreenPose(yaw: 0.3, pitch: 0.1, distance: 1.5, width: 1.0, aspect: 1.0)
    let expected = yawPitchQuat(yaw: 0.3, pitch: 0.1)
    #expect(abs(pose.rotation.vector.x - expected.vector.x) < 1e-9)
    #expect(abs(pose.rotation.vector.y - expected.vector.y) < 1e-9)
    #expect(abs(pose.rotation.vector.z - expected.vector.z) < 1e-9)
    #expect(abs(pose.rotation.vector.w - expected.vector.w) < 1e-9)
}

@Test func modelMatrixCornersMapToExpectedUV() {
    let pose = ScreenPose(yaw: 0, pitch: 0, distance: 1.5, width: 1.0, aspect: 1.0)
    let m = pose.modelMatrix

    func worldPoint(_ x: Float, _ y: Float) -> SIMD3<Double> {
        let v = m * SIMD4<Float>(x, y, 0, 1)
        return SIMD3(Double(v.x), Double(v.y), Double(v.z))
    }

    let topLeft = worldPoint(-1, 1)
    let bottomRight = worldPoint(1, -1)
    let center = worldPoint(0, 0)

    let hitTopLeft = pose.intersect(rayDirection: normalize(topLeft))
    let hitBottomRight = pose.intersect(rayDirection: normalize(bottomRight))
    let hitCenter = pose.intersect(rayDirection: normalize(center))

    #expect(hitTopLeft != nil)
    #expect(hitBottomRight != nil)
    #expect(hitCenter != nil)

    if let uv = hitTopLeft?.uv {
        #expect(abs(uv.x - 0) < 1e-6)
        #expect(abs(uv.y - 0) < 1e-6)
    }
    if let uv = hitBottomRight?.uv {
        #expect(abs(uv.x - 1) < 1e-6)
        #expect(abs(uv.y - 1) < 1e-6)
    }
    if let uv = hitCenter?.uv {
        #expect(abs(uv.x - 0.5) < 1e-6)
        #expect(abs(uv.y - 0.5) < 1e-6)
    }
}

@Test func gazeTurnedLeftHitsScreenYawedLeft() {
    let pose = ScreenPose(yaw: 30 * degree, pitch: 0, distance: 1.5, width: 1.0, aspect: 1.0)
    let head = yawPitchQuat(yaw: 30 * degree, pitch: 0)
    let gaze = head.act(SIMD3(0, 0, -1))
    #expect(pose.intersect(rayDirection: gaze) != nil)
}

@Test func straightAheadGazeMissesYawedScreen() {
    let pose = ScreenPose(yaw: 30 * degree, pitch: 0, distance: 1.5, width: 0.2, aspect: 1.0)
    let gaze = SIMD3<Double>(0, 0, -1)
    #expect(pose.intersect(rayDirection: gaze) == nil)
}

@Test func rayPointingBehindMisses() {
    let pose = ScreenPose(yaw: 0, pitch: 0, distance: 1.5, width: 1.0, aspect: 1.0)
    let behind = SIMD3<Double>(0, 0, 1)
    #expect(pose.intersect(rayDirection: behind) == nil)
}
