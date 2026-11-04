import CoreImage
import CoreML
import CoreVideo
import Foundation

/// One Core ML YOLO26n model (640 or 320 input), and the step that scales a
/// frame into its square input.
final class YOLOModel {
    struct Run {
        let rows: [Float]
        let prepMs: Double
        let inferMs: Double
    }

    let side: Int
    let name: String
    let loadMs: Double
    let specText: String
    private let model: MLModel
    private let inputName: String
    private let outputName: String
    private var pool: CVPixelBufferPool?

    static func resource(side: Int, precision: Precision) -> String {
        "YOLO26n-\(side)-\(precision.rawValue.lowercased())"
    }

    init(side: Int, precision: Precision, computeUnits: MLComputeUnits) throws {
        self.side = side
        name = "YOLO26n \(side)"
        let resource = YOLOModel.resource(side: side, precision: precision)
        guard let url = Bundle.main.url(forResource: resource, withExtension: "mlmodelc") else {
            throw CameraError("\(resource).mlmodelc is missing from the app bundle.")
        }
        let config = MLModelConfiguration()
        config.computeUnits = computeUnits
        let t0 = CFAbsoluteTimeGetCurrent()
        model = try MLModel(contentsOf: url, configuration: config)
        loadMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000

        let desc = model.modelDescription
        guard let input = desc.inputDescriptionsByName.values.first(where: { $0.type == .image }),
              let c = input.imageConstraint else {
            throw CameraError("\(name) has no image input.")
        }
        guard c.pixelsWide == side && c.pixelsHigh == side else {
            throw CameraError("\(name) wants a \(c.pixelsWide)×\(c.pixelsHigh) input, not \(side)×\(side).")
        }
        guard let output = desc.outputDescriptionsByName.values.first(where: { d in
            d.type == .multiArray && d.multiArrayConstraint?.shape.map(\.intValue) == [1, YOLO26.rows, YOLO26.rowLength]
        }) else {
            let outs = desc.outputDescriptionsByName.values.map { "\($0.name) \($0.multiArrayConstraint?.shape.map(\.intValue) ?? [])" }
            throw CameraError("\(name) has no [1, 300, 6] output. Outputs: \(outs.joined(separator: ", "))")
        }
        inputName = input.name
        outputName = output.name
        specText = "input \(input.name) \(side)×\(side) · output \(output.name) [1, 300, 6] \(YOLOModel.typeText(output.multiArrayConstraint?.dataType))"
    }

    /// Scales `frame` into the model input (top-left, black padding) and runs the model.
    func run(_ frame: CIImage, context: CIContext) throws -> Run {
        let t0 = CFAbsoluteTimeGetCurrent()
        let buffer = try makeInput(frame, context: context)
        let t1 = CFAbsoluteTimeGetCurrent()
        let features = try MLDictionaryFeatureProvider(dictionary: [inputName: MLFeatureValue(pixelBuffer: buffer)])
        let result = try model.prediction(from: features)
        let t2 = CFAbsoluteTimeGetCurrent()
        guard let array = result.featureValue(for: outputName)?.multiArrayValue else {
            throw CameraError("\(name) returned no \(outputName) array.")
        }
        return Run(rows: try YOLOModel.rows(array), prepMs: (t1 - t0) * 1000, inferMs: (t2 - t1) * 1000)
    }

    private func makeInput(_ frame: CIImage, context: CIContext) throws -> CVPixelBuffer {
        if pool == nil {
            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: side,
                kCVPixelBufferHeightKey as String: side,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]
            ]
            CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool)
        }
        var buffer: CVPixelBuffer?
        guard let pool = pool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let out = buffer else {
            throw CameraError("Could not get a \(side)×\(side) input buffer.")
        }
        let s = CGFloat(side)
        let k = s / max(frame.extent.width, frame.extent.height)
        let scaled = frame.transformed(by: CGAffineTransform(scaleX: k, y: k))
        // Core Image's origin is the bottom-left: lift the image so its top
        // edge meets the input's top, leaving the padding below and to the right.
        let placed = scaled.transformed(by: CGAffineTransform(translationX: -scaled.extent.minX, y: s - scaled.extent.maxY))
        let square = CGRect(x: 0, y: 0, width: s, height: s)
        let image = placed.composited(over: CIImage(color: CIColor.black).cropped(to: square))
        context.render(image, to: out, bounds: square, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return out
    }

    /// The [1, 300, 6] array as a flat list of 1800 values, row by row.
    static func rows(_ a: MLMultiArray) throws -> [Float] {
        let n = YOLO26.rows, m = YOLO26.rowLength
        let s1 = a.strides[1].intValue, s2 = a.strides[2].intValue
        var out = [Float](repeating: 0, count: n * m)
        switch a.dataType {
        case .float32:
            let p = a.dataPointer.assumingMemoryBound(to: Float32.self)
            for i in 0..<n { for j in 0..<m { out[i * m + j] = p[i * s1 + j * s2] } }
        case .double:
            let p = a.dataPointer.assumingMemoryBound(to: Double.self)
            for i in 0..<n { for j in 0..<m { out[i * m + j] = Float(p[i * s1 + j * s2]) } }
        default:
            throw CameraError("Unexpected output type \(typeText(a.dataType)).")
        }
        return out
    }

    static func typeText(_ t: MLMultiArrayDataType?) -> String {
        switch t {
        case .float32?: return "float32"
        case .double?: return "float64"
        case .int32?: return "int32"
        case nil: return "?"
        default: return "type \(t!.rawValue)"
        }
    }
}

extension MLComputeUnits {
    var text: String {
        switch self {
        case .all: return "all (GPU + CPU)"
        case .cpuAndGPU: return "GPU + CPU"
        case .cpuOnly: return "CPU only"
        default: return "units \(rawValue)"
        }
    }
}
