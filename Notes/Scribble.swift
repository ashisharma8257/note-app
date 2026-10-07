import PencilKit

/// Scribble to erase: a back-and-forth zigzag drawn over ink erases the ink it covers, and itself.
enum Scribble {
    /// `drawing` without its last stroke and the strokes that stroke scribbles over,
    /// or nil when the last stroke isn't a scribble over existing ink.
    static func erase(in drawing: PKDrawing) -> PKDrawing? {
        guard let scribble = drawing.strokes.last, isScribble(scribble) else { return nil }
        let area = scribble.renderBounds
        let others = drawing.strokes.dropLast()
        let kept = others.filter { coverage(of: $0, in: area) < 0.6 }
        guard kept.count < others.count else { return nil }
        return PKDrawing(strokes: Array(kept))
    }

    /// At least four passes along the stroke's longer axis, each spanning 40% or more of it,
    /// so ordinary letters ("m", "w") don't qualify.
    static func isScribble(_ stroke: PKStroke) -> Bool {
        let points = locations(of: stroke)
        guard let first = points.first else { return false }
        let box = points.reduce(CGRect(origin: first, size: .zero)) { $0.union(CGRect(origin: $1, size: .zero)) }
        let horizontal = box.width >= box.height
        let extent = horizontal ? box.width : box.height
        guard extent >= 15 else { return false }

        let threshold = extent * 0.4
        var direction: CGFloat = 0
        var extreme = horizontal ? first.x : first.y
        var reversals = 0
        for point in points {
            let c = horizontal ? point.x : point.y
            if direction == 0 {
                if abs(c - extreme) >= threshold {
                    direction = c > extreme ? 1 : -1
                    extreme = c
                }
            } else if (c - extreme) * direction > 0 {
                extreme = c // still moving the same way
            } else if abs(c - extreme) >= threshold {
                reversals += 1 // turned back far enough to count as a new pass
                direction = -direction
                extreme = c
            }
        }
        return reversals >= 3
    }

    /// Fraction of the stroke's length lying inside `area`.
    static func coverage(of stroke: PKStroke, in area: CGRect) -> Double {
        guard stroke.renderBounds.intersects(area) else { return 0 }
        let points = locations(of: stroke)
        guard !points.isEmpty else { return 0 }
        return Double(points.filter(area.contains).count) / Double(points.count)
    }

    /// Points every 2pt along the stroke, in drawing coordinates (the lasso moves strokes via their transform).
    private static func locations(of stroke: PKStroke) -> [CGPoint] {
        stroke.path.interpolatedPoints(by: .distance(2)).map { $0.location.applying(stroke.transform) }
    }
}
