import MetalKit
import Testing
import RayDeskCore
@testable import RayDesk

@Test func metalReprojectionMatchesWorldGeometryAndClearsUncoveredPixels() throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let queue = try #require(device.makeCommandQueue())
    let compositor = try RotationalCompositor(device: device, pixelFormat: .rgba8Unorm,
                                             depthFormat: .depth32Float, sampleCount: 4)
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 80, height: 80, mipmapped: false)
    descriptor.storageMode = .shared
    descriptor.usage = [.shaderRead]
    let source = try #require(device.makeTexture(descriptor: descriptor))
    var gradient = [UInt8](repeating: 255, count: 80 * 80 * 4)
    for y in 0..<80 {
        for x in 0..<80 {
            gradient[(y * 80 + x) * 4] = UInt8((Double(x) / 79 * 255).rounded())
            gradient[(y * 80 + x) * 4 + 1] = UInt8((Double(y) / 79 * 255).rounded())
        }
    }
    source.replace(region: MTLRegionMake2D(0, 0, 80, 80), mipmapLevel: 0, withBytes: &gradient, bytesPerRow: 80 * 4)
    descriptor.width = 64
    descriptor.height = 64
    descriptor.usage = [.renderTarget]
    let destination = try #require(device.makeTexture(descriptor: descriptor))
    let scene = yawPitchQuat(yaw: 0.7, pitch: 0.2)
    for scanout in [false, true] {
        for turn in [SIMD3<Double>.zero, SIMD3(0.04, -0.03, 0.05), SIMD3(0.8, 0, 0), SIMD3(Double.pi, 0, 0)] {
            let display = scene * yawPitchQuat(yaw: turn.x, pitch: turn.y) * simd_quatd(angle: turn.z, axis: SIMD3(0, 0, 1))
            let bottom = scanout ? display * simd_quatd(angle: 0.05, axis: normalize(SIMD3(0.2, 1, 0.1))) : display
            let warp = RotationalReprojection(scene: scene, displayTop: display, displayBottom: bottom, verticalFOV: 0.5,
                                             aspect: 1, overscan: SIMD2(1.25, 1.25))
            let commandBuffer = try #require(queue.makeCommandBuffer())
            try compositor.encode(warp, source: source, destination: destination, commandBuffer: commandBuffer)
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
            #expect(commandBuffer.status == .completed)
            var pixels = [UInt8](repeating: 0, count: 64 * 64 * 4)
            destination.getBytes(&pixels, bytesPerRow: 64 * 4, from: MTLRegionMake2D(0, 0, 64, 64), mipmapLevel: 0)
            for point in [SIMD2(4, 6), SIMD2(32, 32), SIMD2(58, 56), SIMD2(24, 46)] {
                let uv = (SIMD2<Float>(point) + 0.5) / 64
                let pixel = (point.y * 64 + point.x) * 4
                if let expected = warp.textureCoordinate(at: uv) {
                    let red = min(1, max(0, (expected.x * 80 - 0.5) / 79))
                    let green = min(1, max(0, (expected.y * 80 - 0.5) / 79))
                    #expect(abs(Float(pixels[pixel]) / 255 - red) < 0.008)
                    #expect(abs(Float(pixels[pixel + 1]) / 255 - green) < 0.008)
                } else {
                    #expect(pixels[pixel] == 0 && pixels[pixel + 1] == 0 && pixels[pixel + 2] == 0)
                }
                #expect(pixels[pixel + 3] == 255)
            }
        }
    }
}

@Test func reprojectionTargetsResizeWithoutLosingPixelDensity() throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let compositor = try RotationalCompositor(device: device, pixelFormat: .bgra8Unorm_srgb,
                                             depthFormat: .depth32Float, sampleCount: 4)
    let first = try compositor.prepare(displaySize: SIMD2(64, 48))
    #expect(first.color.width == 80 && first.color.height == 60)
    #expect(first.multisample.sampleCount == 4 && first.depth.sampleCount == 4)
    let resized = try compositor.prepare(displaySize: SIMD2(100, 80))
    #expect(resized.color.width == 125 && resized.color.height == 100)
    #expect(first.color !== resized.color)
    #expect(try compositor.prepare(displaySize: SIMD2(100, 80)).color === resized.color)
}
