import CoreML
import CoreVideo
import Foundation
import RayDeskCore
import Vision
import simd

/// 478 точек лица по кадру камеры: сеть точек лица MediaPipe, переведённая в CoreML (`FaceLandmarks.mlmodelc`).
///
/// Лицо вырезается квадратом 256×256 с поворотом по линии глаз. Первый вырез берётся из рамки лица
/// Vision, следующие — по точкам прошлого кадра, как в MediaPipe. Работает в потоке камеры.
final class FaceMesh {
    private let model: MLModel
    private var input: CVPixelBuffer
    private var region: (center: SIMD2<Double>, size: Double, angle: Double)?
    private static let side = 256
    private static let regionScale = 1.5

    init?() {
        guard let url = Self.compiledModelURL(), let model = try? MLModel(contentsOf: url) else { return nil }
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, Self.side, Self.side, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
        guard let buffer else { return nil }
        self.model = model
        input = buffer
    }

    /// Точки лица в пикселях кадра: x вправо, y вниз, z — глубина относительно середины головы в тех же пикселях,
    /// меньше — ближе к камере. `nil`, если лица нет. Кадр — BGRA.
    func landmarks(in pixels: CVPixelBuffer) -> [SIMD3<Double>]? {
        if region == nil { region = detectRegion(pixels) }
        guard let region else { return nil }
        warp(pixels, region: region)
        guard let output = try? model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(pixelBuffer: input)])),
              let raw = output.featureValue(for: "landmarks")?.multiArrayValue,
              let presence = output.featureValue(for: "presence")?.multiArrayValue
        else { return nil }
        guard 1 / (1 + exp(-presence[0].doubleValue)) >= 0.5 else {
            self.region = nil
            return nil
        }
        let rotation = rotationMatrix(region.angle)
        let unit = region.size / Double(Self.side)
        var points: [SIMD3<Double>] = []
        points.reserveCapacity(raw.count / 3)
        for i in 0..<raw.count / 3 {
            let local = SIMD2(raw[i * 3].doubleValue - Double(Self.side) / 2, raw[i * 3 + 1].doubleValue - Double(Self.side) / 2) * unit
            let image = region.center + rotation * local
            points.append(SIMD3(image.x, image.y, raw[i * 3 + 2].doubleValue * unit))
        }
        self.region = Self.region(following: points)
        return points
    }

    /// Забывает вырез: следующий кадр начнёт с поиска лица Vision.
    func reset() {
        region = nil
    }

    private static func region(following points: [SIMD3<Double>]) -> (center: SIMD2<Double>, size: Double, angle: Double) {
        let xs = points.map(\.x), ys = points.map(\.y)
        let center = SIMD2((xs.min()! + xs.max()!) / 2, (ys.min()! + ys.max()!) / 2)
        let size = max(xs.max()! - xs.min()!, ys.max()! - ys.min()!) * regionScale
        let a = points[FaceMeshPoint.eyeCorners.0], b = points[FaceMeshPoint.eyeCorners.1]
        return (center, size, atan2(b.y - a.y, b.x - a.x))
    }

    private func detectRegion(_ pixels: CVPixelBuffer) -> (center: SIMD2<Double>, size: Double, angle: Double)? {
        let request = VNDetectFaceRectanglesRequest()
        try? VNImageRequestHandler(cvPixelBuffer: pixels, options: [:]).perform([request])
        guard let face = request.results?.max(by: { $0.boundingBox.width < $1.boundingBox.width }) else { return nil }
        let width = Double(CVPixelBufferGetWidth(pixels)), height = Double(CVPixelBufferGetHeight(pixels))
        let box = face.boundingBox
        let center = SIMD2(Double(box.midX) * width, (1 - Double(box.midY)) * height)
        return (center, max(Double(box.width) * width, Double(box.height) * height) * Self.regionScale, 0)
    }

    private func rotationMatrix(_ angle: Double) -> simd_double2x2 {
        simd_double2x2(rows: [SIMD2(cos(angle), -sin(angle)), SIMD2(sin(angle), cos(angle))])
    }

    private func warp(_ pixels: CVPixelBuffer, region: (center: SIMD2<Double>, size: Double, angle: Double)) {
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        CVPixelBufferLockBaseAddress(input, [])
        defer {
            CVPixelBufferUnlockBaseAddress(input, [])
            CVPixelBufferUnlockBaseAddress(pixels, .readOnly)
        }
        guard let source = CVPixelBufferGetBaseAddress(pixels)?.assumingMemoryBound(to: UInt8.self),
              let target = CVPixelBufferGetBaseAddress(input)?.assumingMemoryBound(to: UInt8.self)
        else { return }
        let width = CVPixelBufferGetWidth(pixels), height = CVPixelBufferGetHeight(pixels)
        let sourceRow = CVPixelBufferGetBytesPerRow(pixels), targetRow = CVPixelBufferGetBytesPerRow(input)
        let rotation = rotationMatrix(region.angle)
        let unit = region.size / Double(Self.side)
        for v in 0..<Self.side {
            for u in 0..<Self.side {
                let local = SIMD2(Double(u) + 0.5 - Double(Self.side) / 2, Double(v) + 0.5 - Double(Self.side) / 2) * unit
                let p = region.center + rotation * local - 0.5
                let x0 = Int(floor(p.x)), y0 = Int(floor(p.y))
                let fx = p.x - Double(x0), fy = p.y - Double(y0)
                let out = target + v * targetRow + u * 4
                guard x0 >= 0, y0 >= 0, x0 + 1 < width, y0 + 1 < height else {
                    out[0] = 0; out[1] = 0; out[2] = 0; out[3] = 255
                    continue
                }
                let a = source + y0 * sourceRow + x0 * 4, b = a + 4, c = a + sourceRow, d = c + 4
                for channel in 0..<3 {
                    let top = Double(a[channel]) * (1 - fx) + Double(b[channel]) * fx
                    let bottom = Double(c[channel]) * (1 - fx) + Double(d[channel]) * fx
                    out[channel] = UInt8(max(0, min(255, (top * (1 - fy) + bottom * fy).rounded())))
                }
                out[3] = 255
            }
        }
    }

    private static func compiledModelURL() -> URL? {
        if let bundled = Bundle.main.url(forResource: "FaceLandmarks", withExtension: "mlmodelc") { return bundled }
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Models/FaceLandmarks.mlpackage")
        return try? MLModel.compileModel(at: package)
    }
}
