import PDFKit
import PencilKit

/// Page/ink bookkeeping and shape geometry checks: run with scripts/check.sh.
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

        let exported = try nb.exportPDF()
        assert(PDFDocument(url: exported)?.pageCount == 2, "export has every page")
        // Shapes: ink bounds match the dragged box (within stroke width + spline slack).
        let a = CGPoint(x: 10, y: 10), b = CGPoint(x: 110, y: 60)
        func bounds(_ shape: ShapeKind) -> CGRect { PKDrawing(strokes: shape.strokes(from: a, to: b, color: .black, width: 2)).bounds }
        func near(_ r: CGRect, _ expected: CGRect) -> Bool {
            [r.minX - expected.minX, r.minY - expected.minY, r.maxX - expected.maxX, r.maxY - expected.maxY].allSatisfy { abs($0) <= 3 }
        }
        let box = CGRect(x: 10, y: 10, width: 100, height: 50)
        assert(near(bounds(.rectangle), box), "rectangle bounds: \(bounds(.rectangle))")
        assert(near(bounds(.ellipse), box), "ellipse bounds: \(bounds(.ellipse))")
        assert(ShapeKind.arrow.strokes(from: a, to: b, color: .black, width: 2).count == 2, "arrow is shaft + head")
        assert(ShapeKind.rectangle.polylines(from: a, to: b, width: 2)[0].last == a, "rectangle closes")

        print("NotebookCheck passed")
    }
}
