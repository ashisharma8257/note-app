import PDFKit
import PencilKit
import SwiftUI

enum Paper: String, Codable, CaseIterable { case blank, lined, grid, dotted }

/// A titled jump to a spot on a page.
struct OutlineEntry: Codable, Identifiable, Hashable {
    var id = UUID()
    var title: String
    var page: UUID
    var y: CGFloat? // PDF page coordinates (origin bottom-left); nil means the top of the page
}

struct Meta: Codable {
    var title: String
    var paper: Paper
    var pages: [UUID]? // page ids in PDF page order; nil for notebooks not yet assigned ids
    var lastPage: Int? // page to reopen at
    var bookmarks: [UUID]? // bookmarked page ids
    var outline: [OutlineEntry]?
}

/// A folder's look in the library, stored as .folder.json inside it.
struct FolderStyle: Codable, Hashable {
    var color: String?
    var symbol: String?

    static let colors = ["blue", "red", "orange", "yellow", "green", "teal", "purple", "pink", "gray"]
    static let symbols = ["folder.fill", "star.fill", "book.fill", "briefcase.fill", "graduationcap.fill",
                          "heart.fill", "lightbulb.fill", "flask.fill"]
}

/// A library entry: a notebook, board or text document (directory with meta.json) or a plain folder of entries.
struct Book: Identifiable, Hashable {
    let folder: URL
    let title: String
    let modified: Date
    let isFolder: Bool
    var style = FolderStyle()
    var id: URL { folder }
}

/// A notebook is a directory (anywhere in the library, Store.root): meta.json, doc.pdf (page backgrounds),
/// ink/<page id>.data (one PKDrawing per page, so a save only writes the pages that changed),
/// items/<page id>.json (typed text boxes and arrows, for pages that have any),
/// and optionally paper.pdf (the paper new pages use after a page that isn't paper), cover.jpg and search.json (both caches).
final class Notebook: ObservableObject {
    let folder: URL
    let pdf: PDFDocument
    let paper: Paper
    @Published var title: String { didSet { saveMeta() } }
    @Published private(set) var bookmarks: [UUID]
    @Published private(set) var outline: [OutlineEntry]
    @Published var currentPage = 0
    private(set) var lastPage: Int
    weak var pdfView: PDFView?
    /// Set by the page view: clears a page's ink and text boxes as one undo step.
    var clearPage: ((Int) -> Void)?
    private(set) var pages: [UUID]
    /// Edited drawings not yet on disk.
    private var unsaved: [UUID: PKDrawing] = [:]
    private var saveTask: Task<Void, Never>?
    /// Pages whose ink changed since opening, and whether pages were added, moved or deleted:
    /// close() refreshes the cover and search index only when one of these is set.
    private var changedPages = Set<UUID>()
    private var structureChanged = false

    init(folder: URL) {
        self.folder = folder
        pdf = PDFDocument(url: folder.appending(path: "doc.pdf")) ?? PDFDocument()
        let saved = try? JSONDecoder().decode(Meta.self, from: Data(contentsOf: folder.appending(path: "meta.json")))
        let meta = saved ?? Meta(title: "Untitled", paper: .blank)
        title = meta.title
        paper = meta.paper
        lastPage = meta.lastPage ?? 0
        bookmarks = meta.bookmarks ?? []
        outline = meta.outline ?? []
        pages = meta.pages ?? []
        try? FileManager.default.createDirectory(at: folder.appending(path: "ink"), withIntermediateDirectories: true)
        // Pad only, never truncate: a PDF that fails to load must not drop page ids. Without a meta.json read (one
        // iCloud hasn't downloaded yet) the ids stay in memory, so the real one isn't overwritten.
        if pages.count < pdf.pageCount {
            pages += (pages.count..<pdf.pageCount).map { _ in UUID() }
            if saved != nil { saveMeta() }
        }
    }

    /// nil for a page no longer in the document (index(for:) returns NSNotFound).
    func index(of page: PDFPage) -> Int? {
        let i = pdf.index(for: page)
        return i < pages.count ? i : nil
    }

    var currentIndex: Int? { pdfView?.currentPage.flatMap(index(of:)) }

