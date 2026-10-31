// Everything around the page: the toolbar, the Aa panel, the outline, the empty state and the pointer.
import AppKit
import CoreText

func flatView(_ view: NSView) {
    view.wantsLayer = true
    view.layerContentsRedrawPolicy = .onSetNeedsDisplay
}

func animate(_ layer: CALayer?, _ key: String, to value: Any?, duration: TimeInterval, timing: CAMediaTimingFunction? = nil) {
    guard let layer = layer else { return }
    let seconds = Motion.duration(duration)
    let animation = CABasicAnimation(keyPath: key)
    animation.fromValue = layer.presentation()?.value(forKeyPath: key) ?? layer.value(forKeyPath: key)
    animation.toValue = value
    animation.duration = seconds
    if let timing = timing { animation.timingFunction = timing }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    layer.setValue(value, forKeyPath: key)
    CATransaction.commit()
    if seconds > 0 { layer.add(animation, forKey: key) }
}

// Anything clickable. The reader tells it when the pointer is on it, from one place, rather than each keeping its own tracking.
class ChromeControl: NSView {
    var onClick: (() -> Void)?
    var isHot = false { didSet { if isHot != oldValue { hotChanged() } } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        flatView(self)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
    func hotChanged() { needsDisplay = true }
    override func resetCursorRects() {}
    override func cursorUpdate(with event: NSEvent) {}
}

// ---------- Toolbar ----------

final class IconButton: ChromeControl {
    private let shape = CAShapeLayer()
    private var theme = Theme.light
    var isExpanded = false { didSet { refresh(animated: true) } }
    private let filled: Bool

    init(path: CGPath, filled: Bool, title: String) {
        self.filled = filled
        super.init(frame: NSRect(x: 0, y: 0, width: 32, height: 28))
        toolTip = title
        layer?.cornerRadius = 6
        shape.path = path
        shape.lineWidth = filled ? 0 : 1.3
        shape.lineCap = .round
        shape.lineJoin = .round
        shape.fillColor = nil
        layer?.addSublayer(shape)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let box = shape.path?.boundingBoxOfPath ?? .zero
        let origin = filled
            ? CGPoint(x: (bounds.width - box.width) / 2 - box.minX, y: (bounds.height - box.height) / 2 - box.minY)
            : CGPoint(x: (bounds.width - 18) / 2, y: (bounds.height - 18) / 2)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shape.frame = CGRect(origin: origin, size: CGSize(width: 18, height: 18))
        CATransaction.commit()
    }

    func apply(_ theme: Theme) {
        self.theme = theme
        refresh(animated: false)
    }

    override func hotChanged() { refresh(animated: true) }

    private func refresh(animated: Bool) {
        let on = isHot || isExpanded
        let background = on ? theme.hover.cgColor : NSColor.clear.cgColor
        let ink = (on ? theme.ink : theme.muted).cgColor
        let duration = animated ? 0.15 : 0
        animate(layer, "backgroundColor", to: background, duration: duration)
        animate(shape, filled ? "fillColor" : "strokeColor", to: ink, duration: duration)
    }
}

enum Icons {
    // The toolbar's SVGs have a 20-unit box drawn at 18 points.
    private static func scaled(_ build: (CGMutablePath) -> Void) -> CGPath {
        let path = CGMutablePath()
        build(path)
        var transform = CGAffineTransform(scaleX: 0.9, y: 0.9)
        return path.copy(using: &transform) ?? path
    }

    static let contents = scaled { p in
        p.addRoundedRect(in: CGRect(x: 3, y: 4, width: 14, height: 12), cornerWidth: 2, cornerHeight: 2)
        p.move(to: CGPoint(x: 8, y: 4))
        p.addLine(to: CGPoint(x: 8, y: 16))
    }

