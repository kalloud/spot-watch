import AVFoundation
import SwiftUI
import UIKit

/// Landscape screen: the camera with boxes and the key numbers on the left,
/// a scrolling panel with controls, status, log and About on the right.
struct ContentView: View {
    @ObservedObject var model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        GeometryReader { geo in
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    CameraArea(model: model)
                        .aspectRatio(model.frameAspect, contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: geo.size.height * 0.74)
                    HUD(model: model)
                }
                .frame(width: geo.size.width * 0.58)
                ScrollView {
                    Panel(model: model)
                }
            }
            .padding(.horizontal, 4)
        }
        .font(.system(size: 12))
        .foregroundColor(.white)
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .statusBar(hidden: true)
        .onAppear { model.start() }
        .onChange(of: scenePhase) { model.scenePhaseChanged($0) }
    }
}

// MARK: - Camera and boxes

private struct CameraArea: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ZStack {
            Color(white: 0.08)
            if model.source == .camera {
                CameraPreview(session: model.session, running: model.cameraRunning) { o in
                    DispatchQueue.main.async { model.orientationChanged(o) }
                }
            } else if let img = model.testImage {
                Image(uiImage: img).resizable().aspectRatio(contentMode: .fit)
            }
            BoxesOverlay(detections: model.detections, frame: model.frameSize)
        }
    }
}

private struct BoxesOverlay: View {
    let detections: [Detection]
    let frame: CGSize

    static let vehicle = Color(red: 1, green: 0.62, blue: 0.11)
    static let person = Color(red: 0.18, green: 0.77, blue: 0.95)
    static let other = Color(red: 0.6, green: 0.64, blue: 0.7)

    var body: some View {
        Canvas { ctx, size in
            guard frame.width > 0, frame.height > 0 else { return }
            let s = min(size.width / frame.width, size.height / frame.height)
            let ox = (size.width - frame.width * s) / 2, oy = (size.height - frame.height * s) / 2
            for d in detections {
                let r = CGRect(x: ox + d.box.x * s, y: oy + d.box.y * s, width: d.box.w * s, height: d.box.h * s)
                let color = d.isVehicle ? BoxesOverlay.vehicle : d.isPerson ? BoxesOverlay.person : BoxesOverlay.other
                ctx.stroke(Path(r), with: .color(color), lineWidth: 1.5)
                let label = Text("\(d.className) \(Int((d.score * 100).rounded()))%")
                    .font(.system(size: 9, weight: .semibold)).foregroundColor(color)
                let above = r.minY > 11
                ctx.draw(label, at: CGPoint(x: r.minX + 1, y: above ? r.minY - 1 : r.minY + 1),
                         anchor: above ? .bottomLeading : .topLeading)
            }
        }
        .allowsHitTesting(false)
    }
}

/// The preview layer shows the same full frame the detector gets, so boxes in
/// frame pixels map onto it by aspect fit. Its orientation follows the
/// interface, and so do the frames.
private struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    let running: Bool
    let onOrientation: (AVCaptureVideoOrientation) -> Void

    func makeUIView(context: Context) -> PreviewView {
        let v = PreviewView()
        v.backgroundColor = .black
        v.previewLayer.session = session
        v.previewLayer.videoGravity = .resizeAspect
        v.onOrientation = onOrientation
        return v
    }

    func updateUIView(_ v: PreviewView, context: Context) {
        v.applyOrientation()        // the layer's connection only exists once the session has its input
    }
}

private final class PreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    var onOrientation: ((AVCaptureVideoOrientation) -> Void)?

    override func layoutSubviews() {
        super.layoutSubviews()
        applyOrientation()
    }

    func applyOrientation() {
        guard let io = window?.windowScene?.interfaceOrientation, let o = AVCaptureVideoOrientation(io) else { return }
        if let c = previewLayer.connection, c.isVideoOrientationSupported, c.videoOrientation != o {
            c.videoOrientation = o
        }
        onOrientation?(o)
    }
}

// MARK: - Key numbers under the camera

