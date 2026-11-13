import Testing
import simd
@testable import RayDeskCore

private let identityRotation = simd_quatd(angle: 0, axis: SIMD3(0, 1, 0))

@Test func reprojectionIdentityPreservesTheDisplayFieldOfView() throws {
    let warp = RotationalReprojection(scene: identityRotation, display: identityRotation,
                                     verticalFOV: 0.5, aspect: 1.6, overscan: SIMD2(1.25, 1.25))
    for uv in [SIMD2<Float>(0, 0), SIMD2(0.5, 0.5), SIMD2(1, 1), SIMD2(0.15, 0.8)] {
        let source = try #require(warp.textureCoordinate(at: uv))
        #expect(length(source - ((uv - 0.5) / 1.25 + 0.5)) < 1e-6)
    }
}

@Test func reprojectionMatchesWorldPointsForCombinedHeadRotations() throws {
    let scene = yawPitchQuat(yaw: 0.7, pitch: 0.2) * simd_quatd(angle: -0.15, axis: SIMD3(0, 0, 1))
    let display = scene * yawPitchQuat(yaw: 0.04, pitch: -0.03) * simd_quatd(angle: 0.05, axis: SIMD3(0, 0, 1))
    let warp = RotationalReprojection(scene: scene, display: display,
                                     verticalFOV: 0.5, aspect: 1.6, overscan: SIMD2(1.25, 1.25))
    for point in [SIMD3<Double>(0, 0, -3), SIMD3(0.3, 0.2, -2), SIMD3(-0.2, -0.15, -4)] {
        let worldPoint = scene.act(point)
        let inDisplay = display.inverse.act(worldPoint)
        let displayUV = project(inDisplay, tangents: warp.displayTangents)
        let expected = project(scene.inverse.act(worldPoint), tangents: warp.sceneTangents)
        let actual = try #require(warp.textureCoordinate(at: displayUV))
        #expect(length(actual - expected) < 1e-6)
    }
}

@Test func reprojectionRejectsUncoveredAndBehindCameraPixels() {
    for yaw in [0.8, Double.pi] {
        let warp = RotationalReprojection(scene: identityRotation, display: yawPitchQuat(yaw: yaw, pitch: 0),
                                         verticalFOV: 0.5, aspect: 1.6, overscan: SIMD2(1.25, 1.25))
        #expect(warp.textureCoordinate(at: SIMD2(0.5, 0.5)) == nil)
    }
}

@Test func reprojectionIsInvariantToCommonWorldRecenter() throws {
    let scene = yawPitchQuat(yaw: 0.2, pitch: -0.1)
    let display = yawPitchQuat(yaw: 0.25, pitch: -0.08)
    let recenter = yawPitchQuat(yaw: -1.2, pitch: 0.3)
    let before = RotationalReprojection(scene: scene, display: display, verticalFOV: 0.5,
                                       aspect: 1.6, overscan: SIMD2(1.25, 1.25))
    let after = RotationalReprojection(scene: recenter * scene, display: recenter * display,
                                      verticalFOV: 0.5, aspect: 1.6, overscan: SIMD2(1.25, 1.25))
    let uv = SIMD2<Float>(0.4, 0.6)
    #expect(length(try #require(before.textureCoordinate(at: uv)) - #require(after.textureCoordinate(at: uv))) < 1e-6)
}

private func project(_ point: SIMD3<Double>, tangents: SIMD2<Float>) -> SIMD2<Float> {
    SIMD2(Float(point.x / -point.z) / tangents.x * 0.5 + 0.5,
          0.5 - Float(point.y / -point.z) / tangents.y * 0.5)
}
