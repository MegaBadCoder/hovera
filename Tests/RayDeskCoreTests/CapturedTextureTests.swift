import MetalKit
import CoreVideo
import Testing
@testable import RayDesk

@Suite struct CapturedTextureTests {
    @Test func cancelledGPUEncodingDoesNotConsumeTheLastCaptureFrame() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        var cache: CVMetalTextureCache?
        #expect(CVMetalTextureCacheCreate(nil, nil, device, nil, &cache) == kCVReturnSuccess)
        let textureCache = try #require(cache)
        var buffer: CVPixelBuffer?
        let attrs = [kCVPixelBufferMetalCompatibilityKey: true,
                     kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        #expect(CVPixelBufferCreate(nil, 16, 16, kCVPixelFormatType_32BGRA, attrs, &buffer) == kCVReturnSuccess)
        let contents = CapturedTexture()
        contents.capture.publish(try #require(buffer))
        let cancelled = try #require(queue.makeCommandBuffer())
        let first = try #require(contents.prepare(device: device, cache: textureCache, command: cancelled))
        #expect(contents.seenGeneration == 0)
        let retry = try #require(queue.makeCommandBuffer())
        let upload = try #require(contents.prepare(device: device, cache: textureCache, command: retry))
        #expect(upload.generation == first.generation)
        contents.commit(upload)
        retry.addCompletedHandler { _ in _ = upload.retained }
        retry.commit()
        retry.waitUntilCompleted()
        #expect(retry.status == .completed)
        #expect(contents.seenGeneration == upload.generation)
        let following = try #require(queue.makeCommandBuffer())
        #expect(contents.prepare(device: device, cache: textureCache, command: following) == nil)
        contents.invalidate(upload)
        #expect(contents.prepare(device: device, cache: textureCache, command: following) != nil)
    }
}
