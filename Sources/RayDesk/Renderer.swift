import MetalKit
import CoreVideo
import simd
import RayDeskCore

final class Renderer: NSObject, MTKViewDelegate {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let gridPipeline: MTLRenderPipelineState
    private let skyPipeline: MTLRenderPipelineState
    private let skyDepthState: MTLDepthStencilState
    private let nebulaBakePipeline: MTLRenderPipelineState
    private var nebulaMap: MTLTexture?
    private let gridVertices: MTLBuffer
    private let gridVertexCount: Int
    private let depthState: MTLDepthStencilState
    private let sampler: MTLSamplerState
    private let placeholder: MTLTexture
    private var textureCache: CVMetalTextureCache?

    private let scene: SpatialScene
    private let filter: OrientationFilter

    var verticalFOV = 23.6
    var showsGrid = false
    let headPipeline: HeadPipeline
    var calibration: ViewCalibration {
        get { headPipeline.calibration }
        set { headPipeline.calibration = newValue }
    }
    var stabilizer: OrientationStabilizer {
        get { headPipeline.stabilizer }
        set { headPipeline.stabilizer = newValue }
    }
    private var lastFrameTime = CACurrentMediaTime()
    var macAnchor: MacAnchor?

    var slots: [ScreenSlot] = []
    var cursorScreen: Int?
    var draggingScreen: Int?
    var snappedNeighbor: Int?
    var onFrame: ((simd_quatd) -> Void)?

