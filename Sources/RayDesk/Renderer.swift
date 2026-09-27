import MetalKit
import CoreVideo
import simd
import RayDeskCore

final class Renderer: NSObject, MTKViewDelegate {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let depthState: MTLDepthStencilState
    private let sampler: MTLSamplerState
    private let placeholder: MTLTexture
    private var textureCache: CVMetalTextureCache?

    private let scene: SpatialScene
    private let filter: OrientationFilter

    let verticalFOV = 23.6
    let predictionMs = 18.0

    var slots: [ScreenSlot] = []
    var cursorScreen: Int?
    var draggingScreen: Int?
    var onFrame: ((simd_quatd) -> Void)?

    private(set) var currentHead = simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)

    private struct Uniforms {
        var mvp: simd_float4x4
        var border: SIMD4<Float>
    }

    init(view: MTKView, scene: SpatialScene, filter: OrientationFilter) throws {
        guard let device = view.device ?? MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw RendererError.noMetal
        }
        self.device = device
        self.queue = queue
        self.scene = scene
        self.filter = filter

        view.device = device
        view.colorPixelFormat = .bgra8Unorm_srgb
        view.depthStencilPixelFormat = .depth32Float
        view.sampleCount = 4
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.preferredFramesPerSecond = 120

        let library = try device.makeLibrary(source: Renderer.shaderSource, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "screenVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "screenFragment")
        descriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
        descriptor.depthAttachmentPixelFormat = view.depthStencilPixelFormat
        descriptor.rasterSampleCount = view.sampleCount
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)

        let depthDescriptor = MTLDepthStencilDescriptor()
        depthDescriptor.depthCompareFunction = .less
        depthDescriptor.isDepthWriteEnabled = true
        depthState = device.makeDepthStencilState(descriptor: depthDescriptor)!

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
        let head = filter.orientation(predictAhead: predictionMs / 1000)
        currentHead = head
        scene.tick(head: head)
        onFrame?(head)

        guard let commandBuffer = queue.makeCommandBuffer() else { return }
        var retainedFrames: [CVMetalTexture] = []
        for slot in slots {
            if let retained = uploadLatestFrame(slot: slot, commandBuffer: commandBuffer) {
                retainedFrames.append(retained)
            }
        }

        guard let pass = view.currentRenderPassDescriptor,
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass),
              let drawable = view.currentDrawable
        else { return }

        let size = view.drawableSize
        let projection = simd_float4x4.perspective(
            fovY: Float(verticalFOV * .pi / 180),
            aspect: Float(size.width / max(size.height, 1)),
            near: 0.05, far: 100
        )
        let viewMatrix = simd_float4x4(simd_quatf(vector: SIMD4<Float>(head.inverse.vector)))

        encoder.setRenderPipelineState(pipeline)
        encoder.setDepthStencilState(depthState)
        encoder.setFragmentSamplerState(sampler, index: 0)

        for (i, (slot, pose)) in zip(slots, scene.screens).enumerated() {
            let model = pose.modelMatrix
            let texture = slot.texture ?? placeholder
            let borderAlpha: Float = (scene.grabbed == i || draggingScreen == i) ? 1.0 : (cursorScreen == i ? 0.6 : 0.25)
            var uniforms = Uniforms(
                mvp: projection * viewMatrix * model,
                border: SIMD4(3 / Float(texture.width), 3 / Float(texture.height), borderAlpha, 0)
            )
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
            encoder.setFragmentTexture(texture, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        encoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.addCompletedHandler { _ in _ = retainedFrames }
        commandBuffer.commit()
    }

    private func uploadLatestFrame(slot: ScreenSlot, commandBuffer: MTLCommandBuffer) -> CVMetalTexture? {
        guard let cache = textureCache, let pixelBuffer = slot.capture.takeFrame(newerThan: &slot.seenGeneration) else { return nil }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        var cvTexture: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(nil, cache, pixelBuffer, nil, .bgra8Unorm_srgb, width, height, 0, &cvTexture)
        guard let cvTexture, let source = CVMetalTextureGetTexture(cvTexture) else { return nil }

        if slot.texture?.width != width || slot.texture?.height != height {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb, width: width, height: height, mipmapped: true)
            descriptor.usage = [.shaderRead]
            descriptor.storageMode = .private
            slot.texture = device.makeTexture(descriptor: descriptor)
        }
        guard let target = slot.texture, let blit = commandBuffer.makeBlitCommandEncoder() else { return nil }
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
