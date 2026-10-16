import Foundation

/// Reads the final state of a Yjs document (github.com/yjs/yjs) from a v1 update, as a tree of XML text elements.
/// GoodNotes stores text documents this way (see GoodNotesImport.swift). Reading only: no v2 updates, no editing.
///
/// Every multi-unit item (a string, a run of deleted content) is split into one item per clock tick up front, so an
/// origin pointing into the middle of a string needs no item splitting; items then go into their parents' lists with
/// Yjs' own YATA rule, in an order where each item's neighbours are already in place.
enum Yjs {
    struct Malformed: Error {}

    /// An XML text element: its attributes, then its text and nested elements in document order.
    struct Element {
        var attributes: [String: Any] = [:]
        var children: [Child] = []
    }

    enum Child {
        case text(String)
        case element(Element)
    }

    /// The root shared type `name` in `update`; empty when the update has no such type.
    static func root(_ update: [UInt8], name: String) throws -> Element {
        let doc = try Doc(update)
        return doc.roots[name].map(doc.element) ?? Element()
    }

    private struct ID: Hashable {
        let client: UInt64
        let clock: UInt64
    }

    private enum Parent {
        case root(String)
        case item(ID)
    }

    private enum Content {
        case unit(UInt16) // one UTF-16 code unit of text
        case value(Any) // a map value or array element
        case type(Node)
        case none // deleted content, formatting marks, embeds, binary, subdocuments
    }

    private final class Node {
        var start: Item?
        var entries: [String: [Item]] = [:] // map keys (attributes): every value set, the live one not deleted
    }

    private final class Item {
        let id: ID
        let origin: ID?, rightOrigin: ID?
        let parentRef: Parent?
        let content: Content
        var parent: Node?
        var parentSub: String?
        var right: Item?
        var deleted = false
        var integrated = false

        init(id: ID, origin: ID?, rightOrigin: ID?, parentRef: Parent?, parentSub: String?, content: Content) {
            self.id = id
            self.origin = origin
            self.rightOrigin = rightOrigin
            self.parentRef = parentRef
            self.parentSub = parentSub
            self.content = content
        }
    }

    private final class Doc {
        var items: [ID: Item] = [:]
        var roots: [String: Node] = [:]

        init(_ update: [UInt8]) throws {
            var r = Reader(b: update)
            var order: [Item] = []
            for _ in 0..<(try r.uint()) {
                let structs = try r.uint(), client = try r.uint()
                var clock = try r.uint()
                for _ in 0..<structs {
                    let info = try r.byte()
                    let ref = info & 0x1F
                    if ref == 0 || ref == 10 { // garbage-collected content or a skipped range: clocks only
                        clock += try r.uint()
                        continue
                    }
                    let origin = info & 0x80 != 0 ? ID(client: try r.uint(), clock: try r.uint()) : nil
                    let rightOrigin = info & 0x40 != 0 ? ID(client: try r.uint(), clock: try r.uint()) : nil
                    var parent: Parent?, parentSub: String?
                    if info & 0xC0 == 0 { // no neighbours to take the parent from
                        parent = try r.uint() == 1 ? .root(try r.string()) : .item(ID(client: try r.uint(), clock: try r.uint()))
                        if info & 0x20 != 0 { parentSub = try r.string() }
                    }
                    let contents = try Self.contents(ref, &r)
                    for (k, content) in contents.enumerated() {
                        let id = ID(client: client, clock: clock + UInt64(k))
                        let item = k == 0
                            ? Item(id: id, origin: origin, rightOrigin: rightOrigin, parentRef: parent, parentSub: parentSub, content: content)
                            : Item(id: id, origin: ID(client: client, clock: id.clock - 1), rightOrigin: rightOrigin, parentRef: nil, parentSub: nil, content: content)
                        items[id] = item
                        order.append(item)
                    }
                    clock += UInt64(contents.count)
                }
            }
            // ponytail: re-scans what's left each pass; fine for documents of tens of thousands of characters
            var pending = order
            while !pending.isEmpty {
                let before = pending.count
                pending = pending.filter { !integrate($0) }
                if pending.count == before { break } // malformed: neighbours that never arrive
            }
            for _ in 0..<(try r.uint()) {
                let client = try r.uint()
                for _ in 0..<(try r.uint()) {
                    let clock = try r.uint(), length = try r.uint()
                    guard length < 1 << 24 else { throw Malformed() }
                    for c in clock..<clock + length { items[ID(client: client, clock: c)]?.deleted = true }
                }
            }
        }

        /// One content per clock tick.
        private static func contents(_ ref: UInt8, _ r: inout Reader) throws -> [Content] {
            switch ref {
            case 1: // deleted
                let n = try r.uint()
                guard n < 1 << 24 else { throw Malformed() }
                return Array(repeating: .none, count: Int(n))
            case 2: return try (0..<r.uint()).map { _ in .value(try r.string()) } // JSON
            case 3: _ = try r.bytes(try r.uint()); return [.none] // binary
            case 4: return try r.string().utf16.map(Content.unit)
            case 5: _ = try r.string(); return [.none] // embed
            case 6: _ = try r.string(); _ = try r.string(); return [.none] // formatting mark
            case 7: // a nested type; XML elements and hooks carry a name
                let type = try r.uint()
                if type == 3 || type == 5 { _ = try r.string() }
                return [.type(Node())]
            case 8: return try (0..<r.uint()).map { _ in .value(try r.any()) }
            case 9: _ = try r.string(); _ = try r.any(); return [.none] // subdocument
            default: throw Malformed()
            }
        }

