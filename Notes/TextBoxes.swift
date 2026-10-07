import UIKit

struct TextBox: Codable, Identifiable, Hashable {
    var id = UUID()
    var frame: CGRect // page points, origin top-left; the height follows the text
    var text = ""
    var fontSize: CGFloat = 16
    var rgba: [CGFloat] = [0, 0, 0, 1]

    var color: UIColor { UIColor(red: rgba[0], green: rgba[1], blue: rgba[2], alpha: rgba[3]) }
}

struct Connector: Codable, Identifiable, Hashable {
    var id = UUID()
    var from: UUID
    var to: UUID
}

/// One page's typed text boxes and the arrows between them, stored as items/<page id>.json.
struct PageItems: Codable, Equatable {
    var boxes: [TextBox] = []
    var connectors: [Connector] = []

    static let inset: CGFloat = 6

    var isEmpty: Bool { boxes.isEmpty }
    var text: String { boxes.map(\.text).joined(separator: "\n") }

    /// Arrow ends: where the line between the two boxes' centers leaves each box.
    func arrow(_ connector: Connector) -> (from: CGPoint, to: CGPoint)? {
        guard let a = boxes.first(where: { $0.id == connector.from })?.frame,
              let b = boxes.first(where: { $0.id == connector.to })?.frame else { return nil }
        return (Self.edge(of: a, toward: CGPoint(x: b.midX, y: b.midY)), Self.edge(of: b, toward: CGPoint(x: a.midX, y: a.midY)))
    }

    /// Where the ray from the rectangle's center toward `point` crosses its (slightly padded) edge.
    static func edge(of rect: CGRect, toward point: CGPoint) -> CGPoint {
        let r = rect.insetBy(dx: -4, dy: -4)
        let dx = point.x - r.midX, dy = point.y - r.midY
        guard dx != 0 || dy != 0 else { return CGPoint(x: r.midX, y: r.midY) }
        let t = min(dx == 0 ? .infinity : r.width / 2 / abs(dx), dy == 0 ? .infinity : r.height / 2 / abs(dy))
        return CGPoint(x: r.midX + dx * t, y: r.midY + dy * t)
    }

    static func arrowPath(from a: CGPoint, to b: CGPoint) -> UIBezierPath {
        let path = UIBezierPath()
        path.move(to: a)
        path.addLine(to: b)
        let heading = atan2(b.y - a.y, b.x - a.x)
        for spread in [CGFloat.pi / 7, -.pi / 7] {
            path.move(to: b)
            path.addLine(to: CGPoint(x: b.x - 10 * cos(heading + spread), y: b.y - 10 * sin(heading + spread)))
        }
        path.lineWidth = 1.5
        path.lineCapStyle = .round
        return path
    }

    static func attributes(_ box: TextBox) -> [NSAttributedString.Key: Any] {
        [.font: UIFont.systemFont(ofSize: box.fontSize), .foregroundColor: box.color]
    }

    /// Draws arrows and text into the current UIKit context, in page points (exports and thumbnails).
    func draw() {
        UIColor.darkGray.setStroke()
        for connector in connectors {
            if let ends = arrow(connector) { Self.arrowPath(from: ends.from, to: ends.to).stroke() }
        }
        for box in boxes {
            NSAttributedString(string: box.text, attributes: Self.attributes(box))
                .draw(in: box.frame.insetBy(dx: Self.inset, dy: Self.inset))
        }
    }
}

/// The text boxes and arrows over one page's ink. Interactive only with the Text tool: tap empty space
/// to add a box, tap a box to type, drag a box to move it or its right edge to resize, press and hold a
/// box then drag to another to connect them, tap an arrow to remove it. A box left empty is removed.
final class ItemsView: UIView, UITextViewDelegate, UIGestureRecognizerDelegate {
    var onChange: ((PageItems) -> Void)?
    private(set) var items = PageItems()
    private var textViews: [UUID: UITextView] = [:]
    private var editingID: UUID?
    private var newColor = UIColor.black
    private var newSize: CGFloat = 16
    private let arrows = CAShapeLayer(), preview = CAShapeLayer()
    private var drag: (id: UUID, start: CGRect, resizing: Bool, before: PageItems)?
    private var linkFrom: UUID?

