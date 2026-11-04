import AVFoundation
import SwiftUI
import UIKit

/// Landscape screen: the camera with spots and boxes and the key numbers on
/// the left, a scrolling panel on the right. While a spot is being drawn the
/// camera takes the whole screen.
struct ContentView: View {
    @ObservedObject var model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        GeometryReader { geo in
            let drawing = model.drawingSpot != nil
            // While drawing, the camera takes the full height and the hint
            // sits beside it, so nothing covers the picture.
            let cameraWidth = drawing ? min(geo.size.width - 140, geo.size.height * model.frameAspect) : geo.size.width * 0.58
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    CameraArea(model: model)
                        .aspectRatio(model.frameAspect, contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: geo.size.height * (drawing ? 1 : 0.74))
                    if !drawing { HUD(model: model) }
                }
                .frame(width: cameraWidth)
                if drawing {
                    DrawPanel(model: model)
                } else {
                    ScrollView {
                        Panel(model: model)
                    }
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
        .sheet(isPresented: $model.showSettings) { SettingsView(model: model) }
    }
}

// MARK: - Camera, spots and boxes

private struct CameraArea: View {
    @ObservedObject var model: AppModel
    @State private var dragStart: CGPoint?          // fractions of the frame
    @State private var dragNow: CGPoint?

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .top) {
                Color(white: 0.08)
                if model.source == .camera {
                    CameraPreview(session: model.session, running: model.cameraRunning) { o in
                        DispatchQueue.main.async { model.orientationChanged(o) }
                    }
                } else if let img = model.testImage {
                    Image(uiImage: img).resizable().aspectRatio(contentMode: .fit)
                }
                Overlay(model: model, drag: dragRect)
            }
            .contentShape(Rectangle())
            .gesture(model.drawingSpot == nil ? nil : drawGesture(geo.size))
        }
    }

    private var dragRect: FracRect? {
        guard let a = dragStart, let b = dragNow else { return nil }
        return FracRect(x: Double(min(a.x, b.x)), y: Double(min(a.y, b.y)), w: Double(abs(b.x - a.x)), h: Double(abs(b.y - a.y)))
    }

    private func drawGesture(_ size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                if dragStart == nil { dragStart = fraction(v.startLocation, size) }
                dragNow = fraction(v.location, size)
            }
            .onEnded { v in
                dragNow = fraction(v.location, size)
                if let r = dragRect { model.finishDrawing(r) }
                dragStart = nil
                dragNow = nil
            }
    }

    /// A point in the view as fractions of the frame shown in it (aspect fit), clamped to it.
    private func fraction(_ p: CGPoint, _ size: CGSize) -> CGPoint {
        let fit = Fit(frame: model.frameSize, in: size)
        return CGPoint(x: min(1, max(0, (p.x - fit.ox) / (model.frameSize.width * fit.s))),
                       y: min(1, max(0, (p.y - fit.oy) / (model.frameSize.height * fit.s))))
    }
}

/// Where an aspect-fit frame sits in a view: scale and offset.
private struct Fit {
    let s: CGFloat, ox: CGFloat, oy: CGFloat

    init(frame: CGSize, in size: CGSize) {
        s = frame.width > 0 && frame.height > 0 ? min(size.width / frame.width, size.height / frame.height) : 1
        ox = (size.width - frame.width * s) / 2
        oy = (size.height - frame.height * s) / 2
    }
}

private struct DrawPanel: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.drawHint).bold().fixedSize(horizontal: false, vertical: true)
            Text("Drag from one corner of the spot to the other. Lift to save.")
                .foregroundColor(.gray).fixedSize(horizontal: false, vertical: true)
            Button("Cancel") { model.cancelDrawing() }.buttonStyle(.bordered)
            Spacer()
        }
        .padding(.top, 8)
    }
}

private struct Overlay: View {
    @ObservedObject var model: AppModel
    let drag: FracRect?

    static let vehicle = Color(red: 1, green: 0.62, blue: 0.11)
    static let person = Color(red: 0.18, green: 0.77, blue: 0.95)
    static let other = Color(red: 0.6, green: 0.64, blue: 0.7)
    static let view = Color(red: 0.35, green: 0.65, blue: 1)
    static func color(_ s: SpotState?) -> Color {
        switch s {
        case .occupied?: return Color(red: 0.97, green: 0.32, blue: 0.29)
        case .vacant?: return Color(red: 0.25, green: 0.73, blue: 0.31)
        default: return Color(red: 0.82, green: 0.84, blue: 0.87)
        }
    }

