import PencilKit
import UIKit.UIGestureRecognizerSubclass

/// Shape tools, in the order the shape tool's options show them; the raw value is what the tool settings store.
/// A finished shape is ordinary ink, so the eraser, lasso, undo and export treat it like handwriting.
enum ShapeKind: String, CaseIterable, Codable {
    case freehand = "com.ashish.Notes.shape.freehand"
    case elbow = "com.ashish.Notes.shape.elbow"
    case curve = "com.ashish.Notes.shape.curve"
    case rectangle = "com.ashish.Notes.shape.rectangle"
    case ellipse = "com.ashish.Notes.shape.ellipse"
    case triangle = "com.ashish.Notes.shape.triangle"
    case diamond = "com.ashish.Notes.shape.diamond"
    case roundedRectangle = "com.ashish.Notes.shape.roundedRectangle"

    var name: String {
        switch self {
        case .freehand: "Shape"
        case .elbow: "Elbow Connector"
        case .curve: "Curved Connector"
        case .rectangle: "Rectangle"
        case .ellipse: "Ellipse"
        case .triangle: "Triangle"
        case .diamond: "Diamond"
        case .roundedRectangle: "Rounded Rectangle"
        }
    }

    /// The shape dragged from `a` to `b` as polylines in drawing coordinates. A freehand shape is drawn point by
    /// point and recognized when the Pencil lifts (ShapeSnap); from its two ends alone it's a straight line.
    func polylines(from a: CGPoint, to b: CGPoint, width: CGFloat) -> [[CGPoint]] {
        let box = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
        switch self {
        case .freehand:
            return [[a, b]]
        case .elbow:
            let corner = CGPoint(x: b.x, y: a.y)
            return [[a, corner, b], Self.head(at: b, from: corner == b ? a : corner, width: width)]
        case .curve:
            // An S-curve that leaves `a` and reaches `b` horizontally.
            let c1 = CGPoint(x: (a.x + b.x) / 2, y: a.y), c2 = CGPoint(x: (a.x + b.x) / 2, y: b.y)
            let curve = (0...32).map { i -> CGPoint in
                let t = CGFloat(i) / 32, u = 1 - t
                return CGPoint(x: u * u * u * a.x + 3 * u * u * t * c1.x + 3 * u * t * t * c2.x + t * t * t * b.x,
                               y: u * u * u * a.y + 3 * u * u * t * c1.y + 3 * u * t * t * c2.y + t * t * t * b.y)
            }
            return [curve, Self.head(at: b, from: curve[30], width: width)]
        case .rectangle:
            return [[a, CGPoint(x: b.x, y: a.y), b, CGPoint(x: a.x, y: b.y), a]]
        case .ellipse:
            let center = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
            let rx = abs(b.x - a.x) / 2, ry = abs(b.y - a.y) / 2
            return [(0...96).map { i in
                let t = CGFloat(i) / 96 * 2 * .pi
                return CGPoint(x: center.x + rx * cos(t), y: center.y + ry * sin(t))
            }]
        case .triangle:
            let top = CGPoint(x: box.midX, y: box.minY)
            return [[top, CGPoint(x: box.maxX, y: box.maxY), CGPoint(x: box.minX, y: box.maxY), top]]
        case .diamond:
            let top = CGPoint(x: box.midX, y: box.minY)
            return [[top, CGPoint(x: box.maxX, y: box.midY), CGPoint(x: box.midX, y: box.maxY), CGPoint(x: box.minX, y: box.midY), top]]
        case .roundedRectangle:
            let r = min(box.width, box.height) * 0.2
            let corners = [(CGPoint(x: box.maxX - r, y: box.minY + r), -CGFloat.pi / 2), (CGPoint(x: box.maxX - r, y: box.maxY - r), 0),
                           (CGPoint(x: box.minX + r, y: box.maxY - r), .pi / 2), (CGPoint(x: box.minX + r, y: box.minY + r), .pi)]
            let outline = corners.flatMap { center, start in
                (0...8).map { i in
                    let t = start + CGFloat(i) / 8 * .pi / 2
                    return CGPoint(x: center.x + r * cos(t), y: center.y + r * sin(t))
                }
            }
            return [outline + [outline[0]]]
        }
    }