    static let folder = scaled { p in
        p.move(to: CGPoint(x: 3.5, y: 6.5))
        p.addLine(to: CGPoint(x: 3.5, y: 14.5))
        p.addArc(tangent1End: CGPoint(x: 3.5, y: 16), tangent2End: CGPoint(x: 5, y: 16), radius: 1.5)
        p.addLine(to: CGPoint(x: 15, y: 16))
        p.addArc(tangent1End: CGPoint(x: 16.5, y: 16), tangent2End: CGPoint(x: 16.5, y: 14.5), radius: 1.5)
        p.addLine(to: CGPoint(x: 16.5, y: 8.5))
        p.addArc(tangent1End: CGPoint(x: 16.5, y: 7), tangent2End: CGPoint(x: 15, y: 7), radius: 1.5)
        p.addLine(to: CGPoint(x: 9.5, y: 7))
        p.addLine(to: CGPoint(x: 8, y: 5))
        p.addLine(to: CGPoint(x: 5, y: 5))
        p.addArc(tangent1End: CGPoint(x: 3.5, y: 5), tangent2End: CGPoint(x: 3.5, y: 6.5), radius: 1.5)
        p.closeSubpath()
    }

    // "Aa" in Literata, as outlines, so it can take the same colour fade as the other icons.
    static func aa() -> CGPath {
        let path = CGMutablePath()
        var x: CGFloat = 0
        for (letter, size) in [("A", CGFloat(16)), ("a", CGFloat(12))] {
            let font = Fonts.font("literata", size: size) as CTFont
            var unichars = Array(letter.utf16)
            var glyphs = [CGGlyph](repeating: 0, count: unichars.count)
            CTFontGetGlyphsForCharacters(font, &unichars, &glyphs, unichars.count)
            if let outline = CTFontCreatePathForGlyph(font, glyphs[0], nil) {
                path.addPath(outline, transform: CGAffineTransform(translationX: x, y: 14).scaledBy(x: 1, y: -1))
            }
            var advance = CGSize.zero
            CTFontGetAdvancesForGlyphs(font, .horizontal, &glyphs, &advance, 1)
            x += advance.width
        }
        return path
    }
}

final class BarView: NSView {
    let contents = IconButton(path: Icons.contents, filled: false, title: "Contents (⌘\\)")
    let type = IconButton(path: Icons.aa(), filled: true, title: "Text and appearance")
    let open = IconButton(path: Icons.folder, filled: false, title: "Open (⌘O)")
    var isDimmed = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        [contents, type, open].forEach(addSubview)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        contents.frame.origin = NSPoint(x: 18, y: 8)
        open.frame.origin = NSPoint(x: bounds.width - 18 - 32, y: 8)
        type.frame.origin = NSPoint(x: bounds.width - 18 - 32 - 2 - 32, y: 8)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { isDimmed ? nil : super.hitTest(point) }
    override func mouseDown(with event: NSEvent) {} // the bar doesn't start a text selection underneath it
}

// ---------- Text & appearance panel ----------

// A row with a plain hover background; subclasses draw their contents.
class PanelRow: ChromeControl {
    var theme = Theme.light { didSet { needsDisplay = true } }
    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool { needsDisplay = true; return true }
    override func resignFirstResponder() -> Bool { needsDisplay = true; return true }
    var lit: Bool { isHot || (window?.firstResponder === self && NSApp.currentEvent?.type == .keyDown) }

    func fillHover() {
        if lit {
            theme.hover.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 49 { onClick?() } else { super.keyDown(with: event) }
    }
}

final class SizeButton: PanelRow {
    private let fontSize: CGFloat
    init(size: CGFloat, title: String) {
        fontSize = size
        super.init(frame: .zero)
        toolTip = title
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        fillHover()
        let text = NSAttributedString(string: "A", attributes: [.font: Fonts.font("literata", size: fontSize), .foregroundColor: isHot ? theme.ink : theme.inkSoft])
        let size = text.size()
        text.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2))
    }
}

final class Swatch: ChromeControl {
    let id: String
    let label: String
    var theme = Theme.light { didSet { needsDisplay = true } }
    var isChosen = false { didSet { needsDisplay = true } }