    var body: some View {
        Canvas { ctx, size in
            let frame = model.frameSize
            let fit = Fit(frame: frame, in: size)
            let fw = frame.width * fit.s, fh = frame.height * fit.s
            func rect(_ r: FracRect) -> CGRect {
                CGRect(x: fit.ox + r.x * fw, y: fit.oy + r.y * fh, width: r.w * fw, height: r.h * fh)
            }
            if model.showBoxes {
                for v in model.views {
                    ctx.stroke(Path(rect(v)), with: .color(Overlay.view), style: StrokeStyle(lineWidth: 1, dash: [6, 4]))
                }
                for d in model.detections {
                    let r = CGRect(x: fit.ox + d.box.x * fit.s, y: fit.oy + d.box.y * fit.s,
                                   width: d.box.w * fit.s, height: d.box.h * fit.s)
                    let color = d.isVehicle ? Overlay.vehicle : d.isPerson ? Overlay.person : Overlay.other
                    ctx.stroke(Path(r), with: .color(color), lineWidth: 1.5)
                    let label = Text("\(d.className) \(Int((d.score * 100).rounded()))%")
                        .font(.system(size: 9, weight: .semibold)).foregroundColor(color)
                    let above = r.minY > 11
                    ctx.draw(label, at: CGPoint(x: r.minX + 1, y: above ? r.minY - 1 : r.minY + 1),
                             anchor: above ? .bottomLeading : .topLeading)
                }
            }
            for i in model.spots.indices where model.isActive(i) && !(drag != nil && model.drawingSpot == i) {
                let t = model.tracks[i]
                var label = "\(i + 1)"
                if let c = t.coverage { label += " · \(Int((c * 100).rounded()))%" }
                if t.person { label += " · person" }
                spot(ctx, rect(model.spots[i]!.rect), label: label, color: Overlay.color(t.state), dashed: false)
            }
            if let d = drag, let i = model.drawingSpot {
                spot(ctx, rect(d), label: "\(i + 1)", color: Overlay.color(nil), dashed: true)
            }
        }
        .allowsHitTesting(false)
    }

    private func spot(_ ctx: GraphicsContext, _ r: CGRect, label: String, color: Color, dashed: Bool) {
        ctx.fill(Path(r), with: .color(color.opacity(0.18)))
        ctx.stroke(Path(r), with: .color(color), style: StrokeStyle(lineWidth: 2.5, dash: dashed ? [8, 6] : []))
        let text = ctx.resolve(Text(label).font(.system(size: 12, weight: .bold)).foregroundColor(.white))
        let size = text.measure(in: CGSize(width: 300, height: 40))
        let tag = CGRect(x: r.minX, y: r.minY, width: size.width + 8, height: size.height + 4)
        ctx.fill(Path(tag), with: .color(Color.black.opacity(0.65)))
        ctx.draw(text, at: CGPoint(x: tag.minX + 4, y: tag.midY), anchor: .leading)
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
            ForEach(model.hudLines, id: \.self) { Text($0) }
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
            PanelSection(title: "Spots") {
                HStack {
                    ForEach(0..<AppModel.spotCount, id: \.self) { i in
                        Button(model.spots[i] == nil ? "Draw \(i + 1)" : "Redraw \(i + 1)") { model.startDrawing(i) }
                            .buttonStyle(.bordered)
                            .disabled(!model.canDraw)
                    }
                }
                if !model.drawHint.isEmpty { Text(model.drawHint).foregroundColor(.gray) }
                ForEach(0..<AppModel.spotCount, id: \.self) { i in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Circle().fill(Overlay.color(model.isActive(i) ? model.tracks[i].state : nil)).frame(width: 8, height: 8)
                        Text("\(i + 1)").bold()
                        Text(model.spotLine(i)).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            PanelSection(title: "Status") {
                ForEach(model.rows) { r in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Circle().fill(Panel.color(r.state)).frame(width: 8, height: 8)
                        Text(r.label).bold().frame(width: 92, alignment: .leading)
                        Text(r.detail).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            PanelSection(title: "Events") {
                HStack {
                    Button("Export CSV") { model.exportCSV() }.buttonStyle(.bordered)
                    if !model.exportResult.isEmpty { Text(model.exportResult).foregroundColor(.gray) }
                }
                if model.recentEvents.isEmpty { Text("No events yet").foregroundColor(.gray) }
                Text(model.recentEvents.reversed().map { "\(EventFormat.stamp($0.time))  \(EventFormat.text($0))" }
                        .joined(separator: "\n"))
                    .font(.system(size: 10, design: .monospaced))
                    .fixedSize(horizontal: false, vertical: true)
            }
            PanelSection(title: "Checks") {
                ForEach(Array(model.statRows().enumerated()), id: \.offset) { _, kv in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(kv.0).foregroundColor(.gray).frame(width: 96, alignment: .leading)
                        Text(kv.1).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            PanelSection(title: "Detections") {
                if model.detections.isEmpty {
                    Text("Nothing above \(Int((model.cfg.minScore * 100).rounded()))%").foregroundColor(.gray)
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
            VStack(alignment: .leading, spacing: 2) {
                Text("Views: one detector run for all spots, or one per spot").foregroundColor(.gray)
                picker($model.viewMode)
            }
            Row(label: "Source") { picker($model.source) }
            Row(label: "Compute") { picker($model.compute) }
            Row(label: "Precision") { picker($model.precision) }
            Toggle("Detection boxes", isOn: $model.showBoxes)
            HStack {
                Button(model.paused ? "Resume" : "Pause") { model.paused.toggle() }
                    .buttonStyle(.bordered)
                Button("Settings") { model.showSettings = true }
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
