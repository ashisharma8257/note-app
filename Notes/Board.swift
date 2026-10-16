import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// An Excalidraw board: Excalidraw's own editor (board/, built into build/board and bundled as the app's "board"
/// folder) in a web view, editing the board's board.excalidraw. Files Excalidraw downloads (Save to…, Export Image)
/// go wherever the user moves them.
struct BoardView: View {
    let folder: URL
    @State private var download: URL?

    var body: some View {
        BoardWebView(folder: folder, download: $download)
            .ignoresSafeArea(edges: .bottom)
            .fileMover(isPresented: Binding(get: { download != nil }, set: { if !$0 { download = nil } }), file: download) { _ in }
    }
}

struct BoardWebView: UIViewRepresentable {
    let folder: URL
    @Binding var download: URL?

    /// The page's own origin: the editor, the board and the library are all served under it (Coordinator).
    static let scheme = "notes-board"

    func makeCoordinator() -> Coordinator { Coordinator(folder: folder, download: $download) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(context.coordinator, forURLScheme: Self.scheme)
        config.userContentController.add(context.coordinator, name: "board")
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        view.scrollView.isScrollEnabled = false // Excalidraw pans and zooms its own canvas
        view.isInspectable = true // Safari's Develop menu
        view.load(URLRequest(url: URL(string: "\(Self.scheme)://board/index.html")!))
        context.coordinator.resignObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willResignActiveNotification, object: nil, queue: .main
        ) { [weak view, weak coordinator = context.coordinator] _ in
            if let view { coordinator?.flush(view) }
        }
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {}

    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        coordinator.flush(view)
        view.configuration.userContentController.removeScriptMessageHandler(forName: "board") // it retains the coordinator
    }

    final class Coordinator: NSObject, WKURLSchemeHandler, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
        let folder: URL
        let download: Binding<URL?>
        var resignObserver: NSObjectProtocol?
        private var downloading: [ObjectIdentifier: URL] = [:]
        private static let editor = Bundle.main.url(forResource: "board", withExtension: nil)!

        init(folder: URL, download: Binding<URL?>) {
            self.folder = folder
            self.download = download
        }

        deinit { resignObserver.map(NotificationCenter.default.removeObserver) }

        /// Saves what the page hasn't sent yet. The page sends changes at most every half second, so this runs when
        /// the board closes and when the app goes to the background.
        /// ponytail: quitting the Mac app (⌘Q) runs neither, so it can lose the last half second of drawing.
        func flush(_ view: WKWebView) {
            // The completion handler keeps the view alive until the page answers.
            view.evaluateJavaScript("pendingScene()") { [self] result, _ in
                if let json = result as? String { save(json) }
                _ = view
            }
        }

        private func save(_ json: String) {
            do { try Store.write(Data(json.utf8), to: Store.boardFile(folder)) }
            catch { print("Saving board.excalidraw failed: \(error)") } // ponytail: console only, as notebooks do
        }

        // MARK: Page ↔ app

        func webView(_ view: WKWebView, start task: WKURLSchemeTask) {
            guard let url = task.request.url else { return }
            // "scene" is the board, "library" the Excalidraw library all boards share; the rest is the editor's build.
            let file = switch url.path {
            case "/scene": Store.boardFile(folder)
            case "/library": Store.boardLibrary
            default: Self.editor.appending(path: url.path)
            }
            // The page only asks for files in the build; never serve a path that climbs out of it. Checked by component:
            // standardizing drops the /private prefix of the bundle's path on a device, so prefix checks fail there.
            guard !url.pathComponents.contains(".."), let data = try? Data(contentsOf: file) else {
                task.didReceive(HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!)
                task.didFinish()
                return
            }
            let type = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            task.didReceive(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": type])!)
            task.didReceive(data)
            task.didFinish()
        }

        func webView(_ view: WKWebView, stop task: WKURLSchemeTask) {}

        /// {scene: JSON} as the board changes, then {cover: JPEG data URL, or null for an empty board};
        /// {library: JSON} when the library changes.
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any] else { return }
            if let json = body["scene"] as? String { save(json) }
            if let json = body["library"] as? String {
                do { try Store.write(Data(json.utf8), to: Store.boardLibrary) }
                catch { print("Saving the Excalidraw library failed: \(error)") }
            }
            guard body.keys.contains("cover") else { return }
            let cover = Store.coverURL(folder)
            if let dataURL = (body["cover"] as? String).flatMap(URL.init(string:)), let data = try? Data(contentsOf: dataURL) {
                try? data.write(to: cover, options: .atomic)
            } else {
                try? FileManager.default.removeItem(at: cover)
            }
        }

        // MARK: Downloads and links

        func webView(_ view: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            if action.shouldPerformDownload { return .download }
            // The board stays put; a link that would replace it opens in the browser. Embeds load in their frames.
            guard action.targetFrame?.isMainFrame == true, let url = action.request.url, url.scheme != BoardWebView.scheme else { return .allow }
            await UIApplication.shared.open(url)
            return .cancel
        }

        func webView(_ view: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
            download.delegate = self
        }

        func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String) async -> URL? {
            let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            downloading[ObjectIdentifier(download)] = dir.appending(path: suggestedFilename)
            return downloading[ObjectIdentifier(download)]
        }

        func downloadDidFinish(_ download: WKDownload) {
            self.download.wrappedValue = downloading.removeValue(forKey: ObjectIdentifier(download))
        }

        /// Links (Excalidraw's help, a link on a shape) open in the browser rather than in the board.
        func webView(_ view: WKWebView, createWebViewWith config: WKWebViewConfiguration, for action: WKNavigationAction,
                     windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = action.request.url { UIApplication.shared.open(url) }
            return nil
        }
    }
}