    init(id: String, label: String) {
        self.id = id
        self.label = label
        super.init(frame: NSRect(x: 0, y: 0, width: 56, height: 50))
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let circle = NSRect(x: (bounds.width - 26) / 2, y: 2, width: 26, height: 26)
        let oval = NSBezierPath(ovalIn: circle)
        if isChosen {
            theme.inkSoft.setFill()
            NSBezierPath(ovalIn: circle.insetBy(dx: -3, dy: -3)).fill()
            theme.popBg.setFill()
            NSBezierPath(ovalIn: circle.insetBy(dx: -2, dy: -2)).fill()
        }
        switch id {
        case "auto":
            NSGraphicsContext.saveGraphicsState()
            oval.addClip()
            NSColor(hex: "#faf8f4").setFill()
            circle.fill()
            let dark = NSBezierPath()
            dark.move(to: NSPoint(x: circle.maxX, y: circle.minY))
            dark.line(to: NSPoint(x: circle.maxX, y: circle.maxY))
            dark.line(to: NSPoint(x: circle.minX, y: circle.maxY))
            dark.close()
            NSColor(hex: "#1b1b1d").setFill()
            dark.fill()
            NSGraphicsContext.restoreGraphicsState()
        default:
            Theme.named(id).bg.setFill()
            oval.fill()
        }
        theme.edge.setStroke()
        let ring = NSBezierPath(ovalIn: circle.insetBy(dx: 0.5, dy: 0.5))
        ring.lineWidth = 1
        ring.stroke()
        let color = isChosen ? theme.ink : isHot ? theme.inkSoft : theme.muted
        let text = NSAttributedString(string: label, attributes: [.font: Fonts.ui(11), .foregroundColor: color])
        text.draw(at: NSPoint(x: (bounds.width - text.size().width) / 2, y: 34.5))
    }
}

final class FontRow: PanelRow {
    let face: Typeface
    var isChosen = false { didSet { needsDisplay = true } }
    var onArrow: ((Int) -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 125 { onArrow?(1) } else if event.keyCode == 126 { onArrow?(-1) } else { super.keyDown(with: event) }
    }

    init(face: Typeface) {
        self.face = face
        super.init(frame: .zero)
        toolTip = "⇧⌘F for the next typeface"
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        fillHover()
        let color = isHot || isChosen ? theme.ink : theme.inkSoft
        if isChosen {
            let tick = NSBezierPath()
            let scale: CGFloat = 12.0 / 14.0
            let ox: CGFloat = 8, oy = (bounds.height - 12) / 2
            tick.move(to: NSPoint(x: ox + 2.5 * scale, y: oy + 7.5 * scale))
            tick.line(to: NSPoint(x: ox + 5.5 * scale, y: oy + 10.5 * scale))
            tick.line(to: NSPoint(x: ox + 11.5 * scale, y: oy + 3.5 * scale))
            tick.lineWidth = 1.6 * scale
            tick.lineCapStyle = .round
            tick.lineJoinStyle = .round
            color.setStroke()
            tick.stroke()
        }
        let kind = NSAttributedString(string: face.kind, attributes: [.font: Fonts.ui(12), .foregroundColor: theme.muted])
        let kindSize = kind.size()
        kind.draw(at: NSPoint(x: bounds.width - 10 - kindSize.width, y: (bounds.height - kindSize.height) / 2))
        let font = Fonts.font(face.family, weight: face.listWeight, size: face.listSize)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let name = NSAttributedString(string: face.name, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph])
        let height = name.size().height
        name.draw(in: NSRect(x: 28, y: (bounds.height - height) / 2, width: bounds.width - 28 - 10 - kindSize.width - 6, height: height))
    }
}

