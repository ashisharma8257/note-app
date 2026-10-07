import Foundation
import UIKit
import Vision

/// Per-notebook search index, search.json: page id -> the page PDF's own text, typed text boxes, and
/// handwriting read by Vision text recognition. Notebook.close() re-indexes the pages edited in that session.
enum SearchIndex {
    /// One serial queue, so index writes never race and recognition stays off the main thread.
    private static let queue = DispatchQueue(label: "com.ashish.Notes.search-index", qos: .utility)

    struct Hit: Identifiable, Hashable {
        let notebook: URL
        let title: String
        let page: Int? // nil for a title match
        let snippet: String
        var id: String { "\(notebook.path)#\(page ?? -1)" }
    }

    static func url(_ notebook: URL) -> URL { notebook.appending(path: "search.json") }

    static func load(_ notebook: URL) -> [String: String] {
        (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: url(notebook)))) ?? [:]
    }

    /// Re-indexes `pages` (every page when nil) in the background; deleted pages drop out.
    static func update(_ notebook: URL, pages: Set<UUID>? = nil) {
        queue.async { rebuild(notebook, pages: pages) }
    }

    /// Indexes notebooks that have no index yet, e.g. ones made before search existed.
    static func indexMissing(in root: URL) {
        queue.async {
            for notebook in Store.allNotebooks(in: root) where !FileManager.default.fileExists(atPath: url(notebook).path) {
                rebuild(notebook, pages: nil)
            }
        }
    }

    /// Synchronous indexing, reading the notebook from disk.
    static func rebuild(_ notebook: URL, pages ids: Set<UUID>?) {
        let nb = Notebook(folder: notebook)
        var index = ids == nil ? [:] : load(notebook)
        for (i, id) in nb.pages.enumerated() where ids?.contains(id) ?? true {
            index[id.uuidString] = [nb.pdf.page(at: i)?.string ?? "", nb.items(at: i).text, recognize(nb.inkImage(at: i))]
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
        }
        let live = Set(nb.pages.map(\.uuidString))
        index = index.filter { live.contains($0.key) && !$0.value.isEmpty }
        try? JSONEncoder().encode(index).write(to: url(notebook), options: .atomic)
    }

    static func recognize(_ image: CGImage?) -> String {
        guard let image else { return "" }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        try? VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    /// Case- and accent-insensitive match on titles and page text of every notebook under `root`.
    static func search(_ query: String, in root: URL) -> [Hit] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        var hits: [Hit] = []
        for notebook in Store.allNotebooks(in: root) {
            guard let meta = Store.meta(of: notebook) else { continue }
            if meta.title.range(of: query, options: options) != nil {
                hits.append(Hit(notebook: notebook, title: meta.title, page: nil, snippet: "Title"))
            }
            let index = load(notebook)
            for (i, id) in (meta.pages ?? []).enumerated() {
                guard let text = index[id.uuidString], let match = text.range(of: query, options: options) else { continue }
                hits.append(Hit(notebook: notebook, title: meta.title, page: i, snippet: snippet(text, around: match)))
            }
        }
        return hits
    }

    private static func snippet(_ text: String, around match: Range<String.Index>) -> String {
        let start = text.index(match.lowerBound, offsetBy: -40, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(match.upperBound, offsetBy: 40, limitedBy: text.endIndex) ?? text.endIndex
        return (start > text.startIndex ? "…" : "") + text[start..<end].replacingOccurrences(of: "\n", with: " ")
            + (end < text.endIndex ? "…" : "")
    }
}