    /// Saves pending ink and the page being viewed (so the notebook reopens there), then refreshes
    /// the cover and, in the background, the search index for what changed.
    func close() {
        saveInk()
        // Only the page goes into meta.json as it is on disk: when another device changed the notebook, this one
        // closes to reopen with that change, and the rest of what it holds is out of date.
        if let i = currentIndex, i != lastPage {
            lastPage = i
            Store.setLastPage(i, of: folder)
        }
        guard !changedPages.isEmpty || structureChanged else { return }
        try? FileManager.default.removeItem(at: Store.coverURL(folder))
        SearchIndex.update(folder, pages: changedPages)
        changedPages = []
        structureChanged = false
    }

    func index(of id: UUID) -> Int? { pages.firstIndex(of: id) }

    func isBookmarked(_ i: Int) -> Bool { i < pages.count && bookmarks.contains(pages[i]) }

    func toggleBookmark(_ i: Int) {
        guard i < pages.count else { return }
        if let k = bookmarks.firstIndex(of: pages[i]) { bookmarks.remove(at: k) } else { bookmarks.append(pages[i]) }
        saveMeta()
    }

    func addOutline(_ title: String, page i: Int, y: CGFloat?) {
        guard i < pages.count, !title.isEmpty else { return }
        outline.append(OutlineEntry(title: title, page: pages[i], y: y))
        saveMeta()
    }

    func removeOutline(_ entry: OutlineEntry) {
        outline.removeAll { $0.id == entry.id }
        saveMeta()
    }

    /// Outline in reading order: by page, then top to bottom.
    var sortedOutline: [OutlineEntry] {
        outline.compactMap { entry in index(of: entry.page).map { (entry, $0) } }
            .sorted { $0.1 != $1.1 ? $0.1 < $1.1 : ($0.0.y ?? .infinity) > ($1.0.y ?? .infinity) }
            .map(\.0)
    }

    func go(to entry: OutlineEntry) {
        guard let i = index(of: entry.page), let page = pdf.page(at: i) else { return }
        if let y = entry.y {
            pdfView?.go(to: PDFDestination(page: page, at: CGPoint(x: 0, y: y)))
        } else {
            pdfView?.go(to: page)
        }
    }

    /// The top of the visible area on the current page, in PDF coordinates.
    var visibleY: CGFloat? {
        guard let destination = pdfView?.currentDestination, destination.page == pdfView?.currentPage else { return nil }
        return destination.point.y
    }

    func drawing(at i: Int) -> PKDrawing {
        let id = pages[i]
        if let drawing = unsaved[id] { return drawing }
        return (try? PKDrawing(data: Data(contentsOf: inkURL(id)))) ?? PKDrawing()
    }

    func setDrawing(_ drawing: PKDrawing, at i: Int) {
        unsaved[pages[i]] = drawing
        changedPages.insert(pages[i])
        scheduleSave()
    }

