import PDFKit
import PencilKit
import SwiftUI

/// One open notebook: blue tool bar, floating undo/redo and tool options, then the pages.
struct NotebookView: View {
    @StateObject private var nb: Notebook
    @ObservedObject var tools: Tools
    @EnvironmentObject private var tabs: Tabs
    @State private var confirmDelete = false
    @State private var confirmClear = false
    @State private var showPages = false
    @State private var renaming = false
    @State private var addingOutline = false
    @State private var outlineTitle = ""
    @State private var newTitle = ""
    @State private var exportURL: URL?
    @State private var exportError: String?
    @Environment(\.scenePhase) private var scenePhase

    init(folder: URL, tools: Tools) {
        _nb = StateObject(wrappedValue: Notebook(folder: folder))
        self.tools = tools
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                barButton("sidebar.left", "Pages") { showPages = true }
                barButton(nb.isBookmarked(nb.currentPage) ? "bookmark.fill" : "bookmark", "Bookmark Page") {
                    nb.toggleBookmark(nb.currentPage)
                }
                Spacer()
                ToolPicker(tools: tools)
                Spacer()
                barButton("doc.badge.plus", "Add Page") { nb.addPage(at: (nb.currentIndex ?? nb.pdf.pageCount - 1) + 1) }
                barButton("square.and.arrow.up", "Export PDF") {
                    do { exportURL = try nb.exportPDF() } catch { exportError = error.localizedDescription }
                }
                Menu {
                    Button("Add to Outline…", systemImage: "list.bullet.indent") { outlineTitle = ""; addingOutline = true }
                    Button("Rename Notebook", systemImage: "pencil") { newTitle = nb.title; renaming = true }
                    Section("Clear or Delete Page") {
                        Button("Clear Page", systemImage: "xmark.square", role: .destructive) { confirmClear = true }
                        Button("Delete Page", systemImage: "trash", role: .destructive) { confirmDelete = true }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle").font(.system(size: 20)).frame(width: 44, height: 44)
                }
                .accessibilityLabel("More")
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Theme.bar)

            // The hidden copy of UndoRedo balances the row so the options stay centred.
            HStack(alignment: .top) {
                UndoRedo(undo: { nb.pdfView?.undoManager?.undo() }, redo: { nb.pdfView?.undoManager?.redo() })
                Spacer(minLength: 12)
                ToolOptions(tools: tools)
                Spacer(minLength: 12)
                UndoRedo(undo: {}, redo: {}).hidden()
            }
            .padding(12)
            .background(Theme.canvas)

            PDFCanvas(nb: nb, tools: tools)
                .ignoresSafeArea(edges: .bottom)
        }
        .environment(\.colorScheme, .light) // GoodNotes-style chrome and paper look the same in dark mode
        .alert("Delete Page?", isPresented: $confirmDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) { if let i = nb.currentIndex { nb.deletePage(at: i) } }
        } message: {
            Text("Page \(nb.currentPage + 1) and everything on it will be deleted.")
        }
        .alert("Clear Page?", isPresented: $confirmClear) {
            Button("Cancel", role: .cancel) {}
            Button("Clear", role: .destructive) { if let i = nb.currentIndex { nb.clearPage?(i) } }
        } message: {
            Text("Removes the ink and text boxes on page \(nb.currentPage + 1). Undo brings them back.")
        }
        .alert("Rename Notebook", isPresented: $renaming) {
            TextField("Title", text: $newTitle)
            Button("Cancel", role: .cancel) {}
            Button("Rename") {
                let title = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                if !title.isEmpty { nb.title = title }
                tabs.refresh()
            }
        }
        .alert("Add to Outline", isPresented: $addingOutline) {
            TextField("Title", text: $outlineTitle)
            Button("Cancel", role: .cancel) {}
            Button("Add") {
                nb.addOutline(outlineTitle.trimmingCharacters(in: .whitespacesAndNewlines), page: nb.currentPage, y: nb.visibleY)
            }
        } message: {
            Text("Marks the top of what's on screen on page \(nb.currentPage + 1).")
        }
        .sheet(isPresented: $showPages) {
            PageSheet(nb: nb, current: nb.currentIndex)
        }
        .sheet(isPresented: Binding(get: { exportURL != nil }, set: { if !$0 { exportURL = nil } })) {
            if let exportURL { ShareSheet(url: exportURL) { self.exportURL = nil } }
        }
        .alert("Export failed", isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
        } message: {
            Text(exportError ?? "")
        }
        .onDisappear(perform: nb.close)
        .onChange(of: scenePhase) { _, phase in if phase != .active { nb.close() } }
    }

    private func barButton(_ symbol: String, _ name: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 20)).frame(width: 44, height: 44)
        }
        .accessibilityLabel(name)
    }
}

