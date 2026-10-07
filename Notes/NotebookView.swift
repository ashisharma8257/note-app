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

    final class Coordinator: NSObject, PDFPageOverlayViewProvider, PKCanvasViewDelegate {
        let nb: Notebook
        let picker = PKToolPicker()
        var canvases: [PDFPage: PKCanvasView] = [:]

        init(nb: Notebook) {
            self.nb = nb
            super.init()
            picker.colorUserInterfaceStyle = .light
        }

        func pdfView(_ view: PDFView, overlayViewFor page: PDFPage) -> UIView? {
            let canvas = PKCanvasView()
            canvas.backgroundColor = .clear
            canvas.isOpaque = false
            canvas.isScrollEnabled = false
            canvas.overrideUserInterfaceStyle = .light // pages are white; don't invert ink in dark mode
            canvas.tool = picker.selectedTool
            if let i = nb.index(of: page) { canvas.drawing = nb.drawing(at: i) }
            canvas.delegate = self
            picker.addObserver(canvas)
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
    }
}
