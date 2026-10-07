import Combine
import PencilKit
import SwiftUI

enum Tool: String, Codable { case pen, highlighter, eraser, lasso, shape, text }

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
    @Published var eraseWholeStrokes = false

    private struct Saved: Codable {
        var tool: Tool
        var shape: ShapeKind
        var penType: PenType? // absent in settings saved before pen types existed
        var pen, highlighter, shapeStyle: Style
        var textStyle: Style? // absent in settings saved before text boxes existed
        var eraserWidth: CGFloat
        var eraseWholeStrokes: Bool
    }

    private static let key = "tools"
    private let defaults: UserDefaults
    private var autosave: AnyCancellable?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key), let saved = try? JSONDecoder().decode(Saved.self, from: data) {
            tool = saved.tool
            shape = saved.shape
            penType = saved.penType ?? .ballpoint
            pen = saved.pen
            highlighter = saved.highlighter
            shapeStyle = saved.shapeStyle
            textStyle = saved.textStyle ?? textStyle
            eraserWidth = saved.eraserWidth
            eraseWholeStrokes = saved.eraseWholeStrokes
            // A width saved before the presets changed falls back to the medium step.
            if !Self.penWidths(penType).contains(pen.width) { pen.width = Self.penWidths(penType)[1] }
        }
        autosave = objectWillChange.debounce(for: .milliseconds(300), scheduler: RunLoop.main).sink { [weak self] in self?.save() }
    }

    func save() {
        let saved = Saved(tool: tool, shape: shape, penType: penType, pen: pen, highlighter: highlighter, shapeStyle: shapeStyle,
                          textStyle: textStyle, eraserWidth: eraserWidth, eraseWholeStrokes: eraseWholeStrokes)
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
        case .eraser: eraseWholeStrokes ? PKEraserTool(.vector) : PKEraserTool(.bitmap, width: eraserWidth)
        case .lasso: PKLassoTool()
        case .shape, .text: PKInkingTool(.monoline, color: shapeStyle.color, width: shapeStyle.width) // canvas gets no touches in these modes
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

/// The tool buttons in the notebook's blue bar.
struct ToolPicker: View {
    @ObservedObject var tools: Tools

    var body: some View {
        HStack(spacing: 6) {
            button(.lasso, "lasso", "Lasso")
            button(.pen, "pencil.and.scribble", "Pen")
            button(.highlighter, "highlighter", "Highlighter")
            button(.eraser, "eraser", "Eraser")
            button(.shape, "square.on.circle", "Shapes")
            button(.text, "textformat", "Text")
        }
    }

    private func button(_ tool: Tool, _ symbol: String, _ name: String) -> some View {
        let selected = tools.tool == tool
        return Button { tools.tool = tool } label: {
            Image(systemName: symbol)
                .font(.system(size: 20))
                .frame(width: 46, height: 40)
                .foregroundStyle(selected ? Theme.bar : .white)
                .background(selected ? Color.white : .clear, in: RoundedRectangle(cornerRadius: 10))
        }
        .accessibilityLabel(name)
    }
}

/// Floating white panel with the selected tool's options: kinds, widths, colors.
struct ToolOptions: View {
    @ObservedObject var tools: Tools

    var body: some View {
        if tools.tool != .lasso {
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
                colors
            case .highlighter, .text:
                widths
                colors
            case .shape:
                ForEach(ShapeKind.allCases, id: \.self) { kind in
                    option(selected: tools.shape == kind, label: kind.name) { tools.shape = kind } content: {
                        Image(systemName: kind.symbol).font(.system(size: 18))
                    }
                }
                separator
                widths
                colors
            case .eraser:
                if !tools.eraseWholeStrokes { widths }
                Picker("Eraser", selection: $tools.eraseWholeStrokes) {
                    Text("Partial").tag(false)
                    Text("Whole stroke").tag(true)
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .padding(.horizontal, 6)
            case .lasso:
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
        let selected = tools.tool == .eraser ? tools.eraserWidth : tools.style.width
        return ForEach(Array(tools.widthPresets.enumerated()), id: \.offset) { i, width in
            option(selected: selected == width, label: "Width \(i + 1)") {
                if tools.tool == .eraser { tools.eraserWidth = width } else { tools.style.width = width }
            } content: {
                if tools.tool == .text {
                    Text("A").font(.system(size: [13, 17, 22][i], weight: .medium))
                } else {
                    Capsule().frame(width: 24, height: CGFloat(1.5 + Double(i) * 2))
                }
            }
        }
    }

    private var colors: some View {
        Group {
            separator
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