/// Pages (drag to reorder), bookmarked pages and the outline; tapping an item jumps to it.
struct PageSheet: View {
    @ObservedObject var nb: Notebook
    let current: Int?
    @State private var tab = 0
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                switch tab {
                case 1:
                    let bookmarked = nb.pages.enumerated().filter { nb.bookmarks.contains($0.element) }
                    if bookmarked.isEmpty {
                        ContentUnavailableView("No Bookmarks", systemImage: "bookmark", description: Text("Tap the bookmark button on a page."))
                    } else {
                        grid(bookmarked, reorderable: false)
                    }
                case 2:
                    if nb.outline.isEmpty {
                        ContentUnavailableView("No Outline", systemImage: "list.bullet.indent", description: Text("Use ⋯ › Add to Outline on a page."))
                    } else {
                        List {
                            ForEach(nb.sortedOutline) { entry in
                                Button {
                                    dismiss()
                                    nb.go(to: entry)
                                } label: {
                                    LabeledContent(entry.title, value: "Page \((nb.index(of: entry.page) ?? 0) + 1)")
                                }
                            }
                            .onDelete { offsets in
                                let entries = nb.sortedOutline
                                offsets.forEach { nb.removeOutline(entries[$0]) }
                            }
                        }
                    }
                default:
                    grid(Array(nb.pages.enumerated()), reorderable: true)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("View", selection: $tab) {
                        Text("Pages").tag(0)
                        Text("Bookmarks").tag(1)
                        Text("Outline").tag(2)
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }

    private func grid(_ pages: [(offset: Int, element: UUID)], reorderable: Bool) -> some View {
        ScrollView {
            if reorderable {
                Text("Drag a page onto another to move it there.").font(.footnote).foregroundStyle(.secondary).padding(.top)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 20)], spacing: 20) {
                // Identity is the page id, so thumbnails follow their pages when they move.
                ForEach(pages, id: \.element) { i, _ in
                    let cell = Button {
                        dismiss()
                        nb.goToPage(i)
                    } label: {
                        VStack(spacing: 6) {
                            Thumbnail { nb.thumbnail(at: i, width: 260) }
                                .overlay(RoundedRectangle(cornerRadius: 2).stroke(i == current ? Color.accentColor : .clear, lineWidth: 3))
                                .overlay(alignment: .topTrailing) {
                                    if nb.isBookmarked(i) {
                                        Image(systemName: "bookmark.fill").foregroundStyle(.red).padding(4)
                                    }
                                }
                            Text("\(i + 1)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    if reorderable {
                        cell
                            .draggable(String(i))
                            .dropDestination(for: String.self) { items, _ in
                                guard let from = items.first.flatMap(Int.init) else { return false }
                                nb.movePage(from: from, to: i)
                                return true
                            }
                    } else {
                        cell
                    }
                }
            }
            .padding()
        }
    }
}

/// A page image rendered once the view appears, with a white placeholder until then.
// ponytail: renders on the main actor with no cache; cache to disk if large libraries scroll slowly
struct Thumbnail: View {
    let render: () -> UIImage?
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                Color.white.aspectRatio(612.0 / 792.0, contentMode: .fit)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 2))
        .shadow(color: .black.opacity(0.2), radius: 3, y: 1)
        .task { image = render() }
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