final class PointerToggle: PanelRow {
    var isOn = true { didSet { refreshSwitch(animated: true) } }
    private let track = CALayer()
    private let knob = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        track.cornerRadius = 8
        knob.cornerRadius = 6
        knob.shadowOpacity = 0.2
        knob.shadowRadius = 1
        knob.shadowOffset = CGSize(width: 0, height: 1)
        layer?.addSublayer(track)
        track.addSublayer(knob)
        setAccessibilityElement(true)
        setAccessibilityRole(.checkBox)
        setAccessibilityLabel("Sumi pointer")
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        track.frame = CGRect(x: bounds.width - 10 - 26, y: (bounds.height - 16) / 2, width: 26, height: 16)
        knob.bounds = CGRect(x: 0, y: 0, width: 12, height: 12)
        CATransaction.commit()
        refreshSwitch(animated: false)
    }

    func refreshSwitch(animated: Bool) {
        let duration = animated ? 0.15 : 0
        animate(track, "backgroundColor", to: (isOn ? theme.inkSoft : theme.faint).cgColor, duration: duration)
        animate(knob, "position", to: NSValue(point: NSPoint(x: isOn ? 18 : 8, y: 8)), duration: duration)
        knob.backgroundColor = theme.popBg.cgColor
        setAccessibilityValue(isOn)
    }

    override func draw(_ dirtyRect: NSRect) {
        fillHover()
        let text = NSAttributedString(string: "Sumi pointer", attributes: [.font: Fonts.ui(13), .foregroundColor: isHot ? theme.ink : theme.inkSoft])
        text.draw(at: NSPoint(x: 28, y: (bounds.height - text.size().height) / 2))
    }
}

final class SeparatorView: NSView {
    var color = NSColor.clear { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        bounds.fill()
    }
}

private final class FlippedDocument: NSView {
    override var isFlipped: Bool { true }
}

final class TypoPanel: NSView {
    private let surface = NSView()
    private let scroll = NSScrollView()
    private let content = FlippedDocument()
    let smaller = SizeButton(size: 13, title: "Smaller (⌘−)")
    let larger = SizeButton(size: 20, title: "Larger (⌘+)")
    var swatches: [Swatch] = []
    var fontRows: [FontRow] = []
    let toggle = PointerToggle(frame: .zero)
    private let separators = [SeparatorView(), SeparatorView(), SeparatorView()]
    private(set) var isOpen = false
    static let width: CGFloat = 264
    private let contentHeight: CGFloat = 4 + 36 + 4 + 1 + 70 + 1 + 5 + 320 + 4 + 1 + 4 + 32 + 4

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.opacity = 0
        surface.wantsLayer = true
        surface.layer?.cornerRadius = 10
        surface.layer?.borderWidth = 1
        surface.layer?.masksToBounds = true
        addSubview(surface)

        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.documentView = content
        surface.addSubview(scroll)

        content.addSubview(smaller)
        content.addSubview(larger)
        separators.forEach(content.addSubview)
        for (id, label) in [("auto", "Automatic"), ("light", "Paper"), ("sepia", "Sepia"), ("dark", "Night")] {
            let swatch = Swatch(id: id, label: label)
            swatches.append(swatch)
            content.addSubview(swatch)
        }
        for face in Typeface.all {
            let row = FontRow(face: face)
            fontRows.append(row)
            content.addSubview(row)
        }
        content.addSubview(toggle)
        arrange()
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { isOpen ? super.hitTest(point) : nil }
    override func mouseDown(with event: NSEvent) {}

    // Same arrangement as the page's panel: 4 px of padding, each section separated by a hairline.
    private func arrange() {
        let inner = TypoPanel.width - 2 - 8
        content.frame = NSRect(x: 0, y: 0, width: TypoPanel.width - 2, height: contentHeight)
        var y: CGFloat = 4
        smaller.frame = NSRect(x: 4, y: y, width: inner / 2, height: 36)
        larger.frame = NSRect(x: 4 + inner / 2, y: y, width: inner / 2, height: 36)
        y += 36 + 4
        separators[0].frame = NSRect(x: 4, y: y, width: inner, height: 1)
        y += 1 + 10
        let gap = (inner - 8 - 56 * 4) / 8
        var x: CGFloat = 4 + 4 + gap
        for swatch in swatches {
            swatch.frame = NSRect(x: x, y: y, width: 56, height: 52)
            x += 56 + 2 * gap
        }
        y += 60
        separators[1].frame = NSRect(x: 4, y: y, width: inner, height: 1)
        y += 1 + 5
        for row in fontRows {
            row.frame = NSRect(x: 4, y: y, width: inner, height: 32)
            y += 32
        }
        y += 4
        separators[2].frame = NSRect(x: 4, y: y, width: inner, height: 1)
        y += 1 + 4
        toggle.frame = NSRect(x: 4, y: y, width: inner, height: 32)
    }

