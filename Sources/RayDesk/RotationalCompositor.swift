import MetalKit
import RayDeskCore
import simd

final class RotationalCompositor {
    struct Target {
        let color: MTLTexture
        let multisample: MTLTexture
        let depth: MTLTexture
        let displaySize: SIMD2<Int>

        var overscan: SIMD2<Float> {
            SIMD2(Float(color.width) / Float(displaySize.x), Float(color.height) / Float(displaySize.y))
        }

        var pass: MTLRenderPassDescriptor {
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = multisample
            pass.colorAttachments[0].resolveTexture = color
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .multisampleResolve
            pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
            pass.depthAttachment.texture = depth
            pass.depthAttachment.loadAction = .clear
            pass.depthAttachment.storeAction = .dontCare
            pass.depthAttachment.clearDepth = 1
            return pass
        }
    }

    private struct Uniforms {
        var sceneFromDisplay: simd_float3x3
        var sceneFromDisplayBottom: simd_float3x3
        var displayTangents: SIMD2<Float>
        var sceneTangents: SIMD2<Float>
    }

    enum Failure: Error { case allocation, encoder }

    private let device: MTLDevice
    private let pixelFormat: MTLPixelFormat
    private let depthFormat: MTLPixelFormat
    private let sampleCount: Int
    private let pipeline: MTLRenderPipelineState
    private var target: Target?
    private static let overscanScale = 1.25

    init(device: MTLDevice, pixelFormat: MTLPixelFormat, depthFormat: MTLPixelFormat, sampleCount: Int) throws {
        self.device = device
        self.pixelFormat = pixelFormat
        self.depthFormat = depthFormat
        self.sampleCount = sampleCount
        let library = try device.makeLibrary(source: Self.shader, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "reprojectionVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "reprojectionFragment")
        descriptor.colorAttachments[0].pixelFormat = pixelFormat
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
    }

    func prepare(displaySize: SIMD2<Int>) throws -> Target {
        if let target, target.displaySize == displaySize { return target }
        let next = try makeTarget(displaySize: displaySize)
        target = next
        return next
    }

    func makeTarget(displaySize: SIMD2<Int>) throws -> Target {
        guard displaySize.x > 0, displaySize.y > 0 else { throw Failure.allocation }
        let width = Int(ceil(Double(displaySize.x) * Self.overscanScale))
        let height = Int(ceil(Double(displaySize.y) * Self.overscanScale))
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: pixelFormat, width: width, height: height, mipmapped: false)
        descriptor.storageMode = .private
        descriptor.usage = [.renderTarget, .shaderRead]
        guard let color = device.makeTexture(descriptor: descriptor) else { throw Failure.allocation }
        descriptor.textureType = .type2DMultisample
        descriptor.sampleCount = sampleCount
        descriptor.usage = [.renderTarget]
        guard let multisample = device.makeTexture(descriptor: descriptor) else { throw Failure.allocation }
        descriptor.pixelFormat = depthFormat
        guard let depth = device.makeTexture(descriptor: descriptor) else { throw Failure.allocation }
        let next = Target(color: color, multisample: multisample, depth: depth, displaySize: displaySize)
        return next
    }

    func encode(_ warp: RotationalReprojection, source: MTLTexture, destination: MTLTexture,
                commandBuffer: MTLCommandBuffer) throws {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = destination
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { throw Failure.encoder }
        var uniforms = Uniforms(sceneFromDisplay: warp.sceneFromDisplay,
                                sceneFromDisplayBottom: warp.sceneFromDisplayBottom,
                                displayTangents: warp.displayTangents, sceneTangents: warp.sceneTangents)
        encoder.label = "Rotational reprojection"
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setFragmentTexture(source, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }

    private static let shader = """
    #include <metal_stdlib>
    using namespace metal;

    struct ReprojectionVertex { float4 position [[position]]; float2 uv; };
    struct ReprojectionUniforms { float3x3 sceneFromDisplay; float3x3 sceneFromDisplayBottom; float2 displayTangents; float2 sceneTangents; };

    vertex ReprojectionVertex reprojectionVertex(uint vertexID [[vertex_id]]) {
        const float2 corners[3] = { float2(-1, -1), float2(3, -1), float2(-1, 3) };
        float2 point = corners[vertexID];
        return { float4(point, 0, 1), float2(point.x * 0.5 + 0.5, 0.5 - point.y * 0.5) };
    }

    fragment float4 reprojectionFragment(ReprojectionVertex in [[stage_in]],
                                         constant ReprojectionUniforms &u [[buffer(0)]],
                                         texture2d<float> scene [[texture(0)]]) {
        float3 inputRay = float3((2 * in.uv.x - 1) * u.displayTangents.x,
                                (1 - 2 * in.uv.y) * u.displayTangents.y, -1);
        float3 ray = mix(u.sceneFromDisplay * inputRay, u.sceneFromDisplayBottom * inputRay, clamp(in.uv.y, 0.0f, 1.0f));
        if (ray.z >= -0.000001) { return float4(0, 0, 0, 1); }
        float2 projected = ray.xy / -ray.z / u.sceneTangents;
        float2 uv = float2(projected.x * 0.5 + 0.5, 0.5 - projected.y * 0.5);
        if (any(uv < 0) || any(uv > 1)) { return float4(0, 0, 0, 1); }
        constexpr sampler linearSampler(coord::normalized, address::clamp_to_edge, filter::linear);
        return scene.sample(linearSampler, uv);
    }
    """
}
