import CoreGraphics
import Foundation
import Testing
@testable import RayDeskCore

private let aspect = 16.0 / 9
private let expectedWidth = 0.06 * (1 + cos(Double.pi / 16))

private func face(roll: Double, centre: SIMD2<Double> = SIMD2(0.5, 0.3), scale: Double = 1, jaw: Double = 1) -> (left: [CGPoint], right: [CGPoint], contour: [CGPoint]) {
    func place(_ x: Double, _ y: Double) -> CGPoint {
        let rx = (x * cos(roll) - y * sin(roll)) * scale
        let ry = (x * sin(roll) + y * cos(roll)) * scale
        return CGPoint(x: centre.x + rx, y: (centre.y / aspect + ry) * aspect)
    }
    let left = [place(-0.035, 0.02), place(-0.025, 0.02)]
    let right = [place(0.025, 0.02), place(0.035, 0.02)]
    let contour = stride(from: 0.0, through: .pi, by: .pi / 16).map { place(-0.06 * cos($0), -0.07 * sin($0) * jaw) }
    return (left, right, contour)
}

@Test func tiltingTheHeadToTheShoulderKeepsTheWidth() {
    let upright = face(roll: 0)
    let reference = FaceOutline(leftEye: upright.left, rightEye: upright.right, contour: upright.contour, aspect: aspect)!
    #expect(abs(reference.width - expectedWidth) < 1e-9)
    for degrees in [-35.0, -15.0, 20.0, 40.0] {
        let tilted = face(roll: degrees * .pi / 180)
        let outline = FaceOutline(leftEye: tilted.left, rightEye: tilted.right, contour: tilted.contour, aspect: aspect)!
        #expect(abs(outline.width - reference.width) < 1e-9)
        #expect(abs(outline.roll - degrees * .pi / 180) < 1e-9)
    }
}

@Test func closerFaceIsWider() {
    let near = face(roll: 0.3, scale: 1.25)
    let outline = FaceOutline(leftEye: near.left, rightEye: near.right, contour: near.contour, aspect: aspect)!
    #expect(abs(outline.width - expectedWidth * 1.25) < 1e-9)
}

@Test func equivalentBoxIsCentredAndSizedLikeVisionsBox() {
    let upright = face(roll: 0)
    let outline = FaceOutline(leftEye: upright.left, rightEye: upright.right, contour: upright.contour, aspect: aspect)!
    let box = outline.equivalentBox(center: CGPoint(x: 0.4, y: 0.6), aspect: aspect)
    #expect(abs(box.midX - 0.4) < 1e-12 && abs(box.midY - 0.6) < 1e-12)
    #expect(abs(box.width - expectedWidth * FaceOutline.boxToContour) < 1e-12)
}

@Test func missingLandmarksGiveNothing() {
    #expect(FaceOutline(leftEye: [], rightEye: [CGPoint(x: 0.5, y: 0.5)], contour: [], aspect: aspect) == nil)
}

@Test func openingTheMouthMovesNeitherWidthNorCentre() {
    let closed = face(roll: 0.2)
    let open = face(roll: 0.2, jaw: 1.35)
    let before = FaceOutline(leftEye: closed.left, rightEye: closed.right, contour: closed.contour, aspect: aspect)!
    let after = FaceOutline(leftEye: open.left, rightEye: open.right, contour: open.contour, aspect: aspect)!
    #expect(abs(after.width - before.width) < 0.002 * before.width)
    #expect(abs(after.center.x - before.center.x) < 1e-12 && abs(after.center.y - before.center.y) < 1e-12)
}
