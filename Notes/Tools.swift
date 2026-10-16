import Combine
import PencilKit
import SwiftUI

enum Tool: String, Codable { case pen, highlighter, eraser, lasso, shape, text, laser }

enum EraserType: String, Codable, CaseIterable {
    case precision, standard, stroke

    var name: String { rawValue.capitalized }

    var detail: String {
        switch self {
        case .precision: "Erases just what it touches, wider as you press harder"
        case .standard: "Erases just what it touches, at the size you picked"
        case .stroke: "Erases whole strokes at a touch"
        }
    }

    var pencilKit: PKEraserTool.EraserType {
        switch self {
        case .precision: .bitmap
        case .standard: .fixedWidthBitmap
        case .stroke: .vector
        }
    }
}

enum PenType: String, Codable, CaseIterable {
    case fountain, ballpoint, brush

    var ink: PKInkingTool.InkType {
        switch self {
        case .fountain: .fountainPen
        case .ballpoint: .monoline
        case .brush: .pen
        }
    }

    var symbol: String {
        switch self {
        case .fountain: "pencil.tip"
        case .ballpoint: "pencil"
        case .brush: "paintbrush.pointed"
        }
    }
}

struct Style: Codable {
    var color: UIColor
    var width: CGFloat

    init(color: UIColor, width: CGFloat) {
        self.color = color
        self.width = width
    }

    private enum CodingKeys: String, CodingKey { case rgba, width }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let v = try c.decode([CGFloat].self, forKey: .rgba)
        guard v.count == 4 else { throw DecodingError.dataCorruptedError(forKey: .rgba, in: c, debugDescription: "expected RGBA") }
        color = UIColor(red: v[0], green: v[1], blue: v[2], alpha: v[3])
        width = try c.decode(CGFloat.self, forKey: .width)
    }

    func encode(to encoder: Encoder) throws {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode([r, g, b, a], forKey: .rgba)
        try c.encode(width, forKey: .width)
    }
}

/// Current tool and per-tool settings, shown by ToolBar and applied to every page canvas.
/// Saved to UserDefaults so every notebook and relaunch starts with the last-used tools.
final class Tools: ObservableObject {
    @Published var tool: Tool = .pen { didSet { if tool != oldValue { previousTool = oldValue } } }
    private(set) var previousTool: Tool = .eraser
    @Published var shape: ShapeKind = .rectangle
    /// Switching pen type keeps the chosen thin/medium/thick step.
    @Published var penType: PenType = .ballpoint {
        didSet { pen.width = Self.penWidths(penType)[Self.penWidths(oldValue).firstIndex(of: pen.width) ?? 1] }
    }
    @Published var pen = Style(color: Tools.black, width: 0.85)
    @Published var highlighter = Style(color: Tools.yellow, width: 20)
    @Published var shapeStyle = Style(color: Tools.black, width: 2)
    @Published var textStyle = Style(color: Tools.black, width: 16) // width is the font size
    @Published var eraserWidth: CGFloat = 15
    @Published var eraserType: EraserType = .standard
    /// The laser pointer draws a fading line; otherwise it shows a dot.
    @Published var laserLine = true

    private struct Saved: Codable {
        var tool: Tool
        var shape: String // a ShapeKind; unknown shapes fall back to the rectangle
        var penType: PenType? // absent in settings saved before pen types existed
        var pen, highlighter, shapeStyle: Style
        var textStyle: Style? // absent in settings saved before text boxes existed
        var eraserWidth: CGFloat
        var eraserType: EraserType? // absent in settings saved before eraser types existed, which say eraseWholeStrokes
        var eraseWholeStrokes: Bool?
        var laserLine: Bool?
    }

