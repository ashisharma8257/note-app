import PencilKit

/// Shape tools in the Pencil tool picker; the raw value is the picker item identifier.
/// A finished shape is ordinary ink, so the eraser, lasso, undo and export treat it like handwriting.
enum ShapeKind: String, CaseIterable, Codable {
    case line = "com.ashish.Notes.shape.line"
    case arrow = "com.ashish.Notes.shape.arrow"
    case rectangle = "com.ashish.Notes.shape.rectangle"
    case ellipse = "com.ashish.Notes.shape.ellipse"

    var name: String {
        switch self {
        case .line: "Line"
        case .arrow: "Arrow"
        case .rectangle: "Rectangle"
        case .ellipse: "Ellipse"
        }
    }

    var symbol: String {
        switch self {
        case .line: "line.diagonal"
        case .arrow: "arrow.up.right"
        case .rectangle: "rectangle"
        case .ellipse: "circle"
        }
    }

    /// The shape dragged from `a` to `b` as polylines in drawing coordinates.
    func polylines(from a: CGPoint, to b: CGPoint, width: CGFloat) -> [[CGPoint]] {
        switch self {
        case .line:
            return [[a, b]]
        case .arrow:
            let angle = atan2(b.y - a.y, b.x - a.x)
            let length = max(12, width * 4)
            func wing(_ spread: CGFloat) -> CGPoint {
                CGPoint(x: b.x - length * cos(angle + spread), y: b.y - length * sin(angle + spread))
            }
            return [[a, b], [wing(.pi / 7), b, wing(-.pi / 7)]]
        case .rectangle:
            return [[a, CGPoint(x: b.x, y: a.y), b, CGPoint(x: a.x, y: b.y), a]]
        case .ellipse:
            let center = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
            let rx = abs(b.x - a.x) / 2, ry = abs(b.y - a.y) / 2
            return [(0...96).map { i in
                let t = CGFloat(i) / 96 * 2 * .pi
                return CGPoint(x: center.x + rx * cos(t), y: center.y + ry * sin(t))
            }]
        }
    }

    func strokes(from a: CGPoint, to b: CGPoint, color: UIColor, width: CGFloat) -> [PKStroke] {
        let ink = PKInk(.monoline, color: color)
        // PencilKit renders a point of size s about 2s - 4 points wide (measured; sizes <= 2 draw nothing),
        // so pick the size that renders `width`.
        let size = width / 2 + 2
        return polylines(from: a, to: b, width: width).map { line in
            let points = densified(line).enumerated().map { i, p in
                PKStrokePoint(location: p, timeOffset: Double(i) * 0.001, size: CGSize(width: size, height: size),
                              opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
            }
            return PKStroke(ink: ink, path: PKStrokePath(controlPoints: points, creationDate: Date()))
        }
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
