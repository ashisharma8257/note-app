import PDFKit
import SwiftUI

@main
struct NotesApp: App {
    var body: some Scene {
        WindowGroup {
            NavigationStack {
                LibraryView(dir: .documentsDirectory, title: "Notebooks")
                    .navigationDestination(for: URL.self) { dir in
                        if Store.isNotebook(dir) {
                            NotebookView(folder: dir)
                        } else {
                            LibraryView(dir: dir, title: dir.lastPathComponent)
                        }
                    }
            }
        }
    }
}

/// Lists the folders and notebooks directly inside `dir`.
struct LibraryView: View {
    let dir: URL
    let title: String
    @State private var books: [Book] = []
    @State private var importing = false
    @State private var naming = false
    @State private var folderName = ""
    @State private var pendingDelete: Book?
    @State private var error: String?

    var body: some View {
        List(books) { book in
            NavigationLink(value: book.folder) {
                Label {
                    VStack(alignment: .leading) {
                        Text(book.title)
                        if !book.isFolder {
                            Text(book.modified, format: .dateTime).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } icon: {
                    Image(systemName: book.isFolder ? "folder" : "book.closed")
                }
            }
            .swipeActions { Button("Delete", systemImage: "trash") { pendingDelete = book }.tint(.red) }
            .contextMenu { Button("Delete", systemImage: "trash", role: .destructive) { pendingDelete = book } }
        }
        .overlay { if books.isEmpty { ContentUnavailableView("Empty", systemImage: "book.closed", description: Text("Tap + to add a notebook or folder.")) } }
        .navigationTitle(title)
        .toolbar {
            Menu {
                ForEach(Paper.allCases, id: \.self) { paper in
                    Button("New \(paper.rawValue.capitalized) Notebook") { create(paper) }
                }
                Button("Import PDF…") { importing = true }
                Divider()
                Button("New Folder", systemImage: "folder.badge.plus") { folderName = ""; naming = true }
            } label: {
                Image(systemName: "plus")
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.pdf]) { result in
            attempt {
                let url = try result.get()
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                guard let pdf = PDFDocument(url: url) else { throw CocoaError(.fileReadCorruptFile) }
                try Store.create(title: url.deletingPathExtension().lastPathComponent, paper: .blank, pdf: pdf, in: dir)
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
            Button("Delete \(book.title)", role: .destructive) { attempt { try Store.delete(book) } }
        }
        .alert("Something went wrong", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
        } message: {
            Text(error ?? "")
        }
        .onAppear(perform: reload)
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
