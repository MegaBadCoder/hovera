import Foundation
import Testing
import simd
@testable import RayDeskCore

private let skinRGB: (UInt8, UInt8, UInt8) = (200, 150, 120)
private let frameRGB: (UInt8, UInt8, UInt8) = (60, 62, 64)
private let side = 320

private func render(glasses: (x0: Int, y0: Int, x1: Int, y1: Int)) -> RGBAImage {
    var pixels = [UInt8](repeating: 255, count: side * side * 4)
    for y in 0..<side {
        for x in 0..<side {
            let inside = x >= glasses.x0 && x <= glasses.x1 && y >= glasses.y0 && y <= glasses.y1
            let c = inside ? frameRGB : skinRGB
            let i = (y * side + x) * 4
            pixels[i] = c.0
            pixels[i + 1] = c.1
            pixels[i + 2] = c.2
        }
    }
    return RGBAImage(width: side, height: side, pixels: pixels)
}

private func head() -> [SIMD3<Double>] {
    let centre = SIMD2(160.0, 330.0), width = 222.0
    let half = width / 2, height = width * 1.13
    var landmarks = [SIMD3<Double>](repeating: SIMD3(centre.x, centre.y, 0), count: 478)
    for (i, index) in FaceMeshPoint.oval.enumerated() {
        let angle = Double(i) / Double(FaceMeshPoint.oval.count) * 2 * .pi
        landmarks[index] = SIMD3(centre.x + half * cos(angle), centre.y + height / 2 * sin(angle), 0)
    }
    landmarks[FaceMeshPoint.sides.0] = SIMD3(centre.x - half, centre.y, 0)
    landmarks[FaceMeshPoint.sides.1] = SIMD3(centre.x + half, centre.y, 0)
    landmarks[FaceMeshPoint.noseBridge] = SIMD3(centre.x, centre.y, 0)
    landmarks[FaceMeshPoint.noseMiddle] = SIMD3(centre.x, centre.y + 0.18 * width, 0)
    for index in FaceMeshPoint.brows { landmarks[index] = SIMD3(centre.x + (index == 70 || index == 105 ? -0.2 : 0.2) * width,
                                                               centre.y - 0.14 * width, 0) }
    for index in [33, 133] { landmarks[index] = SIMD3(centre.x - 0.18 * width, centre.y - 0.03 * width, 0) }
    for index in [362, 263] { landmarks[index] = SIMD3(centre.x + 0.18 * width, centre.y - 0.03 * width, 0) }
    for index in FaceMeshPoint.skin { landmarks[index] = SIMD3(centre.x, centre.y + 0.2 * width, 0) }
    return landmarks
}

private func fit(scale: Double = 1, rotation: simd_double3x3 = matrix_identity_double3x3, shift: SIMD3<Double> = .zero) -> SimilarityFit {
    SimilarityFit(from: [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1)],
                  to: [shift, shift + scale * (rotation * SIMD3(1, 0, 0)), shift + scale * (rotation * SIMD3(0, 1, 0)),
                       shift + scale * (rotation * SIMD3(0, 0, 1))])
}

private let rectangle = (x0: 30, y0: 230, x1: 290, y1: 310)

private func contour(_ box: (x0: Int, y0: Int, x1: Int, y1: Int)) -> [SIMD2<Double>] {
    [SIMD2(Double(box.x0) - 0.5, Double(box.y0) - 0.5), SIMD2(Double(box.x1) + 0.5, Double(box.y0) - 0.5),
     SIMD2(Double(box.x1) + 0.5, Double(box.y1) + 0.5), SIMD2(Double(box.x0) - 0.5, Double(box.y1) + 0.5)]
}

private func outline(_ box: (x0: Int, y0: Int, x1: Int, y1: Int)) -> GlassesOutline {
    GlassesOutline(contour: contour(box), width: side, height: side)!
}

@Test func outlineFillsTheDrawnContour() {
    let shape = outline(rectangle)
    #expect(shape.mask.box.x0 == rectangle.x0 - 1)
    #expect(shape.mask.box.y1 == rectangle.y1 + 1)
    #expect(shape.mask.box.x1 == rectangle.x1 + 1)
    let filled = shape.mask.mask.filter { $0 }.count
    #expect(filled >= 260 * 75)
    #expect(filled <= 262 * 81)
    #expect(shape.mask.contains(SIMD2(160, 270)))
    #expect(!shape.mask.contains(SIMD2(160, 100)))
}

@Test func outlineNeedsThreePointsAndArea() {
    #expect(GlassesOutline(contour: [SIMD2(1, 1), SIMD2(2, 2)], width: side, height: side) == nil)
    #expect(GlassesOutline(contour: [SIMD2(1, 1), SIMD2(2, 1), SIMD2(3, 1)], width: side, height: side) == nil)
    #expect(GlassesOutline(contour: [SIMD2(1, 1), SIMD2(1, 1), SIMD2(1, 1)], width: side, height: side) == nil)
}

@Test func theOutlineDecidesTheLensStandoff() {
    var shape = GlassesShape(landmarks: head(), depth: 0.5, fieldOfView: 70 * .pi / 180)
    let oval = faceOvalMask(landmarks: head(), width: side, height: side)
    for _ in 0..<2 { shape.commitOutline(outline(rectangle), oval: oval, fit: fit(), scale: 1, width: side) }
    let kept = shape.keptPoints()
    #expect(kept.count > 400)
    let strays = kept.filter { $0.x < Double(rectangle.x0) || $0.x > Double(rectangle.x1) + 1
        || $0.y < Double(rectangle.y0) || $0.y > Double(rectangle.y1) + 1 }
    #expect(strays.isEmpty)
    #expect(Set(kept.map(\.z)).count == 1)
    #expect(shape.lensStandoff == nil)
    shape.resolveStandoff()
    let standoff = try? #require(shape.lensStandoff)
    #expect(GlassesShape.depths.contains(standoff ?? .nan))
    #expect(shape.keptPoints().count > 400)
}

