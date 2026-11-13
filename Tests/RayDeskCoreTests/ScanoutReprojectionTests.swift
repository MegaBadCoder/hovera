import Testing
import simd
@testable import RayDeskCore

private let scanoutIdentity = simd_quatd(angle: 0, axis: SIMD3(0, 1, 0))

@Suite struct ScanoutReprojectionTests {
    @Test func usesTheTopAndBottomPosesAtTheCorrespondingUVRows() throws {
        let top = yawPitchQuat(yaw: 0.03, pitch: -0.02)
        let bottom = top * simd_quatd(angle: 0.04, axis: normalize(SIMD3(0.2, 1, 0.3)))
        let rows = RotationalReprojection(scene: scanoutIdentity, displayTop: top, displayBottom: bottom,
                                          verticalFOV: 0.5, aspect: 1.6, overscan: SIMD2(1.25, 1.25))
        for row: Float in [0, 0.25, 0.5, 0.75, 1] {
            let uv = SIMD2<Float>(0.45, row)
            let input = SIMD3((2 * uv.x - 1) * rows.displayTangents.x, (1 - 2 * uv.y) * rows.displayTangents.y, -1)
            let first = simd_float3x3(simd_quatf(vector: SIMD4<Float>(top.vector))) * input
            let last = simd_float3x3(simd_quatf(vector: SIMD4<Float>(bottom.vector))) * input
            let ray = first * (1 - row) + last * row
            let projected = SIMD2(ray.x, ray.y) / -ray.z / rows.sceneTangents
            let expected = SIMD2(projected.x * 0.5 + 0.5, 0.5 - projected.y * 0.5)
            #expect(length(try #require(rows.textureCoordinate(at: uv)) - expected) < 1e-6)
        }
    }

    @Test(arguments: [SIMD3<Double>(0, 1, 0), SIMD3(1, 0, 0), SIMD3(0, 0, 1)])
    func compensatesKnownRowMotionWithoutAddingTheReferenceHorizonTwice(axis: SIMD3<Double>) throws {
        let rate = 1.0
        let horizon = 0.025
        let reference = simd_quatd(angle: horizon * rate, axis: axis)
        let prediction = ScanoutPrediction(reference: reference, angularVelocity: axis * rate,
                                           duration: 1 / 120, maximumAdditionalTime: 0.05 - horizon,
                                           enabled: true, bottomToTop: false)
        #expect(abs(simd_dot(prediction.top.vector, reference.vector)) > 1 - 1e-12)
        let expectedBottom = simd_quatd(angle: (horizon + 1 / 120) * rate, axis: axis)
        #expect(abs(simd_dot(prediction.bottom.vector, expectedBottom.vector)) > 1 - 1e-12)
        let warp = RotationalReprojection(scene: scanoutIdentity, displayTop: prediction.top, displayBottom: prediction.bottom,
                                         verticalFOV: 0.5, aspect: 1.6, overscan: SIMD2(1.25, 1.25))
        for row: Float in [0.05, 0.25, 0.5, 0.75, 0.95] {
            let uv = SIMD2<Float>(0.4, row)
            let actualPose = simd_quatd(angle: (horizon + Double(row) / 120) * rate, axis: axis)
            let exact = RotationalReprojection(scene: scanoutIdentity, display: actualPose,
                                              verticalFOV: 0.5, aspect: 1.6, overscan: SIMD2(1.25, 1.25))
            #expect(length(try #require(warp.textureCoordinate(at: uv)) - #require(exact.textureCoordinate(at: uv))) < 1e-5)
        }
    }

    @Test func zeroMotionAndDisabledScanoutPreserveTheBaseline() {
        let reference = yawPitchQuat(yaw: 0.2, pitch: -0.1)
        for enabled in [false, true] {
            let pair = ScanoutPrediction(reference: reference, angularVelocity: .zero, duration: 1 / 120,
                                         maximumAdditionalTime: 0.05, enabled: enabled, bottomToTop: false)
            #expect(pair.top.vector == reference.vector)
            #expect(pair.bottom.vector == reference.vector)
        }
        let disabled = ScanoutPrediction(reference: reference, angularVelocity: SIMD3(0, 1, 0), duration: 1 / 120,
                                         maximumAdditionalTime: 0.05, enabled: false, bottomToTop: false)
        #expect(disabled.top.vector == disabled.bottom.vector)
        #expect(disabled.duration == 0)
    }

    @Test func respectsTheRemainingPredictionBudgetAndReversesTheRows() {
        let pair = ScanoutPrediction(reference: scanoutIdentity, angularVelocity: SIMD3(0, 1, 0), duration: 1 / 120,
                                     maximumAdditionalTime: 0.003, enabled: true, bottomToTop: true)
        #expect(abs(pair.duration - 0.003) < 1e-12)
        #expect(pair.bottom.vector == scanoutIdentity.vector)
        #expect(abs(pair.top.yawPitch.yaw - 0.003) < 1e-12)
    }

    @Test func commonWorldRecenterDoesNotChangeTheRowProjection() throws {
        let scene = yawPitchQuat(yaw: 0.2, pitch: -0.1)
        let top = yawPitchQuat(yaw: 0.24, pitch: -0.08)
        let bottom = top * simd_quatd(angle: 0.012, axis: SIMD3(0, 0, 1))
        let shift = yawPitchQuat(yaw: -1.3, pitch: 0.25)
        let before = RotationalReprojection(scene: scene, displayTop: top, displayBottom: bottom,
                                            verticalFOV: 0.5, aspect: 1.6, overscan: SIMD2(1.25, 1.25))
        let after = RotationalReprojection(scene: shift * scene, displayTop: shift * top, displayBottom: shift * bottom,
                                           verticalFOV: 0.5, aspect: 1.6, overscan: SIMD2(1.25, 1.25))
        for row: Float in [0, 0.5, 1] {
            let uv = SIMD2<Float>(0.4, row)
            #expect(length(try #require(before.textureCoordinate(at: uv)) - #require(after.textureCoordinate(at: uv))) < 1e-6)
        }
    }

    @Test func invalidVelocityAndBudgetCannotCreateAnInvalidRowPose() {
        for velocity in [SIMD3<Double>(.nan, 0, 0), SIMD3(.infinity, 0, 0)] {
            let pair = ScanoutPrediction(reference: scanoutIdentity, angularVelocity: velocity, duration: 1 / 120,
                                         maximumAdditionalTime: 0.05, enabled: true, bottomToTop: false)
            #expect(pair.duration == 0)
            #expect(pair.top.vector == pair.bottom.vector)
        }
        let pair = ScanoutPrediction(reference: scanoutIdentity, angularVelocity: SIMD3(0, 1, 0), duration: 1 / 120,
                                     maximumAdditionalTime: -0.01, enabled: true, bottomToTop: false)
        #expect(pair.duration == 0)
    }
}