        /// Puts `item` in its parent; false while a neighbour it depends on isn't in place yet.
        private func integrate(_ item: Item) -> Bool {
            func drop() -> Bool { item.integrated = true; return true } // hangs off garbage-collected content
            var left: Item?, right: Item?
            if let id = item.origin {
                guard let l = items[id] else { return drop() }
                guard l.integrated else { return false }
                left = l
            }
            if let id = item.rightOrigin {
                guard let r = items[id] else { return drop() }
                guard r.integrated else { return false }
                right = r
            }
            switch item.parentRef {
            case .root(let name)?:
                item.parent = roots[name] ?? Node()
                roots[name] = item.parent
            case .item(let id)?:
                guard let p = items[id], case .type(let node) = p.content else { return drop() }
                item.parent = node
            case nil:
                guard let near = left ?? right else { return drop() }
                item.parent = near.parent
                item.parentSub = near.parentSub
            }
            guard let parent = item.parent else { return drop() }
            item.integrated = true
            if let key = item.parentSub {
                parent.entries[key, default: []].append(item)
                return true
            }
            // YATA (Item.integrate in yjs): concurrent inserts at the same place settle in the same order everywhere.
            if left.map({ $0.right !== right }) ?? (parent.start !== right) {
                var o = left?.right ?? parent.start
                var conflicting = Set<ObjectIdentifier>(), beforeOrigin = Set<ObjectIdentifier>()
                while let x = o, x !== right {
                    beforeOrigin.insert(ObjectIdentifier(x))
                    conflicting.insert(ObjectIdentifier(x))
                    if x.origin == item.origin {
                        if x.id.client < item.id.client {
                            left = x
                            conflicting.removeAll()
                        } else if x.rightOrigin == item.rightOrigin {
                            break
                        }
                    } else if let xo = x.origin.flatMap({ items[$0] }), beforeOrigin.contains(ObjectIdentifier(xo)) {
                        if !conflicting.contains(ObjectIdentifier(xo)) {
                            left = x
                            conflicting.removeAll()
                        }
                    } else {
                        break
                    }
                    o = x.right
                }
            }
            if let left {
                item.right = left.right
                left.right = item
            } else {
                item.right = parent.start
                parent.start = item
            }
            return true
        }

        func element(_ node: Node) -> Element {
            var element = Element()
            for (key, values) in node.entries {
                if let live = values.last(where: { !$0.deleted }), case .value(let value) = live.content { element.attributes[key] = value }
            }
            var text: [UInt16] = []
            func flush() {
                if !text.isEmpty { element.children.append(.text(String(decoding: text, as: UTF16.self))) }
                text = []
            }
            var next = node.start
            while let item = next {
                if !item.deleted {
                    switch item.content {
                    case .unit(let unit): text.append(unit)
                    case .type(let child): flush(); element.children.append(.element(self.element(child)))
                    default: break
                    }
                }
                next = item.right
            }
            flush()
            return element
        }
    }

    /// lib0 decoding (github.com/dmonad/lib0).
    private struct Reader {
        let b: [UInt8]
        var i = 0

        mutating func byte() throws -> UInt8 {
            guard i < b.count else { throw Malformed() }
            defer { i += 1 }
            return b[i]
        }

        mutating func uint() throws -> UInt64 {
            var result: UInt64 = 0, shift: UInt64 = 0
            while true {
                let c = try byte()
                guard shift < 64 else { throw Malformed() }
                result |= UInt64(c & 0x7F) << shift
                shift += 7
                if c < 0x80 { return result }
            }
        }

        /// Sign in bit 6 of the first byte, which carries 6 bits of the value.
        mutating func int() throws -> Int64 {
            var c = try byte()
            let negative = c & 0x40 != 0
            var n = Int64(c & 0x3F), shift: Int64 = 6
            while c & 0x80 != 0 {
                c = try byte()
                guard shift < 63 else { throw Malformed() }
                n |= Int64(c & 0x7F) << shift
                shift += 7
            }
            return negative ? -n : n
        }

        mutating func bytes(_ n: UInt64) throws -> ArraySlice<UInt8> {
            guard n <= UInt64(b.count - i) else { throw Malformed() }
            defer { i += Int(n) }
            return b[i..<i + Int(n)]
        }

        mutating func string() throws -> String { String(decoding: try bytes(try uint()), as: UTF8.self) }

        private mutating func bigEndian(_ n: UInt64) throws -> UInt64 { try bytes(n).reduce(0) { $0 << 8 | UInt64($1) } }

        mutating func any() throws -> Any {
            switch try byte() {
            case 127, 126: return NSNull() // undefined, null
            case 125: return try int()
            case 124: return Double(Float(bitPattern: UInt32(try bigEndian(4))))
            case 123: return Double(bitPattern: try bigEndian(8))
            case 122: return Int64(bitPattern: try bigEndian(8))
            case 121: return false
            case 120: return true
            case 119: return try string()
            case 118: return Dictionary(try (0..<uint()).map { _ in (try string(), try any()) }) { $1 }
            case 117: return try (0..<uint()).map { _ in try any() }
            case 116: return Array(try bytes(try uint()))
            default: throw Malformed()
            }
        }
    }
}
