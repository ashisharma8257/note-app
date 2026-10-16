import SwiftUI

enum Theme {
    static let tabStrip = Color(red: 0.2, green: 0.31, blue: 0.5)
    static let bar = Color(red: 0.25, green: 0.37, blue: 0.62)
    static let canvas = Color(white: 0.96)
}

/// Open notebooks shown as tabs; no selection shows the library.
/// Tabs are paths relative to `root` (the library) because the app container's absolute path changes on reinstall.
final class Tabs: ObservableObject {
    @Published private(set) var open: [String] = []
    @Published private(set) var selected: String?
    @Published var libraryPath: [URL] = []

    private let defaults: UserDefaults
    let root: URL

    init(defaults: UserDefaults = .standard, root: URL = Store.root) {
        self.defaults = defaults
        self.root = root
        open = (defaults.stringArray(forKey: "tabs.open") ?? []).filter { Store.isNotebook(root.appending(path: $0)) }
        selected = defaults.string(forKey: "tabs.selected").flatMap { open.contains($0) ? $0 : nil }
    }

    func url(_ tab: String) -> URL { root.appending(path: tab) }

    func open(_ notebook: URL) {
        guard let tab = relative(notebook) else { return }
        if !open.contains(tab) { open.append(tab) }
        select(tab)
    }

    func select(_ tab: String?) {
        selected = tab
        save()
    }

    /// Closing the selected tab selects its right neighbour, else its left, else the library.
    func close(_ tab: String) {
        guard let i = open.firstIndex(of: tab) else { return }
        open.remove(at: i)
        if selected == tab { selected = open.isEmpty ? nil : open[min(i, open.count - 1)] }
        save()
    }

    /// Follows a rename or move of `old` (a notebook, or a folder containing open notebooks) to `new`.
    func relocate(from old: URL, to new: URL) {
        guard let from = relative(old), let to = relative(new) else { return }
        func moved(_ tab: String) -> String {
            tab == from ? to : tab.hasPrefix(from + "/") ? to + tab.dropFirst(from.count) : tab
        }
        open = open.map(moved)
        selected = selected.map(moved)
        save()
    }

    /// Closes tabs whose notebook no longer exists.
    func prune() {
        open = open.filter { Store.isNotebook(url($0)) }
        if let selected, !open.contains(selected) { self.selected = nil }
        save()
    }

    /// Redraws tab titles after a notebook is renamed.
    func refresh() { objectWillChange.send() }

    private func save() {
        defaults.set(open, forKey: "tabs.open")
        defaults.set(selected, forKey: "tabs.selected")
    }

    /// Symlinks (e.g. /var -> /private/var) only resolve for existing paths, so resolve the parent:
    /// after a rename or move the old path itself is gone.
    private func relative(_ url: URL) -> String? {
        let base = root.resolvingSymlinksInPath().path + "/"
        let path = url.deletingLastPathComponent().resolvingSymlinksInPath().appending(path: url.lastPathComponent).path
        return path.hasPrefix(base) ? String(path.dropFirst(base.count)) : nil
    }
}

struct TabStrip: View {
    @ObservedObject var tabs: Tabs

    var body: some View {
        HStack(spacing: 0) {
            let home = tabs.selected == nil
            Button { tabs.select(nil) } label: {
                Image(systemName: "house")
                    .frame(width: 56, height: 44)
                    .foregroundStyle(home ? Theme.bar : .white)
                    .background(home ? Color(uiColor: .systemBackground) : .clear, in: UnevenRoundedRectangle(topLeadingRadius: 10, topTrailingRadius: 10))
            }
            .accessibilityLabel("Library")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(tabs.open, id: \.self) { tab in
                        HStack {
                            Text(Store.title(of: tabs.url(tab))).lineLimit(1)
                            Spacer(minLength: 8)
                            Button { tabs.close(tab) } label: {
                                Image(systemName: "xmark").font(.caption.weight(.semibold)).frame(width: 28, height: 28)
                            }
                            .accessibilityLabel("Close tab")
                        }
                        .padding(.leading, 14)
                        .padding(.trailing, 6)
                        .frame(width: 210, height: 44)
                        .background(tab == tabs.selected ? Theme.bar : .clear, in: UnevenRoundedRectangle(topLeadingRadius: 10, topTrailingRadius: 10))
                        .contentShape(Rectangle())
                        .onTapGesture { tabs.select(tab) }
                    }
                }
            }
        }
        .foregroundStyle(.white)
        .padding(.top, 4)
        .background(Theme.tabStrip.ignoresSafeArea(edges: .top))
    }
}