    /// Arrowhead wings at `tip`, for a line arriving from `from`.
    private static func head(at tip: CGPoint, from: CGPoint, width: CGFloat) -> [CGPoint] {
        let angle = atan2(tip.y - from.y, tip.x - from.x), length = max(12, width * 4)
        func wing(_ spread: CGFloat) -> CGPoint {
            CGPoint(x: tip.x - length * cos(angle + spread), y: tip.y - length * sin(angle + spread))
        }
        return [wing(.pi / 7), tip, wing(-.pi / 7)]
    }

    func strokes(from a: CGPoint, to b: CGPoint, color: UIColor, width: CGFloat) -> [PKStroke] {
        Self.strokes(polylines(from: a, to: b, width: width), color: color, width: width)
    }

    /// `lines` as ballpoint ink `width` points wide.
    static func strokes(_ lines: [[CGPoint]], color: UIColor, width: CGFloat) -> [PKStroke] {
        let ink = PKInk(.monoline, color: color)
        // PencilKit renders a point of size s about 2s - 4 points wide (measured; sizes <= 2 draw nothing),
        // so pick the size that renders `width`.
        let size = width / 2 + 2
        let template = PKStrokePoint(location: .zero, timeOffset: 0, size: CGSize(width: size, height: size),
                                     opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        return lines.map { PKStroke(along: $0, ink: ink, like: template, created: Date()) }
    }
}

/// Draw and hold: a pen or highlighter stroke held still for half a second, Pencil still down, becomes the shape it
/// resembles, which then follows the Pencil until it lifts.
enum ShapeSnap {
    /// The polyline `points` resemble, in the same coordinates: a straight line, a few straight segments, a triangle,
    /// a quadrilateral (a rectangle when its sides are near horizontal and vertical) or an ellipse (a circle when
    /// nearly round); nil when they resemble none of them.
    static func shape(_ points: [CGPoint]) -> [CGPoint]? {
        guard let first = points.first, let last = points.last else { return nil }
        let box = points.reduce(CGRect(origin: first, size: .zero)) { $0.union(CGRect(origin: $1, size: .zero)) }
        let size = hypot(box.width, box.height)
        guard size >= 10 else { return nil } // a dot
        let tolerance = size * 0.05
        let corners = simplified(points, tolerance)
        if distance(first, last) > size * 0.2 {
            return corners.count <= 4 ? corners : nil // a line, an angle, a zigzag; curves stay as drawn
        }
        // Closed: the start and end usually sit partway along a side, so drop corners that are really on a side.
        var polygon = Array(corners.dropLast())
        while polygon.count > 2, let i = polygon.indices.first(where: { i in
            distance(polygon[i], from: polygon[(i + polygon.count - 1) % polygon.count], to: polygon[(i + 1) % polygon.count]) < tolerance
        }) {
            polygon.remove(at: i)
        }
        if polygon.count == 4, zip(polygon, polygon.dropFirst() + [polygon[0]]).allSatisfy({ p, q in
            min(abs(q.x - p.x), abs(q.y - p.y)) < 0.25 * max(abs(q.x - p.x), abs(q.y - p.y)) // within ~14° of an axis
        }) {
            let xs = polygon.map(\.x).sorted(), ys = polygon.map(\.y).sorted()
            return ShapeKind.rectangle.polylines(from: CGPoint(x: (xs[0] + xs[1]) / 2, y: (ys[0] + ys[1]) / 2),
                                                 to: CGPoint(x: (xs[2] + xs[3]) / 2, y: (ys[2] + ys[3]) / 2), width: 0)[0]
        }
        if (3...4).contains(polygon.count) { return polygon + [polygon[0]] }
        return ellipse(points)
    }