    private static let key = "tools"
    private let defaults: UserDefaults
    private var autosave: AnyCancellable?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key), let saved = try? JSONDecoder().decode(Saved.self, from: data) {
            tool = saved.tool
            shape = ShapeKind(rawValue: saved.shape) ?? .rectangle
            penType = saved.penType ?? .ballpoint
            pen = saved.pen
            highlighter = saved.highlighter
            shapeStyle = saved.shapeStyle
            textStyle = saved.textStyle ?? textStyle
            eraserWidth = saved.eraserWidth
            eraserType = saved.eraserType ?? (saved.eraseWholeStrokes == true ? .stroke : .standard)
            laserLine = saved.laserLine ?? true
            // A width saved before the presets changed falls back to the medium step.
            if !Self.penWidths(penType).contains(pen.width) { pen.width = Self.penWidths(penType)[1] }
        }
        autosave = objectWillChange.debounce(for: .milliseconds(300), scheduler: RunLoop.main).sink { [weak self] in self?.save() }
    }

    func save() {
        let saved = Saved(tool: tool, shape: shape.rawValue, penType: penType, pen: pen, highlighter: highlighter, shapeStyle: shapeStyle,
                          textStyle: textStyle, eraserWidth: eraserWidth, eraserType: eraserType, laserLine: laserLine)
        defaults.set(try? JSONEncoder().encode(saved), forKey: Self.key)
    }

    /// Apple Pencil double-tap. Other preferred actions (color palette, ink attributes, shortcuts) are ignored.
    func pencilTap(_ action: UIPencilPreferredAction) {
        switch action {
        case .switchEraser: tool = tool == .eraser ? previousTool : .eraser
        case .switchPrevious: tool = previousTool
        default: break
        }
    }

    /// Settings of the selected tool; pen settings stand in for tools without color.
    var style: Style {
        get {
            switch tool {
            case .highlighter: highlighter
            case .shape: shapeStyle
            case .text: textStyle
            default: pen
            }
        }
        set {
            switch tool {
            case .highlighter: highlighter = newValue
            case .shape: shapeStyle = newValue
            case .text: textStyle = newValue
            default: pen = newValue
            }
        }
    }

    /// The PencilKit tool for the canvas. Shapes are drawn by the page overlay's shape view, not PencilKit.
    var pkTool: PKTool {
        switch tool {
        case .pen: PKInkingTool(penType.ink, color: pen.color, width: pen.width)
        case .highlighter: PKInkingTool(.marker, color: highlighter.color, width: highlighter.width)
        case .eraser: PKEraserTool(eraserType.pencilKit, width: eraserWidth)
        case .lasso: PKLassoTool()
        case .shape, .text, .laser: PKInkingTool(.monoline, color: shapeStyle.color, width: shapeStyle.width) // canvas gets no touches in these modes
        }
    }

    var colorPresets: [UIColor] {
        tool == .highlighter
            ? [Self.yellow, Self.green, Self.pink, Self.cyan]
            : [Self.red, Self.blue, Self.black, Self.yellow, Self.green]
    }

    var widthPresets: [CGFloat] {
        switch tool {
        case .highlighter: [10, 20, 35]
        case .shape: [1, 2, 3]
        case .eraser: [5, 15, 40]
        case .text: [12, 16, 24]
        default: Self.penWidths(penType)
        }
    }

    /// Thin/medium/thick per pen. PencilKit draws a ballpoint (monoline) line about twice the tool width
    /// (measured on the iPad), so 0.85 gives GoodNotes' usual 1.7 pt line. Fountain (min 1.5) and brush
    /// (min 0.88) vary with pressure; theirs are starting points.
    static func penWidths(_ type: PenType) -> [CGFloat] {
        switch type {
        case .ballpoint: [0.6, 0.85, 1.15]
        case .fountain: [1.5, 2, 2.8]
        case .brush: [0.9, 1.2, 1.6]
        }
    }

    // RGB colors (not .black, which is grayscale) so saved colors compare equal to presets.
    static let black = UIColor(red: 0, green: 0, blue: 0, alpha: 1)
    static let yellow = UIColor(red: 1, green: 0.85, blue: 0.2, alpha: 1)
    static let green = UIColor(red: 0.2, green: 0.7, blue: 0.35, alpha: 1)
    static let pink = UIColor(red: 1, green: 0.45, blue: 0.7, alpha: 1)
    static let cyan = UIColor(red: 0.3, green: 0.8, blue: 1, alpha: 1)
    static let blue = UIColor(red: 0.12, green: 0.36, blue: 0.85, alpha: 1)
    static let red = UIColor(red: 0.85, green: 0.15, blue: 0.15, alpha: 1)
}