/// Fits the widest page to the view's width, GoodNotes-style, whenever that width changes (rotation,
/// split view); pinch zoom works in between. PDFView's autoScales fits the whole page instead, which
/// leaves a narrow page in landscape.
final class FitWidthPDFView: PDFView {
    private var fittedWidth: CGFloat = 0

    override func layoutSubviews() {
        refit()
        super.layoutSubviews()
    }

    private func refit() {
        guard bounds.width > 0, bounds.width != fittedWidth, let document else { return }
        let widest = (0..<document.pageCount).compactMap { document.page(at: $0)?.bounds(for: displayBox).width }.max() ?? 0
        guard widest > 0 else { return }
        fittedWidth = bounds.width
        let fit = (bounds.width - pageBreakMargins.left - pageBreakMargins.right) / widest
        minScaleFactor = fit / 2
        maxScaleFactor = fit * 5
        scaleFactor = fit
    }
}

/// PDFView does scrolling/zoom/layout; each visible page gets a PKCanvasView overlay for ink.
struct PDFCanvas: UIViewRepresentable {
    let nb: Notebook
    @ObservedObject var tools: Tools

    func makeCoordinator() -> Coordinator { Coordinator(nb: nb, tools: tools) }

    func makeUIView(context: Context) -> PDFView {
        let view = FitWidthPDFView()
        view.pageOverlayViewProvider = context.coordinator
        view.isInMarkupMode = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.backgroundColor = UIColor(Theme.canvas)
        view.document = nb.pdf
        let pencil = UIPencilInteraction()
        pencil.delegate = context.coordinator
        view.addInteraction(pencil)
        // GoodNotes gestures: two-finger tap undoes, three-finger tap redoes.
        for (fingers, action) in [(2, #selector(Coordinator.undo)), (3, #selector(Coordinator.redo))] {
            let tap = UITapGestureRecognizer(target: context.coordinator, action: action)
            tap.numberOfTouchesRequired = fingers
            tap.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
            view.addGestureRecognizer(tap)
        }
        nb.pdfView = view
        nb.clearPage = { [weak coordinator = context.coordinator] in coordinator?.clear(page: $0) }
        let hint = context.coordinator.pullHint
        hint.font = .preferredFont(forTextStyle: .footnote)
        hint.textColor = .gray
        hint.alpha = 0
        hint.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hint)
        NSLayoutConstraint.activate([
            hint.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            hint.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24),
        ])
        let pull = context.coordinator.pullGesture
        pull.addTarget(context.coordinator, action: #selector(Coordinator.pulled(_:)))
        pull.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)] // scrolling is a finger thing
        pull.cancelsTouchesInView = false
        pull.delegate = context.coordinator
        view.addGestureRecognizer(pull)
        // PencilKit can keep stale or missing tiles after PDFView rescales an existing ink overlay (fit to
        // width, rotation, pinch zoom), so redraw the ink once each scale change settles.
        context.coordinator.scaleObserver = NotificationCenter.default.addObserver(
            forName: .PDFViewScaleChanged, object: view, queue: .main
        ) { [weak coordinator = context.coordinator] _ in coordinator?.scheduleRedraw() }
        context.coordinator.pageObserver = NotificationCenter.default.addObserver(
            forName: .PDFViewPageChanged, object: view, queue: .main
        ) { [weak nb] _ in
            guard let nb, let i = nb.currentIndex, i != nb.currentPage else { return }
            nb.currentPage = i
        }
        // Reopen at the last viewed page once PDFView has laid out.
        let lastPage = nb.lastPage
        DispatchQueue.main.async { nb.goToPage(lastPage) }
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        context.coordinator.overlays.values.forEach(context.coordinator.applyTool)
    }

    /// One page's overlay: the ink canvas, with shape-drawing and laser views on top that take touches
    /// only while their tool is selected, so PencilKit never sees shape drags or the laser.
    final class PageOverlay: UIView {
        weak var page: PDFPage?
        let canvas = PKCanvasView()
        let items = ItemsView()
        let shapeView = UIView()
        let laser = LaserView()
        let hold = HoldGesture()

        override init(frame: CGRect) {
            super.init(frame: frame)
            canvas.addGestureRecognizer(hold)
            addSubview(canvas)
            addSubview(items)
            addSubview(shapeView)
            addSubview(laser)
        }

        required init?(coder: NSCoder) { fatalError("not used") }

        override func layoutSubviews() {
            super.layoutSubviews()
            canvas.frame = bounds
            items.frame = bounds
            shapeView.frame = bounds
            laser.frame = bounds
        }
    }

    final class Coordinator: NSObject, PDFPageOverlayViewProvider, PKCanvasViewDelegate, UIGestureRecognizerDelegate, UIPencilInteractionDelegate {
        let nb: Notebook
        let tools: Tools
        var overlays: [PDFPage: PageOverlay] = [:]
        var pageObserver: NSObjectProtocol?
        var scaleObserver: NSObjectProtocol?
        private var redraw: DispatchWorkItem?

        deinit {
            pageObserver.map(NotificationCenter.default.removeObserver)
            scaleObserver.map(NotificationCenter.default.removeObserver)
        }

        func scheduleRedraw() {
            redraw?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.redrawInk() }
            redraw = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
        }
        private let preview = CAShapeLayer()
        private var dragStart = CGPoint.zero
        /// The points of a freehand shape being drawn.
        private var freehand: [CGPoint] = []
        /// Watches finger drags, alongside PDFView's own scrolling, for a pull up past the last page.
        let pullGesture = UIPanGestureRecognizer()
        /// Shown below the last page while pulling up past it.
        let pullHint = UILabel()
        /// Newest stroke already checked for scribble-to-erase; older strokes (undo, lasso moves) are never rechecked.
        private var lastChecked = Date()
        /// Draw and hold in progress: the shape as snapped, where the Pencil was then, and the drawing without the stroke.
        private var snap: (shape: [CGPoint], from: CGPoint, base: PKDrawing)?
        /// Per ink, the pen or highlighter width last drawn with it and the middle point of that stroke, so snapped
        /// shapes match the user's own ink.
        private var inkSamples: [PKInk.InkType: (width: CGFloat, point: PKStrokePoint)] = [:]

        init(nb: Notebook, tools: Tools) {
            self.nb = nb
            self.tools = tools
            super.init()
            preview.fillColor = nil
            preview.lineCap = .round
            preview.lineJoin = .round
        }

        func pdfView(_ view: PDFView, overlayViewFor page: PDFPage) -> UIView? {
            let overlay = PageOverlay()
            overlay.page = page
            let canvas = overlay.canvas
            canvas.backgroundColor = .clear
            canvas.isOpaque = false
            canvas.isScrollEnabled = false
            canvas.overrideUserInterfaceStyle = .light // pages are light paper; don't invert ink in dark mode
            if let i = nb.index(of: page) {
                canvas.drawing = nb.drawing(at: i)
                overlay.items.load(nb.items(at: i))
            }
            canvas.delegate = self
            overlay.items.onChange = { [weak self, weak overlay] items in
                guard let self, let page = overlay?.page, let i = self.nb.index(of: page) else { return }
                self.nb.setItems(items, at: i)
            }

            let drag = UIPanGestureRecognizer(target: self, action: #selector(dragShape(_:)))
            drag.maximumNumberOfTouches = 1
            let touches: [UITouch.TouchType] = UIPencilInteraction.prefersPencilOnlyDrawing ? [.pencil] : [.pencil, .direct]
            drag.allowedTouchTypes = touches.map { NSNumber(value: $0.rawValue) }
            drag.delegate = self
            overlay.shapeView.addGestureRecognizer(drag)
            overlay.hold.allowedTouchTypes = drag.allowedTouchTypes
            overlay.laser.gesture.allowedTouchTypes = drag.allowedTouchTypes
            overlay.hold.shouldBegin = { [weak self] in self?.beginSnap($0) ?? false }
            overlay.hold.addTarget(self, action: #selector(followSnap(_:)))
            applyTool(to: overlay)

            overlays[page] = overlay
            return overlay
        }

        func pdfView(_ view: PDFView, willDisplayOverlayView overlayView: UIView, for page: PDFPage) {
            (overlayView as? PageOverlay)?.canvas.becomeFirstResponder() // lets the lasso selection show its edit menu
        }

        func pdfView(_ view: PDFView, willEndDisplayingOverlayView overlayView: UIView, for page: PDFPage) {
            // PDFView can create a page's replacement overlay before ending the old one; keep the replacement.
            if overlays[page] === overlayView { overlays[page] = nil }
        }

        func canvasViewDrawingDidChange(_ canvas: PKCanvasView) {
            guard let page = (canvas.superview as? PageOverlay)?.page, let i = nb.index(of: page) else { return }
            nb.setDrawing(canvas.drawing, at: i)
            checkNewStroke(on: canvas)
        }

        /// Remembers how each new pen or highlighter stroke looks, for draw and hold; a new pen scribble erases the ink under it.
        private func checkNewStroke(on canvas: PKCanvasView) {
            guard tools.tool == .pen || tools.tool == .highlighter, let newest = canvas.drawing.strokes.last,
                  newest.path.creationDate > lastChecked, !newest.path.isEmpty else { return }
            lastChecked = newest.path.creationDate
            inkSamples[newest.ink.inkType] = (tools.style.width, newest.path[newest.path.count / 2])
            // During a snap this is PencilKit keeping the stroke it was cut off from; the snap's next update replaces it.
            guard snap == nil, tools.tool == .pen, let erased = Scribble.erase(in: canvas.drawing) else { return }
            // Undo brings back the erased ink without the scribble itself.
            replaceDrawing(of: canvas, with: erased, previous: PKDrawing(strokes: canvas.drawing.strokes.dropLast()))
        }

        /// Draw and hold: when the stroke held still resembles a shape, takes the stroke from PencilKit
        /// so `followSnap` can show the shape instead.
        private func beginSnap(_ hold: HoldGesture) -> Bool {
            guard let canvas = hold.view as? PKCanvasView, let from = hold.points.last,
                  let shape = ShapeSnap.shape(hold.points) else { return false }
            snap = (shape, from, canvas.drawing)
            // Disabling the drawing gesture cancels the stroke in progress; the touch stays with HoldGesture.
            canvas.drawingGestureRecognizer.isEnabled = false
            canvas.drawingGestureRecognizer.isEnabled = true
            return true
        }

        /// Shows the snapped shape following the Pencil, and keeps it, with one undo step, when the Pencil lifts.
        @objc private func followSnap(_ hold: HoldGesture) {
            guard let canvas = hold.view as? PKCanvasView, let snap, let tool = tools.pkTool as? PKInkingTool else { return }
            let shape = ShapeSnap.adjusted(snap.shape, from: snap.from, to: hold.location(in: canvas))
            // Sized like the user's last stroke in this ink, scaled to the current width. With no stroke yet, the size is
            // a guess carried over from the ballpoint measurement in ShapeKind.strokes.
            let sample = inkSamples[tool.inkType]
            let scale = sample.map { tools.style.width / $0.width } ?? 1
            let size = sample.map { CGSize(width: $0.point.size.width * scale, height: $0.point.size.height * scale) }
                ?? CGSize(width: tool.width + 2, height: tool.width + 2)
            let template = PKStrokePoint(location: .zero, timeOffset: 0, size: size, opacity: sample?.point.opacity ?? 1,
                                         force: sample?.point.force ?? 1, azimuth: sample?.point.azimuth ?? 0,
                                         altitude: sample?.point.altitude ?? .pi / 2)
            // Stamped as already checked, so checkNewStroke leaves it alone.
            let drawing = PKDrawing(strokes: snap.base.strokes + [PKStroke(along: shape, ink: tool.ink, like: template, created: lastChecked)])
            switch hold.state {
            case .began, .changed:
                canvas.drawing = drawing
            case .ended, .cancelled:
                self.snap = nil
                replaceDrawing(of: canvas, with: drawing, previous: snap.base)
            default:
                break
            }
        }

        /// Makes PencilKit render each visible canvas again from scratch.
        func redrawInk() {
            for overlay in overlays.values {
                let canvas = overlay.canvas
                canvas.delegate = nil // not an edit: keep it out of saving and change tracking
                let drawing = canvas.drawing
                canvas.drawing = PKDrawing() // assigning an equal drawing doesn't re-render; clearing first does
                canvas.drawing = drawing
                canvas.delegate = self
            }
        }

        func applyTool(to overlay: PageOverlay) {
            overlay.canvas.tool = tools.pkTool
            overlay.shapeView.isHidden = tools.tool != .shape // hidden views receive no touches
            overlay.laser.isHidden = tools.tool != .laser
            overlay.laser.line = tools.laserLine
            overlay.hold.isEnabled = tools.tool == .pen || tools.tool == .highlighter
            overlay.items.active = tools.tool == .text
            overlay.items.setStyle(color: tools.textStyle.color, size: tools.textStyle.width)
        }

        @objc func undo() { nb.pdfView?.undoManager?.undo() }
        @objc func redo() { nb.pdfView?.undoManager?.redo() }

        /// Apple Pencil double-tap, following the action chosen in Settings → Apple Pencil.
        func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveTap tap: UIPencilInteraction.Tap) {
            tools.pencilTap(UIPencilInteraction.preferredTapAction)
        }

        @objc private func dragShape(_ drag: UIPanGestureRecognizer) {
            guard let shapeView = drag.view, let overlay = shapeView.superview as? PageOverlay else { return }
            let style = tools.shapeStyle
            let end = drag.location(in: shapeView)
            switch drag.state {
            case .began:
                let moved = drag.translation(in: shapeView)
                dragStart = CGPoint(x: end.x - moved.x, y: end.y - moved.y)
                freehand = [dragStart]
                preview.strokeColor = style.color.cgColor
                preview.lineWidth = style.width
                shapeView.layer.addSublayer(preview)
                fallthrough
            case .changed:
                freehand.append(end)
                let path = UIBezierPath()
                for line in tools.shape == .freehand ? [freehand] : tools.shape.polylines(from: dragStart, to: end, width: style.width) {
                    path.move(to: line[0])
                    line.dropFirst().forEach(path.addLine(to:))
                }
                preview.path = path.cgPath
            case .ended:
                preview.removeFromSuperlayer()
                guard hypot(end.x - dragStart.x, end.y - dragStart.y) > 2 || freehand.count > 2 else { return }
                // A freehand shape becomes the shape it resembles, or stays as drawn when it resembles none.
                let strokes = tools.shape == .freehand
                    ? ShapeKind.strokes([ShapeSnap.shape(freehand + [end]) ?? freehand + [end]], color: style.color, width: style.width)
                    : tools.shape.strokes(from: dragStart, to: end, color: style.color, width: style.width)
                replaceDrawing(of: overlay.canvas, with: overlay.canvas.drawing.appending(PKDrawing(strokes: strokes)), previous: overlay.canvas.drawing)
            default:
                preview.removeFromSuperlayer()
            }
        }

        /// Clears a page's ink and text boxes; undo (one step, as UndoManager groups by event) brings them back.
        func clear(page i: Int) {
            guard let page = nb.pdf.page(at: i), let overlay = overlays[page] else { return }
            replaceDrawing(of: overlay.canvas, with: PKDrawing(), previous: overlay.canvas.drawing)
            overlay.items.removeAll()
        }

        /// Pull up past the last page and let go to add a page there; the hint below says when letting go will.
        @objc func pulled(_ pan: UIPanGestureRecognizer) {
            guard let scroll = pan.view?.subviews.lazy.compactMap({ $0 as? UIScrollView }).first else { return }
            let inset = scroll.adjustedContentInset
            let resting = max(scroll.contentSize.height + inset.bottom - scroll.bounds.height, -inset.top)
            let pull = scroll.contentOffset.y - resting
            switch pan.state {
            case .began, .changed:
                pullHint.text = pull > 120 ? "Release to add a page" : "Pull up to add a page"
                pullHint.alpha = min(1, max(0, pull / 60))
            case .ended where pull > 120:
                pullHint.alpha = 0
                nb.addPage(at: nb.pdf.pageCount)
            default:
                pullHint.alpha = 0
            }
        }

        /// Sets the drawing with an undo step back to `previous`; undoing registers the redo the same way.
        private func replaceDrawing(of canvas: PKCanvasView, with drawing: PKDrawing, previous: PKDrawing) {
            let current = drawing
            canvas.undoManager?.registerUndo(withTarget: canvas) { [weak self] canvas in
                self?.replaceDrawing(of: canvas, with: previous, previous: current)
            }
            canvas.drawing = drawing
        }

        /// The PDF's scroll view waits for a shape drag, so dragging a shape doesn't scroll the page.
        func gestureRecognizer(_ gesture: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
            gesture !== pullGesture && other.view is UIScrollView
        }

        /// Watching for a pull never gets in the way of scrolling.
        func gestureRecognizer(_ gesture: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            gesture === pullGesture
        }
    }
}