@Test func aContourOutsideTheFaceTeachesNothing() {
    var shape = GlassesShape(landmarks: head(), depth: 0.5, fieldOfView: 70 * .pi / 180)
    let oval = faceOvalMask(landmarks: head(), width: side, height: side)
    shape.commitOutline(outline((10, 10, 60, 40)), oval: oval, fit: fit(), scale: 1, width: side)
    #expect(shape.keptPoints().isEmpty)
    shape.resolveStandoff()
    #expect(shape.lensStandoff == nil)
}

@Test func turnKeepsTheLensOneDepth() {
    var shape = GlassesShape(landmarks: head(), depth: 0.5, fieldOfView: 70 * .pi / 180)
    let oval = faceOvalMask(landmarks: head(), width: side, height: side)
    let turn = simd_double3x3(simd_quatd(angle: 0.35, axis: SIMD3(0, 1, 0)))
    for moved in [fit(), fit(rotation: turn, shift: SIMD3(6, -2, 0))] {
        shape.commitOutline(outline(rectangle), oval: oval, fit: moved, scale: 1, width: side)
    }
    shape.resolveStandoff()
    #expect(shape.lensStandoff != nil)
    let depths = Set(shape.keptPoints().map(\.z))
    #expect(depths.count == 1)
    #expect(shape.keptPoints().count > 300)
}

@Test func theStandoffNeedsTwoOutlinedFrames() {
    var shape = GlassesShape(landmarks: head(), depth: 0.5, fieldOfView: 70 * .pi / 180)
    let oval = faceOvalMask(landmarks: head(), width: side, height: side)
    shape.commitOutline(outline(rectangle), oval: oval, fit: fit(), scale: 1, width: side)
    shape.resolveStandoff()
    #expect(shape.lensStandoff == nil)
    shape.commitOutline(outline(rectangle), oval: oval, fit: fit(), scale: 1, width: side)
    shape.resolveStandoff()
    #expect(shape.lensStandoff != nil)
}

@Test func theStandoffStaysUntilAnotherWins() {
    var shape = GlassesShape(landmarks: head(), depth: 0.5, fieldOfView: 70 * .pi / 180)
    let oval = faceOvalMask(landmarks: head(), width: side, height: side)
    for _ in 0..<2 { shape.commitOutline(outline(rectangle), oval: oval, fit: fit(), scale: 1, width: side) }
    shape.resolveStandoff()
    let chosen = try? #require(shape.lensStandoff)
    let same = SIMD3<Double>(0, 0, 0)
    shape.noteOutline(outline(rectangle), fit: fit(shift: same), scale: 1, width: side)
    shape.resolveStandoff()
    #expect(shape.lensStandoff == chosen)
}

@Test func outlineSurvivesTheShapeFile() throws {
    var shape = GlassesShape(landmarks: head(), depth: 0.5, fieldOfView: 70 * .pi / 180)
    let oval = faceOvalMask(landmarks: head(), width: side, height: side)
    shape.commitOutline(outline(rectangle), oval: oval, fit: fit(), scale: 1, width: side)
    shape.commitOutline(outline(rectangle), oval: oval, fit: fit(), scale: 1, width: side)
    shape.resolveStandoff()
    let data = try PropertyListEncoder().encode(shape)
    let restored = try PropertyListDecoder().decode(GlassesShape.self, from: data)
    #expect(restored.lensStandoff == shape.lensStandoff)
    #expect(restored.keptPoints().count == shape.keptPoints().count)
}

@Test func theWindowContourLandsWhereItWasDrawn() {
    var pixels = [UInt8](repeating: 0, count: side * side * 4)
    for y in 0..<side { for x in 0..<side {
        let i = (y * side + x) * 4
        let frame = x >= rectangle.x0 && x <= rectangle.x1 && y >= rectangle.y0 && y <= rectangle.y1
        pixels[i] = frame ? frameRGB.0 : skinRGB.0
        pixels[i + 1] = frame ? frameRGB.1 : skinRGB.1
        pixels[i + 2] = frame ? frameRGB.2 : skinRGB.2
        pixels[i + 3] = 255
    } }
    let image = RGBAImage(width: side, height: side, pixels: pixels)
    let landmarks = head().map { $0 }
    let context = GlassesFrameContext(image: image, landmarks: landmarks, fit: fit(), scale: 1, depth: 0.5,
                                      fieldOfView: 70 * .pi / 180, fullWidth: Double(side), fullHeight: Double(side),
                                      generation: 1, head: simd_quatd(ix: 0, iy: 0, iz: 0, r: 1))
    let drawn = [CGPoint(x: 0.2, y: 0.8), CGPoint(x: 0.8, y: 0.8), CGPoint(x: 0.8, y: 0.4), CGPoint(x: 0.2, y: 0.4)]
    let outline = try? #require(context.outline(contour: drawn.map { SIMD2(Double($0.x), Double($0.y)) }))
    guard let outline else { return }
    #expect(outline.mask.contains(SIMD2(Int(0.5 * Double(side)), Int(0.4 * Double(side)))))
    #expect(!outline.mask.contains(SIMD2(Int(0.5 * Double(side)), Int(0.9 * Double(side)))))
    let classifier = try? #require(SkinClassifier.sampled(from: image, landmarks: landmarks))
    guard let classifier else { return }
    #expect(!classifier.isNotSkin(image.color(x: 100, y: 100)))
    #expect(classifier.isNotSkin(image.color(x: 160, y: 250)))
}