    var active = false {
        didSet {
            isUserInteractionEnabled = active
            textViews.values.forEach { $0.layer.borderWidth = active ? 1 : 0 }
            if !active { endEditing(true) }
        }
    }

    init() {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        for shape in [arrows, preview] {
            shape.fillColor = nil
            shape.strokeColor = UIColor.darkGray.cgColor
            shape.lineWidth = 1.5
            shape.lineCap = .round
            layer.addSublayer(shape)
        }
        preview.lineDashPattern = [4, 4]
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        let pan = UIPanGestureRecognizer(target: self, action: #selector(dragged(_:)))
        pan.maximumNumberOfTouches = 1
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(linking(_:)))
        hold.minimumPressDuration = 0.35
        for gesture in [tap, pan, hold] {
            gesture.delegate = self
            addGestureRecognizer(gesture)
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func load(_ items: PageItems) {
        self.items = items
        rebuild()
    }

    /// Style for new boxes; also restyles the box being typed in.
    func setStyle(color: UIColor, size: CGFloat) {
        newColor = color
        newSize = size
        guard let id = editingID, let i = index(id),
              items.boxes[i].fontSize != size || items.boxes[i].color != color else { return }
        commit { $0.boxes[i].fontSize = size; $0.boxes[i].rgba = rgba(color) }
        beginEditing(id)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        arrows.frame = bounds
        preview.frame = bounds
    }

    // MARK: Views

    private func rebuild() {
        textViews.values.forEach { $0.removeFromSuperview() }
        textViews = [:]
        for box in items.boxes {
            let view = UITextView(frame: box.frame)
            view.text = box.text
            view.font = .systemFont(ofSize: box.fontSize)
            view.textColor = box.color
            view.backgroundColor = .clear
            view.isScrollEnabled = false
            view.textContainerInset = UIEdgeInsets(top: PageItems.inset, left: PageItems.inset, bottom: PageItems.inset, right: PageItems.inset)
            view.textContainer.lineFragmentPadding = 0 // matches PageItems.draw
            view.layer.borderColor = UIColor.systemBlue.withAlphaComponent(0.4).cgColor
            view.layer.borderWidth = active ? 1 : 0
            view.layer.cornerRadius = 4
            view.isUserInteractionEnabled = false // this view's gestures decide when typing starts
            view.delegate = self
            textViews[box.id] = view
            addSubview(view)
        }
        redrawArrows()
    }

    private func redrawArrows() {
        let path = UIBezierPath()
        for connector in items.connectors {
            if let ends = items.arrow(connector) { path.append(PageItems.arrowPath(from: ends.from, to: ends.to)) }
        }
        arrows.path = path.cgPath
    }

    private func index(_ id: UUID) -> Int? { items.boxes.firstIndex { $0.id == id } }

    private func box(at point: CGPoint) -> UUID? {
        items.boxes.last { $0.frame.insetBy(dx: -6, dy: -6).contains(point) }?.id
    }

    private func connector(near point: CGPoint) -> Connector? {
        items.connectors.first { connector in
            guard let ends = items.arrow(connector) else { return false }
            let a = ends.from, b = ends.to
            let ab = CGPoint(x: b.x - a.x, y: b.y - a.y), length = ab.x * ab.x + ab.y * ab.y
            guard length > 0 else { return false }
            let t = max(0, min(1, ((point.x - a.x) * ab.x + (point.y - a.y) * ab.y) / length))
            return hypot(point.x - (a.x + t * ab.x), point.y - (a.y + t * ab.y)) < 10
        }
    }

    // MARK: Changes and undo

    /// Applies a change as one undo step and saves it.
    private func commit(_ change: (inout PageItems) -> Void) {
        let before = items
        change(&items)
        record(undoTo: before)
        rebuild()
        onChange?(items)
    }

    private func record(undoTo before: PageItems) {
        undoManager?.registerUndo(withTarget: self) { view in
            let after = view.items
            view.load(before)
            view.record(undoTo: after)
            view.onChange?(before)
        }
    }

    private func beginEditing(_ id: UUID) {
        guard let view = textViews[id] else { return }
        editingID = id
        view.isUserInteractionEnabled = true
        view.becomeFirstResponder()
    }

    // MARK: Gestures

    /// Touches inside the box being typed in belong to the text view (cursor, selection).
    func gestureRecognizer(_ gesture: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard let id = editingID, let editing = textViews[id], let view = touch.view else { return true }
        return !view.isDescendant(of: editing)
    }

    override func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
        // Drags and holds start only on a box, so a finger on empty paper still scrolls the page.
        if gesture is UITapGestureRecognizer { return true }
        let start = (gesture as? UIPanGestureRecognizer).map { $0.location(in: self) - $0.translation(in: self) } ?? gesture.location(in: self)
        return box(at: start) != nil
    }

    @objc private func tapped(_ gesture: UITapGestureRecognizer) {
        let point = gesture.location(in: self)
        if let connector = connector(near: point) {
            commit { $0.connectors.removeAll { $0.id == connector.id } }
        } else if let id = box(at: point) {
            beginEditing(id)
        } else if editingID != nil {
            endEditing(true) // the first tap outside just finishes typing
        } else {
            let box = TextBox(frame: CGRect(x: point.x, y: point.y - newSize, width: 240, height: newSize * 1.3 + 2 * PageItems.inset),
                              fontSize: newSize, rgba: rgba(newColor))
            commit { $0.boxes.append(box) }
            beginEditing(box.id)
        }
    }

    @objc private func dragged(_ gesture: UIPanGestureRecognizer) {
        let t = gesture.translation(in: self)
        switch gesture.state {
        case .began:
            let start = gesture.location(in: self) - t
            guard let id = box(at: start), let i = index(id) else { return }
            let frame = items.boxes[i].frame
            drag = (id, frame, start.x > frame.maxX - 18, items)
        case .changed:
            guard let drag, let i = index(drag.id), let view = textViews[drag.id] else { return }
            var frame = drag.start
            if drag.resizing {
                frame.size.width = max(60, drag.start.width + t.x)
                frame.size.height = view.sizeThatFits(CGSize(width: frame.width, height: .greatestFiniteMagnitude)).height
            } else {
                frame.origin = CGPoint(x: drag.start.minX + t.x, y: drag.start.minY + t.y)
            }
            items.boxes[i].frame = frame
            view.frame = frame
            redrawArrows()
        case .ended, .cancelled:
            guard let drag else { return }
            self.drag = nil
            record(undoTo: drag.before)
            onChange?(items)
        default:
            break
        }
    }

    @objc private func linking(_ gesture: UILongPressGestureRecognizer) {
        let point = gesture.location(in: self)
        switch gesture.state {
        case .began:
            linkFrom = box(at: point)
        case .changed:
            guard let from = linkFrom, let i = index(from) else { return }
            preview.path = PageItems.arrowPath(from: PageItems.edge(of: items.boxes[i].frame, toward: point), to: point).cgPath
        case .ended:
            preview.path = nil
            if let from = linkFrom, let to = box(at: point), to != from,
               !items.connectors.contains(where: { $0.from == from && $0.to == to }) {
                commit { $0.connectors.append(Connector(from: from, to: to)) }
            }
            linkFrom = nil
        default:
            preview.path = nil
            linkFrom = nil
        }
    }

    // MARK: Typing

    func textViewDidChange(_ view: UITextView) {
        guard let id = textViews.first(where: { $0.value === view })?.key, let i = index(id) else { return }
        items.boxes[i].text = view.text
        let height = view.sizeThatFits(CGSize(width: view.frame.width, height: .greatestFiniteMagnitude)).height
        view.frame.size.height = height
        items.boxes[i].frame.size.height = height
        redrawArrows()
        onChange?(items)
    }

    func textViewDidEndEditing(_ view: UITextView) {
        view.isUserInteractionEnabled = false
        guard let id = editingID else { return }
        editingID = nil
        if items.boxes.first(where: { $0.id == id })?.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? false {
            commit { items in
                items.boxes.removeAll { $0.id == id }
                items.connectors.removeAll { $0.from == id || $0.to == id }
            }
        }
    }
}

private func rgba(_ color: UIColor) -> [CGFloat] {
    var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
    color.getRed(&r, green: &g, blue: &b, alpha: &a)
    return [r, g, b, a]
}

private func - (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x - b.x, y: a.y - b.y) }
