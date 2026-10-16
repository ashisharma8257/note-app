import Foundation
import PDFKit
import PencilKit
import UIKit

// Converts a GoodNotes backup (folders of .goodnotes files) into this app's notebook format.
// Built and run by scripts/goodnotes-import.sh, compiled together with Notes/Notebook.swift; the script
// unzips each .goodnotes file into a same-named directory first (Mac Catalyst has no Process to do it here).
//
// A .goodnotes file is a ZIP holding:
//   index.events.pb   length-delimited protobuf log: title (kinds 30/31), attachment id -> file (6), page templates (2),
//                     pages with a fractional sort key (54), template changes (3), current page (10),
//                     whiteboards (64), outline entries (62), bookmarks (56)
//   notes/<id>        one page's elements; ink is kind 7, an Apple-LZ4 ("bv41") compressed `tpl`
//                     image holding a path of quadratic curves; images are kind 1 (frame + attachment);
//                     a text document's page is kind 13, a Plate editor document as a Yjs update (Yjs.swift);
//                     a page's ink file id is its page id + 1
//   attachments/<id>  PDFs: paper templates and imported documents
//   thumbnail.jpg     page 1, used here to check each conversion

// MARK: - Schema-less protobuf

struct Field {
    let number: Int
    let value: UInt64 // varint, or the raw bits of a fixed32/fixed64
    let bytes: [UInt8]
    var string: String? { String(bytes: bytes, encoding: .utf8) }
    var message: [Field] { (try? Proto.fields(bytes)) ?? [] }
    var float: CGFloat { CGFloat(Float(bitPattern: UInt32(truncatingIfNeeded: value))) }
}

extension Array where Element == Field {
    func field(_ number: Int) -> Field? { first { $0.number == number } }
}

enum Proto {
    struct Malformed: Error {}

    static func varint(_ b: [UInt8], _ i: inout Int) throws -> UInt64 {
        var result: UInt64 = 0, shift: UInt64 = 0
        while true {
            guard i < b.count, shift < 64 else { throw Malformed() }
            let c = b[i]
            i += 1
            result |= UInt64(c & 0x7F) << shift
            shift += 7
            if c < 0x80 { return result }
        }
    }

    static func fields(_ b: [UInt8]) throws -> [Field] {
        var i = 0, out: [Field] = []
        func fixed(_ n: Int) throws -> UInt64 {
            guard i + n <= b.count else { throw Malformed() }
            defer { i += n }
            return b[i..<i + n].reversed().reduce(0) { $0 << 8 | UInt64($1) }
        }
        while i < b.count {
            let key = try varint(b, &i)
            let number = Int(key >> 3)
            switch key & 7 {
            case 0: out.append(Field(number: number, value: try varint(b, &i), bytes: []))
            case 1: out.append(Field(number: number, value: try fixed(8), bytes: []))
            case 5: out.append(Field(number: number, value: try fixed(4), bytes: []))
            case 2:
                let n = Int(try varint(b, &i))
                guard i + n <= b.count else { throw Malformed() }
                out.append(Field(number: number, value: 0, bytes: Array(b[i..<i + n])))
                i += n
            default: throw Malformed()
            }
        }
        return out
    }

    /// A file of varint-length-prefixed messages.
    static func delimited(_ b: [UInt8]) throws -> [[Field]] {
        var i = 0, out: [[Field]] = []
        while i < b.count {
            let n = Int(try varint(b, &i))
            guard i + n <= b.count else { throw Malformed() }
            out.append(try fields(Array(b[i..<i + n])))
            i += n
        }
        return out
    }
}

// MARK: - tpl images (github.com/troydhanson/tpl layout; here 'f' is 4 bytes)

indirect enum Tpl {
    case num(UInt32)
    case list([[Tpl]]) // A(...): one item list per element; S(...) members are inlined

    var n: UInt32 { if case .num(let v) = self { v } else { 0 } }
    var f: CGFloat { CGFloat(Float(bitPattern: n)) }
    var entries: [[Tpl]] { if case .list(let v) = self { v } else { [] } }
}

enum TplImage {
    struct Malformed: Error {}
    private indirect enum Token { case scalar(Int), array([Token]), group([Token]) }

    static func parse(_ b: [UInt8]) throws -> (format: String, values: [Tpl]) {
        guard b.count > 8, b.starts(with: Array("tpl".utf8)), let end = b[8...].firstIndex(of: 0),
              let format = String(bytes: b[8..<end], encoding: .ascii) else { throw Malformed() }
        var tokens = Substring(format)
        let parsed = try tokenize(&tokens)
        var i = end + 1
        let values = try read(parsed, b, &i)
        guard i == b.count else { throw Malformed() }
        return (format, values)
    }

    private static func tokenize(_ s: inout Substring) throws -> [Token] {
        var out: [Token] = []
        while let c = s.first, c != ")" {
            s.removeFirst()
            switch c {
            case "v": out.append(.scalar(2))
            case "u", "i", "f": out.append(.scalar(4))
            case "A", "S":
                guard s.first == "(" else { throw Malformed() }
                s.removeFirst()
                let inner = try tokenize(&s)
                guard s.first == ")" else { throw Malformed() }
                s.removeFirst()
                out.append(c == "A" ? .array(inner) : .group(inner))
            default: throw Malformed()
            }
        }
        return out
    }

