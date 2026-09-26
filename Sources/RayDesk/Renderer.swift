import MetalKit
import CoreVideo
import simd

final class Renderer: NSObject, MTKViewDelegate {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let sampler: MTLSamplerState
    private let placeholder: MTLTexture
    private var textureCache: CVMetalTextureCache?
    private var screenTexture: MTLTexture?
    private var seenGeneration = 0
    private var lastTick = CACurrentMediaTime()

    private let capture: DisplayCapture
    private let filter: OrientationFilter
    private let placement: ScreenPlacement
    private let screenAspect: Float

    private(set) var currentHead = simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)

    private struct Uniforms {
        var mvp: simd_float4x4
        var border: SIMD4<Float>
    }

    init(view: MTKView, capture: DisplayCapture, filter: OrientationFilter, placement: ScreenPlacement, screenAspect: Double) throws {
        guard let device = view.device ?? MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw RendererError.noMetal
        }
        self.device = device
        self.queue = queue
        self.capture = capture
        self.filter = filter
        self.placement = placement
        self.screenAspect = Float(screenAspect)

        view.device = device
        view.colorPixelFormat = .bgra8Unorm_srgb
        view.sampleCount = 4
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.preferredFramesPerSecond = 120

        let library = try device.makeLibrary(source: Renderer.shaderSource, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "screenVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "screenFragment")
        descriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
        descriptor.rasterSampleCount = view.sampleCount
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)

        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.mipFilter = .linear
        samplerDescriptor.maxAnisotropy = 8
        samplerDescriptor.sAddressMode = .clampToEdge
        samplerDescriptor.tAddressMode = .clampToEdge
        sampler = device.makeSamplerState(descriptor: samplerDescriptor)!

        let placeholderDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb, width: 1, height: 1, mipmapped: false)
        placeholder = device.makeTexture(descriptor: placeholderDescriptor)!
        var gray: [UInt8] = [40, 40, 40, 255]
        placeholder.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &gray, bytesPerRow: 4)

        CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache)
        super.init()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        let now = CACurrentMediaTime()
        let dt = now - lastTick
        lastTick = now

        let head = filter.orientation(predictAhead: placement.predictionMs / 1000)
        currentHead = head
        placement.tick(head: head, dt: dt)

        guard let commandBuffer = queue.makeCommandBuffer() else { return }
        let retainedFrame = uploadLatestFrame(commandBuffer: commandBuffer)

        guard let pass = view.currentRenderPassDescriptor,
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass),
              let drawable = view.currentDrawable
        else { return }

        let size = view.drawableSize
        let projection = simd_float4x4.perspective(
            fovY: Float(placement.verticalFOV * .pi / 180),
            aspect: Float(size.width / max(size.height, 1)),
            near: 0.05, far: 100
        )
        let viewMatrix = simd_float4x4(simd_quatf(vector: SIMD4<Float>(head.inverse.vector)))
        let halfWidth = Float(placement.width / 2)
        let model = simd_float4x4(simd_quatf(vector: SIMD4<Float>(placement.rotation.vector)))
            * .translation(SIMD3(0, 0, -Float(placement.distance)))
            * .scale(SIMD3(halfWidth, halfWidth / screenAspect, 1))

        let texture = screenTexture ?? placeholder
        let borderAlpha: Float = placement.isGrabbing ? 1 : 0.35
        var uniforms = Uniforms(
            mvp: projection * viewMatrix * model,
            border: SIMD4(3 / Float(texture.width), 3 / Float(texture.height), borderAlpha, 0)
        )

        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.addCompletedHandler { _ in _ = retainedFrame }
        commandBuffer.commit()
    }

    private func uploadLatestFrame(commandBuffer: MTLCommandBuffer) -> CVMetalTexture? {
        guard let cache = textureCache, let pixelBuffer = capture.takeFrame(newerThan: &seenGeneration) else { return nil }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        var cvTexture: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(nil, cache, pixelBuffer, nil, .bgra8Unorm_srgb, width, height, 0, &cvTexture)
        guard let cvTexture, let source = CVMetalTextureGetTexture(cvTexture) else { return nil }

        if screenTexture?.width != width || screenTexture?.height != height {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb, width: width, height: height, mipmapped: true)
            descriptor.usage = [.shaderRead]
            descriptor.storageMode = .private
            screenTexture = device.makeTexture(descriptor: descriptor)
        }
        guard let target = screenTexture, let blit = commandBuffer.makeBlitCommandEncoder() else { return nil }
        blit.copy(from: source, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(),
                  sourceSize: MTLSize(width: width, height: height, depth: 1),
                  to: target, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin())
        blit.generateMipmaps(for: target)
        blit.endEncoding()
        return cvTexture
    }

    enum RendererError: Error { case noMetal }

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct Uniforms { float4x4 mvp; float4 border; };
    struct VertexOut { float4 position [[position]]; float2 uv; };

    vertex VertexOut screenVertex(uint vid [[vertex_id]], constant Uniforms &u [[buffer(0)]]) {
        const float2 corners[4] = { float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, 1) };
        float2 c = corners[vid];
        VertexOut out;
        out.position = u.mvp * float4(c, 0, 1);
        out.uv = float2(c.x * 0.5 + 0.5, 0.5 - c.y * 0.5);
        return out;
    }

    fragment float4 screenFragment(VertexOut in [[stage_in]],
                                   constant Uniforms &u [[buffer(0)]],
                                   texture2d<float> tex [[texture(0)]],
                                   sampler s [[sampler(0)]]) {
        float4 color = tex.sample(s, in.uv);
        float2 edge = min(in.uv, 1 - in.uv);
        if (edge.x < u.border.x || edge.y < u.border.y) {
            color.rgb = mix(color.rgb, float3(0.55, 0.75, 1.0), u.border.z);
        }
        return float4(color.rgb, 1);
    }
    """
}