/// The laser pointer: a glowing red dot under the Pencil, or a glowing red line that fades away soon after the Pencil
/// lifts. Nothing is kept.
final class LaserView: UIView {
    var line = true
    let gesture = UILongPressGestureRecognizer()
    private var trail = UIBezierPath()
    private var current: CAShapeLayer?

    override init(frame: CGRect) {
        super.init(frame: frame)
        gesture.minimumPressDuration = 0
        gesture.allowableMovement = .greatestFiniteMagnitude
        gesture.addTarget(self, action: #selector(track(_:)))
        addGestureRecognizer(gesture)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    @objc private func track(_ gesture: UILongPressGestureRecognizer) {
        let p = gesture.location(in: self)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        switch gesture.state {
        case .began:
            let glow = CAShapeLayer()
            glow.strokeColor = UIColor.systemRed.cgColor
            glow.fillColor = line ? nil : UIColor.systemRed.cgColor
            glow.lineWidth = 3
            glow.lineCap = .round
            glow.lineJoin = .round
            glow.shadowColor = UIColor.systemRed.cgColor
            glow.shadowRadius = 6
            glow.shadowOpacity = 1
            glow.shadowOffset = .zero
            layer.addSublayer(glow)
            current = glow
            trail = UIBezierPath()
            trail.move(to: p)
            fallthrough
        case .changed:
            if line {
                trail.addLine(to: p)
                current?.path = trail.cgPath
            } else {
                current?.path = UIBezierPath(arcCenter: p, radius: 5, startAngle: 0, endAngle: 2 * .pi, clockwise: true).cgPath
            }
        default:
            guard let glow = current else { return }
            current = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + (line ? 0.6 : 0)) { [line] in
                CATransaction.begin()
                CATransaction.setAnimationDuration(line ? 0.5 : 0.2)
                CATransaction.setCompletionBlock { glow.removeFromSuperlayer() }
                glow.opacity = 0
                CATransaction.commit()
            }
        }
    }
}