    private static func read(_ tokens: [Token], _ b: [UInt8], _ i: inout Int) throws -> [Tpl] {
        var out: [Tpl] = []
        for token in tokens {
            switch token {
            case .scalar(let size):
                guard i + size <= b.count else { throw Malformed() }
                out.append(.num(b[i..<i + size].reversed().reduce(0) { $0 << 8 | UInt32($1) }))
                i += size
            case .group(let inner):
                out += try read(inner, b, &i)
            case .array(let inner):
                guard i + 4 <= b.count else { throw Malformed() }
                let count = Int(b[i..<i + 4].reversed().reduce(0) { $0 << 8 | UInt32($1) })
                i += 4
                guard count <= b.count else { throw Malformed() }
                out.append(.list(try (0..<count).map { _ in try read(inner, b, &i) }))
            }
        }
        return out
    }
}

// MARK: - GoodNotes content

struct InkStroke {
    var subpaths: [[(point: CGPoint, width: CGFloat)]]
    var color: UIColor
    var highlighter: Bool
}

struct GNTextBox {
    var frame: CGRect
    var runs: [(text: String, color: UIColor, size: CGFloat)]
}

struct GNConnector {
    var from: (box: String, angle: CGFloat)
    var to: (box: String, angle: CGFloat)
    var width: CGFloat
    var color: UIColor
}

struct PageInk {
    var strokes: [InkStroke] = []
    var images: [(attachment: String, frame: CGRect)] = []
    var textBoxes: [String: GNTextBox] = [:]
    var connectors: [GNConnector] = []
    var document: [String]? // a text document's lines, title first
    var shapes = 0
    var unsupported = 0 // strokes and elements in formats this converter doesn't read
}

private func point(_ field: Field?) -> CGPoint? {
    guard let m = field?.message else { return nil }
    return CGPoint(x: m.field(1)?.float ?? 0, y: m.field(2)?.float ?? 0)
}

private func color(_ field: Field?, default fallback: [CGFloat] = [0, 0, 0, 1]) -> [CGFloat] {
    var rgba = fallback
    for c in field?.message ?? [] where (1...4).contains(c.number) { rgba[c.number - 1] = c.float }
    return rgba
}

enum GoodNotes {
    /// Live content of one notes/<id> file. Records are versions: the last one per element id wins,
    /// field 14 = 1 marks a deleted element, and an ink element with an empty path was erased.
    static func ink(_ bytes: [UInt8]) throws -> PageInk {
        var order: [(kind: Int, id: String)] = [], latest: [String: [Field]] = [:]
        for record in try Proto.delimited(bytes) {
            for element in record where element.bytes.count > 40 && [1, 7, 13, 21, 22].contains(element.number) {
                let fields = element.message
                guard let id = fields.field(1)?.string else { continue }
                if latest[id] == nil { order.append((element.number, id)) }
                latest[id] = fields
            }
        }
        var page = PageInk()
        for (kind, id) in order {
            guard let fields = latest[id], fields.field(14)?.value != 1 else { continue }
            switch kind {
            case 7: try addInk(fields, to: &page)
            case 1: addImage(fields, to: &page)
            case 21: try addTextBox(id, fields, to: &page)
            case 22: addConnector(fields, to: &page)
            default: page.document = try document(fields) // 13
            }
        }
        return page
    }

    private static func addInk(_ fields: [Field], to page: inout PageInk) throws {
        let rgba = color(fields.field(4))
        // Notebook highlighters are constant-width strokes at 50% opacity; translucent variable-width
        // strokes are whiteboard brushes and stay ordinary ink.
        var highlighter = rgba[3] < 0.99
        let move = point(fields.field(6)) ?? .zero // lasso moves are stored as an offset
        var path: [[(CGPoint, CGFloat)]]?

        if let geometry = fields.field(9)?.message, !geometry.isEmpty {
            path = shape(geometry)
            if path != nil { page.shapes += 1 }
        } else if let payload = fields.field(2)?.bytes, !payload.isEmpty {
            let raw = try [UInt8]((Data(payload) as NSData).decompressed(using: .lz4) as Data)
            let (format, v) = try TplImage.parse(raw)
            if format.hasPrefix("vuA(v)A(S(uu))A(S(uuuu))") {
                // Constant width: start points (x, y) and quads (cx, cy, x, y).
                let width = v[1].f
                path = curves(commands: v[2].entries.map { $0[0].n },
                              starts: v[3].entries.map { (CGPoint(x: $0[0].f, y: $0[1].f), width) },
                              quads: v[4].entries.map { ((CGPoint(x: $0[0].f, y: $0[1].f)), (CGPoint(x: $0[2].f, y: $0[3].f), width)) })
            } else if format.hasPrefix("vuA(v)A(S(uuuuu))A(S(uuuuuuuuuuu))") {
                highlighter = false
                // Variable width: start (x, y, w, _, _) and quads (_, cx, cy, cw, _, _, x, y, w, _, _).
                path = curves(commands: v[2].entries.map { $0[0].n },
                              starts: v[3].entries.map { (CGPoint(x: $0[0].f, y: $0[1].f), $0[2].f) },
                              quads: v[4].entries.map { ((CGPoint(x: $0[1].f, y: $0[2].f)), (CGPoint(x: $0[6].f, y: $0[7].f), $0[8].f)) })
            }
        } else {
            return
        }
        guard let path else { page.unsupported += 1; return }
        guard !path.isEmpty else { return } // erased: GoodNotes keeps the record with an empty path
        let moved = path.map { $0.map { (point: CGPoint(x: $0.0.x + move.x, y: $0.0.y + move.y), width: $0.1) } }
        page.strokes.append(InkStroke(subpaths: moved, color: UIColor(red: rgba[0], green: rgba[1], blue: rgba[2], alpha: highlighter ? 1 : rgba[3]),
                                      highlighter: highlighter))
    }

