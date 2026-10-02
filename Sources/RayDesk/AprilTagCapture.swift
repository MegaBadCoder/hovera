import AVFoundation
import AprilTagTracking
import simd
import Vision

/// Capture-queue only. UVC frames stay local; metadata intrinsics take precedence over FOV estimates.
final class AprilTagCapture {
    struct Frame {
        var observations: [TagObservation]
        var points: [CGPoint]
        var intrinsics: String
        var faceYaw: Double? = nil
        var facePitch: Double? = nil
        var faceConfidence: Float = 0
    }
    private let detector = AprilTagDetector()
    func detect(_ sample: CMSampleBuffer, size: Double, fieldOfView: Double) -> Frame {
        guard let detector, let pixels=CMSampleBufferGetImageBuffer(sample),
              CVPixelBufferGetPixelFormatType(pixels)==kCVPixelFormatType_32BGRA else {
            return Frame(observations:[],points:[],intrinsics:"детектор недоступен")
        }
        CVPixelBufferLockBaseAddress(pixels,.readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels,.readOnly) }
        let width=CVPixelBufferGetWidth(pixels),height=CVPixelBufferGetHeight(pixels)
        let step=1
        let w=width/step,h=height/step,stride=CVPixelBufferGetBytesPerRow(pixels)
        guard let base=CVPixelBufferGetBaseAddress(pixels)?.assumingMemoryBound(to:UInt8.self) else {
            return Frame(observations:[],points:[],intrinsics:"нет пикселей")
        }
        var gray=[UInt8](repeating:0,count:w*h)
        for y in 0..<h { for x in 0..<w {
            let p=(y*step)*stride+x*step*4
            gray[y*w+x]=UInt8((Int(base[p])*29+Int(base[p+1])*150+Int(base[p+2])*77)>>8)
        }}
        let f=Double(width)/2/tan(fieldOfView * .pi/360)/Double(step)
        var k=TagIntrinsics(fx:f,fy:f,cx:Double(width)/2/Double(step),cy:Double(height)/2/Double(step))
        var source="\(w)×\(h) · оценка FOV \(Int(fieldOfView))°, без калибровки объектива"
        if let data=CMGetAttachment(sample,key:kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix,attachmentModeOut:nil) as? Data,
           data.count>=MemoryLayout<matrix_float3x3>.size {
            let matrix=data.withUnsafeBytes { $0.loadUnaligned(as:matrix_float3x3.self) }
            let values=[matrix.columns.0.x,matrix.columns.1.y,matrix.columns.2.x,matrix.columns.2.y]
            if values.allSatisfy(\.isFinite),values[0]>0,values[1]>0 {
                k=TagIntrinsics(fx:Double(values[0])/Double(step),fy:Double(values[1])/Double(step),
                                cx:Double(values[2])/Double(step),cy:Double(values[3])/Double(step))
                source="\(w)×\(h) · параметры камеры из кадра"
            }
        }
        let tags=detector.detect(gray:gray,width:w,height:h,intrinsics:k,size:size)
        let points=tags.flatMap(\.corners).map { CGPoint(x:$0.x/Double(w),y:1-$0.y/Double(h)) }
        var frame = Frame(observations:tags,points:points,intrinsics:source)
        // Associate a face only with the front tag in this same frame.
        if let front = tags.first(where: { $0.id == 0 }), front.corners.count == 4 {
            let centre = front.corners.reduce(SIMD2<Double>.zero, +) / 4
            let point = CGPoint(x:centre.x/Double(w),y:1-centre.y/Double(h))
            let request = VNDetectFaceRectanglesRequest()
            let handler = VNImageRequestHandler(cvPixelBuffer:pixels,options:[:])
            try? handler.perform([request])
            let matches = (request.results ?? []).filter {
                $0.confidence >= 0.8 && $0.boundingBox.insetBy(dx:-$0.boundingBox.width*0.15,
                                                              dy:-$0.boundingBox.height*0.25).contains(point)
            }
            if matches.count == 1, let face = matches.first {
                frame.faceYaw = face.yaw?.doubleValue
                frame.facePitch = face.pitch?.doubleValue
                frame.faceConfidence = face.confidence
            }
        }
        return frame
    }
}
