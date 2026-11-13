import CoreGraphics
import CoreText
import MetalKit
import RayDeskCore
import RayDeskLocalization

extension RestStabilizationStrength {
    var titleKey: UIString {
        switch self {
        case .light: .menuRestLight
        case .medium: .menuRestMedium
        case .strong: .menuRestStrong
        }
    }
}

extension RestStabilizationPhase {
    var titleKey: UIString {
        switch self {
        case .disabled: .restPhaseDisabled
        case .unavailable: .restPhaseUnavailable
        case .waiting: .restPhaseWaiting
        case .moving: .restPhaseMoving
        case .resting: .restPhaseResting
        }
    }

    var indicatorColor: CGColor {
        switch self {
        case .resting: CGColor(red: 0.25, green: 1, blue: 0.55, alpha: 1)
        case .moving: CGColor(red: 1, green: 0.65, blue: 0.2, alpha: 1)
        case .waiting: CGColor(red: 0.55, green: 0.8, blue: 1, alpha: 1)
        case .unavailable, .disabled: CGColor(gray: 0.75, alpha: 1)
        }
    }
}

final class RestStatusIndicator {
    private struct Key: Hashable {
        let language: String
        let phase: String
        let detail: String
    }

    private enum Failure: Error { case allocation, encoder }
    private let pipeline: MTLRenderPipelineState
    private let textures: [Key: MTLTexture]
    private static let width = 512
    private static let height = 112

    init(device: MTLDevice, pixelFormat: MTLPixelFormat) throws {
        let library = try device.makeLibrary(source: Self.shader, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "restIndicatorVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "restIndicatorFragment")
        descriptor.colorAttachments[0].pixelFormat = pixelFormat
        descriptor.colorAttachments[0].isBlendingEnabled = true
        descriptor.colorAttachments[0].sourceRGBBlendFactor = .one
        descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        var textures: [Key: MTLTexture] = [:]
        for language in AppLanguage.allCases {
            for phase in RestStabilizationPhase.allCases {
                for strength in RestStabilizationStrength.allCases {
                    let key = Key(language: language.rawValue, phase: phase.rawValue, detail: strength.rawValue)
                    let caption = String(format: UIString.restStrengthCaption.text(language), strength.titleKey.text(language))
                    textures[key] = try Self.texture(device: device, language: language, phase: phase, caption: caption)
                }
                for enabled in [false, true] {
                    let key = Key(language: language.rawValue, phase: phase.rawValue, detail: enabled ? "sync-on" : "sync-off")
                    let caption = (enabled ? UIString.restAdaptiveSyncOn : .restAdaptiveSyncOff).text(language)
                    textures[key] = try Self.texture(device: device, language: language, phase: phase, caption: caption)
                }
            }
        }
        self.textures = textures
    }

    static func matrix(head: simd_quatd, position: SIMD3<Double>, anchorYaw: Double,
                       verticalFOV: Float, size: SIMD2<Int>) -> simd_float4x4 {
        let pose = ScreenPose(yaw: anchorYaw, pitch: -9.5 * .pi / 180, distance: 3,
                              width: 0.58, aspect: Double(width) / Double(height))
        let projection = simd_float4x4.perspective(fovY: verticalFOV, aspect: Float(size.x) / Float(size.y), near: 0.05, far: 100)
        let view = simd_float4x4(simd_quatf(vector: SIMD4<Float>(head.inverse.vector)))
            * .translation(-SIMD3<Float>(position))
        return projection * view * pose.modelMatrix
    }

    func encode(phase: RestStabilizationPhase, strength: RestStabilizationStrength, adaptiveSync: Bool? = nil,
                head: simd_quatd, position: SIMD3<Double>, anchorYaw: Double, verticalFOV: Float,
                destination: MTLTexture, commandBuffer: MTLCommandBuffer) throws {
        let detail = adaptiveSync.map { $0 ? "sync-on" : "sync-off" } ?? strength.rawValue
        let key = Key(language: Localization.shared.language.rawValue, phase: phase.rawValue, detail: detail)
        guard let texture = textures[key] else { throw Failure.allocation }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = destination
        pass.colorAttachments[0].loadAction = .load
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { throw Failure.encoder }
        var matrix = Self.matrix(head: head, position: position, anchorYaw: anchorYaw,
                                 verticalFOV: verticalFOV, size: SIMD2(destination.width, destination.height))
        encoder.label = "Stillness status on sphere"
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBytes(&matrix, length: MemoryLayout<simd_float4x4>.stride, index: 0)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
    }

    private static func texture(device: MTLDevice, language: AppLanguage, phase: RestStabilizationPhase,
                                caption: String) throws -> MTLTexture {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        try pixels.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw Failure.allocation }
            context.setFillColor(CGColor(gray: 0, alpha: 0.85))
            context.addPath(CGPath(roundedRect: CGRect(x: 3, y: 3, width: width - 6, height: height - 6),
                                   cornerWidth: 14, cornerHeight: 14, transform: nil))
            context.fillPath()
            draw(phase.titleKey.text(language), size: 30, baseline: 65, color: phase.indicatorColor, context: context)
            draw(caption, size: 20, baseline: 27, color: CGColor(gray: 0.85, alpha: 1), context: context)
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm_srgb, width: width, height: height, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead]
        guard let texture = device.makeTexture(descriptor: descriptor) else { throw Failure.allocation }
        pixels.withUnsafeBytes { bytes in
            texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                            withBytes: bytes.baseAddress!, bytesPerRow: width * 4)
        }
        return texture
    }

    private static func draw(_ text: String, size: CGFloat, baseline: CGFloat, color: CGColor, context: CGContext) {
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        context.textPosition = CGPoint(x: (Double(width) - CTLineGetTypographicBounds(line, nil, nil, nil)) * 0.5, y: baseline)
        CTLineDraw(line, context)
    }

    private static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    struct RestIndicatorVertex { float4 position [[position]]; float2 uv; };
    vertex RestIndicatorVertex restIndicatorVertex(uint id [[vertex_id]], constant float4x4 &mvp [[buffer(0)]]) {
        const float2 corners[4] = { float2(-1,-1), float2(1,-1), float2(-1,1), float2(1,1) };
        float2 p = corners[id];
        return { mvp * float4(p,0,1), float2(p.x * 0.5 + 0.5, 0.5 - p.y * 0.5) };
    }
    fragment float4 restIndicatorFragment(RestIndicatorVertex in [[stage_in]], texture2d<float> label [[texture(0)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        return label.sample(s, in.uv);
    }
    """
}