/// The tool buttons in the notebook's blue bar. Tapping the selected laser again picks dot or line.
struct ToolPicker: View {
    @ObservedObject var tools: Tools
    @State private var laserOptions = false

    var body: some View {
        HStack(spacing: 6) {
            button(.lasso, "lasso", "Lasso")
            button(.pen, "pencil.and.scribble", "Pen")
            button(.highlighter, "highlighter", "Highlighter")
            button(.eraser, "eraser", "Eraser")
            button(.shape, "square.on.circle", "Shapes")
            button(.text, "textformat", "Text")
            button(.laser, nil, "Laser Pointer")
                .popover(isPresented: $laserOptions) { LaserOptions(tools: tools) }
        }
    }

    /// A tool button showing `symbol`, or the laser pointer's own icon when there's none.
    private func button(_ tool: Tool, _ symbol: String?, _ name: String) -> some View {
        let selected = tools.tool == tool
        return Button {
            if selected && tool == .laser { laserOptions = true } else { tools.tool = tool }
        } label: {
            HStack(spacing: 2) {
                if let symbol { Image(systemName: symbol).font(.system(size: 20)) } else { LaserIcon(selected: selected) }
                if selected && tool == .laser { Image(systemName: "chevron.down").font(.system(size: 11, weight: .semibold)) }
            }
            .frame(minWidth: 46, minHeight: 40)
            .padding(.horizontal, selected && tool == .laser ? 6 : 0)
            .foregroundStyle(selected ? Theme.bar : .white)
            .background(selected ? Color.white : .clear, in: RoundedRectangle(cornerRadius: 10))
        }
        .accessibilityLabel(name)
    }
}

/// Floating white panel with the selected tool's options: kinds, widths, colors. The lasso and laser have none.
struct ToolOptions: View {
    @ObservedObject var tools: Tools
    @State private var showWidths = false
    @State private var showColors = false
    @State private var showEraserTypes = false

    var body: some View {
        if tools.tool != .lasso && tools.tool != .laser {
            ViewThatFits(in: .horizontal) {
                panel
                ScrollView(.horizontal, showsIndicators: false) { panel }
            }
        }
    }

