import Foundation

// Pure detection types and YOLO26n output parsing. Foundation only: no
// AVFoundation, UIKit, SwiftUI or Core ML, so it runs in unit tests.

/// A box in frame pixels. x, y is the top-left corner, like the web app's bbox.
struct Box: Equatable {
    var x: Double
    var y: Double
    var w: Double
    var h: Double

    var area: Double { max(0, w) * max(0, h) }
}

struct Detection: Equatable {
    let classIndex: Int
    let score: Double
    let box: Box

    var className: String { COCO.name(classIndex) }
    var isVehicle: Bool { COCO.vehicles.contains(className) }
    var isPerson: Bool { className == "person" }
}

enum COCO {
    static let classes: [String] = ("person,bicycle,car,motorcycle,airplane,bus,train,truck,boat,traffic light," +
        "fire hydrant,stop sign,parking meter,bench,bird,cat,dog,horse,sheep,cow,elephant,bear,zebra," +
        "giraffe,backpack,umbrella,handbag,tie,suitcase,frisbee,skis,snowboard,sports ball,kite," +
        "baseball bat,baseball glove,skateboard,surfboard,tennis racket,bottle,wine glass,cup,fork," +
        "knife,spoon,bowl,banana,apple,sandwich,orange,broccoli,carrot,hot dog,pizza,donut,cake,chair," +
        "couch,potted plant,bed,dining table,toilet,tv,laptop,mouse,remote,keyboard,cell phone," +
        "microwave,oven,toaster,sink,refrigerator,book,clock,vase,scissors,teddy bear,hair drier," +
        "toothbrush").components(separatedBy: ",")
    static let vehicles: Set<String> = ["car", "truck", "bus", "motorcycle"]

    static func name(_ index: Int) -> String {
        classes.indices.contains(index) ? classes[index] : "class \(index)"
    }
}

/// How a frame sits in the square model input: scaled to fit, anchored at
/// the top-left, with black padding on the right or bottom (as in the web app).
struct Letterbox: Equatable {
    let frameWidth: Double
    let frameHeight: Double
    let side: Double

    /// Input pixels per frame pixel.
    var scale: Double { side / max(frameWidth, frameHeight) }
}

enum YOLO26 {
    static let rows = 300
    static let rowLength = 6
    static let minScore = 0.2       // PLAN.md: lowest confidence that counts for cars
    static let maxBoxes = 20        // as the web app's MAX_BOXES

    /// Turns the model's [1, 300, 6] output into detections in frame pixels.
    /// Each row is x1, y1, x2, y2 (input pixels), score, class. The head is
    /// end-to-end: rows are already de-duplicated and best first, so there is
    /// no NMS step. Boxes are clipped to the frame.
    static func detections(rows values: [Float], letterbox: Letterbox,
                           minScore: Double = minScore, maxBoxes: Int = maxBoxes) -> [Detection] {
        let k = 1 / letterbox.scale     // frame pixels per input pixel
        var out: [Detection] = []
        var i = 0
        while i + rowLength <= values.count && out.count < maxBoxes {
            let score = Double(values[i + 4])
            if score >= minScore {
                let x1 = max(0, Double(values[i]) * k), y1 = max(0, Double(values[i + 1]) * k)
                let x2 = min(letterbox.frameWidth, Double(values[i + 2]) * k)
                let y2 = min(letterbox.frameHeight, Double(values[i + 3]) * k)
                if x2 > x1 && y2 > y1 {
                    out.append(Detection(classIndex: Int(values[i + 5].rounded()), score: score,
                                         box: Box(x: x1, y: y1, w: x2 - x1, h: y2 - y1)))
                }
            }
            i += rowLength
        }
        return out
    }

    /// "2 car, 1 person", or "Nothing detected".
    static func summarize(_ dets: [Detection]) -> String {
        if dets.isEmpty { return "Nothing detected" }
        var counts: [String: Int] = [:]
        for d in dets { counts[d.className, default: 0] += 1 }
        return counts.keys.sorted().map { "\(counts[$0]!) \($0)" }.joined(separator: ", ")
    }
}
