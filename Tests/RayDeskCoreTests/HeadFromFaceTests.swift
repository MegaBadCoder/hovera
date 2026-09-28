import CoreGraphics
import Testing
import simd
@testable import RayDeskCore

private let camera = FaceCamera(horizontalFieldOfView: 70 * .pi / 180, aspect: 16.0 / 9, faceWidth: 0.15)

private func face(centerX: Double, centerY: Double, width: Double) -> CGRect {
    let height = width * camera.aspect
    return CGRect(x: centerX - width / 2, y: centerY - height / 2, width: width, height: height)
}

@Test func centredFaceIsStraightInFrontOfTheCamera() {
    let head = camera.headPosition(face: face(centerX: 0.5, centerY: 0.5, width: 0.2))
    #expect(abs(head.x) < 1e-12 && abs(head.y) < 1e-12)
    #expect(head.z > 0)
}

@Test func faceTwiceAsWideIsHalfAsFar() {
    let far = camera.headPosition(face: face(centerX: 0.5, centerY: 0.5, width: 0.1))
    let near = camera.headPosition(face: face(centerX: 0.5, centerY: 0.5, width: 0.2))
    #expect(abs(far.z / near.z - 2) < 1e-12)
}

@Test func faceFillingTheFieldOfViewIsWhereItsWidthMatchesTheView() {
    let head = camera.headPosition(face: face(centerX: 0.5, centerY: 0.5, width: 1))
    let visibleWidth = 2 * head.z * tan(camera.horizontalFieldOfView / 2)
    #expect(abs(visibleWidth - camera.faceWidth) < 1e-12)
}

@Test func faceAtTheRightEdgeIsOffToTheRightByHalfTheVisibleWidth() {
    let head = camera.headPosition(face: face(centerX: 1, centerY: 0.5, width: 0.2))
    let visibleHalfWidth = head.z * tan(camera.horizontalFieldOfView / 2)
    #expect(abs(head.x - visibleHalfWidth) < 1e-12)
    #expect(abs(head.y) < 1e-12)
}

@Test func faceHigherInTheFrameIsAbove() {
    let head = camera.headPosition(face: face(centerX: 0.5, centerY: 0.8, width: 0.2))
    #expect(head.y > 0)
    let visibleHalfHeight = head.z * tan(camera.horizontalFieldOfView / 2) / camera.aspect
    #expect(abs(head.y - 0.6 * visibleHalfHeight) < 1e-12)
}

@Test func spreadMeasuresJitterOverTheWindow() {
    var spread = RollingSpread(window: 1)
    #expect(spread.deviation == nil)
    for i in 0..<31 {
        spread.add(SIMD3(i.isMultiple(of: 2) ? 0.01 : -0.01, 0, 0.6), at: Double(i) / 30)
    }
    #expect(spread.count == 31)
    #expect(abs(spread.mean!.z - 0.6) < 1e-12)
    #expect(abs(spread.deviation!.x - 0.01) < 0.001)
    #expect(spread.deviation!.z < 1e-12)
}

@Test func spreadForgetsOldSamples() {
    var spread = RollingSpread(window: 1)
    spread.add(SIMD3(1, 1, 1), at: 0)
    spread.add(SIMD3(0, 0, 0), at: 2)
    spread.add(SIMD3(0, 0, 0), at: 2.5)
    #expect(spread.count == 2)
    #expect(spread.deviation! == SIMD3(repeating: 0))
}