    /// Shape-tool geometry (stroke field 9): 1 polyline, 2 three-point curve, 3 rectangle (center, size, rotation),
    /// 4 ellipse (center, radii, rotation).
    private static func shape(_ geometry: [Field]) -> [[(CGPoint, CGFloat)]]? {
        let width = geometry.field(15)?.float ?? 2
        if let line = geometry.field(1)?.message {
            let points = line.filter { $0.number == 1 }.compactMap(point)
            guard points.count > 1 else { return nil }
            return [zip(points, points.dropFirst()).flatMap { a, b in
                let n = max(1, Int((hypot(b.x - a.x, b.y - a.y) / 1.5).rounded(.up)))
                return (0..<n).map { k in (CGPoint(x: a.x + (b.x - a.x) * CGFloat(k) / CGFloat(n), y: a.y + (b.y - a.y) * CGFloat(k) / CGFloat(n)), width) }
            } + [(points.last!, width)]]
        }
        if let curve = geometry.field(2)?.message, let p0 = point(curve.field(1)), let c = point(curve.field(2)), let p1 = point(curve.field(3)) {
            return [(0...32).map { k in
                let t = CGFloat(k) / 32, u = 1 - t
                return (CGPoint(x: u * u * p0.x + 2 * u * t * c.x + t * t * p1.x, y: u * u * p0.y + 2 * u * t * c.y + t * t * p1.y), width)
            }]
        }
        if let rect = geometry.field(3)?.message, let center = point(rect.field(1)), let size = point(rect.field(2)) {
            let rotation = rect.field(3)?.float ?? 0
            let corners = [(-1.0, -1.0), (1, -1), (1, 1), (-1, 1), (-1, -1)].map { sx, sy in
                let x = sx * size.x / 2, y = sy * size.y / 2
                return (CGPoint(x: center.x + x * cos(rotation) - y * sin(rotation), y: center.y + x * sin(rotation) + y * cos(rotation)), width)
            }
            // Dense samples keep PencilKit's spline from rounding the corners.
            return [zip(corners, corners.dropFirst()).flatMap { a, b in
                (0..<24).map { k in
                    let t = CGFloat(k) / 24
                    return (CGPoint(x: a.0.x + (b.0.x - a.0.x) * t, y: a.0.y + (b.0.y - a.0.y) * t), width)
                }
            } + [corners[4]]]
        }
        if let ellipse = geometry.field(4)?.message, let center = point(ellipse.field(1)), let r = point(ellipse.field(2)) {
            let rotation = ellipse.field(3)?.float ?? 0
            return [(0...96).map { k in
                let t = CGFloat(k) / 96 * 2 * .pi
                let x = r.x * cos(t), y = r.y * sin(t)
                return (CGPoint(x: center.x + x * cos(rotation) - y * sin(rotation), y: center.y + x * sin(rotation) + y * cos(rotation)), width)
            }]
        }
        return nil
    }

    private static func addImage(_ fields: [Field], to page: inout PageInk) {
        guard let attachment = fields.field(4)?.string, let frame = fields.field(2)?.message,
              let origin = point(frame.field(1)), let size = point(frame.field(2)) else { return }
        page.images.append((attachment, CGRect(x: origin.x, y: origin.y, width: size.x, height: size.y)))
    }

