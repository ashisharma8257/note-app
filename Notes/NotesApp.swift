import PDFKit
import SwiftUI

@main
struct NotesApp: App {
    @StateObject private var tabs = Tabs()
    @StateObject private var tools = Tools()

    var body: some Scene {
        WindowGroup {
            VStack(spacing: 0) {
                TabStrip(tabs: tabs)
                if let tab = tabs.selected {
                    NotebookView(folder: tabs.url(tab), tools: tools).id(tab)
                } else {
                    NavigationStack(path: $tabs.libraryPath) {
                        LibraryView(dir: .documentsDirectory, title: "Notebooks")
                            .navigationDestination(for: URL.self) { LibraryView(dir: $0, title: $0.lastPathComponent) }
                    }
                }
            }
            .environmentObject(tabs)
        }
    }
}

/// Grid of the folders and notebooks directly inside `dir`, or search results across everything under it.
struct LibraryView: View {
    let dir: URL
    let title: String
    @State private var books: [Book] = []
    @State private var importing = false
    @State private var naming = false
    @State private var folderName = ""
    @State private var pendingDelete: Book?
    @State private var renaming: Book?
    @State private var newName = ""
    @State private var moving: Book?
    @State private var importingNow = false
    @State private var error: String?
    @State private var query = ""
    @State private var hits: [SearchIndex.Hit] = []
    @EnvironmentObject private var tabs: Tabs

    var body: some View {
        Group {
            if query.trimmingCharacters(in: .whitespaces).isEmpty { grid } else { results }
        }
        .searchable(text: $query, prompt: "Search titles and handwriting")
        .task(id: query) {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            let query = query
            hits = await Task.detached { [dir] in SearchIndex.search(query, in: dir) }.value
        }
        .overlay { if importingNow { ProgressView("Importing…").padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) } }
        .navigationTitle(title)
        .toolbar {
            Menu {
                ForEach(Paper.allCases, id: \.self) { paper in
                    Button("New \(paper.rawValue.capitalized) Notebook") { create(paper) }
                }
                Button("Import…", systemImage: "square.and.arrow.down") { importing = true }
                Divider()
                Button("New Folder", systemImage: "folder.badge.plus") { folderName = ""; naming = true }
            } label: {
                Image(systemName: "plus")
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.pdf, .folder], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            importingNow = true
            Task {
                let skipped = await Task.detached { [dir] in Store.importItems(urls, into: dir) }.value
                importingNow = false
                if !skipped.isEmpty { error = "Not imported (only PDFs and folders are supported):\n" + skipped.joined(separator: "\n") }
                reload()
            }
        }
        .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } }), presenting: renaming) { book in
            TextField("Name", text: $newName)
            Button("Cancel", role: .cancel) {}
            Button("Rename") {
                attempt {
                    tabs.relocate(from: book.folder, to: try Store.rename(book, to: newName))
                    tabs.refresh()
                }
            }
        }
        .sheet(item: $moving) { book in
            MoveSheet(book: book) { destination in
                moving = nil
                attempt { tabs.relocate(from: book.folder, to: try Store.move(book, to: destination)) }
            }
        }
        .alert("New Folder", isPresented: $naming) {
            TextField("Name", text: $folderName)
            Button("Cancel", role: .cancel) {}
            Button("Create") { attempt { try Store.createFolder(named: folderName, in: dir) } }
        }
        .confirmationDialog(
            pendingDelete?.isFolder == true ? "Delete this folder and everything in it?" : "Delete this notebook?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { book in
            Button("Delete \(book.title)", role: .destructive) {
                attempt { try Store.delete(book) }
                tabs.prune()
            }
        }
        .alert("Something went wrong", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
        } message: {
            Text(error ?? "")
        }
        .onAppear {
            reload()
            SearchIndex.indexMissing(in: dir)
        }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 28)], spacing: 32) {
                ForEach(books) { book in
                    Group {
                        if book.isFolder {
                            NavigationLink(value: book.folder) { BookTile(book: book) }
                        } else {
                            Button { tabs.open(book.folder) } label: { BookTile(book: book) }
                        }
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        if book.isFolder { folderStyleMenus(book) }
                        Button("Rename", systemImage: "pencil") { newName = book.title; renaming = book }
                        Button("Move to…", systemImage: "folder") { moving = book }
                        Button("Delete", systemImage: "trash", role: .destructive) { pendingDelete = book }
                    }
                }
            }
            .padding(24)
        }
        .overlay { if books.isEmpty { ContentUnavailableView("Empty", systemImage: "book.closed", description: Text("Tap + to add a notebook or folder.")) } }
    }

    @ViewBuilder private func folderStyleMenus(_ book: Book) -> some View {
        Menu("Color", systemImage: "paintpalette") {
            ForEach(FolderStyle.colors, id: \.self) { color in
                Button(color.capitalized, systemImage: (book.style.color ?? "blue") == color ? "checkmark" : "circle") {
                    attempt { try Store.setFolderStyle(FolderStyle(color: color, symbol: book.style.symbol), of: book.folder) }
                }
            }
        }
        Menu("Icon", systemImage: "star") {
            ForEach(FolderStyle.symbols, id: \.self) { symbol in
                Button {
                    attempt { try Store.setFolderStyle(FolderStyle(color: book.style.color, symbol: symbol), of: book.folder) }
                } label: {
                    Image(systemName: symbol)
                }
            }
        }
    }

    /// Matches across this folder and everything under it; tapping one opens the notebook at that page.
    private var results: some View {
        List(hits) { hit in
            Button {
                if let page = hit.page { Store.setLastPage(page, of: hit.notebook) }
                tabs.open(hit.notebook)
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(hit.title).font(.headline)
                    Text(hit.page.map { "Page \($0 + 1) · \(hit.snippet)" } ?? "Title match")
                        .font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                }
            }
        }
        .overlay { if hits.isEmpty { ContentUnavailableView.search(text: query) } }
    }

    private func create(_ paper: Paper) {
        let pdf = PDFDocument()
        pdf.insert(Store.paperPage(paper), at: 0)
        attempt { try Store.create(title: "Untitled", paper: paper, pdf: pdf, in: dir) }
    }

    private func attempt(_ action: () throws -> Void) {
        do { try action() } catch { self.error = error.localizedDescription }
        reload()
    }

    private func reload() { books = Store.list(in: dir) }
}