    /// The ellipse through `points`, or nil when they stray from it by more than 8% of its radius on average.
    /// Axes come from the points' principal directions (snapped to horizontal/vertical within 10°), radii from their extent.
    private static func ellipse(_ points: [CGPoint]) -> [CGPoint]? {
        let n = CGFloat(points.count)
        let mean = CGPoint(x: points.map(\.x).reduce(0, +) / n, y: points.map(\.y).reduce(0, +) / n)
        let d = points.map { CGPoint(x: $0.x - mean.x, y: $0.y - mean.y) }
        var angle = atan2(2 * d.map { $0.x * $0.y }.reduce(0, +), d.map { $0.x * $0.x - $0.y * $0.y }.reduce(0, +)) / 2
        let upright = (angle / (.pi / 2)).rounded() * .pi / 2
        if abs(angle - upright) < .pi / 18 { angle = upright }
        let toLocal = CGAffineTransform(translationX: -mean.x, y: -mean.y).concatenating(CGAffineTransform(rotationAngle: -angle))
        let local = points.map { $0.applying(toLocal) }
        let xs = local.map(\.x), ys = local.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { return nil }
        var rx = (maxX - minX) / 2, ry = (maxY - minY) / 2
        let center = CGPoint(x: (minX + maxX) / 2, y: (minY + maxY) / 2)
        guard min(rx, ry) > max(rx, ry) * 0.1 else { return nil } // a line traced back on itself
        let error = local.map { abs(hypot(($0.x - center.x) / rx, ($0.y - center.y) / ry) - 1) }.reduce(0, +) / n
        guard error < 0.08 else { return nil }
        if min(rx, ry) > max(rx, ry) * 0.85 { (rx, ry) = ((rx + ry) / 2, (rx + ry) / 2) }
        let toDrawing = toLocal.inverted()
        return ShapeKind.ellipse.polylines(from: CGPoint(x: center.x - rx, y: center.y - ry),
                                           to: CGPoint(x: center.x + rx, y: center.y + ry), width: 0)[0].map { $0.applying(toDrawing) }
    }

    /// Ramer–Douglas–Peucker: the corners of `points`, keeping every point that strays more than `tolerance` from the result.
    private static func simplified(_ points: [CGPoint], _ tolerance: CGFloat) -> [CGPoint] {
        guard points.count > 2, let first = points.first, let last = points.last else { return points }
        let (far, offset) = (1..<points.count - 1).map { ($0, distance(points[$0], from: first, to: last)) }.max { $0.1 < $1.1 }!
        guard offset > tolerance else { return [first, last] }
        return simplified(Array(points[...far]), tolerance).dropLast() + simplified(Array(points[far...]), tolerance)
    }

    /// `shape`, snapped with the Pencil at `from`, after the Pencil moves to `to`: an open shape turns and stretches
    /// about its first point (a line's end follows the Pencil), a closed one grows or shrinks about its centre.
    static func adjusted(_ shape: [CGPoint], from: CGPoint, to: CGPoint) -> [CGPoint] {
        guard let first = shape.first, let last = shape.last else { return shape }
        let transform: CGAffineTransform
        if distance(first, last) > 1 {
            let a = CGPoint(x: from.x - first.x, y: from.y - first.y), b = CGPoint(x: to.x - first.x, y: to.y - first.y)
            guard a != .zero else { return shape }
            transform = CGAffineTransform(translationX: first.x, y: first.y)
                .rotated(by: atan2(b.y, b.x) - atan2(a.y, a.x))
                .scaledBy(x: hypot(b.x, b.y) / hypot(a.x, a.y), y: hypot(b.x, b.y) / hypot(a.x, a.y))
                .translatedBy(x: -first.x, y: -first.y)
        } else {
            let xs = shape.map(\.x), ys = shape.map(\.y)
            let center = CGPoint(x: (xs.min()! + xs.max()!) / 2, y: (ys.min()! + ys.max()!) / 2)
            guard from != center else { return shape }
            let scale = distance(to, center) / distance(from, center)
            transform = CGAffineTransform(translationX: center.x, y: center.y).scaledBy(x: scale, y: scale)
                .translatedBy(x: -center.x, y: -center.y)
        }
        return shape.map { $0.applying(transform) }
    }