    /// Text box: top-left in field 20, size in 32.2, paragraphs (text + style) in an LZ4 protobuf at 32.1.2.
    private static func addTextBox(_ id: String, _ fields: [Field], to page: inout PageInk) throws {
        guard let origin = point(fields.field(20)?.message.field(1)), let body = fields.field(32)?.message,
              let size = point(body.field(2)), let payload = body.field(1)?.message.field(2)?.bytes, !payload.isEmpty else { return }
        let raw = try [UInt8]((Data(payload) as NSData).decompressed(using: .lz4) as Data)
        let runs: [(String, UIColor, CGFloat)] = try Proto.fields(raw).filter { $0.number == 1 }.compactMap { paragraph in
            let p = paragraph.message
            guard let text = p.field(1)?.string else { return nil }
            let style = p.field(2)?.message ?? []
            let rgba = color(style.field(3))
            let fontSize = style.field(40)?.float ?? 24
            return (text, UIColor(red: rgba[0], green: rgba[1], blue: rgba[2], alpha: rgba[3]), fontSize > 0 ? fontSize : 24)
        }
        guard runs.contains(where: { !$0.0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { return }
        page.textBoxes[id] = GNTextBox(frame: CGRect(x: origin.x, y: origin.y, width: size.x, height: size.y), runs: runs)
    }

    /// Text document (kind 13): the Plate editor's value as a Yjs update in field 10, under the root "content". Its
    /// blocks are XML text elements with attributes (type, listStyleType, checked, listStart, indent); dates are inline
    /// elements. Becomes plain lines, with lists written the way this app's text boxes write them (TextLists).
    private static func document(_ fields: [Field]) throws -> [String]? {
        guard let update = fields.field(10)?.bytes, !update.isEmpty else { return nil }
        var lines: [String] = []
        for case .element(let block) in try Yjs.root(update, name: "content").children { lines += documentLines(block) }
        // One blank line at most between paragraphs, none at the ends.
        lines = lines.reduce(into: []) { out, line in if !line.isEmpty || out.last?.isEmpty == false { out.append(line) } }
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines
    }

    private static func documentLines(_ block: Yjs.Element) -> [String] {
        func int(_ value: Any?) -> Int? { (value as? Int64).map(Int.init) ?? (value as? Double).map(Int.init) }
        var text = "", nested: [String] = [], dated = false
        for child in block.children {
            switch child {
            case .text(let run): text += run
            case .element(let e):
                switch e.attributes["type"] as? String {
                case "date":
                    text += e.attributes["date"] as? String ?? ""
                    dated = true
                case "slash_input": break // a slash command being typed
                default: nested += documentLines(e) // table rows and cells, or anything else holding blocks
                }
            }
        }
        let a = block.attributes
        let marker = switch a["listStyleType"] as? String {
        case "todo": a["checked"] as? Bool == true ? TextLists.checked : TextLists.unchecked
        case "decimal": "\(int(a["listStart"]) ?? 1). "
        case .some: TextLists.bullet
        case nil: ""
        }
        let indent = String(repeating: "    ", count: max(0, (int(a["indent"]) ?? 0) - (marker.isEmpty ? 0 : 1)))
        let own = text.trimmingCharacters(in: .whitespaces)
        let lines = nested.isEmpty || !own.isEmpty ? [indent + marker + own] + nested : nested
        // GoodNotes shows a date as a chip; a blank line before a dated paragraph keeps such headings apart.
        // Table rows get a blank line after them.
        return (dated && marker.isEmpty ? [""] : []) + lines + (a["type"] as? String == "tr" ? [""] : [])
    }

    /// Connector between two text boxes, each end given as an angle on that box's edge.
    private static func addConnector(_ fields: [Field], to page: inout PageInk) {
        guard let ends = fields.field(21)?.message else { return }
        func end(_ number: Int) -> (String, CGFloat)? {
            guard let anchor = ends.field(number)?.message.field(2)?.message,
                  let box = anchor.field(1)?.message.field(1)?.string else { return nil }
            return (box, anchor.field(2)?.float ?? 0)
        }
        guard let from = end(1), let to = end(3) else { page.unsupported += 1; return }
        let style = fields.field(32)?.message ?? []
        let rgba = color(style.field(3)?.message.field(1))
        page.connectors.append(GNConnector(from: from, to: to, width: style.field(1)?.float ?? 3,
                                         color: UIColor(red: rgba[0], green: rgba[1], blue: rgba[2], alpha: rgba[3])))
    }

    /// Samples move-to (0) / quad-to (1) commands into points about 1.5 units apart.
    private static func curves(commands: [UInt32], starts: [(CGPoint, CGFloat)],
                               quads: [(CGPoint, (CGPoint, CGFloat))]) -> [[(CGPoint, CGFloat)]]? {
        var subpaths: [[(CGPoint, CGFloat)]] = [], current: [(CGPoint, CGFloat)] = []
        var s = 0, q = 0
        for command in commands {
            switch command {
            case 0:
                guard s < starts.count else { return nil }
                if !current.isEmpty { subpaths.append(current) }
                current = [starts[s]]
                s += 1
            case 1:
                guard q < quads.count, let (p0, w0) = current.last else { return nil }
                let (c, (p1, w1)) = quads[q]
                q += 1
                let length = hypot(c.x - p0.x, c.y - p0.y) + hypot(p1.x - c.x, p1.y - c.y)
                let n = max(1, Int((length / 1.5).rounded(.up)))
                for k in 1...n {
                    let t = CGFloat(k) / CGFloat(n), u = 1 - t
                    let x = u * u * p0.x + 2 * u * t * c.x + t * t * p1.x
                    let y = u * u * p0.y + 2 * u * t * c.y + t * t * p1.y
                    current.append((CGPoint(x: x, y: y), w0 + (w1 - w0) * t))
                }
            default:
                return nil
            }
        }
        if !current.isEmpty { subpaths.append(current) }
        return subpaths
    }

    /// GoodNotes names a page's ink file with the page id plus one.
    static func inkID(forPage id: String) -> String? {
        guard let uuid = UUID(uuidString: id) else { return nil }
        var b = withUnsafeBytes(of: uuid.uuid) { Array($0) }
        for k in stride(from: 15, through: 0, by: -1) {
            b[k] &+= 1
            if b[k] != 0 { break }
        }
        return b.withUnsafeBytes { UUID(uuid: $0.load(as: uuid_t.self)) }.uuidString
    }
}

/// PencilKit renders a point of size s about 2s - 4 wide for pens and 0.6s - 2 for the marker (measured).
func pencilKitStrokes(_ stroke: InkStroke, scale: CGFloat, offset: CGPoint) -> [PKStroke] {
    let ink = PKInk(stroke.highlighter ? .marker : .monoline, color: stroke.color)
    return stroke.subpaths.map { path in
        let samples = path.count == 1 ? [path[0], path[0]] : path
        let points = samples.enumerated().map { i, sample in
            let width = sample.width / scale
            let size = stroke.highlighter ? (width + 2) / 0.6 : max(width, 0.6) / 2 + 2
            return PKStrokePoint(location: CGPoint(x: (sample.point.x - offset.x) / scale, y: (sample.point.y - offset.y) / scale),
                                 timeOffset: Double(i) * 0.001, size: CGSize(width: size, height: size),
                                 opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        return PKStroke(ink: ink, path: PKStrokePath(controlPoints: points, creationDate: Date()))
    }
}

// MARK: - Conversion

struct Report {
    var title = ""
    var pages = 0
    var strokes = 0
    var highlighter = 0
    var shapes = 0
    var textBoxes = 0
    var arrows = 0
    var unsupported = 0
    var outline = 0
    var bookmarks = 0
    var similarity: Double?
}

struct Template {
    var attachment: String?
    var pageNumber: Int
    var size: CGSize
}

struct Page {
    let id: String
    var template: String?
    var sortKey = ""
}

/// GoodNotes coordinates per PDF point, used when a page has no PDF to measure against.
let defaultScale: CGFloat = 1467.0 / 800.0
var keepAlive: [PDFDocument] = [] // source documents must outlive the pages copied from them

func convert(archive dir: URL, fallbackTitle: String, into parent: URL) throws -> (URL, Report) {
    var report = Report(title: fallbackTitle)
    var templates: [String: Template] = [:], pages: [String: Page] = [:], boards: [(String, String)] = []
    var files: [String: String] = [:] // attachment id -> file name in attachments/
    var current: String?
    var bookmarked: [String: Bool] = [:] // page id -> latest bookmark state
    var outlineEntries: [String: (page: String, title: String, y: CGFloat?, sortKey: String)] = [:]
    for record in try Proto.delimited([UInt8](Data(contentsOf: dir.appending(path: "index.events.pb")))) {
        for event in record where event.number != 1 {
            let m = event.message
            switch event.number {
            case 30, 31:
                if let title = m.field(2)?.message.field(1)?.string, !title.isEmpty { report.title = title }
            case 6:
                if let id = m.field(1)?.string, let file = m.field(2)?.string { files[id] = file }
            case 2:
                guard let id = m.field(2)?.string else { continue }
                let size = m.field(8)?.message ?? []
                templates[id] = Template(attachment: m.field(4)?.string, pageNumber: max(1, Int(m.field(5)?.value ?? 1)),
                                         size: CGSize(width: size.field(1)?.float ?? 0, height: size.field(2)?.float ?? 0))
            case 54, 3:
                guard let id = m.field(2)?.string else { continue }
                var page = pages[id] ?? Page(id: id)
                if let template = m.field(3)?.message.field(1)?.string { page.template = template }
                if event.number == 54, let key = m.field(4)?.message.field(1)?.string { page.sortKey = key }
                pages[id] = page
            case 10:
                current = m.field(2)?.string
            case 64:
                if let id = m.field(2)?.string { boards.append((id, m.field(3)?.message.field(1)?.string ?? "Board")) }
            case 62:
                // Outline entry: page (1), entry id (2), position (3.1, GoodNotes units from the top), title (5), sort key (6).
                guard let page = m.field(1)?.string, let id = m.field(2)?.string, let title = m.field(5)?.string else { continue }
                let y = m.field(3)?.message.field(1)?.message.field(2)?.float
                outlineEntries[id] = (page, title, y, m.field(6)?.string ?? "")
            case 56:
                if let page = m.field(2)?.string { bookmarked[page] = m.field(3)?.message.field(1)?.value == 1 }
            default: break
            }
        }
    }

    func pageInk(_ id: String) throws -> PageInk {
        guard let inkID = GoodNotes.inkID(forPage: id) else { return PageInk() }
        let url = dir.appending(path: "notes/\(inkID)")
        guard let bytes = try? [UInt8](Data(contentsOf: url)) else { return PageInk() }
        return try GoodNotes.ink(bytes)
    }
    var attachments: [String: PDFDocument] = [:]
    func attachment(_ id: String) -> PDFDocument? {
        if let doc = attachments[id] { return doc }
        let doc = PDFDocument(url: dir.appending(path: "attachments/\(files[id] ?? id)"))
        attachments[id] = doc
        if let doc { keepAlive.append(doc) }
        return doc
    }
    /// The background with the page's images drawn over it. Frames are in GoodNotes units; `scale`
    /// converts them to PDF points.
    func decorated(_ page: PDFPage, _ ink: PageInk, scale: CGFloat) -> PDFPage {
        let pictures = ink.images.compactMap { image in
            UIImage(contentsOfFile: dir.appending(path: "attachments/\(files[image.attachment] ?? image.attachment)").path).map { ($0, image.frame) }
        }
        guard !pictures.isEmpty else { return page }
        let rect = CGRect(origin: .zero, size: page.bounds(for: .cropBox).size)
        let data = UIGraphicsPDFRenderer(bounds: rect).pdfData { ctx in
            ctx.beginPage()
            let cg = ctx.cgContext
            cg.saveGState()
            cg.translateBy(x: 0, y: rect.height)
            cg.scaleBy(x: 1, y: -1)
            page.draw(with: .cropBox, to: cg)
            cg.restoreGState()
            for (picture, frame) in pictures {
                picture.draw(in: CGRect(x: frame.minX / scale, y: frame.minY / scale, width: frame.width / scale, height: frame.height / scale))
            }
        }
        let doc = PDFDocument(data: data)!
        keepAlive.append(doc)
        return doc.page(at: 0)!
    }
    func blankPage(_ size: CGSize) -> PDFPage {
        let rect = CGRect(origin: .zero, size: size)
        let data = UIGraphicsPDFRenderer(bounds: rect).pdfData { ctx in
            ctx.beginPage()
            Store.paperColor.setFill()
            ctx.fill(rect)
        }
        let doc = PDFDocument(data: data)!
        keepAlive.append(doc)
        return doc.page(at: 0)!
    }

    let pdf = PDFDocument()
    var ids: [UUID] = [], drawings: [PKDrawing] = [], itemsByPage: [UUID: PageItems] = [:]
    func add(_ page: PDFPage, id: String, drawing: PKDrawing, ink: PageInk, items: PageItems) {
        if !items.isEmpty, let uuid = UUID(uuidString: id) { itemsByPage[uuid] = items }
        pdf.insert(page, at: pdf.pageCount)
        ids.append(UUID(uuidString: id) ?? UUID())
        drawings.append(drawing)
        report.pages += 1
        report.strokes += ink.strokes.count
        report.highlighter += ink.strokes.filter(\.highlighter).count
        report.shapes += ink.shapes
        report.textBoxes += items.boxes.count
        report.arrows += items.connectors.count
        report.unsupported += ink.unsupported
    }

    // Fractional-index sort keys order pages by plain byte comparison.
    let ordered = pages.values.sorted {
        $0.sortKey == $1.sortKey ? $0.id < $1.id : $0.sortKey.utf8.lexicographicallyPrecedes($1.sortKey.utf8)
    }
    // A GoodNotes text document (nothing but typed text, on one endless page) becomes a text document: its first line
    // the title, the rest its text.
    let inks = try ordered.map { try pageInk($0.id) }
    if boards.isEmpty, !inks.isEmpty,
       inks.allSatisfy({ $0.document != nil && $0.strokes.isEmpty && $0.images.isEmpty && $0.textBoxes.isEmpty }) {
        let lines = inks.flatMap { $0.document! }
        let title = lines.first?.trimmingCharacters(in: .whitespaces) ?? ""
        let doc = try Store.createTextDocument(title: title.isEmpty ? report.title : title, in: parent)
        try Data(lines.dropFirst().drop { $0.isEmpty }.joined(separator: "\n").utf8).write(to: Store.textFile(doc))
        report.title = Store.title(of: doc)
        _ = Store.cover(of: doc)
        return (doc, report)
    }

    var geometry: [String: (scale: CGFloat, height: CGFloat)] = [:] // page id -> GoodNotes units per point, height in points
    var paperUse: [String: Int] = [:] // one-page template attachment -> pages using it
    for page in ordered {
        let template = page.template.flatMap { templates[$0] }
        let ink = try pageInk(page.id)
        var background: PDFPage?
        var scale = defaultScale
        if let template, let id = template.attachment, let source = attachment(id)?.page(at: template.pageNumber - 1),
           let copy = source.copy() as? PDFPage {
            background = copy
            let width = source.bounds(for: .cropBox).width
            if template.size.width > 0, width > 0 { scale = template.size.width / width }
            if attachment(id)?.pageCount == 1 { paperUse[id, default: 0] += 1 }
        }
        let size = template.map { CGSize(width: $0.size.width / scale, height: $0.size.height / scale) } ?? CGSize(width: 612, height: 792)
        let strokes = ink.strokes.flatMap { pencilKitStrokes($0, scale: scale, offset: .zero) }
        let finished = decorated(background ?? blankPage(size), ink, scale: scale)
        geometry[page.id] = (scale, finished.bounds(for: .cropBox).height)
        guard let document = ink.document else {
            add(finished, id: page.id, drawing: PKDrawing(strokes: strokes), ink: ink, items: editableItems(ink, scale: scale))
            continue
        }
        // A text document scrolls without pages in GoodNotes; here it continues onto copies of its page.
        for (k, items) in documentPages(document, size: finished.bounds(for: .cropBox).size).enumerated() {
            if k == 0 {
                add(finished, id: page.id, drawing: PKDrawing(strokes: strokes), ink: ink, items: items)
            } else if let copy = finished.copy() as? PDFPage {
                add(copy, id: UUID().uuidString, drawing: PKDrawing(), ink: PageInk(), items: items)
            }
        }
    }

    // Whiteboards are unbounded canvases: one page fitted around the ink, at 1 GoodNotes unit per point.
    for (id, _) in boards {
        let ink = try pageInk(id)
        let points = ink.strokes.flatMap { $0.subpaths.flatMap { $0.map(\.point) } }
        guard let first = points.first else { continue }
        let bounds = points.reduce(CGRect(origin: first, size: .zero)) { $0.union(CGRect(origin: $1, size: .zero)) }.insetBy(dx: -40, dy: -40)
        let strokes = ink.strokes.flatMap { pencilKitStrokes($0, scale: 1, offset: bounds.origin) }
        add(blankPage(bounds.size), id: id, drawing: PKDrawing(strokes: strokes), ink: ink, items: editableItems(ink, scale: 1))
    }

    guard pdf.pageCount > 0, let data = pdf.dataRepresentation() else { throw CocoaError(.fileWriteUnknown) }
    let notebook = parent.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: notebook.appending(path: "ink"), withIntermediateDirectories: true)
    try data.write(to: notebook.appending(path: "doc.pdf"))
    if !itemsByPage.isEmpty { try FileManager.default.createDirectory(at: notebook.appending(path: "items"), withIntermediateDirectories: true) }
    for (id, items) in itemsByPage {
        try JSONEncoder().encode(items).write(to: notebook.appending(path: "items/\(id.uuidString).json"))
    }
    for (id, drawing) in zip(ids, drawings) where !drawing.strokes.isEmpty {
        try drawing.dataRepresentation().write(to: notebook.appending(path: "ink/\(id.uuidString).data"))
    }
    // New pages get the paper most pages use (a one-page template, not an imported document).
    if let paper = paperUse.max(by: { $0.value < $1.value })?.key, let source = attachment(paper)?.page(at: 0),
       let copy = source.copy() as? PDFPage {
        let doc = PDFDocument()
        doc.insert(copy, at: 0)
        try doc.dataRepresentation()?.write(to: notebook.appending(path: "paper.pdf"))
    }

    let bookmarks = ordered.filter { bookmarked[$0.id] == true }.compactMap { UUID(uuidString: $0.id) }
    let position = Dictionary(uniqueKeysWithValues: ordered.enumerated().map { ($1.id, $0) })
    let outline: [OutlineEntry] = outlineEntries.values
        .filter { position[$0.page] != nil }
        .sorted { (position[$0.page]!, $0.sortKey) < (position[$1.page]!, $1.sortKey) }
        .compactMap { entry in
            guard let page = UUID(uuidString: entry.page), let g = geometry[entry.page] else { return nil }
            return OutlineEntry(title: entry.title, page: page, y: entry.y.map { g.height - $0 / g.scale }) // PDF y grows upward
        }
    report.bookmarks = bookmarks.count
    report.outline = outline.count

    let lastPage = current.flatMap { c in ordered.firstIndex { $0.id == c } }
    try JSONEncoder().encode(Meta(title: report.title, paper: .blank, pages: ids, lastPage: lastPage,
                                  bookmarks: bookmarks.isEmpty ? nil : bookmarks, outline: outline.isEmpty ? nil : outline))
        .write(to: notebook.appending(path: "meta.json"))
    _ = Store.cover(of: notebook)
    SearchIndex.rebuild(notebook, pages: nil)
    return (notebook, report)
}

/// A text document's lines (title first) as text boxes filling pages of `size` points, one box per page: the title
/// in 20 pt, the rest in 12 pt (a Text tool size, so boxes added later match).
func documentPages(_ lines: [String], size: CGSize) -> [PageItems] {
    let margin = (size.width * 0.07).rounded(), width = size.width - 2 * margin
    func box(_ lines: [String], top: CGFloat, fontSize: CGFloat) -> TextBox {
        var box = TextBox(frame: CGRect(x: margin, y: top, width: width, height: 0), text: lines.joined(separator: "\n"), fontSize: fontSize)
        let text = NSAttributedString(string: box.text, attributes: PageItems.attributes(box))
        let bounds = text.boundingRect(with: CGSize(width: width - 2 * PageItems.inset, height: .greatestFiniteMagnitude),
                                       options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        box.frame.size.height = ceil(bounds.height) + 2 * PageItems.inset
        return box
    }
    guard let title = lines.first else { return [PageItems()] }
    var pages = [PageItems(boxes: [box([title], top: margin, fontSize: 20)])]
    var top = pages[0].boxes[0].frame.maxY + 4, chunk: [String] = []
    // ponytail: measures the growing chunk once per line; fine for documents of a few hundred lines
    for line in lines.dropFirst() {
        if chunk.isEmpty && line.isEmpty { continue } // no blank line at the top of a page
        if !chunk.isEmpty, box(chunk + [line], top: top, fontSize: 12).frame.maxY > size.height - margin {
            pages[pages.count - 1].boxes.append(box(chunk, top: top, fontSize: 12))
            pages.append(PageItems())
            top = margin
            chunk = line.isEmpty ? [] : [line]
        } else {
            chunk.append(line)
        }
    }
    if !chunk.isEmpty { pages[pages.count - 1].boxes.append(box(chunk, top: top, fontSize: 12)) }
    return pages
}

/// GoodNotes text boxes and connectors as this app's editable text boxes and arrows, in PDF points.
/// Each box takes the font size and color of its first non-blank paragraph.
func editableItems(_ ink: PageInk, scale: CGFloat) -> PageItems {
    var items = PageItems()
    for (id, box) in ink.textBoxes {
        guard let uuid = UUID(uuidString: id) else { continue }
        let first = box.runs.first { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 1
        (first?.color ?? .black).getRed(&r, green: &g, blue: &b, alpha: &a)
        let f = box.frame
        items.boxes.append(TextBox(id: uuid, frame: CGRect(x: f.minX / scale, y: f.minY / scale, width: f.width / scale, height: f.height / scale),
                                   text: box.runs.map(\.text).joined(), fontSize: (first?.size ?? 24) / scale, rgba: [r, g, b, a]))
    }
    items.boxes.sort { ($0.frame.minY, $0.frame.minX) < ($1.frame.minY, $1.frame.minX) }
    let ids = Set(items.boxes.map(\.id))
    for connector in ink.connectors {
        guard let from = UUID(uuidString: connector.from.box), let to = UUID(uuidString: connector.to.box),
              ids.contains(from), ids.contains(to) else { continue }
        items.connectors.append(Connector(from: from, to: to))
    }
    return items
}

/// Folder colors from the backup's .goodnotesmeta ({"items": [{"path", "color", "symbol"}]}).
/// GoodNotes symbol names don't match SF Symbols, so only colors carry over.
func applyFolderStyles(backup: URL, library: URL) {
    struct Item: Decodable { let path: String; let color: String? }
    struct Meta: Decodable { let items: [Item] }
    guard let data = try? Data(contentsOf: backup.appending(path: ".goodnotesmeta")),
          let meta = try? JSONDecoder().decode(Meta.self, from: data) else { return }
    for item in meta.items {
        let folder = library.appending(path: item.path)
        guard let color = item.color, FolderStyle.colors.contains(color),
              FileManager.default.fileExists(atPath: folder.path) else { continue }
        try? Store.setFolderStyle(FolderStyle(color: color), of: folder)
    }
}

// MARK: - Verification against GoodNotes' own thumbnail

/// Pearson correlation of two images as 48x48 grayscale; 1 means identical layout of ink.
func similarity(_ a: UIImage, _ b: UIImage) -> Double {
    func pixels(_ image: UIImage) -> [Double] {
        let side = 48
        var buffer = [UInt8](repeating: 0, count: side * side)
        let ctx = CGContext(data: &buffer, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
        if let cg = image.cgImage { ctx.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side)) }
        return buffer.map(Double.init)
    }
    let x = pixels(a), y = pixels(b)
    let mx = x.reduce(0, +) / Double(x.count), my = y.reduce(0, +) / Double(y.count)
    let cov = zip(x, y).map { ($0 - mx) * ($1 - my) }.reduce(0, +)
    let vx = x.map { ($0 - mx) * ($0 - mx) }.reduce(0, +), vy = y.map { ($0 - my) * ($0 - my) }.reduce(0, +)
    return vx > 0 && vy > 0 ? cov / (vx * vy).squareRoot() : 0
}

// MARK: - Entry point

@main
enum GoodNotesImport {
    static func main() throws {
        let args = CommandLine.arguments
        guard args.count == 3 else {
            print("usage: GoodNotesImport UNPACKED_BACKUP_DIR OUTPUT_DIR")
            exit(2)
        }
        let backup = URL(fileURLWithPath: args[1]).standardizedFileURL
        let output = URL(fileURLWithPath: args[2]).standardizedFileURL
        let library = output.appending(path: "GoodNotes")
        defer { applyFolderStyles(backup: backup, library: library) }
        let lowMatches = output.appending(path: "low-match")
        let fm = FileManager.default

        let files = (fm.enumerator(at: backup, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? [])
            .filter { $0.pathExtension == "goodnotes" }
            .sorted { $0.path < $1.path }
        var totals = Report(), failures: [String] = [], suspicious: [String] = []
        for file in files {
            let relative = String(file.deletingLastPathComponent().standardizedFileURL.path.dropFirst(backup.path.count))
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let name = file.deletingPathExtension().lastPathComponent
            let parent = relative.isEmpty ? library : library.appending(path: relative)
            let unpacked = file
            do {
                try fm.createDirectory(at: parent, withIntermediateDirectories: true)
                let (notebook, converted) = try convert(archive: unpacked, fallbackTitle: name, into: parent)
                var report = converted
                if Store.isTextDocument(notebook) {
                    let lines = (try String(contentsOf: Store.textFile(notebook), encoding: .utf8)).split(separator: "\n", omittingEmptySubsequences: false)
                    print("\(relative.isEmpty ? "" : relative + "/")\(report.title): text document, \(lines.count) lines")
                    continue
                }
                if let theirs = UIImage(contentsOfFile: unpacked.appending(path: "thumbnail.jpg").path),
                   let ours = Notebook(folder: notebook).thumbnail(at: 0, width: 400) {
                    report.similarity = similarity(ours, theirs)
                    if report.similarity! < 0.8 {
                        // Side by side for a look: GoodNotes' thumbnail left, the conversion right.
                        try fm.createDirectory(at: lowMatches, withIntermediateDirectories: true)
                        let height = max(theirs.size.height, ours.size.height)
                        let pair = UIGraphicsImageRenderer(size: CGSize(width: theirs.size.width + ours.size.width + 20, height: height)).image { _ in
                            UIColor.gray.setFill()
                            UIRectFill(CGRect(x: 0, y: 0, width: theirs.size.width + ours.size.width + 20, height: height))
                            theirs.draw(at: .zero)
                            ours.draw(at: CGPoint(x: theirs.size.width + 20, y: 0))
                        }
                        try pair.pngData()?.write(to: lowMatches.appending(path: "\(report.title).png"))
                    }
                }
                let score = report.similarity.map { String(format: "%.2f", $0) } ?? "n/a"
                var notes: [String] = []
                if report.textBoxes > 0 { notes.append("\(report.textBoxes) text box(es), \(report.arrows) arrow(s)") }
                if report.unsupported > 0 { notes.append("\(report.unsupported) element(s) in an unsupported format") }
                print("\(relative.isEmpty ? "" : relative + "/")\(report.title): \(report.pages) pages, \(report.strokes) strokes, match \(score)"
                      + (notes.isEmpty ? "" : " — " + notes.joined(separator: "; ")))
                if (report.similarity ?? 1) < 0.8 { suspicious.append("\(report.title) (\(score))") }
                totals.pages += report.pages
                totals.strokes += report.strokes
                totals.highlighter += report.highlighter
                totals.shapes += report.shapes
                totals.textBoxes += report.textBoxes
                totals.arrows += report.arrows
                totals.unsupported += report.unsupported
                totals.outline += report.outline
                totals.bookmarks += report.bookmarks
            } catch {
                failures.append("\(file.lastPathComponent): \(error)")
            }
        }
        print("""

        Converted \(files.count - failures.count) of \(files.count) notebooks: \(totals.pages) pages, \(totals.strokes) strokes \
        (\(totals.highlighter) highlighter).
        Shapes: \(totals.shapes). Text boxes: \(totals.textBoxes), with \(totals.arrows) arrows.
        Bookmarks: \(totals.bookmarks). Outline entries: \(totals.outline).
        Not converted: \(totals.unsupported) elements in unsupported formats.
        Low thumbnail match (< 0.80): \(suspicious.isEmpty ? "none" : suspicious.joined(separator: ", "))
        Failed: \(failures.isEmpty ? "none" : failures.joined(separator: "\n  "))
        """)
    }
}