extension FolderStyle {
    var tint: Color {
        switch color {
        case "red": .red
        case "orange": .orange
        case "yellow": .yellow
        case "green": .green
        case "teal": .teal
        case "purple": .purple
        case "pink": .pink
        case "gray": .gray
        default: .blue
        }
    }
}

/// Folder icon in its color, or the notebook's cover (page 1), with title and date underneath.
struct BookTile: View {
    let book: Book

    var body: some View {
        VStack(spacing: 6) {
            Group {
                if book.isFolder {
                    Image(systemName: book.style.symbol ?? "folder.fill")
                        .font(.system(size: 80))
                        .foregroundStyle(book.style.tint)
                } else {
                    Thumbnail { Store.cover(of: book.folder) }
                        .id(book.modified) // reload the cover after the notebook changes
                }
            }
            .frame(height: 180, alignment: .bottom)
            Text(book.title)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
            Text(book.isFolder ? " " : book.modified.formatted(date: .abbreviated, time: .omitted))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
    }
}

/// Picks a destination folder for a notebook or folder.
struct MoveSheet: View {
    let book: Book
    let move: (URL) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let root = URL.documentsDirectory
        // A folder can't move into itself or its own subfolders.
        let source = book.folder.standardizedFileURL.path
        let destinations = [root] + Store.allFolders(in: root).filter {
            let path = $0.standardizedFileURL.path
            return path != source && !path.hasPrefix(source + "/")
        }
        NavigationStack {
            List(destinations, id: \.self) { folder in
                let path = folder.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count)
                Button {
                    move(folder)
                } label: {
                    Label(path.isEmpty ? "Notebooks" : String(path.dropFirst()), systemImage: path.isEmpty ? "house" : "folder")
                }
                .disabled(folder.standardizedFileURL == book.folder.deletingLastPathComponent().standardizedFileURL)
            }
            .navigationTitle("Move \(book.title)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Cancel") { dismiss() } }
        }
    }
}