    private var panel: some View {
        HStack(spacing: 4) {
            switch tools.tool {
            case .pen:
                ForEach(PenType.allCases, id: \.self) { type in
                    option(selected: tools.penType == type, label: type.rawValue.capitalized) { tools.penType = type } content: {
                        Image(systemName: type.symbol).font(.system(size: 18))
                    }
                }
                separator
                widths
                separator
                colors
            case .highlighter, .text:
                widths
                separator
                colors
            case .shape:
                // GoodNotes' layout: freehand and connectors, then shapes, then width and color behind a tap each.
                ForEach(ShapeKind.allCases, id: \.self) { kind in
                    option(selected: tools.shape == kind, label: kind.name) { tools.shape = kind } content: { ShapeIcon(kind: kind) }
                    if kind == .curve { separator }
                }
                separator
                Button { showWidths = true } label: {
                    VStack(spacing: 4) {
                        Capsule().frame(width: 22, height: 3.5)
                        Capsule().frame(width: 22, height: 2).opacity(0.35)
                    }
                    .frame(width: 40, height: 40)
                }
                .accessibilityLabel("Line Width")
                .popover(isPresented: $showWidths) { HStack(spacing: 4) { widths }.padding(8).presentationCompactAdaptation(.popover) }
                Button { showColors = true } label: {
                    Circle().fill(Color(uiColor: tools.style.color))
                        .frame(width: 28, height: 28)
                        .overlay(Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold)).foregroundStyle(.white))
                        .frame(width: 40, height: 40)
                }
                .accessibilityLabel("Color")
                .popover(isPresented: $showColors) { HStack(spacing: 4) { colors }.padding(8).presentationCompactAdaptation(.popover) }
            case .eraser:
                Button { showEraserTypes = true } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "eraser")
                        Text(tools.eraserType.name)
                        Image(systemName: "chevron.down").font(.system(size: 12, weight: .semibold))
                    }
                    .font(.system(size: 17))
                    .padding(.horizontal, 10)
                    .frame(height: 40)
                    .background(Color.gray.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                }
                .accessibilityLabel("Eraser Type")
                .popover(isPresented: $showEraserTypes) { EraserTypes(tools: tools) }
                eraserSizes
            case .lasso, .laser:
                EmptyView()
            }
        }
        .padding(6)
        .background(.white, in: Capsule())
        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
        .foregroundStyle(.black)
    }

    private var separator: some View { Divider().frame(height: 26).padding(.horizontal, 6) }

    /// Widths drawn as lines of increasing thickness.
    private var widths: some View {
        ForEach(Array(tools.widthPresets.enumerated()), id: \.offset) { i, width in
            option(selected: tools.style.width == width, label: "Width \(i + 1)") { tools.style.width = width } content: {
                if tools.tool == .text {
                    Text("A").font(.system(size: [13, 17, 22][i], weight: .medium))
                } else {
                    Capsule().frame(width: 24, height: CGFloat(1.5 + Double(i) * 2))
                }
            }
        }
    }

    /// Eraser sizes as circles of increasing size, the selected one ringed in blue.
    private var eraserSizes: some View {
        ForEach(Array(tools.widthPresets.enumerated()), id: \.offset) { i, width in
            let selected = tools.eraserWidth == width
            Button { tools.eraserWidth = width } label: {
                Circle()
                    .fill(Color.gray.opacity(0.08))
                    .overlay(Circle().strokeBorder(selected ? Color.accentColor : Color.gray.opacity(0.5), lineWidth: selected ? 3 : 2))
                    .frame(width: [20, 28, 36][i], height: [20, 28, 36][i])
                    .frame(width: 44, height: 40)
            }
            .accessibilityLabel("Size \(i + 1)")
        }
    }

    private var colors: some View {
        Group {
            ForEach(tools.colorPresets, id: \.self) { color in
                let selected = tools.style.color == color
                Button { tools.style.color = color } label: {
                    Circle().fill(Color(uiColor: color))
                        .frame(width: 26, height: 26)
                        .padding(4)
                        .overlay(Circle().stroke(Color.gray.opacity(selected ? 0.4 : 0), lineWidth: 4))
                        .frame(width: 40, height: 40)
                }
                .accessibilityLabel("Color")
            }
            ColorPicker("Custom color", selection: Binding(
                get: { Color(uiColor: tools.style.color) },
                set: { tools.style.color = UIColor($0) }
            ), supportsOpacity: false)
            .labelsHidden()
            .padding(.horizontal, 6)
        }
    }

    private func option(selected: Bool, label: String, action: @escaping () -> Void, @ViewBuilder content: () -> some View) -> some View {
        Button(action: action) {
            content()
                .frame(width: 40, height: 40)
                .background(selected ? Color.gray.opacity(0.2) : .clear, in: RoundedRectangle(cornerRadius: 10))
        }
        .accessibilityLabel(label)
    }
}

/// GoodNotes-style laser pointer: a pointer held at an angle, its beam a burst at the tip, red while selected.
struct LaserIcon: View {
    let selected: Bool

    var body: some View {
        ZStack {
            ZStack {
                Capsule().fill(selected ? AnyShapeStyle(.foreground) : AnyShapeStyle(.clear))
                Capsule().stroke(.foreground, lineWidth: 1.6)
                Circle() // its button
                    .fill(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.foreground))
                    .frame(width: 3, height: 3)
                    .offset(y: 4)
            }
            .frame(width: 7.5, height: 18)
            .rotationEffect(.degrees(45))
            .offset(x: -4, y: 4)
            Burst()
                .stroke(selected ? AnyShapeStyle(.red) : AnyShapeStyle(.foreground), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                .frame(width: 12, height: 12)
                .offset(x: 7, y: -7)
        }
        .frame(width: 28, height: 28)
    }

