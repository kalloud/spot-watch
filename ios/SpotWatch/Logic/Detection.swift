import Foundation

// Pure detection types and YOLO26n output parsing. Foundation only: no
// AVFoundation, UIKit, SwiftUI or Core ML, so it runs in unit tests.

/// A box in pixels. x, y is the top-left corner, like the web app's bbox.
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

    func with(box: Box) -> Detection { Detection(classIndex: classIndex, score: score, box: box) }
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

enum YOLO26 {
    static let rows = 300
    static let rowLength = 6
    static let maxBoxes = 20        // per run, as the web app's MAX_BOXES

    /// Turns the model's [1, 300, 6] output into detections in input pixels,
    /// clipped to the side×side input. Each row is x1, y1, x2, y2, score,
    /// class. The head is end-to-end, best first, with no NMS step, but it can
    /// still return one object twice: `Geometry.dedupe` handles that.
    static func detections(rows values: [Float], side: Double, minScore: Double,
                           maxBoxes: Int = maxBoxes) -> [Detection] {
        var out: [Detection] = []
        var i = 0
        while i + rowLength <= values.count && out.count < maxBoxes {
            let score = Double(values[i + 4])
            if score >= minScore {
                let x1 = max(0, Double(values[i])), y1 = max(0, Double(values[i + 1]))
                let x2 = min(side, Double(values[i + 2])), y2 = min(side, Double(values[i + 3]))
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
