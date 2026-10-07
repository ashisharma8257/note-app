import PDFKit
import PencilKit
import SwiftUI

enum Paper: String, Codable, CaseIterable { case blank, lined, grid }

struct Meta: Codable {
    var title: String
    var paper: Paper
    var pages: [UUID]? // page ids in PDF page order; nil for notebooks not yet assigned ids
}

/// A library entry: a notebook (directory with meta.json) or a plain folder of entries.
struct Book: Identifiable, Hashable {
    let folder: URL
    let title: String
    let modified: Date
    let isFolder: Bool
    var id: URL { folder }
}

/// A notebook is a directory (anywhere under Documents): meta.json, doc.pdf (page backgrounds),
/// and ink/<page id>.data (one PKDrawing per page, so a save only writes the pages that changed).
final class Notebook: ObservableObject {
    let folder: URL
    let pdf: PDFDocument
    let paper: Paper
    @Published var title: String { didSet { saveMeta() } }
    weak var pdfView: PDFView?
    private var pages: [UUID]
    /// Edited drawings not yet on disk.
    private var unsaved: [UUID: PKDrawing] = [:]
    private var saveTask: Task<Void, Never>?

    init(folder: URL) {
        self.folder = folder
        pdf = PDFDocument(url: folder.appending(path: "doc.pdf")) ?? PDFDocument()
        let meta = (try? JSONDecoder().decode(Meta.self, from: Data(contentsOf: folder.appending(path: "meta.json"))))
            ?? Meta(title: "Untitled", paper: .blank)
        title = meta.title
        paper = meta.paper
        pages = meta.pages ?? []
        try? FileManager.default.createDirectory(at: folder.appending(path: "ink"), withIntermediateDirectories: true)
        // Pad only, never truncate: a PDF that fails to load must not drop page ids.
        if pages.count < pdf.pageCount {
            pages += (pages.count..<pdf.pageCount).map { _ in UUID() }
            saveMeta()
        }
    }

    /// nil for a page no longer in the document (index(for:) returns NSNotFound).
    func index(of page: PDFPage) -> Int? {
        let i = pdf.index(for: page)
        return i < pages.count ? i : nil
    }

    var currentIndex: Int? { pdfView?.currentPage.flatMap(index(of:)) }

    func drawing(at i: Int) -> PKDrawing {
        let id = pages[i]
        if let drawing = unsaved[id] { return drawing }
        return (try? PKDrawing(data: Data(contentsOf: inkURL(id)))) ?? PKDrawing()
    }

    func setDrawing(_ drawing: PKDrawing, at i: Int) {
        unsaved[pages[i]] = drawing
        scheduleSave()
    }

    // ponytail: doc.pdf and meta.json are two writes; a crash between them misaligns ink from that page on (ink files survive)
    func addPage(at i: Int) {
        let page = Store.paperPage(paper)
        pages.insert(UUID(), at: i)
        pdf.insert(page, at: i)
        savePDF()
        saveMeta()
        pdfView?.go(to: page)
    }

    func deletePage(at i: Int) {
        guard pdf.pageCount > 1, i < pdf.pageCount else { return }
        pdf.removePage(at: i)
        let id = pages.remove(at: i)
        unsaved[id] = nil
        savePDF()
        saveMeta()
        try? FileManager.default.removeItem(at: inkURL(id))
    }

    func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            if !Task.isCancelled { saveInk() }
        }
    }

    /// Writes only edited pages; a page whose write fails stays pending for the next save.
    func saveInk() {
        saveTask?.cancel()
        for (id, drawing) in unsaved where save(inkURL(id), { drawing.dataRepresentation() }) {
            unsaved[id] = nil
        }
    }

    private func inkURL(_ id: UUID) -> URL { folder.appending(path: "ink/\(id.uuidString).data") }

    private func saveMeta() {
        save(folder.appending(path: "meta.json")) { try JSONEncoder().encode(Meta(title: title, paper: paper, pages: pages)) }
    }

    private func savePDF() {
        save(folder.appending(path: "doc.pdf")) {
            guard let data = pdf.dataRepresentation() else { throw CocoaError(.fileWriteUnknown) }
            return data
        }
    }

    @discardableResult
    private func save(_ url: URL, _ data: () throws -> Data) -> Bool {
        do { try data().write(to: url, options: .atomic); return true }
        catch { print("Saving \(url.lastPathComponent) failed: \(error)"); return false } // ponytail: console only, surface in UI if it ever happens
    }

    /// Flattens pages + ink into a shareable PDF. Ink is rasterized at 3x.
    func exportPDF() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: title.replacingOccurrences(of: "/", with: "-") + ".pdf")
        try UIGraphicsPDFRenderer(bounds: .zero).writePDF(to: url) { ctx in
            for i in 0..<pdf.pageCount {
                guard let page = pdf.page(at: i) else { continue }
                let rect = CGRect(origin: .zero, size: page.bounds(for: .cropBox).size)
                ctx.beginPage(withBounds: rect, pageInfo: [:])
                let cg = ctx.cgContext
                cg.saveGState()
                cg.translateBy(x: 0, y: rect.height)
                cg.scaleBy(x: 1, y: -1)
                page.draw(with: .cropBox, to: cg)
                cg.restoreGState()
                // Light traits so black ink doesn't export as white when the iPad is in dark mode.
                UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
                    drawing(at: i).image(from: rect, scale: 3).draw(in: rect)
                }
            }
        }
        return url
    }
}