    /// A dot with eight short rays around it.
    private struct Burst: Shape {
        func path(in rect: CGRect) -> Path {
            let c = CGPoint(x: rect.midX, y: rect.midY), r = rect.width / 2
            var path = Path(ellipseIn: CGRect(x: c.x - r * 0.38, y: c.y - r * 0.38, width: r * 0.76, height: r * 0.76))
            for k in 0..<8 {
                let a = CGFloat(k) * .pi / 4
                path.move(to: CGPoint(x: c.x + r * 0.62 * cos(a), y: c.y + r * 0.62 * sin(a)))
                path.addLine(to: CGPoint(x: c.x + r * cos(a), y: c.y + r * sin(a)))
            }
            return path
        }
    }
}

/// A shape tool's icon: connectors as symbols, shapes drawn filled light gray with a dark outline.
struct ShapeIcon: View {
    let kind: ShapeKind

    var body: some View {
        switch kind {
        case .freehand: Image(systemName: "square.on.circle").font(.system(size: 19))
        case .elbow: Image(systemName: "arrow.turn.right.down").font(.system(size: 18))
        case .curve: Image(systemName: "point.topleft.down.to.point.bottomright.curvepath").font(.system(size: 18))
        default: outline.fill(Color.gray.opacity(0.3)).overlay(outline.stroke(.black, lineWidth: 1.5)).frame(width: 22, height: 22)
        }
    }

    private var outline: Path {
        let lines = kind.polylines(from: .zero, to: CGPoint(x: 22, y: kind == .rectangle || kind == .roundedRectangle ? 20 : 22), width: 0)
        return Path { path in for line in lines { path.addLines(line) } }
    }
}

/// Tool options shown as a row of cards in a popover, the selected one raised on white, with a note under them.
private struct OptionCards<Option: Hashable, Icon: View>: View {
    let title: String
    let options: [Option]
    @Binding var selection: Option
    let name: (Option) -> String
    var note: String?
    @ViewBuilder let icon: (Option) -> Icon

    var body: some View {
        VStack(spacing: 18) {
            Text(title).font(.headline)
            HStack(spacing: 8) {
                ForEach(options, id: \.self) { option in
                    Button { selection = option } label: {
                        VStack(spacing: 10) {
                            icon(option).frame(height: 30)
                            Text(name(option)).font(.subheadline).multilineTextAlignment(.center)
                        }
                        .frame(width: 120, height: 110)
                        .background(selection == option ? Color.white : .clear, in: RoundedRectangle(cornerRadius: 18))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(name(option))
                }
            }
            if let note { Text(note).font(.footnote).foregroundStyle(.secondary) }
        }
        .padding(20)
        .foregroundStyle(.black) // not the toolbar's white
        .presentationBackground(Color(white: 0.95))
        .presentationCompactAdaptation(.popover)
    }
}

struct EraserTypes: View {
    @ObservedObject var tools: Tools

    var body: some View {
        OptionCards(title: "Eraser Type", options: EraserType.allCases, selection: $tools.eraserType,
                    name: { "\($0.name) Eraser" }, note: tools.eraserType.detail) { _ in
            Image(systemName: "eraser").font(.system(size: 24))
        }
    }
}

struct LaserOptions: View {
    @ObservedObject var tools: Tools

    var body: some View {
        OptionCards(title: "Laser Pointer", options: [false, true], selection: $tools.laserLine, name: { $0 ? "Line" : "Dot" }) { line in
            if line {
                Path { p in
                    p.move(to: CGPoint(x: 2, y: 6))
                    p.addQuadCurve(to: CGPoint(x: 30, y: 4), control: CGPoint(x: 14, y: 20))
                }
                .stroke(.red, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .frame(width: 32, height: 20)
                .shadow(color: .red.opacity(0.6), radius: 3)
            } else {
                Circle().fill(.red).frame(width: 10, height: 10).shadow(color: .red, radius: 4)
            }
        }
    }
}

/// Floating undo/redo panel at the top left of the page area.
struct UndoRedo: View {
    let undo: () -> Void
    let redo: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Button(action: undo) { Image(systemName: "arrow.uturn.backward").frame(width: 40, height: 40) }
                .accessibilityLabel("Undo")
            Button(action: redo) { Image(systemName: "arrow.uturn.forward").frame(width: 40, height: 40) }
                .accessibilityLabel("Redo")
        }
        .font(.system(size: 18))
        .foregroundStyle(.gray)
        .padding(6)
        .background(.white, in: RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
    }
}
