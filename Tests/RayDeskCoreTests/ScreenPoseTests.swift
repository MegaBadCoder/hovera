import Foundation
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

@Test func tiltedScreenCornersStillMapToTheirUV() {
    for tilt in [-40.0, -15.0, 25.0, 50.0] {
        let pose = ScreenPose(yaw: 0.4, pitch: -0.2, distance: 1.5, width: 1.0, aspect: 16.0 / 9, tilt: tilt * degree)
        let m = pose.modelMatrix
        for (x, y, u, v) in [(-0.99, 0.99, 0.005, 0.005), (0.99, -0.99, 0.995, 0.995), (0.0, 0.0, 0.5, 0.5), (0.5, 0.5, 0.75, 0.25)] {
            let p = m * SIMD4<Float>(Float(x), Float(y), 0, 1)
            let hit = pose.intersect(rayDirection: SIMD3(Double(p.x), Double(p.y), Double(p.z)))
            #expect(hit != nil)
            if let uv = hit?.uv {
                #expect(abs(uv.x - u) < 1e-4 && abs(uv.y - v) < 1e-4)
            }
        }
    }
}

@Test func tiltingBackPushesTheTopAwayFromTheViewer() {
    let pose = ScreenPose(yaw: 0, pitch: 0, distance: 1.5, width: 1.0, aspect: 1.0, tilt: 30 * degree)
    let top = pose.modelMatrix * SIMD4<Float>(0, 1, 0, 1)
    let bottom = pose.modelMatrix * SIMD4<Float>(0, -1, 0, 1)
    #expect(top.z < -1.5)
    #expect(bottom.z > -1.5)
}

@Test func tiltKeepsTheScreenCenterInPlace() {
    let flat = ScreenPose(yaw: 0.3, pitch: 0.1, distance: 1.5, width: 1.0, aspect: 1.0)
    var tilted = flat
    tilted.tilt = 35 * degree
    let a = flat.modelMatrix * SIMD4<Float>(0, 0, 0, 1)
    let b = tilted.modelMatrix * SIMD4<Float>(0, 0, 0, 1)
    #expect(simd_length(a - b) < 1e-5)
}

@Test func screenSavedBeforeTiltExistedLoadsFlat() {
    let json = #"[{"yaw":0.1,"pitch":0.2,"distance":1.5,"width":1,"aspect":1.7777}]"#
    let screens = SpatialScene.decode(Data(json.utf8), default: 2, aspect: 16.0 / 9)
    #expect(screens.count == 1)
    #expect(screens[0].yaw == 0.1)
    #expect(screens[0].tilt == 0)
}

@Test func tiltSurvivesSaving() throws {
    let pose = ScreenPose(yaw: 0.1, pitch: 0.2, distance: 1.5, width: 1, aspect: 1.5, tilt: 0.3)
    let decoded = try JSONDecoder().decode(ScreenPose.self, from: JSONEncoder().encode(pose))
    #expect(decoded == pose)
}

@Test func tiltStepsAreClampedToSixtyDegrees() {
    var pose = ScreenPose(yaw: 0, pitch: 0, distance: 1.5, width: 1, aspect: 1)
    pose = tilted(pose, by: 5 * degree)
    #expect(abs(pose.tilt - 5 * degree) < 1e-12)
    for _ in 0..<30 { pose = tilted(pose, by: 5 * degree) }
    #expect(abs(pose.tilt - 60 * degree) < 1e-12)
    for _ in 0..<40 { pose = tilted(pose, by: -5 * degree) }
    #expect(abs(pose.tilt + 60 * degree) < 1e-12)
}
