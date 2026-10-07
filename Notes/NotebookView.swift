import PDFKit
import PencilKit
import SwiftUI

struct NotebookView: View {
    @StateObject private var nb: Notebook
    @State private var confirmDelete = false
    @State private var exportURL: URL?
    @State private var exportError: String?
    @Environment(\.scenePhase) private var scenePhase

    init(folder: URL) { _nb = StateObject(wrappedValue: Notebook(folder: folder)) }

    var body: some View {
        PDFCanvas(nb: nb)
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle($nb.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarRole(.editor)
            .toolbar {
                Button("Add Page", systemImage: "doc.badge.plus") { nb.addPage(at: (nb.currentIndex ?? nb.pdf.pageCount - 1) + 1) }
                Button("Delete Page", systemImage: "trash") { confirmDelete = true }
                Button("Export PDF", systemImage: "square.and.arrow.up") {
                    do { exportURL = try nb.exportPDF() } catch { exportError = error.localizedDescription }
                }
            }
            .confirmationDialog("Delete this page?", isPresented: $confirmDelete) {
                Button("Delete Page", role: .destructive) { if let i = nb.currentIndex { nb.deletePage(at: i) } }
            }
            .sheet(isPresented: Binding(get: { exportURL != nil }, set: { if !$0 { exportURL = nil } })) {
                if let exportURL { ShareSheet(url: exportURL) { self.exportURL = nil } }
            }
            .alert("Export failed", isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
            } message: {
                Text(exportError ?? "")
            }
            .onDisappear(perform: nb.saveInk)
            .onChange(of: scenePhase) { _, phase in if phase != .active { nb.saveInk() } }
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    let onDone: () -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let vc = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        vc.completionWithItemsHandler = { _, _, _, _ in onDone() }
        return vc
    }

    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

/// PDFView does scrolling/zoom/layout; each visible page gets a PKCanvasView overlay for ink.
struct PDFCanvas: UIViewRepresentable {
    let nb: Notebook

    func makeCoordinator() -> Coordinator { Coordinator(nb: nb) }

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.pageOverlayViewProvider = context.coordinator
        view.isInMarkupMode = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.autoScales = true
        view.document = nb.pdf
        nb.pdfView = view
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {}

    final class Coordinator: NSObject, PDFPageOverlayViewProvider, PKCanvasViewDelegate, PKToolPickerObserver, UIGestureRecognizerDelegate {
        let nb: Notebook
        let picker = PKToolPicker(toolItems: PKToolPicker.defaultToolItems + ShapeKind.allCases.map(\.toolItem))
        var canvases: [PDFPage: PKCanvasView] = [:]
        private let preview = CAShapeLayer()
        private var dragStart = CGPoint.zero

        init(nb: Notebook) {
            self.nb = nb
            super.init()
            picker.colorUserInterfaceStyle = .light
            picker.addObserver(self)
            preview.fillColor = nil
            preview.lineCap = .round
            preview.lineJoin = .round
        }

        func pdfView(_ view: PDFView, overlayViewFor page: PDFPage) -> UIView? {
            let canvas = PKCanvasView()
            canvas.backgroundColor = .clear
            canvas.isOpaque = false
            canvas.isScrollEnabled = false
            canvas.overrideUserInterfaceStyle = .light // pages are white; don't invert ink in dark mode
            if let tool = picker.selectedToolItem.tool { canvas.tool = tool }
            if let i = nb.index(of: page) { canvas.drawing = nb.drawing(at: i) }
            canvas.delegate = self
            picker.addObserver(canvas)

            let drag = UIPanGestureRecognizer(target: self, action: #selector(dragShape(_:)))
            drag.name = "shape"
            drag.maximumNumberOfTouches = 1
            let touches: [UITouch.TouchType] = UIPencilInteraction.prefersPencilOnlyDrawing ? [.pencil] : [.pencil, .direct]
            drag.allowedTouchTypes = touches.map { NSNumber(value: $0.rawValue) }
            drag.delegate = self
            canvas.addGestureRecognizer(drag)
            applyShapeMode(to: canvas)

            canvases[page] = canvas
            return canvas
        }

        func pdfView(_ view: PDFView, willDisplayOverlayView overlayView: UIView, for page: PDFPage) {
            picker.setVisible(true, forFirstResponder: overlayView)
            overlayView.becomeFirstResponder()
        }

        func pdfView(_ view: PDFView, willEndDisplayingOverlayView overlayView: UIView, for page: PDFPage) {
            guard let canvas = overlayView as? PKCanvasView else { return }
            picker.removeObserver(canvas)
            canvases[page] = nil
        }

        func canvasViewDrawingDidChange(_ canvas: PKCanvasView) {
            guard let page = canvases.first(where: { $0.value === canvas })?.key, let i = nb.index(of: page) else { return }
            nb.setDrawing(canvas.drawing, at: i)
        }

        // MARK: Shape tools

        private var selectedShape: ShapeKind? { ShapeKind(rawValue: picker.selectedToolItem.identifier) }

        func toolPickerSelectedToolItemDidChange(_ toolPicker: PKToolPicker) {
            canvases.values.forEach(applyShapeMode)
        }

        /// With a shape tool selected, the canvas stops inking and the drag gesture draws the shape instead.
        private func applyShapeMode(to canvas: PKCanvasView) {
            let shaping = selectedShape != nil
            canvas.drawingGestureRecognizer.isEnabled = !shaping
            canvas.gestureRecognizers?.filter { $0.name == "shape" }.forEach { $0.isEnabled = shaping }
        }

        @objc private func dragShape(_ drag: UIPanGestureRecognizer) {
            guard let canvas = drag.view as? PKCanvasView, let shape = selectedShape,
                  let item = picker.selectedToolItem as? PKToolPickerCustomItem else { return }
            let end = drag.location(in: canvas)
            switch drag.state {
            case .began:
                let moved = drag.translation(in: canvas)
                dragStart = CGPoint(x: end.x - moved.x, y: end.y - moved.y)
                preview.strokeColor = item.color.cgColor
                preview.lineWidth = item.width
                canvas.layer.addSublayer(preview)
                fallthrough
            case .changed:
                let path = UIBezierPath()
                for line in shape.polylines(from: dragStart, to: end, width: item.width) {
                    path.move(to: line[0])
                    line.dropFirst().forEach(path.addLine(to:))
                }
                preview.path = path.cgPath
            case .ended:
                preview.removeFromSuperlayer()
                guard hypot(end.x - dragStart.x, end.y - dragStart.y) > 2 else { return }
                let strokes = shape.strokes(from: dragStart, to: end, color: item.color, width: item.width)
                replaceDrawing(of: canvas, with: canvas.drawing.appending(PKDrawing(strokes: strokes)))
            default:
                preview.removeFromSuperlayer()
            }
        }

        /// Sets the drawing with an undo step that restores the previous one (and redo via the same path).
        private func replaceDrawing(of canvas: PKCanvasView, with drawing: PKDrawing) {
            let previous = canvas.drawing
            canvas.undoManager?.registerUndo(withTarget: canvas) { [weak self] canvas in
                self?.replaceDrawing(of: canvas, with: previous)
            }
            canvas.drawing = drawing
        }

        /// The PDF's scroll view waits for a shape drag, so dragging a shape doesn't scroll the page.
        func gestureRecognizer(_ gesture: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
            gesture.name == "shape" && other.view is UIScrollView
        }
    }
}

extension ShapeKind {
    var toolItem: PKToolPickerCustomItem {
        var config = PKToolPickerCustomItem.Configuration(identifier: rawValue, name: name)
        config.defaultWidth = 3
        config.allowsColorSelection = true
        config.widthVariants = Dictionary(uniqueKeysWithValues: [1.5, 3, 6].map { ($0, widthImage($0)) })
        config.imageProvider = { [symbol] item in toolImage(symbol: symbol, color: item.color) }
        return PKToolPickerCustomItem(configuration: config)
    }
}

/// Tool picker art: a pale body with the shape symbol in the tool's color (picker wants 150pt tall).
private func toolImage(symbol: String, color: UIColor) -> UIImage {
    UIGraphicsImageRenderer(size: CGSize(width: 50, height: 150)).image { _ in
        UIColor(white: 0.9, alpha: 1).setFill()
        UIBezierPath(roundedRect: CGRect(x: 8, y: 20, width: 34, height: 130), cornerRadius: 10).fill()
        let config = UIImage.SymbolConfiguration(pointSize: 20, weight: .semibold)
        if let image = UIImage(systemName: symbol, withConfiguration: config)?.withTintColor(color, renderingMode: .alwaysOriginal) {
            image.draw(at: CGPoint(x: 25 - image.size.width / 2, y: 44 - image.size.height / 2))
        }
    }
}

private func widthImage(_ width: CGFloat) -> UIImage {
    UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32)).image { _ in
        let path = UIBezierPath()
        path.move(to: CGPoint(x: 5, y: 16))
        path.addLine(to: CGPoint(x: 27, y: 16))
        path.lineWidth = width
        path.lineCapStyle = .round
        UIColor.black.setStroke()
        path.stroke()
    }
}