enum Store {
    static func isNotebook(_ dir: URL) -> Bool {
        FileManager.default.fileExists(atPath: dir.appending(path: "meta.json").path)
    }

    /// Folders first (by name), then notebooks (newest first).
    static func list(in dir: URL) -> [Book] {
        let dirs = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey], options: .skipsHiddenFiles)) ?? []
        return dirs.compactMap { dir in
            let values = try? dir.resourceValues(forKeys: [.contentModificationDateKey, .isDirectoryKey])
            guard values?.isDirectory == true else { return nil }
            let modified = values?.contentModificationDate ?? .distantPast
            guard let data = try? Data(contentsOf: dir.appending(path: "meta.json")) else {
                return Book(folder: dir, title: dir.lastPathComponent, modified: modified, isFolder: true)
            }
            guard let meta = try? JSONDecoder().decode(Meta.self, from: data) else { return nil }
            return Book(folder: dir, title: meta.title, modified: modified, isFolder: false)
        }
        .sorted {
            if $0.isFolder != $1.isFolder { return $0.isFolder }
            return $0.isFolder ? $0.title.localizedStandardCompare($1.title) == .orderedAscending : $0.modified > $1.modified
        }
    }

    static func create(title: String, paper: Paper, pdf: PDFDocument, in parent: URL) throws {
        let dir = parent.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let data = pdf.dataRepresentation() else { throw CocoaError(.fileWriteUnknown) }
        try data.write(to: dir.appending(path: "doc.pdf"))
        let pages = (0..<pdf.pageCount).map { _ in UUID() }
        try JSONEncoder().encode(Meta(title: title, paper: paper, pages: pages)).write(to: dir.appending(path: "meta.json"))
    }

    static func createFolder(named name: String, in parent: URL) throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.hasPrefix("."), !name.contains("/") else { throw CocoaError(.fileWriteInvalidFileName) }
        try FileManager.default.createDirectory(at: parent.appending(path: name), withIntermediateDirectories: false)
    }

    static func delete(_ book: Book) throws { try FileManager.default.removeItem(at: book.folder) }

    // ponytail: retains every generated source doc for the session so inserted pages never lose their backing document
    private static var keepAlive: [PDFDocument] = []

    /// One US Letter page of the given paper, drawn as vector PDF.
    static func paperPage(_ paper: Paper) -> PDFPage {
        let rect = CGRect(x: 0, y: 0, width: 612, height: 792)
        let data = UIGraphicsPDFRenderer(bounds: rect).pdfData { ctx in
            ctx.beginPage()
            let path = UIBezierPath()
            func line(_ a: CGPoint, _ b: CGPoint) { path.move(to: a); path.addLine(to: b) }
            switch paper {
            case .blank:
                break
            case .lined:
                for y in stride(from: 72.0, to: rect.maxY - 24, by: 24) { line(CGPoint(x: 0, y: y), CGPoint(x: rect.maxX, y: y)) }
            case .grid:
                for y in stride(from: 20.0, to: rect.maxY, by: 20) { line(CGPoint(x: 0, y: y), CGPoint(x: rect.maxX, y: y)) }
                for x in stride(from: 20.0, to: rect.maxX, by: 20) { line(CGPoint(x: x, y: 0), CGPoint(x: x, y: rect.maxY)) }
            }
            UIColor(white: 0.78, alpha: 1).setStroke()
            path.lineWidth = 0.5
            path.stroke()
        }
        let doc = PDFDocument(data: data)!
        keepAlive.append(doc)
        return doc.page(at: 0)!
    }
}