    func apply(_ theme: Theme) {
        surface.layer?.backgroundColor = theme.popBg.cgColor
        surface.layer?.borderColor = theme.edge.cgColor
        layer?.shadowColor = NSColor(calibratedWhite: 0, alpha: 1).cgColor
        layer?.shadowOpacity = theme.shadowOpacity
        layer?.shadowRadius = theme.shadowRadius
        layer?.shadowOffset = CGSize(width: 0, height: -theme.shadowOffset)
        separators.forEach { $0.color = theme.rule }
        smaller.theme = theme
        larger.theme = theme
        swatches.forEach { $0.theme = theme }
        fontRows.forEach { $0.theme = theme }
        toggle.theme = theme
        toggle.refreshSwitch(animated: false)
    }

    func fit(in rootBounds: NSRect) {
        let height = min(contentHeight + 2, rootBounds.height - 56)
        frame = NSRect(x: rootBounds.width - 18 - TypoPanel.width, y: 42, width: TypoPanel.width, height: max(height, 40))
        surface.frame = bounds
        scroll.frame = surface.bounds.insetBy(dx: 1, dy: 1)
        let wanted = NSRect(x: 0, y: 0, width: TypoPanel.width - 2, height: contentHeight)
        if content.frame != wanted { arrange() }
    }

    func setOpen(_ open: Bool) {
        guard open != isOpen else { return }
        isOpen = open
        let ease = CAMediaTimingFunction(name: .easeInEaseOut)
        animate(layer, "opacity", to: open ? Float(1) : Float(0), duration: 0.16, timing: ease)
        animate(layer, "sublayerTransform", to: NSValue(caTransform3D: open ? CATransform3DIdentity : CATransform3DMakeTranslation(0, -4, 0)), duration: 0.16, timing: ease)
    }

    func moveFocus(from row: FontRow, by delta: Int) {
        guard let index = fontRows.firstIndex(where: { $0 === row }) else { return }
        let next = min(max(index + delta, 0), fontRows.count - 1)
        window?.makeFirstResponder(fontRows[next])
    }
}

// ---------- Outline ----------

struct OutlineRow {
    let title: String
    let depth: Int
    let location: Int
}

final class OutlineList: ChromeControl {
    var rows: [OutlineRow] = [] { didSet { measure() } }
    var emptyText: String?
    var theme = Theme.light { didSet { needsDisplay = true } }
    var active: Int? { didSet { if active != oldValue { needsDisplay = true } } }
    var hovered: Int? { didSet { if hovered != oldValue { needsDisplay = true } } }
    var onChoose: ((OutlineRow) -> Void)?
    private var frames: [NSRect] = []
    private var strings: [NSAttributedString] = []