    private static func distance(_ p: CGPoint, _ q: CGPoint) -> CGFloat { hypot(q.x - p.x, q.y - p.y) }

    /// Distance from `p` to the segment `a`–`b`.
    private static func distance(_ p: CGPoint, from a: CGPoint, to b: CGPoint) -> CGFloat {
        let ab = CGPoint(x: b.x - a.x, y: b.y - a.y)
        let length = ab.x * ab.x + ab.y * ab.y
        let t = length == 0 ? 0 : max(0, min(1, ((p.x - a.x) * ab.x + (p.y - a.y) * ab.y) / length))
        return distance(p, CGPoint(x: a.x + ab.x * t, y: a.y + ab.y * t))
    }
}

/// Draw and hold on a canvas: follows the Pencil alongside PencilKit's own drawing and begins once the Pencil has
/// stayed within a few points for half a second, if `shouldBegin` agrees; then changes as it moves until it lifts.
final class HoldGesture: UIGestureRecognizer {
    var shouldBegin: (HoldGesture) -> Bool = { _ in false }
    /// The stroke so far, in the view's coordinates.
    private(set) var points: [CGPoint] = []
    private weak var touch: UITouch?
    private var anchor = CGPoint.zero
    private var timer: DispatchWorkItem?

    override func canBePrevented(by other: UIGestureRecognizer) -> Bool { false } // PencilKit drawing mustn't stop it

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard touch == nil, let touch = touches.first else { return }
        self.touch = touch
        points = [touch.location(in: view)]
        restartTimer(at: touch)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch, touches.contains(touch) else { return }
        guard state == .possible else { state = .changed; return }
        points += (event.coalescedTouches(for: touch) ?? [touch]).map { $0.location(in: view) }
        let p = touch.location(in: nil) // window points, so zoom doesn't change how still is still
        if hypot(p.x - anchor.x, p.y - anchor.y) > 4 { restartTimer(at: touch) }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch, touches.contains(touch) else { return }
        state = state == .possible ? .failed : .ended
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch, touches.contains(touch) else { return }
        state = state == .possible ? .failed : .cancelled
    }

    override func reset() {
        timer?.cancel()
        touch = nil
        points = []
    }

    private func restartTimer(at touch: UITouch) {
        anchor = touch.location(in: nil)
        timer?.cancel()
        let timer = DispatchWorkItem { [weak self] in
            guard let self, self.state == .possible, self.shouldBegin(self) else { return }
            self.state = .began
        }
        self.timer = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: timer)
    }
}

extension PKStroke {
    /// A stroke along `line` with every point sized and angled like `template`.
    init(along line: [CGPoint], ink: PKInk, like template: PKStrokePoint, created: Date) {
        let points = densified(line).enumerated().map { i, p in
            PKStrokePoint(location: p, timeOffset: Double(i) * 0.001, size: template.size, opacity: template.opacity,
                          force: template.force, azimuth: template.azimuth, altitude: template.altitude)
        }
        self.init(ink: ink, path: PKStrokePath(controlPoints: points, creationDate: created))
    }
}

/// PencilKit treats stroke points as B-spline control points; sampling every `step` points
/// keeps straight edges straight and corners within about `step` of the polyline.
private func densified(_ line: [CGPoint], step: CGFloat = 2) -> [CGPoint] {
    guard let first = line.first else { return [] }
    var out = [first]
    for (p, q) in zip(line, line.dropFirst()) {
        let n = max(1, Int((hypot(q.x - p.x, q.y - p.y) / step).rounded(.up)))
        out += (1...n).map { k in
            let t = CGFloat(k) / CGFloat(n)
            return CGPoint(x: p.x + (q.x - p.x) * t, y: p.y + (q.y - p.y) * t)
        }
    }
    return out
}
