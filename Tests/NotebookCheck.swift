import PDFKit
import PencilKit

/// Notebook storage, import, shape geometry and tool checks: run with scripts/check.sh.
@main
enum NotebookCheck {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "notebook-check-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        func strokes(_ n: Int) -> PKDrawing {
            let points = (0..<5).map { i in
                PKStrokePoint(location: CGPoint(x: i * 10, y: i * 10), timeOffset: Double(i) * 0.01, size: CGSize(width: 3, height: 3),
                              opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
            }
            let stroke = PKStroke(ink: PKInk(.pen, color: .black), path: PKStrokePath(controlPoints: points, creationDate: Date()))
            return PKDrawing(strokes: Array(repeating: stroke, count: n))
        }
        func counts(_ nb: Notebook) -> [Int] { (0..<nb.pdf.pageCount).map { nb.drawing(at: $0).strokes.count } }

        let pdf = PDFDocument()
        pdf.insert(Store.paperPage(.lined), at: 0)
        try Store.create(title: "Check", paper: .lined, pdf: pdf, in: root)
        let folder = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)[0]

        var nb = Notebook(folder: folder)
        nb.setDrawing(strokes(1), at: 0)
        nb.addPage(at: 1)
        nb.setDrawing(strokes(2), at: 1)
        nb.addPage(at: 1) // blank page inserted between the two inked pages
        nb.saveInk()
        nb = Notebook(folder: folder)
        assert(counts(nb) == [1, 0, 2], "insert keeps ink with its page: \(counts(nb))")

        nb.deletePage(at: 0)
        nb = Notebook(folder: folder)
        assert(counts(nb) == [0, 2], "delete shifts later pages: \(counts(nb))")
        let inkFiles = try FileManager.default.contentsOfDirectory(atPath: folder.appending(path: "ink").path)
        assert(inkFiles.count == 1, "deleted page's ink file removed: \(inkFiles)")

        // Notebook whose meta.json has no page ids: ids get assigned once and persisted.
        try JSONEncoder().encode(Meta(title: "Legacy", paper: .blank)).write(to: folder.appending(path: "meta.json"))
        nb = Notebook(folder: folder)
        nb.setDrawing(strokes(3), at: 1)
        nb.saveInk()
        nb = Notebook(folder: folder)
        assert(counts(nb) == [0, 3], "assigned page ids persist: \(counts(nb))")

        // Deleting the only page replaces it with a blank one and drops its ink.
        nb.deletePage(at: 0)
        nb.deletePage(at: 0)
        nb = Notebook(folder: folder)
        assert(counts(nb) == [0], "only page becomes blank: \(counts(nb))")

        let thumb = nb.thumbnail(at: 0, width: 100)
        assert(thumb.map { abs($0.size.height - 100 * 792 / 612) < 1 } == true, "thumbnail keeps page aspect: \(String(describing: thumb?.size))")

        // An ink-only save still bumps the notebook's modified date in the library.
        let before = Store.list(in: root)[0].modified
        Thread.sleep(forTimeInterval: 0.05)
        nb.setDrawing(strokes(4), at: 0)
        nb.saveInk()
        assert(Store.list(in: root)[0].modified > before, "ink save updates modified date")

        let exported = try nb.exportPDF()
        assert(PDFDocument(url: exported)?.pageCount == nb.pdf.pageCount, "export has every page")
        // Shapes: ink bounds match the dragged box (within stroke width + spline slack).
        let a = CGPoint(x: 10, y: 10), b = CGPoint(x: 110, y: 60)
        func bounds(_ shape: ShapeKind) -> CGRect { PKDrawing(strokes: shape.strokes(from: a, to: b, color: .black, width: 2)).bounds }
        func near(_ r: CGRect, _ expected: CGRect) -> Bool {
            [r.minX - expected.minX, r.minY - expected.minY, r.maxX - expected.maxX, r.maxY - expected.maxY].allSatisfy { abs($0) <= 3 }
        }
        let box = CGRect(x: 10, y: 10, width: 100, height: 50)
        assert(near(bounds(.rectangle), box), "rectangle bounds: \(bounds(.rectangle))")
        assert(near(bounds(.ellipse), box), "ellipse bounds: \(bounds(.ellipse))")
        let shapeTools = Tools()
        shapeTools.tool = .shape
        for width in shapeTools.widthPresets {
            // renderBounds pads the ink by 1pt on each side.
            let drawn = ShapeKind.line.strokes(from: a, to: CGPoint(x: 110, y: 10), color: .black, width: width)[0].renderBounds.height - 2
            assert(abs(drawn - width) <= 1, "shape width \(width) renders \(drawn)pt wide")
        }
        assert(ShapeKind.arrow.strokes(from: a, to: b, color: .black, width: 2).count == 2, "arrow is shaft + head")
        assert(ShapeKind.rectangle.polylines(from: a, to: b, width: 2)[0].last == a, "rectangle closes")

        // Pencil double-tap: eraser toggles back to whatever tool was in use.
        let tools = Tools()
        tools.tool = .highlighter
        tools.pencilTap(.switchEraser)
        assert(tools.tool == .eraser, "double-tap switches to eraser")
        tools.pencilTap(.switchEraser)
        assert(tools.tool == .highlighter, "double-tap again restores highlighter")
        tools.pencilTap(.switchPrevious)
        assert(tools.tool == .eraser, "switch-previous goes to the last tool")
        tools.pencilTap(.ignore)
        assert(tools.tool == .eraser, "ignore leaves the tool alone")

        // Reopen position survives close().
        nb.addPage(at: 1)
        nb.close()
        assert(Notebook(folder: folder).lastPage == 0, "lastPage defaults to first page without a PDFView")

        // Import: folder trees keep their structure; non-PDFs are reported, hidden files ignored.
        let source = root.appending(path: "source")
        let library = root.appending(path: "library")
        let fm = FileManager.default
        try fm.createDirectory(at: source.appending(path: "Course/Week 1"), withIntermediateDirectories: true)
        try fm.createDirectory(at: library, withIntermediateDirectories: true)
        let pdfDoc = PDFDocument()
        pdfDoc.insert(Store.paperPage(.blank), at: 0)
        pdfDoc.insert(Store.paperPage(.lined), at: 1)
        let pdfData = pdfDoc.dataRepresentation()!
        try pdfData.write(to: source.appending(path: "Course/Intro.pdf"))
        try pdfData.write(to: source.appending(path: "Course/Week 1/Lecture.pdf"))
        try pdfData.write(to: source.appending(path: "Loose.pdf"))
        try Data("x".utf8).write(to: source.appending(path: "Course/notes.txt"))
        try Data().write(to: source.appending(path: "Course/.DS_Store"))
        try Data().write(to: source.appending(path: "Course/.Later.pdf.icloud"))
        let skipped = Store.importItems([source.appending(path: "Course"), source.appending(path: "Loose.pdf")], into: library)
        assert(skipped == ["Later.pdf (not downloaded)", "notes.txt"], "skipped: \(skipped)")
        func names(_ dir: URL) -> [String] { Store.list(in: dir).map { ($0.isFolder ? "/" : "") + $0.title } }
        assert(Set(names(library)) == ["/Course", "Loose"], "library: \(names(library))")
        let course = library.appending(path: "Course")
        assert(names(course) == ["/Week 1", "Intro"], "course: \(names(course))")
        assert(names(course.appending(path: "Week 1")) == ["Lecture"], "week 1: \(names(course.appending(path: "Week 1")))")
        let lecture = Notebook(folder: Store.list(in: course.appending(path: "Week 1"))[0].folder)
        assert(lecture.pdf.pageCount == 2 && lecture.drawing(at: 1).strokes.isEmpty, "imported notebook opens with its pages")
        _ = Store.importItems([source.appending(path: "Course")], into: library)
        assert(Set(names(library)) == ["/Course", "/Course 2", "Loose"], "re-import gets a new name: \(names(library))")

        // Rename and move.
        let loose = Store.list(in: library).first { $0.title == "Loose" }!
        try Store.rename(loose, to: "  Physics  ")
        let courseBook = Store.list(in: library).first { $0.title == "Course" }!
        try Store.rename(Store.list(in: library).first { $0.title == "Course 2" }!, to: "Archive")
        assert(Set(names(library)) == ["/Archive", "/Course", "Physics"], "renamed: \(names(library))")
        try Store.move(Store.list(in: library).first { $0.title == "Physics" }!, to: course)
        assert(names(course).contains("Physics"), "moved notebook: \(names(course))")
        var refused = false
        do { try Store.move(courseBook, to: course.appending(path: "Week 1")) } catch { refused = true }
        assert(refused, "a folder can't move into its own subfolder")
        assert(Store.allFolders(in: library).map(\.lastPathComponent) == ["Archive", "Week 1", "Course", "Week 1"],
               "all folders: \(Store.allFolders(in: library).map(\.lastPathComponent))")

        // Tool settings persist, and a saved preset color still matches its preset.
        let defaults = UserDefaults(suiteName: "notebook-check-\(UUID())")!
        let saved = Tools(defaults: defaults)
        saved.tool = .highlighter
        saved.highlighter = Style(color: Tools.pink, width: 35)
        saved.shapeStyle.width = 3
        saved.save()
        let loaded = Tools(defaults: defaults)
        assert(loaded.tool == .highlighter && loaded.highlighter.width == 35 && loaded.shapeStyle.width == 3, "tools reload")
        assert(loaded.colorPresets.contains(loaded.highlighter.color), "reloaded color equals its preset")

        // Scribble to erase.
        // Dense samples like a real Pencil stroke (sparse points get smoothed away by the spline).
        func ink(_ corners: [CGPoint]) -> PKStroke {
            let points = zip(corners, corners.dropFirst()).flatMap { p, q in
                let n = max(1, Int(hypot(q.x - p.x, q.y - p.y) / 2))
                return (0..<n).map { k in CGPoint(x: p.x + (q.x - p.x) * CGFloat(k) / CGFloat(n), y: p.y + (q.y - p.y) * CGFloat(k) / CGFloat(n)) }
            } + [corners.last!]
            let samples = points.enumerated().map { i, p in
                PKStrokePoint(location: p, timeOffset: Double(i) * 0.01, size: CGSize(width: 4, height: 4), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
            }
            return PKStroke(ink: PKInk(.pen, color: .black), path: PKStrokePath(controlPoints: samples, creationDate: Date()))
        }
        // Passes back and forth across `x`, drifting from y 40 to 60 so any pass count covers the word at y≈50.
        func zigzag(x: ClosedRange<CGFloat>, passes: Int) -> PKStroke {
            ink((0...passes).map { CGPoint(x: $0 % 2 == 0 ? x.lowerBound : x.upperBound, y: 40 + 20 * CGFloat($0) / CGFloat(passes)) })
        }
        let word = ink(stride(from: 20.0, through: 80.0, by: 5.0).map { CGPoint(x: $0, y: 50 + sin($0) * 4) })
        let neighbour = ink(stride(from: 200.0, through: 260.0, by: 5.0).map { CGPoint(x: $0, y: 50) })
        let scribbled = Scribble.erase(in: PKDrawing(strokes: [word, neighbour, zigzag(x: 15...85, passes: 6)]))
        assert(scribbled?.strokes.count == 1, "scribble removes the covered word and itself, keeps the neighbour")
        assert(Scribble.erase(in: PKDrawing(strokes: [word, zigzag(x: 300...370, passes: 6)])) == nil, "scribble over nothing stays ink")
        assert(Scribble.erase(in: PKDrawing(strokes: [word, zigzag(x: 15...85, passes: 2)])) == nil, "a couple of passes isn't a scribble")
        let mmm = ink((0...12).map { CGPoint(x: 20 + CGFloat($0) * 5, y: $0 % 2 == 0 ? 60 : 40) })
        assert(!Scribble.isScribble(mmm), "handwriting like 'mmm' isn't a scribble")

        // Tabs: open/select/close, follow renames and moves, survive relaunch.
        let tabDefaults = UserDefaults(suiteName: "notebook-check-tabs-\(UUID())")!
        let tabs = Tabs(defaults: tabDefaults, root: library)
        let intro = Store.list(in: course).first { $0.title == "Intro" }!.folder
        let physics = Store.list(in: course).first { $0.title == "Physics" }!.folder
        tabs.open(intro)
        tabs.open(physics)
        tabs.open(intro)
        assert(tabs.open == ["Course/\(intro.lastPathComponent)", "Course/\(physics.lastPathComponent)"], "no duplicate tabs: \(tabs.open)")
        assert(tabs.selected == tabs.open[0], "reopening selects the existing tab")
        let renamed = try Store.rename(courseBook, to: "Semester 1")
        tabs.relocate(from: courseBook.folder, to: renamed)
        assert(tabs.open.allSatisfy { $0.hasPrefix("Semester 1/") } && tabs.open.allSatisfy { Store.isNotebook(tabs.url($0)) },
               "tabs follow a folder rename: \(tabs.open)")
        let relaunched = Tabs(defaults: tabDefaults, root: library)
        assert(relaunched.open == tabs.open && relaunched.selected == tabs.selected, "tabs restore after relaunch")
        tabs.close(tabs.open[0])
        assert(tabs.open.count == 1 && tabs.selected == tabs.open[0], "closing the selected tab selects its neighbour")
        try Store.delete(Store.list(in: renamed).first { $0.title == "Physics" }!)
        tabs.prune()
        assert(tabs.open.isEmpty && tabs.selected == nil, "deleting a notebook closes its tab")

        // Page reorder, bookmarks, outline, notebook paper, covers and search.
        let features = root.appending(path: "features")
        try fm.createDirectory(at: features, withIntermediateDirectories: true)
        let textPDF = PDFDocument(data: UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792)).pdfData { ctx in
            for word in ["Photosynthesis", "Mitochondria", "Ribosome"] {
                ctx.beginPage()
                NSString(string: word).draw(at: CGPoint(x: 72, y: 72), withAttributes: [.font: UIFont.systemFont(ofSize: 24)])
            }
        })!
        try Store.create(title: "Biology", paper: .lined, pdf: textPDF, in: features)
        let bio = Store.list(in: features)[0].folder
        nb = Notebook(folder: bio)
        let ids = nb.pages
        nb.setDrawing(strokes(5), at: 2)
        nb.toggleBookmark(2)
        nb.addOutline("Ribosomes", page: 2, y: 500)
        nb.addOutline("Intro", page: 0, y: nil)
        nb.movePage(from: 2, to: 0)
        nb.saveInk()
        nb = Notebook(folder: bio)
        assert(nb.pages == [ids[2], ids[0], ids[1]], "move reorders page ids")
        assert(nb.pdf.page(at: 0)?.string?.contains("Ribosome") == true, "move reorders PDF pages")
        assert(counts(nb) == [5, 0, 0], "ink follows its page: \(counts(nb))")
        assert(nb.isBookmarked(0) && !nb.isBookmarked(2), "bookmark follows its page")
        assert(nb.sortedOutline.map(\.title) == ["Ribosomes", "Intro"], "outline in page order: \(nb.sortedOutline.map(\.title))")

        // Paper: paper.pdf decides what new pages look like.
        let custom = PDFDocument(data: UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 400, height: 500)).pdfData { $0.beginPage() })!
        try custom.dataRepresentation()!.write(to: bio.appending(path: "paper.pdf"))
        nb.addPage(at: 3)
        assert(nb.pdf.page(at: 3)?.bounds(for: .cropBox).size == CGSize(width: 400, height: 500), "new page uses paper.pdf")

        // Deleting a page drops its bookmark and outline entries.
        nb.deletePage(at: 0)
        nb.close()
        nb = Notebook(folder: bio)
        assert(nb.bookmarks.isEmpty && nb.outline.map(\.title) == ["Intro"], "delete cleans bookmarks/outline")

        // Search: PDF text and titles, by page; deleted pages drop out of the index.
        SearchIndex.rebuild(bio, pages: nil)
        let photo = SearchIndex.search("photosynth", in: features)
        assert(photo.count == 1 && photo[0].page == 0 && photo[0].snippet.contains("Photosynthesis"), "finds PDF text on its page: \(photo)")
        assert(SearchIndex.search("ribosome", in: features).isEmpty, "deleted page no longer matches")
        assert(SearchIndex.search("BIOLOGY", in: features).first?.page == nil, "title match, case-insensitive")
        Store.setLastPage(1, of: bio)
        assert(Notebook(folder: bio).lastPage == 1, "search hit opens at its page")

        // Covers are cached and invalidated by close() after a change.
        let cover = Store.coverURL(bio)
        assert(Store.cover(of: bio) != nil && fm.fileExists(atPath: cover.path), "cover saved")
        nb = Notebook(folder: bio)
        nb.close()
        assert(fm.fileExists(atPath: cover.path), "close without changes keeps the cover")
        nb.setDrawing(strokes(1), at: 0)
        nb.close()
        assert(!fm.fileExists(atPath: cover.path), "close after a change invalidates the cover")

        // Folder style.
        try Store.createFolder(named: "Physics", in: features)
        let physicsDir = features.appending(path: "Physics")
        try Store.setFolderStyle(FolderStyle(color: "green", symbol: "flask.fill"), of: physicsDir)
        let physicsTile = Store.list(in: features).first { $0.isFolder }!
        assert(physicsTile.style == FolderStyle(color: "green", symbol: "flask.fill"), "folder style round trip")
        assert(Store.allNotebooks(in: features) == [bio] || Store.allNotebooks(in: features).map(\.lastPathComponent) == [bio.lastPathComponent],
               "hidden .folder.json isn't a notebook")

        // Pages fill the view's width, in landscape too.
        let wide = PDFDocument()
        wide.insert(PDFDocument(data: UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 800, height: 842)).pdfData { $0.beginPage() })!.page(at: 0)!, at: 0)
        let pdfView = FitWidthPDFView(frame: CGRect(x: 0, y: 0, width: 1180, height: 700))
        pdfView.displayMode = .singlePageContinuous
        pdfView.document = wide
        pdfView.layoutIfNeeded()
        let expected = (1180 - pdfView.pageBreakMargins.left - pdfView.pageBreakMargins.right) / 800
        assert(abs(pdfView.scaleFactor - expected) < 0.001, "landscape fits width: \(pdfView.scaleFactor) vs \(expected)")
        pdfView.frame.size = CGSize(width: 820, height: 1100)
        pdfView.layoutIfNeeded()
        assert(abs(pdfView.scaleFactor - (820 - pdfView.pageBreakMargins.left - pdfView.pageBreakMargins.right) / 800) < 0.001, "refits after rotation")

        // Pen widths: switching pen type keeps the step; stale saved widths snap to medium.
        let penTools = Tools(defaults: UserDefaults(suiteName: "notebook-check-pen-\(UUID())")!)
        penTools.pen.width = Tools.penWidths(.ballpoint)[2]
        penTools.penType = .fountain
        assert(penTools.pen.width == Tools.penWidths(.fountain)[2], "pen type switch keeps the thick step")
        let staleDefaults = UserDefaults(suiteName: "notebook-check-stale-\(UUID())")!
        let stale = Tools(defaults: staleDefaults)
        stale.pen.width = 1.5
        stale.save()
        assert(Tools(defaults: staleDefaults).pen.width == Tools.penWidths(.ballpoint)[1], "old saved width snaps to medium")

        // Text boxes and arrows.
        let edge = PageItems.edge(of: CGRect(x: 0, y: 0, width: 100, height: 50), toward: CGPoint(x: 300, y: 25))
        assert(abs(edge.x - 104) < 0.01 && abs(edge.y - 25) < 0.01, "arrow leaves the box at its padded right edge: \(edge)")
        let corner = PageItems.edge(of: CGRect(x: 0, y: 0, width: 100, height: 100), toward: CGPoint(x: 200, y: 200))
        assert(abs(corner.x - 104) < 0.01 && abs(corner.y - 104) < 0.01, "diagonal leaves through the corner: \(corner)")
        nb = Notebook(folder: bio)
        let boxA = TextBox(frame: CGRect(x: 40, y: 40, width: 200, height: 30), text: "Enzyme kinetics")
        let boxB = TextBox(frame: CGRect(x: 40, y: 200, width: 200, height: 30), text: "Michaelis–Menten")
        let typed = PageItems(boxes: [boxA, boxB], connectors: [Connector(from: boxA.id, to: boxB.id)])
        nb.setItems(typed, at: 1)
        assert(Notebook(folder: bio).items(at: 1) == typed, "text boxes round trip")
        let arrow = typed.arrow(typed.connectors[0])!
        assert(arrow.from.y < arrow.to.y && abs(arrow.from.y - 74) < 0.01 && abs(arrow.to.y - 196) < 0.01, "arrow runs box edge to box edge: \(arrow)")
        SearchIndex.rebuild(bio, pages: nil)
        assert(SearchIndex.search("menten", in: features).first?.page == 1, "typed text is searchable")
        nb.setItems(PageItems(), at: 1)
        assert(!fm.fileExists(atPath: bio.appending(path: "items/\(nb.pages[1].uuidString).json").path), "empty page drops its items file")
        nb.setItems(typed, at: 1)
        let typedID = nb.pages[1]
        nb.deletePage(at: 1)
        assert(!fm.fileExists(atPath: bio.appending(path: "items/\(typedID.uuidString).json").path), "deleting a page removes its text boxes")

        print("NotebookCheck passed")
    }
}