    private func font(_ depth: Int) -> NSFont { Fonts.ui(depth == 3 ? 12.5 : 13) }
    private func line(_ depth: Int) -> CGFloat { depth == 3 ? 12.5 * 1.45 : 13 * 1.45 }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize.width != frame.width
        super.setFrameSize(newSize)
        if changed { measure() }
    }

    func measure() {
        frames = []
        var y: CGFloat = 0
        let width = bounds.width
        for (index, row) in rows.enumerated() {
            if row.depth == 1, index > 0 { y += 7 }
            let indent: CGFloat = row.depth == 2 ? 12 : row.depth == 3 ? 24 : 0
            let height = NSAttributedString(string: row.title, attributes: [.font: font(row.depth), .paragraphStyle: style(row.depth)])
                .boundingRect(with: NSSize(width: max(width - indent, 10), height: 1000), options: [.usesLineFragmentOrigin]).height
            frames.append(NSRect(x: indent, y: y, width: width - indent, height: ceil(height) + 6))
            y += ceil(height) + 6
        }
        if rows.isEmpty, emptyText != nil { y = 19 }
        setFrameSize(NSSize(width: width, height: y))
        needsDisplay = true
    }

    private func style(_ depth: Int) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.minimumLineHeight = line(depth)
        p.maximumLineHeight = line(depth)
        return p
    }

    func row(at point: NSPoint) -> Int? { frames.firstIndex { $0.contains(point) || ($0.minY...$0.maxY).contains(point.y) } }

    override func mouseUp(with event: NSEvent) {
        if let index = row(at: convert(event.locationInWindow, from: nil)) { onChoose?(rows[index]) }
    }

    override func hotChanged() { if !isHot { hovered = nil } }

    func y(ofRow index: Int) -> ClosedRange<CGFloat>? { frames.indices.contains(index) ? frames[index].minY...frames[index].maxY : nil }

    override func draw(_ dirtyRect: NSRect) {
        if rows.isEmpty, let empty = emptyText {
            NSAttributedString(string: empty, attributes: [.font: Fonts.ui(13), .foregroundColor: theme.ink3]).draw(at: .zero)
            return
        }
        for (index, row) in rows.enumerated() where frames[index].intersects(dirtyRect) {
            let on = index == hovered || index == active
            let color = on ? theme.ink : row.depth == 1 ? theme.inkSoft : theme.ink3
            let text = NSAttributedString(string: row.title, attributes: [.font: font(row.depth), .foregroundColor: color, .paragraphStyle: style(row.depth)])
            text.draw(with: frames[index].insetBy(dx: 0, dy: 3), options: [.usesLineFragmentOrigin])
        }
    }
}

final class OutlineView: NSView {
    let list = OutlineList(frame: NSRect(x: 0, y: 0, width: 200, height: 0))
    private let scroll = NSScrollView()
    private let shade = NSView()
    private(set) var isOverlay = false
    private var theme = Theme.light

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.opacity = 0
        isHidden = true
        shade.wantsLayer = true
        addSubview(shade)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.documentView = list
        addSubview(scroll)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func mouseDown(with event: NSEvent) {}

    func apply(_ theme: Theme) {
        self.theme = theme
        list.theme = theme
        refreshShade()
    }

    private func refreshShade() {
        shade.isHidden = !isOverlay
        shade.layer?.backgroundColor = theme.bg.cgColor
        shade.layer?.shadowOpacity = isOverlay ? 0.2 : 0
        shade.layer?.shadowRadius = 16
        shade.layer?.shadowOffset = CGSize(width: 12, height: 0)
    }

    // Sits under the toolbar's contents icon; in small windows it lies over the page instead.
    func place(in root: NSRect, overlay: Bool) {
        isOverlay = overlay
        if overlay {
            frame = NSRect(x: 0, y: 44, width: 250, height: root.height - 44)
            shade.frame = bounds
            scroll.frame = NSRect(x: 28, y: 6, width: 250 - 28 - 24, height: bounds.height - 6 - 40)
        } else {
            let height = min(max(list.frame.height, 1), root.height - 82)
            frame = NSRect(x: 28, y: 50, width: 200, height: max(height, 1))
            shade.frame = bounds
            scroll.frame = bounds
        }
        list.setFrameSize(NSSize(width: scroll.frame.width, height: list.frame.height))
        refreshShade()
    }

    func setOpen(_ open: Bool) {
        if open { isHidden = false }
        animate(layer, "opacity", to: open ? Float(1) : Float(0), duration: 0.2)
        if !open {
            DispatchQueue.main.asyncAfter(deadline: .now() + Motion.duration(0.2)) { [weak self] in
                if self?.layer?.opacity == 0 { self?.isHidden = true }
            }
        }
    }

