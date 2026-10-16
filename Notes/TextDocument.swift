import SwiftUI
import UIKit

/// A text document, GoodNotes-style: a title over one column of typed text, where "/" opens quick tools
/// (SlashCommand), Return continues a list and a tap ticks a checkbox. It saves as you type.
struct TextDocumentView: View {
    let folder: URL
    @EnvironmentObject private var tabs: Tabs

    var body: some View {
        TextDocumentEditor(folder: folder) { tabs.refresh() }
            .ignoresSafeArea(.container, edges: .bottom) // still clear of the keyboard
    }
}

struct TextDocumentEditor: UIViewRepresentable {
    let folder: URL
    let retitled: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(folder: folder, retitled: retitled) }

    func makeUIView(context: Context) -> DocumentTextView {
        let view = DocumentTextView()
        let coordinator = context.coordinator
        view.text = (try? String(contentsOf: Store.textFile(folder), encoding: .utf8)) ?? ""
        let title = Store.title(of: folder)
        view.title.text = title == Coordinator.untitled ? "" : title // the placeholder says it
        view.hint.isHidden = !view.text.isEmpty
        view.delegate = coordinator
        view.title.delegate = coordinator
        view.title.addTarget(coordinator, action: #selector(Coordinator.titleChanged(_:)), for: .editingChanged)
        view.addSubview(coordinator.slashMenu)
        coordinator.slashMenu.run = { [weak view] command in
            guard let view, let slash = TextLists.slash(in: view.text, before: view.selectedRange.location) else { return }
            view.apply(TextLists.run(command, in: view.text, replacing: slash.range))
        }
        let tap = UITapGestureRecognizer(target: coordinator, action: #selector(Coordinator.tapped(_:)))
        tap.delegate = coordinator
        view.addGestureRecognizer(tap)
        if view.text.isEmpty { DispatchQueue.main.async { view.becomeFirstResponder() } } // a new document: start writing
        return view
    }

    func updateUIView(_ view: DocumentTextView, context: Context) {}

    final class Coordinator: NSObject, UITextViewDelegate, UITextFieldDelegate, UIGestureRecognizerDelegate {
        static let untitled = "Untitled"
        let folder: URL
        let retitled: () -> Void
        let slashMenu = SlashMenu()

        init(folder: URL, retitled: @escaping () -> Void) {
            self.folder = folder
            self.retitled = retitled
        }

        @objc func titleChanged(_ field: UITextField) {
            let title = (field.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            do { try Store.setTitle(title.isEmpty ? Self.untitled : title, of: folder) }
            catch { print("Saving the title failed: \(error)") }
            try? FileManager.default.removeItem(at: Store.coverURL(folder)) // the library redraws it
            retitled()
        }

        /// Return in the title moves on to the text.
        func textFieldShouldReturn(_ field: UITextField) -> Bool {
            field.superview?.becomeFirstResponder()
            return false
        }

        func textViewDidChange(_ view: UITextView) {
            // ponytail: rewrites the whole file per keystroke; fine for typed notes, debounce if documents get long
            do { try Store.write(Data(view.text.utf8), to: Store.textFile(folder)) }
            catch { print("Saving text.txt failed: \(error)") }
            try? FileManager.default.removeItem(at: Store.coverURL(folder))
            (view as? DocumentTextView)?.hint.isHidden = !view.text.isEmpty
            updateSlashMenu(view)
        }

        /// Return runs the slash command being typed, else continues a list.
        func textView(_ view: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            guard text == "\n" else { return true }
            var edit = TextLists.newline(in: view.text, replacing: range)
            if range.length == 0, let slash = TextLists.slash(in: view.text, before: range.location), !slash.query.isEmpty,
               let command = SlashCommand.matching(slash.query).first {
                edit = TextLists.run(command, in: view.text, replacing: slash.range)
            }
            guard let edit else { return true }
            view.apply(edit)
            return false
        }

        func textViewDidEndEditing(_ view: UITextView) { slashMenu.isHidden = true }

        func textViewDidChangeSelection(_ view: UITextView) { updateSlashMenu(view) }

        /// Lists the commands matching the "/query" just before the cursor under it (above it when there's no room
        /// below); hidden when there's no such query or nothing matches.
        private func updateSlashMenu(_ view: UITextView) {
            guard view.selectedRange.length == 0, let slash = TextLists.slash(in: view.text, before: view.selectedRange.location),
                  case let commands = SlashCommand.matching(slash.query), !commands.isEmpty, let cursor = view.selectedTextRange?.end else {
                slashMenu.isHidden = true
                return
            }
            slashMenu.show(commands)
            let caret = view.caretRect(for: cursor), size = slashMenu.bounds.size
            let visibleBottom = view.contentOffset.y + view.bounds.height - view.adjustedContentInset.bottom
            let y = caret.maxY + 6 + size.height <= visibleBottom ? caret.maxY + 6 : caret.minY - 6 - size.height
            slashMenu.frame.origin = CGPoint(x: min(caret.minX, view.bounds.width - size.width - 16), y: y)
            slashMenu.isHidden = false
            view.bringSubviewToFront(slashMenu)
        }

        @objc func tapped(_ gesture: UITapGestureRecognizer) {
            guard let view = gesture.view as? UITextView, let offset = view.checkbox(at: gesture.location(in: view)),
                  let text = TextLists.toggled(view.text, at: offset) else { return }
            let tick = NSRange(location: offset, length: 1)
            view.apply((tick, (text as NSString).substring(with: tick)))
        }

        /// The checkbox tap is also the text view's own tap, which places the cursor.
        func gestureRecognizer(_ gesture: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    }
}

/// The "/" quick tools: one row per matching command, the first highlighted because Return runs it.
final class SlashMenu: UIView {
    var run: (SlashCommand) -> Void = { _ in }
    private let rows = UIStackView()
    private static let width: CGFloat = 240, rowHeight: CGFloat = 40, inset: CGFloat = 6

    init() {
        super.init(frame: .zero)
        isHidden = true
        backgroundColor = .systemBackground
        layer.cornerRadius = 12
        layer.borderWidth = 0.5
        layer.borderColor = UIColor.separator.cgColor
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.15
        layer.shadowRadius = 12
        layer.shadowOffset = CGSize(width: 0, height: 4)
        rows.axis = .vertical
        addSubview(rows)
        accessibilityIdentifier = "Quick tools"
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show(_ commands: [SlashCommand]) {
        rows.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (i, command) in commands.enumerated() {
            var config = UIButton.Configuration.plain()
            config.title = command.title
            config.image = UIImage(systemName: command.symbol)
            config.imagePadding = 10
            config.baseForegroundColor = .label
            config.background.backgroundColor = i == 0 ? .tertiarySystemFill : .clear
            config.background.cornerRadius = 8
            let button = UIButton(configuration: config, primaryAction: UIAction { [weak self] _ in self?.run(command) })
            button.contentHorizontalAlignment = .leading
            button.heightAnchor.constraint(equalToConstant: Self.rowHeight).isActive = true
            rows.addArrangedSubview(button)
        }
        frame.size = CGSize(width: Self.width, height: CGFloat(commands.count) * Self.rowHeight + 2 * Self.inset)
        rows.frame = bounds.insetBy(dx: Self.inset, dy: Self.inset)
    }
}

/// The document's text, with the title field and the empty-document hint laid out in its centred column.
final class DocumentTextView: UITextView {
    let title = UITextField()
    let hint = UILabel()
    private static let column: CGFloat = 680, top: CGFloat = 40, titleHeight: CGFloat = 44

    init() {
        super.init(frame: .zero, textContainer: nil)
        font = .systemFont(ofSize: 18)
        backgroundColor = .systemBackground
        alwaysBounceVertical = true
        keyboardDismissMode = .interactive
        title.font = .systemFont(ofSize: 34, weight: .bold)
        title.placeholder = TextDocumentEditor.Coordinator.untitled
        title.returnKeyType = .next
        hint.text = "Write, type “/” for quick tools"
        hint.font = font
        hint.textColor = .placeholderText
        addSubview(title)
        addSubview(hint)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let side = max(24, (bounds.width - Self.column) / 2)
        let inset = UIEdgeInsets(top: Self.top + Self.titleHeight + 16, left: side, bottom: 40, right: side)
        if textContainerInset != inset { textContainerInset = inset }
        title.frame = CGRect(x: side + textContainer.lineFragmentPadding, y: Self.top, width: bounds.width - 2 * side, height: Self.titleHeight)
        hint.frame = CGRect(x: side + textContainer.lineFragmentPadding, y: inset.top, width: bounds.width - 2 * side, height: font?.lineHeight ?? 22)
    }
}