    private(set) var currentHead = simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)
    private(set) var meditation = MeditationTransition()
    var breathingEnabled = false
    private var breathingVisibility = 0.0
    private var meditationStart = CACurrentMediaTime()
    private let skyClockStart = CACurrentMediaTime()

    private struct Uniforms {
        var mvp: simd_float4x4
        var border: SIMD4<Float>
    }

    private struct SkyUniforms {
        var inverseViewProjection: simd_float4x4
        var params: SIMD4<Float>
    }

    init(view: MTKView, scene: SpatialScene, filter: OrientationFilter) throws {
        guard let device = view.device ?? MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw RendererError.noMetal
        }
        self.device = device
        self.queue = queue
        self.scene = scene
        self.filter = filter
        headPipeline = HeadPipeline(filter: filter)

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
        descriptor.colorAttachments[0].isBlendingEnabled = true
        descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)

        let skyDescriptor = MTLRenderPipelineDescriptor()
        skyDescriptor.vertexFunction = library.makeFunction(name: "skyVertex")
        skyDescriptor.fragmentFunction = library.makeFunction(name: "skyFragment")
        skyDescriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
        skyDescriptor.depthAttachmentPixelFormat = view.depthStencilPixelFormat
        skyDescriptor.rasterSampleCount = view.sampleCount
        skyPipeline = try device.makeRenderPipelineState(descriptor: skyDescriptor)

        let bakeDescriptor = MTLRenderPipelineDescriptor()
        bakeDescriptor.vertexFunction = library.makeFunction(name: "skyVertex")
        bakeDescriptor.fragmentFunction = library.makeFunction(name: "nebulaBakeFragment")
        bakeDescriptor.colorAttachments[0].pixelFormat = .rgba16Float
        nebulaBakePipeline = try device.makeRenderPipelineState(descriptor: bakeDescriptor)

        let gridDescriptor = MTLRenderPipelineDescriptor()
        gridDescriptor.vertexFunction = library.makeFunction(name: "gridVertex")
        gridDescriptor.fragmentFunction = library.makeFunction(name: "gridFragment")
        gridDescriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
        gridDescriptor.depthAttachmentPixelFormat = view.depthStencilPixelFormat
        gridDescriptor.rasterSampleCount = view.sampleCount
        gridPipeline = try device.makeRenderPipelineState(descriptor: gridDescriptor)

        let lines = Renderer.worldGridLines()
        gridVertexCount = lines.count
        gridVertices = device.makeBuffer(bytes: lines, length: MemoryLayout<SIMD4<Float>>.stride * lines.count)!

        let depthDescriptor = MTLDepthStencilDescriptor()
        depthDescriptor.depthCompareFunction = .less
        depthDescriptor.isDepthWriteEnabled = true
        depthState = device.makeDepthStencilState(descriptor: depthDescriptor)!
        let skyDepthDescriptor = MTLDepthStencilDescriptor()
        skyDepthDescriptor.depthCompareFunction = .always
        skyDepthDescriptor.isDepthWriteEnabled = false
        skyDepthState = device.makeDepthStencilState(descriptor: skyDepthDescriptor)!

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

    func toggleMeditation() {
        meditation.toggle()
        if meditation.isActive, meditation.progress == 0 {
            meditationStart = CACurrentMediaTime()
        }
        if meditation.isActive, nebulaMap == nil {
            nebulaMap = bakeNebula()
        }
    }

    private func bakeNebula() -> MTLTexture? {
        let size = Renderer.nebulaMapSize
        let descriptor = MTLTextureDescriptor.textureCubeDescriptor(pixelFormat: .rgba16Float, size: size, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        guard let map = device.makeTexture(descriptor: descriptor), let commandBuffer = queue.makeCommandBuffer() else { return nil }
        var faceSize = Float(size)
        for face in 0..<6 {
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = map
            pass.colorAttachments[0].slice = face
            pass.colorAttachments[0].loadAction = .dontCare
            pass.colorAttachments[0].storeAction = .store
            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return nil }
            var faceIndex = UInt32(face)
            encoder.setRenderPipelineState(nebulaBakePipeline)
            encoder.setFragmentBytes(&faceIndex, length: MemoryLayout<UInt32>.stride, index: 0)
            encoder.setFragmentBytes(&faceSize, length: MemoryLayout<Float>.stride, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
        }
        commandBuffer.commit()
        return map
    }

    private static let nebulaMapSize = 1024

    func draw(in view: MTKView) {
        dispatchPrecondition(condition: .onQueue(.main))
        let now = CACurrentMediaTime()
        let head = headPipeline.renderedOrientation(frameInterval: now - lastFrameTime)
        let frameSeconds = min(now - lastFrameTime, 0.1)
        meditation.advance(by: frameSeconds)
        let breathingTarget = breathingEnabled ? 1.0 : 0.0
        breathingVisibility += max(-frameSeconds, min(frameSeconds, breathingTarget - breathingVisibility))
        lastFrameTime = now
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

        let skyAmount = Float(meditation.eased)
        if skyAmount > 0, let nebulaMap {
            let breathing = Float(Breathing.openness(at: now - meditationStart))
            var sky = SkyUniforms(
                inverseViewProjection: (projection * viewMatrix).inverse,
                params: SIMD4(Float(now - skyClockStart), skyAmount, breathing, Float(breathingVisibility))
            )
            encoder.setRenderPipelineState(skyPipeline)
            encoder.setDepthStencilState(skyDepthState)
            encoder.setFragmentBytes(&sky, length: MemoryLayout<SkyUniforms>.stride, index: 0)
            encoder.setFragmentTexture(nebulaMap, index: 0)
            encoder.setFragmentSamplerState(sampler, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }

        encoder.setRenderPipelineState(pipeline)
        encoder.setDepthStencilState(depthState)
        encoder.setFragmentSamplerState(sampler, index: 0)

        let screenOpacity = 1 - skyAmount
        for (i, (slot, pose)) in zip(slots, scene.screens).enumerated() where screenOpacity > 0 {
            let model = pose.modelMatrix
            let texture = slot.texture ?? placeholder
            let borderAlpha: Float = (scene.grabbed == i || draggingScreen == i || snappedNeighbor == i) ? 1.0 : (cursorScreen == i ? 0.6 : 0.25)
            var uniforms = Uniforms(
                mvp: projection * viewMatrix * model,
                border: SIMD4(3 / Float(texture.width), 3 / Float(texture.height), borderAlpha, screenOpacity)
            )
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
            encoder.setFragmentTexture(texture, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        if showsGrid, skyAmount == 0 {
            var gridUniforms = Uniforms(mvp: projection * viewMatrix, border: SIMD4(0.15, 0.75, 0.3, 1))
            encoder.setRenderPipelineState(gridPipeline)
            encoder.setVertexBuffer(gridVertices, offset: 0, index: 1)
            encoder.setVertexBytes(&gridUniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
            encoder.setFragmentBytes(&gridUniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
            encoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: gridVertexCount)
            if let macAnchor {
                let model = macAnchor.pose.modelMatrix
                let corners = [SIMD4<Float>(-1, -1, 0, 1), SIMD4(1, -1, 0, 1), SIMD4(1, 1, 0, 1), SIMD4(-1, 1, 0, 1)].map { model * $0 }
                var outline = (0..<4).flatMap { [corners[$0], corners[($0 + 1) % 4]] }
                var anchorUniforms = Uniforms(mvp: projection * viewMatrix, border: SIMD4(0.9, 0.7, 0.2, 1))
                encoder.setVertexBytes(&outline, length: MemoryLayout<SIMD4<Float>>.stride * outline.count, index: 1)
                encoder.setVertexBytes(&anchorUniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
                encoder.setFragmentBytes(&anchorUniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
                encoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: outline.count)
            }
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

    private static func worldGridLines() -> [SIMD4<Float>] {
        let radius = 3.0
        func point(yawDegrees: Double, pitchDegrees: Double) -> SIMD4<Float> {
            let p = yawPitchQuat(yaw: yawDegrees * .pi / 180, pitch: pitchDegrees * .pi / 180).act(SIMD3(0, 0, -radius))
            return SIMD4(Float(p.x), Float(p.y), Float(p.z), 1)
        }
        var lines: [SIMD4<Float>] = []
        for pitch in [-30.0, -15.0, 0.0, 15.0, 30.0] {
            for yaw in stride(from: 0.0, to: 360.0, by: 2.0) {
                lines.append(point(yawDegrees: yaw, pitchDegrees: pitch))
                lines.append(point(yawDegrees: yaw + 2, pitchDegrees: pitch))
            }
        }
        for yaw in stride(from: 0.0, to: 360.0, by: 15.0) {
            let halfHeight = yaw == 0 ? 30.0 : 3.0
            lines.append(point(yawDegrees: yaw, pitchDegrees: -halfHeight))
            lines.append(point(yawDegrees: yaw, pitchDegrees: halfHeight))
        }
        return lines
    }

    enum RendererError: Error { case noMetal }

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct Uniforms { float4x4 mvp; float4 border; };
    struct VertexOut { float4 position [[position]]; float2 uv; };

    constant float sharpenAmount = 0.6;

    vertex VertexOut screenVertex(uint vid [[vertex_id]], constant Uniforms &u [[buffer(0)]]) {
        const float2 corners[4] = { float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, 1) };
        float2 c = corners[vid];
        VertexOut out;
        out.position = u.mvp * float4(c, 0, 1);
        out.uv = float2(c.x * 0.5 + 0.5, 0.5 - c.y * 0.5);
        return out;
    }

    vertex float4 gridVertex(uint vid [[vertex_id]], constant Uniforms &u [[buffer(0)]], const device float4 *points [[buffer(1)]]) {
        return u.mvp * points[vid];
    }

    fragment float4 gridFragment(constant Uniforms &u [[buffer(0)]]) {
        return float4(u.border.rgb, 1);
    }

    float3 sampleCatmullRom(texture2d<float> tex, sampler s, float2 uv, float lod) {
        float2 size = float2(tex.get_width(uint(lod)), tex.get_height(uint(lod)));
        float2 position = uv * size;
        float2 texel1 = floor(position - 0.5) + 0.5;
        float2 f = position - texel1;
        float2 w0 = f * (-0.5 + f * (1.0 - 0.5 * f));
        float2 w1 = 1.0 + f * f * (-2.5 + 1.5 * f);
        float2 w2 = f * (0.5 + f * (2.0 - 1.5 * f));
        float2 w3 = f * f * (-0.5 + 0.5 * f);
        float2 w12 = w1 + w2;
        float2 t0 = (texel1 - 1.0) / size;
        float2 t12 = (texel1 + w2 / w12) / size;
        float2 t3 = (texel1 + 2.0) / size;
        float3 result = 0;
        result += tex.sample(s, float2(t0.x, t0.y), level(lod)).rgb * w0.x * w0.y;
        result += tex.sample(s, float2(t12.x, t0.y), level(lod)).rgb * w12.x * w0.y;
        result += tex.sample(s, float2(t3.x, t0.y), level(lod)).rgb * w3.x * w0.y;
        result += tex.sample(s, float2(t0.x, t12.y), level(lod)).rgb * w0.x * w12.y;
        result += tex.sample(s, float2(t12.x, t12.y), level(lod)).rgb * w12.x * w12.y;
        result += tex.sample(s, float2(t3.x, t12.y), level(lod)).rgb * w3.x * w12.y;
        result += tex.sample(s, float2(t0.x, t3.y), level(lod)).rgb * w0.x * w3.y;
        result += tex.sample(s, float2(t12.x, t3.y), level(lod)).rgb * w12.x * w3.y;
        result += tex.sample(s, float2(t3.x, t3.y), level(lod)).rgb * w3.x * w3.y;
        return max(result, 0.0);
    }

    float3 sampleScreen(texture2d<float> tex, sampler s, float2 uv) {
        float2 texels = uv * float2(tex.get_width(), tex.get_height());
        float footprint = max(length(dfdx(texels)), length(dfdy(texels)));
        float lod = clamp(floor(log2(max(footprint, 1.0))), 0.0, float(tex.get_num_mip_levels() - 1));
        float3 center = sampleCatmullRom(tex, s, uv, lod);
        float2 across = dfdx(uv);
        float2 down = dfdy(uv);
        float3 left = tex.sample(s, uv - across, level(lod)).rgb;
        float3 right = tex.sample(s, uv + across, level(lod)).rgb;
        float3 up = tex.sample(s, uv - down, level(lod)).rgb;
        float3 below = tex.sample(s, uv + down, level(lod)).rgb;
        float3 lowest = min(center, min(min(left, right), min(up, below)));
        float3 highest = max(center, max(max(left, right), max(up, below)));
        float3 blurred = (left + right + up + below) * 0.25;
        return clamp(center + sharpenAmount * (center - blurred), lowest, highest);
    }

    fragment float4 screenFragment(VertexOut in [[stage_in]],
                                   constant Uniforms &u [[buffer(0)]],
                                   texture2d<float> tex [[texture(0)]],
                                   sampler s [[sampler(0)]]) {
        float3 color = sampleScreen(tex, s, in.uv);
        float2 edge = min(in.uv, 1 - in.uv);
        if (edge.x < u.border.x || edge.y < u.border.y) {
            color = mix(color, float3(0.55, 0.75, 1.0), u.border.z);
        }
        return float4(color, u.border.w);
    }
    """ + skyShaderSource
}