    /// Ink alone on white, for handwriting recognition; nil for a page without ink.
    func inkImage(at i: Int) -> CGImage? {
        let drawing = drawing(at: i)
        guard !drawing.strokes.isEmpty, let page = pdf.page(at: i) else { return nil }
        let box = CGRect(origin: .zero, size: page.bounds(for: .cropBox).size)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        return UIGraphicsImageRenderer(size: box.size, format: format).image { _ in
            UIColor.white.setFill()
            UIRectFill(box)
            UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
                drawing.image(from: box, scale: 2).draw(in: box)
            }
        }.cgImage
    }

    // ponytail: doc.pdf and meta.json are two writes; a crash between them misaligns ink from that page on (ink files survive)
    /// A new page repeats the paper of the page before it (lined, grid, a GoodNotes template); after a page of a
    /// document, or at the start, it gets the notebook's paper.
    func addPage(at i: Int) {
        let above = i > 0 ? pdf.page(at: i - 1) : nil
        let page = above.flatMap { Store.isPaper($0) ? $0.copy() as? PDFPage : nil } ?? Store.paperPage(for: folder) ?? Store.paperPage(paper)
        pages.insert(UUID(), at: i)
        pdf.insert(page, at: i)
        structureChanged = true
        savePDF()
        saveMeta()
        objectWillChange.send()
        pdfView?.go(to: page)
    }

    /// Moves a page; its ink, bookmark and outline entries follow because they're keyed by page id.
    func movePage(from: Int, to: Int) {
        guard from != to, from < pdf.pageCount, to < pdf.pageCount, let page = pdf.page(at: from) else { return }
        // Ids and PDF change in step, as in deletePage.
        let id = pages.remove(at: from)
        pdf.removePage(at: from)
        pages.insert(id, at: to)
        pdf.insert(page, at: to)
        structureChanged = true
        savePDF()
        saveMeta()
        objectWillChange.send()
    }

    /// Deleting the only page leaves a fresh page in its place.
    func deletePage(at i: Int) {
        guard i < pdf.pageCount else { return }
        if pdf.pageCount == 1 { addPage(at: 1) }
        // The id goes first: while the page is being removed, PDFView asks for the overlays (ink and text boxes) of
        // the pages that move up, looking them up by index.
        let id = pages.remove(at: i)
        pdf.removePage(at: i)
        unsaved[id] = nil
        changedPages.remove(id)
        bookmarks.removeAll { $0 == id }
        outline.removeAll { $0.page == id }
        structureChanged = true
        savePDF()
        saveMeta()
        objectWillChange.send()
        try? FileManager.default.removeItem(at: inkURL(id))
        try? FileManager.default.removeItem(at: itemsURL(id))
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
    private func itemsURL(_ id: UUID) -> URL { folder.appending(path: "items/\(id.uuidString).json") }

    private func saveMeta() {
        save(folder.appending(path: "meta.json")) {
            try JSONEncoder().encode(Meta(title: title, paper: paper, pages: pages, lastPage: lastPage,
                                          bookmarks: bookmarks, outline: outline))
        }
    }

    private func savePDF() {
        save(folder.appending(path: "doc.pdf")) {
            guard let data = pdf.dataRepresentation() else { throw CocoaError(.fileWriteUnknown) }
            return data
        }
    }

    @discardableResult
    private func save(_ url: URL, _ data: () throws -> Data) -> Bool {
        do { try Store.write(data(), to: url); return true }
        catch { print("Saving \(url.lastPathComponent) failed: \(error)"); return false } // ponytail: console only, surface in UI if it ever happens
    }

    func goToPage(_ i: Int) {
        if let page = pdf.page(at: i) { pdfView?.go(to: page) }
    }

    /// Page background with its ink, text boxes and arrows, `width` points wide.
    func thumbnail(at i: Int, width: CGFloat) -> UIImage? {
        guard let page = pdf.page(at: i) else { return nil }
        let box = CGRect(origin: .zero, size: page.bounds(for: .cropBox).size)
        let size = CGSize(width: width, height: width * box.height / box.width)
        let background = page.thumbnail(of: size, for: .cropBox)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            background.draw(in: CGRect(origin: .zero, size: size))
            UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
                drawing(at: i).image(from: box, scale: 2 * width / box.width).draw(in: CGRect(origin: .zero, size: size))
            }
            ctx.cgContext.scaleBy(x: width / box.width, y: width / box.width)
            items(at: i).draw()
        }
    }

    /// Typed text boxes and arrows on page `i`.
    func items(at i: Int) -> PageItems {
        (try? JSONDecoder().decode(PageItems.self, from: Data(contentsOf: itemsURL(pages[i])))) ?? PageItems()
    }

    func setItems(_ items: PageItems, at i: Int) {
        let id = pages[i]
        changedPages.insert(id)
        if items.isEmpty {
            try? FileManager.default.removeItem(at: itemsURL(id))
        } else {
            try? FileManager.default.createDirectory(at: folder.appending(path: "items"), withIntermediateDirectories: true)
            save(itemsURL(id)) { try JSONEncoder().encode(items) }
        }
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
                items(at: i).draw()
            }
        }
        return url
    }
}

enum Store {
    /// True for notebooks, boards and text documents: they all open in a tab.
    static func isNotebook(_ dir: URL) -> Bool {
        exists(dir.appending(path: "meta.json"))
    }

    /// A board is a directory with meta.json (its title) and board.excalidraw (the Excalidraw scene), plus cover.jpg
    /// once it has been drawn on.
    static func boardFile(_ dir: URL) -> URL { dir.appending(path: "board.excalidraw") }

    /// The Excalidraw library (saved shapes), shared by every board; hidden, so the library list skips it.
    static var boardLibrary: URL { root.appending(path: libraryName) }
    static let libraryName = ".library.excalidrawlib"

    static func isBoard(_ dir: URL) -> Bool { exists(boardFile(dir)) }

    /// A text document is a directory with meta.json (its title) and text.txt (its body, lists written the way
    /// TextLists reads them).
    static func textFile(_ dir: URL) -> URL { dir.appending(path: "text.txt") }

