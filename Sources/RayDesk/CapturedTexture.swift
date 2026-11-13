import MetalKit
import CoreVideo

final class CapturedTexture {
    struct Upload {
        let retained: CVMetalTexture
        let texture: MTLTexture
        let generation: Int
    }

    let capture = DisplayCapture()
    private(set) var seenGeneration = 0
    private(set) var texture: MTLTexture?

    func prepare(device: MTLDevice, cache: CVMetalTextureCache, command: MTLCommandBuffer) -> Upload? {
        var generation = seenGeneration
        guard let pixelBuffer = capture.takeFrame(newerThan: &generation) else { return nil }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        var cvTexture: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(nil, cache, pixelBuffer, nil, .bgra8Unorm_srgb,
                                                       width, height, 0, &cvTexture) == kCVReturnSuccess,
              let cvTexture, let source = CVMetalTextureGetTexture(cvTexture) else { return nil }
        let target: MTLTexture
        if let texture, texture.width == width, texture.height == height {
            target = texture
        } else {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb,
                                                                      width: width, height: height, mipmapped: true)
            descriptor.usage = [.shaderRead]
            descriptor.storageMode = .private
            guard let created = device.makeTexture(descriptor: descriptor) else { return nil }
            target = created
        }
        guard let blit = command.makeBlitCommandEncoder() else { return nil }
        blit.copy(from: source, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(),
                  sourceSize: MTLSize(width: width, height: height, depth: 1),
                  to: target, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin())
        blit.generateMipmaps(for: target)
        blit.endEncoding()
        return Upload(retained: cvTexture, texture: target, generation: generation)
    }

    func commit(_ upload: Upload) {
        texture = upload.texture
        seenGeneration = upload.generation
    }

    func invalidate(_ upload: Upload) {
        if seenGeneration == upload.generation { seenGeneration = 0 }
    }
}