private struct HUD: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(model.hudLine(640))
            Text(model.hudLine(320))
            Text("CPU \(model.cpuText)")
            Text("Thermal \(model.thermal) · battery \(model.battery)")
            Text("Memory \(model.memoryText)")
        }
        .font(.system(size: 11, design: .monospaced))
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }
}

// MARK: - Panel

private struct Panel: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Spot Watch").font(.system(size: 15, weight: .bold))
                Spacer()
                Text(buildLabel).foregroundColor(.gray)
            }
            if !model.errors.isEmpty { ErrorBox(model: model) }
            Controls(model: model)
            PanelSection(title: "Status") {
                ForEach(model.rows) { r in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Circle().fill(Panel.color(r.state)).frame(width: 8, height: 8)
                        Text(r.label).bold().frame(width: 92, alignment: .leading)
                        Text(r.detail).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            PanelSection(title: "Checks") {
                ForEach(Array(model.statRows().enumerated()), id: \.offset) { _, kv in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(kv.0).foregroundColor(.gray).frame(width: 96, alignment: .leading)
                        Text(kv.1).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            PanelSection(title: "Detections" + (model.lastSide.map { " · YOLO26n \($0)" } ?? "")) {
                if model.detections.isEmpty {
                    Text("Nothing above \(Int(YOLO26.minScore * 100))%").foregroundColor(.gray)
                }
                ForEach(Array(model.detections.enumerated()), id: \.offset) { _, d in
                    Text("\(d.className) \(Int((d.score * 100).rounded()))% · \(Int(d.box.x)), \(Int(d.box.y)), \(Int(d.box.w))×\(Int(d.box.h))")
                }
            }
            PanelSection(title: "Log") {
                Text(model.log.reversed().map(\.line).joined(separator: "\n"))
                    .font(.system(size: 10, design: .monospaced))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            PanelSection(title: "About") {
                Text("Detector: Ultralytics YOLO26n, converted to Core ML from the official yolo26n.pt (GitHub release v8.4.0) at 640 and 320. "
                     + "YOLO26n and the bus.jpg test image are © Ultralytics, under the AGPL-3.0 license "
                     + "(github.com/ultralytics/ultralytics). Frames stay on this phone.")
                    .foregroundColor(.gray)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 6)
    }

    static func color(_ s: AppModel.RowState) -> Color {
        switch s {
        case .idle: return .gray
        case .busy: return .yellow
        case .ok: return .green
        case .warn: return .orange
        case .fail: return .red
        }
    }
}

private struct Controls: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Row(label: "Models") { picker($model.mode) }
            Row(label: "Pace") { picker($model.pace) }
            Row(label: "Source") { picker($model.source) }
            Row(label: "Compute") { picker($model.compute) }
            Row(label: "Precision") { picker($model.precision) }
            HStack {
                Button(model.paused ? "Resume" : "Pause") { model.paused.toggle() }
                    .buttonStyle(.bordered)
                Button("Copy report") { model.copyReport() }
                    .buttonStyle(.borderedProminent)
            }
            if !model.copyResult.isEmpty {
                Text(model.copyResult).foregroundColor(.gray)
            }
        }
    }

    private func picker<T: CaseIterable & Identifiable & Hashable & RawRepresentable>(_ value: Binding<T>) -> some View
        where T.AllCases: RandomAccessCollection, T.RawValue == String {
        Picker("", selection: value) {
            ForEach(T.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
    }
}

private struct Row<Content: View>: View {
    let label: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(spacing: 6) {
            Text(label).foregroundColor(.gray).frame(width: 60, alignment: .leading)
            content()
        }
    }
}

private struct PanelSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title.uppercased()).font(.system(size: 10, weight: .semibold)).foregroundColor(.gray)
            content()
        }
    }
}

private struct ErrorBox: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text("Errors (\(model.errors.count))").bold()
                Spacer()
                Button("Clear") { model.clearErrors() }
            }
            ForEach(model.errors.suffix(8)) { e in
                Text("\(e.time)  \(e.msg)").fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(6)
        .background(Color(red: 0.35, green: 0.06, blue: 0.06))
        .cornerRadius(6)
    }
}