    func reveal(row index: Int) {
        guard let span = list.y(ofRow: index) else { return }
        let visible = scroll.contentView.bounds
        if span.lowerBound < visible.minY || span.upperBound > visible.maxY {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, span.lowerBound - 20)))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }
}

// ---------- Empty state ----------

final class WelcomeButton: ChromeControl {
    var theme = Theme.light { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        theme.popBg.setFill()
        path.fill()
        if isHot {
            theme.hover.setFill()
            path.fill()
        }
        theme.edge.setStroke()
        path.lineWidth = 1
        path.stroke()
        let text = NSAttributedString(string: "Open…", attributes: [.font: Fonts.ui(13), .foregroundColor: theme.ink])
        text.draw(at: NSPoint(x: (bounds.width - text.size().width) / 2, y: (bounds.height - text.size().height) / 2))
    }
}

final class WelcomeView: NSView {
    let button = WelcomeButton(frame: .zero)
    var theme = Theme.light {
        didSet {
            needsDisplay = true
            button.theme = theme
        }
    }
    private let icon = NSImage(contentsOf: Bundle.main.resourceURL!.appendingPathComponent("icon.png"))
    private var lines: [(NSAttributedString, NSPoint)] = []
    private(set) var textRects: [NSRect] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(button)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    private func text(_ string: String, _ size: CGFloat, _ color: NSColor) -> NSAttributedString {
        NSAttributedString(string: string, attributes: [.font: Fonts.ui(size), .foregroundColor: color])
    }

    override func layout() {
        super.layout()
        let lead = text("Open a Markdown file to start reading.", 15, theme.inkSoft)
        let keys = text("⌘O", 12, theme.muted)
        let sub = text("You can also drag a file into this window.", 12, theme.muted)
        let buttonWidth = ceil(text("Open…", 13, theme.ink).size().width) + 34
        let total: CGFloat = 64 + 18 + 24 + 18 + 30 + 26 + 18
        let area = bounds.height - 40 - 80
        var y = 40 + max(0, (area - total) / 2)
        iconFrame = NSRect(x: (bounds.width - 64) / 2, y: y, width: 64, height: 64)
        y += 64 + 18
        lines = []
        textRects = []
        func place(_ s: NSAttributedString, x: CGFloat, y: CGFloat) {
            lines.append((s, NSPoint(x: x, y: y)))
            textRects.append(NSRect(origin: NSPoint(x: x, y: y), size: s.size()))
        }
        place(lead, x: (bounds.width - lead.size().width) / 2, y: y + (22.5 - lead.size().height) / 2)
        y += 24 + 18
        let row = buttonWidth + 10 + keys.size().width
        let x = (bounds.width - row) / 2
        button.frame = NSRect(x: x, y: y, width: buttonWidth, height: 30)
        place(keys, x: x + buttonWidth + 10, y: y + (30 - keys.size().height) / 2)
        y += 30 + 26
        place(sub, x: (bounds.width - sub.size().width) / 2, y: y)
    }

    private var iconFrame = NSRect.zero

    override func draw(_ dirtyRect: NSRect) {
        icon?.draw(in: iconFrame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])
        for (string, point) in lines { string.draw(at: point) }
    }

    override func resetCursorRects() {}
}

// ---------- Messages & drop ----------

final class ToastView: NSView {
    private let label = NSTextField(labelWithString: "")
    private var timer: Timer?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.opacity = 0
        layer?.cornerRadius = 7
        layer?.borderWidth = 1
        label.font = Fonts.ui(13)
        addSubview(label)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func apply(_ theme: Theme) {
        layer?.backgroundColor = theme.popBg.cgColor
        layer?.borderColor = theme.edge.cgColor
        layer?.shadowOpacity = theme.shadowOpacity
        layer?.shadowRadius = theme.shadowRadius
        layer?.shadowOffset = CGSize(width: 0, height: -theme.shadowOffset)
        label.textColor = theme.inkSoft
    }

