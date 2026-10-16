import Foundation

/// Where the library lives, and keeping it in step with other devices. The library is the app's iCloud container
/// (iCloud Drive › Notes in Files), which iCloud syncs across the user's devices; without iCloud (signed out, or a
/// build signed without the iCloud entitlement, as a free developer account signs it) it is this device's Documents.
/// iCloud can hold a file back from this device until it is asked for: on an iPad it is a hidden ".name.icloud"
/// placeholder, on a Mac a file whose data is still in iCloud.
extension Store {
    /// The library's top folder.
    /// ponytail: looked up on the main thread at launch, which Apple advises against (the first lookup can wait while
    /// iCloud sets up the container); look it up in the background before showing the library if launch ever stalls
    static let root: URL = {
        guard let container = FileManager.default.url(forUbiquityContainerIdentifier: nil) else { return .documentsDirectory }
        let documents = container.appending(path: "Documents") // the part Files shows
        try? FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        return documents
    }()

    // MARK: Files iCloud hasn't downloaded

    static func placeholder(_ file: URL) -> URL { file.deletingLastPathComponent().appending(path: ".\(file.lastPathComponent).icloud") }

    /// The file `url` stands in for, if it's a placeholder.
    static func placeholderTarget(_ url: URL) -> URL? {
        let name = url.lastPathComponent
        guard name.hasPrefix("."), name.hasSuffix(".icloud"), name.count > ".icloud".count + 1 else { return nil }
        return url.deletingLastPathComponent().appending(path: String(name.dropFirst().dropLast(".icloud".count)))
    }

    /// Whether `file` is there, downloaded or not.
    static func exists(_ file: URL) -> Bool {
        FileManager.default.fileExists(atPath: file.path) || FileManager.default.fileExists(atPath: placeholder(file).path)
    }

    /// Whether iCloud hasn't brought `file` to this device yet: reading it fails, or waits for the download.
    static func isMissing(_ file: URL) -> Bool {
        FileManager.default.fileExists(atPath: placeholder(file).path)
            || (try? file.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]).ubiquitousItemDownloadingStatus) == .notDownloaded
    }

    /// Asks iCloud for every file under `dir` that this device lacks (`missing`: it can't be read yet) or has an
    /// older copy of (`outdated`).
    static func requestDownloads(in dir: URL) -> (missing: Int, outdated: Int) {
        var missing = 0, outdated = 0
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .ubiquitousItemDownloadingStatusKey]
        let files = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: Array(keys))
        while let url = files?.nextObject() as? URL {
            var file = url
            if let target = placeholderTarget(url) {
                file = target
                missing += 1
            } else {
                guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true else { continue }
                if values.ubiquitousItemDownloadingStatus == .notDownloaded { missing += 1 }
                else if values.ubiquitousItemDownloadingStatus == .downloaded { outdated += 1 }
                else { continue }
            }
            try? FileManager.default.startDownloadingUbiquitousItem(at: file)
        }
        return (missing, outdated)
    }

    // MARK: Changes from other devices

    /// Modification dates of the files this app saved, by path; main thread only.
    private static var written: [String: Date] = [:]

    /// Saves `data` atomically. The write is coordinated, so it waits for iCloud Drive to finish putting another
    /// device's version of the file in place rather than racing it, and iCloud Drive hears of it right away.
    static func write(_ data: Data, to url: URL) throws {
        var coordinationError: NSError?
        var writeError: Error?
        NSFileCoordinator(filePresenter: LibraryWatcher.shared).coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { url in
            do { try data.write(to: url, options: .atomic) } catch { writeError = error }
        }
        if let error = coordinationError ?? writeError { throw error }
        var saved = url
        saved.removeAllCachedResourceValues()
        written[saved.standardizedFileURL.path] = try? saved.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    /// The modification date of each file in document `doc`, by path. Covers and search indexes are left out: each
    /// device rebuilds its own.
    static func fingerprint(_ doc: URL) -> [String: Date] {
        var dates: [String: Date] = [:]
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .contentModificationDateKey]
        let files = FileManager.default.enumerator(at: doc, includingPropertiesForKeys: Array(keys))
        while let url = files?.nextObject() as? URL {
            guard url.lastPathComponent != "cover.jpg", url.lastPathComponent != "search.json",
                  let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true,
                  let date = values.contentModificationDate else { continue }
            dates[url.standardizedFileURL.path] = date
        }
        return dates
    }

    /// Whether a file changed since `before` other than by this app's own saves: another device changed the document.
    /// Deleted files don't count; a document never loses a file without its meta.json changing too.
    static func changedElsewhere(_ now: [String: Date], since before: [String: Date]) -> Bool {
        now.contains { path, date in date != before[path] && date != written[path] }
    }
}

/// Watches the library for changes from outside the app (iCloud Drive bringing another device's edits) and keeps it
/// downloaded. Each change, and each return to the foreground, asks iCloud for whatever this device lacks and posts
/// `changed`; while files are still on their way it checks again every 2 seconds, for up to a minute.
final class LibraryWatcher: NSObject, NSFilePresenter {
    static let shared = LibraryWatcher()
    static let changed = Notification.Name("LibraryWatcher.changed")

    var presentedItemURL: URL?
    let presentedItemOperationQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        return queue
    }()
    private var scheduled = false
    private var rounds = 0

    /// Called when the app comes to the foreground. A suspended app can't take part in file coordination, so `stop`
    /// unregisters it when the app leaves.
    func start() {
        NSFileCoordinator.removeFilePresenter(self)
        presentedItemURL = Store.root
        NSFileCoordinator.addFilePresenter(self)
        refresh()
    }

    func stop() { NSFileCoordinator.removeFilePresenter(self) }

    func presentedSubitemDidChange(at url: URL) { changedOnDisk() }
    func presentedSubitemDidAppear(at url: URL) { changedOnDisk() }
    func presentedSubitem(at oldURL: URL, didMoveTo newURL: URL) { changedOnDisk() }
    func accommodatePresentedSubitemDeletion(at url: URL, completionHandler: @escaping (Error?) -> Void) {
        completionHandler(nil)
        changedOnDisk()
    }

    private func changedOnDisk() { DispatchQueue.main.async { self.refresh() } }

    /// Main thread.
    func refresh() {
        rounds = 0
        poll()
    }

    private func poll() {
        guard !scheduled else { return }
        scheduled = true
        // A sync brings many files at once: one check a second later covers them all.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [self] in
            scheduled = false
            let root = Store.root
            DispatchQueue.global(qos: .utility).async { [self] in
                let pending = Store.requestDownloads(in: root)
                DispatchQueue.main.async { [self] in
                    NotificationCenter.default.post(name: Self.changed, object: nil)
                    guard pending.missing + pending.outdated > 0, rounds < 30 else { return }
                    rounds += 1
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.poll() }
                }
            }
        }
    }
}
