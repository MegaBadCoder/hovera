import Testing
import simd
@testable import RayDeskCore

private let skinRGB: (UInt8, UInt8, UInt8) = (200, 150, 120)
private let frameRGB: (UInt8, UInt8, UInt8) = (60, 62, 64)

private func image(width: Int, height: Int, glasses: (x0: Int, y0: Int, x1: Int, y1: Int)?) -> RGBAImage {
    var pixels = [UInt8](repeating: 255, count: width * height * 4)
    for y in 0..<height {
        for x in 0..<width {
            let inside = glasses.map { x >= $0.x0 && x <= $0.x1 && y >= $0.y0 && y <= $0.y1 } ?? false
            let c = inside ? frameRGB : skinRGB
            let i = (y * width + x) * 4
            pixels[i] = c.0
            pixels[i + 1] = c.1
            pixels[i + 2] = c.2
        }
    }
    return RGBAImage(width: width, height: height, pixels: pixels)
}

private func skinClassifier() -> SkinClassifier {
     SkinClassifier(skin: image(width: 1, height: 1, glasses: nil).color(x: 0, y: 0))
}

@Test func similarityFitRecoversRotationScaleAndShift() {
    var generator = SystemRandomNumberGenerator()
    let points = (0..<35).map { _ in SIMD3(Double.random(in: -50...50, using: &generator), Double.random(in: -50...50, using: &generator),
                                           Double.random(in: -20...20, using: &generator)) }
    let rotation = simd_double3x3(simd_quatd(angle: 0.4, axis: simd_normalize(SIMD3(0.3, 1, 0.2))))
    let moved = points.map { 1.3 * (rotation * $0) + SIMD3(400, 250, -10) }
    let fit = SimilarityFit(from: points, to: moved)
    #expect(abs(fit.scale - 1.3) < 1e-9)
    #expect(fit.residual < 1e-6)
    #expect(simd_length(fit.apply(SIMD3(10, -20, 5)) - (1.3 * (rotation * SIMD3(10, -20, 5)) + SIMD3(400, 250, -10))) < 1e-6)
}

@Test func faceOvalMaskFillsTheInsideOfTheContour() {
    var landmarks = [SIMD3<Double>](repeating: .zero, count: 478)
    for (i, index) in FaceMeshPoint.oval.enumerated() {
        let angle = Double(i) / Double(FaceMeshPoint.oval.count) * 2 * .pi
        landmarks[index] = SIMD3(50 + 20 * cos(angle), 40 + 20 * sin(angle), 0)
    }
    let mask = faceOvalMask(landmarks: landmarks, width: 100, height: 80)
    #expect(mask[40 * 100 + 50])
    #expect(!mask[5 * 100 + 5])
    #expect(!mask[40 * 100 + 75])
    let area = Double(mask.filter { $0 }.count)
    #expect(abs(area - Double.pi * 400) / (Double.pi * 400) < 0.05)
}

@Test func greyFrameIsNotSkinAndSkinIs() {
    let classifier = skinClassifier()
    let picture = image(width: 10, height: 10, glasses: (2, 2, 5, 5))
    #expect(classifier.isNotSkin(picture.color(x: 3, y: 3)))
    #expect(!classifier.isNotSkin(picture.color(x: 8, y: 8)))
}

@Test func trackerFindsTheGlassesFromAnOffStart() {
    let picture = image(width: 200, height: 120, glasses: (60, 40, 139, 69))
    let kept = stride(from: 60.5, through: 139.5, by: 1.0).flatMap { x in
        stride(from: 40.5, through: 69.5, by: 1.0).map { y in SIMD3(x, y, 0.0) }
    }
    let probes = stride(from: 62.5, through: 137.5, by: 3.0).flatMap { x in
        [SIMD3(x, 38.5, 0.0), SIMD3(x, 71.5, 0.0), SIMD3(x, 35.0, 0.0), SIMD3(x, 75.0, 0.0)]
    }
    let identity = matrix_identity_double3x3
    let offCentre = SimilarityFit(from: [SIMD3(0, 0, 0), SIMD3(10, 0, 0), SIMD3(0, 10, 0)],
                                  to: [SIMD3(4, -3, 0), SIMD3(14.5, -3, 0), SIMD3(4, 7.5, 0)])
    var tracker = GlassesTracker()
    let result = tracker.track(image: picture, scale: 1, rotation: identity, start: offCentre, kept: kept, probes: probes,
                               classifier: skinClassifier())
    #expect(result != nil)
    #expect(abs((result?.scale ?? 0) - 1) < 0.02)
    #expect(simd_length((result?.center ?? .zero) - SIMD2(100, 55)) < 1.5)
    #expect((result?.score ?? 0) > 0.95)
}

@Test func trackerGivesUpWhenThereAreNoGlasses() {
    let picture = image(width: 200, height: 120, glasses: nil)
    let kept = [SIMD3(100.0, 60, 0), SIMD3(101, 60, 0), SIMD3(102, 60, 0)]
    let probes = [SIMD3(100.0, 50, 0), SIMD3(100, 70, 0)]
    let start = SimilarityFit(from: [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0)], to: [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0)])
    var tracker = GlassesTracker()
    #expect(tracker.track(image: picture, scale: 1, rotation: matrix_identity_double3x3, start: start, kept: kept, probes: probes,
                          classifier: skinClassifier()) == nil)
    #expect(!tracker.ready)
}