    func show(_ text: String, in root: NSRect) {
        label.stringValue = text
        label.sizeToFit()
        let size = NSSize(width: label.frame.width + 26, height: label.frame.height + 16)
        frame = NSRect(x: (root.width - size.width) / 2, y: root.height - 20 - size.height, width: size.width, height: size.height)
        label.frame.origin = NSPoint(x: 13, y: 8)
        animate(layer, "opacity", to: Float(1), duration: 0.2)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak self] _ in
            animate(self?.layer, "opacity", to: Float(0), duration: 0.2)
        }
    }
}

final class DropView: NSView {
    private var accent = NSColor.clear

    override init(frame: NSRect) {
        super.init(frame: frame)
        flatView(self)
        layer?.opacity = 0
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func apply(_ theme: Theme) {
        accent = theme.accent
        needsDisplay = true
    }

    func setShown(_ shown: Bool) {
        animate(layer, "opacity", to: shown ? Float(1) : Float(0), duration: 0.15)
    }

    override func draw(_ dirtyRect: NSRect) {
        accent.withOpacity(0.05).setFill()
        bounds.fill()
        accent.withOpacity(0.55).setFill()
        let ring = NSBezierPath(rect: bounds)
        ring.append(NSBezierPath(rect: bounds.insetBy(dx: 2, dy: 2)))
        ring.windingRule = .evenOdd
        ring.fill()
    }
}

// ---------- Pointer ----------

// A small ink dot that follows the mouse exactly. It grows over things you can click, presses in on click, and becomes
// a slim rounded bar over text. White with a difference blend, so it always inverts whatever is beneath it.
final class PointerLayer {
    enum Shape: Equatable {
        case dot, hover
        case bar(CGFloat)
    }

    // Directly over the page: Core Animation's blend only sees the page from there, not from inside a holder layer.
    let ink = CALayer()
    private let spring = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
    private(set) var shape = Shape.dot
    private var isDown = false
    private var isAway = true

    init() {
        ink.zPosition = 1000
        ink.backgroundColor = NSColor.white.cgColor
        ink.compositingFilter = "differenceBlendMode"
        ink.bounds = CGRect(x: 0, y: 0, width: 10, height: 10)
        ink.cornerRadius = 5
        ink.opacity = 0
        ink.actions = ["position": NSNull(), "hidden": NSNull()]
    }

    func move(to point: CGPoint) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ink.position = point
        CATransaction.commit()
    }

    func set(_ next: Shape) {
        guard next != shape else { return }
        shape = next
        var width: CGFloat = 10, height: CGFloat = 10, radius: CGFloat = 5
        switch next {
        case .dot: break
        case .hover: width = 34; height = 34; radius = 17
        case .bar(let h): width = 4; height = h; radius = 2
        }
        animate(ink, "bounds", to: NSValue(rect: NSRect(x: 0, y: 0, width: width, height: height)), duration: 0.22, timing: spring)
        animate(ink, "cornerRadius", to: radius, duration: 0.22, timing: spring)
    }

    func setDown(_ down: Bool) {
        guard down != isDown else { return }
        isDown = down
        var transform = CATransform3DIdentity
        if down {
            if case .bar = shape { transform = CATransform3DMakeScale(1, 0.92, 1) } else { transform = CATransform3DMakeScale(0.78, 0.78, 1) }
        }
        animate(ink, "transform", to: NSValue(caTransform3D: transform), duration: 0.14, timing: CAMediaTimingFunction(name: .default))
    }

    func setAway(_ away: Bool) {
        guard away != isAway else { return }
        isAway = away
        animate(ink, "opacity", to: away ? Float(0) : Float(1), duration: 0.2)
    }
}

let blankCursor: NSCursor = {
    // Drawn into, so it has a real transparent bitmap: a cursor with an empty image isn't reliably blank.
    let image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { _ in
        NSColor.clear.setFill()
        return true
    }
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 16, pixelsHigh: 16, bitsPerSample: 8, samplesPerPixel: 4,
                                  hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    image.addRepresentation(bitmap)
    return NSCursor(image: image, hotSpot: .zero)
}()