    static func isTextDocument(_ dir: URL) -> Bool { exists(textFile(dir)) }

    /// Returns the new document.
    @discardableResult
    static func createTextDocument(title: String, in parent: URL) throws -> URL {
        let dir = parent.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data().write(to: textFile(dir))
        try JSONEncoder().encode(Meta(title: title, paper: .blank, pages: [])).write(to: dir.appending(path: "meta.json"))
        return dir
    }

    static func createBoard(title: String, in parent: URL) throws {
        let dir = parent.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(#"{"type":"excalidraw","version":2,"source":"Notes","elements":[],"appState":{},"files":{}}"#.utf8).write(to: boardFile(dir))
        try JSONEncoder().encode(Meta(title: title, paper: .blank, pages: [])).write(to: dir.appending(path: "meta.json"))
    }

    static func meta(of notebook: URL) -> Meta? {
        try? JSONDecoder().decode(Meta.self, from: Data(contentsOf: notebook.appending(path: "meta.json")))
    }

    static func title(of notebook: URL) -> String { meta(of: notebook)?.title ?? "Untitled" }

    /// Makes the notebook open at page `i` next time.
    static func setLastPage(_ i: Int, of notebook: URL) {
        guard var meta = meta(of: notebook) else { return }
        meta.lastPage = i
        try? write(JSONEncoder().encode(meta), to: notebook.appending(path: "meta.json"))
    }

    /// Every notebook under `root`, at any depth.
    static func allNotebooks(in root: URL) -> [URL] {
        list(in: root).flatMap { $0.isFolder ? allNotebooks(in: $0.folder) : [$0.folder] }
    }

    static func folderStyle(_ folder: URL) -> FolderStyle {
        (try? JSONDecoder().decode(FolderStyle.self, from: Data(contentsOf: folder.appending(path: ".folder.json")))) ?? FolderStyle()
    }

    static func setFolderStyle(_ style: FolderStyle, of folder: URL) throws {
        try JSONEncoder().encode(style).write(to: folder.appending(path: ".folder.json"), options: .atomic)
    }

    static func coverURL(_ notebook: URL) -> URL { notebook.appending(path: "cover.jpg") }

    /// Page 1 as a cover image, from cover.jpg or rendered and saved there. Notebook.close() and text documents
    /// delete the file after changes, so the next request redraws it. A board writes its own cover.jpg as it saves.
    /// Nil until iCloud has downloaded the whole document.
    static func cover(of notebook: URL) -> UIImage? {
        if !isMissing(coverURL(notebook)), let image = UIImage(contentsOfFile: coverURL(notebook).path) { return image }
        guard !isBoard(notebook), requestDownloads(in: notebook).missing == 0,
              let image = isTextDocument(notebook) ? textCover(notebook, width: 280) : Notebook(folder: notebook).thumbnail(at: 0, width: 280)
        else { return nil }
        try? image.jpegData(compressionQuality: 0.85)?.write(to: coverURL(notebook), options: .atomic)
        return image
    }

    /// A text document's title and the start of its text on a white letter-size page, `width` points wide.
    private static func textCover(_ doc: URL, width: CGFloat) -> UIImage {
        let page = CGRect(x: 0, y: 0, width: 612, height: 792)
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: width * page.height / page.width)).image { ctx in
            ctx.cgContext.scaleBy(x: width / page.width, y: width / page.width)
            UIColor.white.setFill()
            UIRectFill(page)
            let text = (try? String(contentsOf: textFile(doc), encoding: .utf8)) ?? ""
            NSAttributedString(string: title(of: doc), attributes: [.font: UIFont.boldSystemFont(ofSize: 34), .foregroundColor: UIColor.black])
                .draw(in: CGRect(x: 54, y: 54, width: 504, height: 44))
            NSAttributedString(string: text, attributes: [.font: UIFont.systemFont(ofSize: 18), .foregroundColor: UIColor.black])
                .draw(in: CGRect(x: 54, y: 114, width: 504, height: 624))
        }
    }

    /// True for a page that's only vector drawing: paper (blank, lined, grid, a template) rather than a page of a
    /// document, which has text or pictures.
    static func isPaper(_ page: PDFPage) -> Bool {
        var resources: CGPDFDictionaryRef?
        guard let dict = page.pageRef?.dictionary, CGPDFDictionaryGetDictionary(dict, "Resources", &resources), let resources else { return true }
        return !hasTextOrPictures(resources)
    }

    /// Whether these PDF resources hold fonts or images, looking into nested form drawings too.
    private static func hasTextOrPictures(_ resources: CGPDFDictionaryRef, depth: Int = 0) -> Bool {
        var fonts: CGPDFDictionaryRef?
        if CGPDFDictionaryGetDictionary(resources, "Font", &fonts), let fonts, CGPDFDictionaryGetCount(fonts) > 0 { return true }
        var objects: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(resources, "XObject", &objects), let objects else { return false }
        var found = false
        CGPDFDictionaryApplyBlock(objects, { _, object, _ in
            var stream: CGPDFStreamRef?
            guard CGPDFObjectGetValue(object, .stream, &stream), let stream, let dict = CGPDFStreamGetDictionary(stream) else { return true }
            var subtype: UnsafePointer<CChar>?, inner: CGPDFDictionaryRef?
            if CGPDFDictionaryGetName(dict, "Subtype", &subtype), let subtype, String(cString: subtype) == "Image" {
                found = true
            } else if depth < 4, CGPDFDictionaryGetDictionary(dict, "Resources", &inner), let inner {
                found = hasTextOrPictures(inner, depth: depth + 1)
            }
            return !found
        }, nil)
        return found
    }

    /// The notebook's own paper (paper.pdf, e.g. a template brought over from GoodNotes), if it has one.
    static func paperPage(for notebook: URL) -> PDFPage? {
        guard let doc = PDFDocument(url: notebook.appending(path: "paper.pdf")), let page = doc.page(at: 0) else { return nil }
        keepAlive.append(doc)
        return page
    }

    /// Folders first (by name), then notebooks (newest first).
    static func list(in dir: URL) -> [Book] {
        let dirs = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey], options: .skipsHiddenFiles)) ?? []
        return dirs.compactMap { dir in
            let values = try? dir.resourceValues(forKeys: [.contentModificationDateKey, .isDirectoryKey])
            guard values?.isDirectory == true else { return nil }
            // Ink saves only touch ink/, so it counts toward the notebook's modified date.
            let inkModified = try? dir.appending(path: "ink").resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            let modified = max(values?.contentModificationDate ?? .distantPast, inkModified ?? .distantPast)
            let metaFile = dir.appending(path: "meta.json")
            guard exists(metaFile) else {
                return Book(folder: dir, title: dir.lastPathComponent, modified: modified, isFolder: true, style: folderStyle(dir))
            }
            guard !isMissing(metaFile), let data = try? Data(contentsOf: metaFile) else {
                return Book(folder: dir, title: "Downloading…", modified: modified, isFolder: false)
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

    @discardableResult
    static func createFolder(named name: String, in parent: URL) throws -> URL {
        let dir = parent.appending(path: try folderName(name))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
        return dir
    }

    static func delete(_ book: Book) throws { try FileManager.default.removeItem(at: book.folder) }

    /// Notebooks keep their directory and change the title; folders are renamed on disk.
    /// Returns where the item now lives.
    @discardableResult
    static func rename(_ book: Book, to name: String) throws -> URL {
        if book.isFolder {
            let target = book.folder.deletingLastPathComponent().appending(path: try folderName(name))
            try FileManager.default.moveItem(at: book.folder, to: target)
            return target
        }
        try setTitle(name, of: book.folder)
        return book.folder
    }

    /// Retitles a notebook, board or text document.
    static func setTitle(_ title: String, of notebook: URL) throws {
        let url = notebook.appending(path: "meta.json")
        var meta = try JSONDecoder().decode(Meta.self, from: Data(contentsOf: url))
        meta.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        try write(JSONEncoder().encode(meta), to: url)
    }

    /// Returns where the item now lives.
    @discardableResult
    static func move(_ book: Book, to parent: URL) throws -> URL {
        let source = book.folder.standardizedFileURL.path
        let destination = parent.standardizedFileURL.path
        guard destination != source, !destination.hasPrefix(source + "/") else { throw CocoaError(.fileWriteInvalidFileName) }
        let name = book.isFolder ? uniqueName(book.folder.lastPathComponent, in: parent) : book.folder.lastPathComponent
        let target = parent.appending(path: name)
        try FileManager.default.moveItem(at: book.folder, to: target)
        return target
    }

    /// Every folder under `root`, depth first, for the "Move to" list.
    static func allFolders(in root: URL) -> [URL] {
        list(in: root).filter(\.isFolder).flatMap { [$0.folder] + allFolders(in: $0.folder) }
    }

    /// Copies picked PDFs and folders into `parent`, recreating folder structure. Notebooks, boards and text documents
    /// (from this app's library on another device, say) come in whole, ink and all, and folders keep their look.
    /// Returns the names of items that weren't imported.
    static func importItems(_ urls: [URL], into parent: URL) -> [String] {
        urls.flatMap { url in
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            return importItem(url, into: parent)
        }
    }

    private static func importItem(_ url: URL, into parent: URL) -> [String] {
        let name = url.lastPathComponent
        if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            if isNotebook(url) {
                do { try FileManager.default.copyItem(at: url, to: parent.appending(path: uniqueName(name, in: parent))) } catch { return [name] }
                return []
            }
            do {
                let dir = try createFolder(named: uniqueName(name, in: parent), in: parent)
                let children = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey])
                return children.sorted { $0.lastPathComponent < $1.lastPathComponent }.flatMap { child -> [String] in
                    let childName = child.lastPathComponent
                    guard childName.hasPrefix(".") else { return importItem(child, into: dir) }
                    if childName == ".folder.json" { try? FileManager.default.copyItem(at: child, to: dir.appending(path: childName)) }
                    // iCloud files not on this device show up as hidden ".name.icloud" placeholders.
                    return childName.hasSuffix(".icloud") ? ["\(childName.dropFirst().dropLast(7)) (not downloaded)"] : []
                }
            } catch {
                return [name]
            }
        }
        guard url.pathExtension.lowercased() == "pdf" else { return [name] }
        do { try importPDF(url, into: parent) } catch { return [name] }
        return []
    }

    private static func importPDF(_ url: URL, into parent: URL) throws {
        let dir = parent.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        do {
            let pdfURL = dir.appending(path: "doc.pdf")
            try FileManager.default.copyItem(at: url, to: pdfURL)
            guard let pdf = PDFDocument(url: pdfURL), !pdf.isLocked, pdf.pageCount > 0 else { throw CocoaError(.fileReadCorruptFile) }
            let meta = Meta(title: url.deletingPathExtension().lastPathComponent, paper: .blank, pages: (0..<pdf.pageCount).map { _ in UUID() })
            try JSONEncoder().encode(meta).write(to: dir.appending(path: "meta.json"))
        } catch {
            try? FileManager.default.removeItem(at: dir)
            throw error
        }
    }

    private static func folderName(_ name: String) throws -> String {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.hasPrefix("."), !name.contains("/") else { throw CocoaError(.fileWriteInvalidFileName) }
        return name
    }

    /// `name`, or `name 2`, `name 3`... if taken.
    private static func uniqueName(_ name: String, in parent: URL) -> String {
        var candidate = name
        var n = 2
        while FileManager.default.fileExists(atPath: parent.appending(path: candidate).path) {
            candidate = "\(name) \(n)"
            n += 1
        }
        return candidate
    }

    // ponytail: retains every generated source doc for the session so inserted pages never lose their backing document
    private static var keepAlive: [PDFDocument] = []

    /// Warm cream page color for generated paper.
    static let paperColor = UIColor(red: 0.99, green: 0.97, blue: 0.91, alpha: 1)

    /// One US Letter page of the given paper, drawn as vector PDF.
    static func paperPage(_ paper: Paper) -> PDFPage {
        let rect = CGRect(x: 0, y: 0, width: 612, height: 792)
        let data = UIGraphicsPDFRenderer(bounds: rect).pdfData { ctx in
            ctx.beginPage()
            paperColor.setFill()
            ctx.fill(rect)
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
            case .dotted:
                UIColor(white: 0.7, alpha: 1).setFill()
                for y in stride(from: 20.0, to: rect.maxY, by: 20) {
                    for x in stride(from: 20.0, to: rect.maxX, by: 20) {
                        UIBezierPath(ovalIn: CGRect(x: x - 0.8, y: y - 0.8, width: 1.6, height: 1.6)).fill()
                    }
                }
            }
            UIColor(white: 0.85, alpha: 1).setStroke()
            path.lineWidth = 0.5
            path.stroke()
        }
        let doc = PDFDocument(data: data)!
        keepAlive.append(doc)
        return doc.page(at: 0)!
    }
}
