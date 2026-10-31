// Turns parsed Markdown into styled text for TextKit, following the rules in style.css.
import AppKit

extension NSAttributedString.Key {
    static let sumiBaseFont = NSAttributedString.Key("sumi.baseFont")       // the font that sets a line's baseline
    static let sumiLink = NSAttributedString.Key("sumi.link")               // destination of a link
    static let sumiChip = NSAttributedString.Key("sumi.chip")               // ChipStyle: inline code, kbd, mark
    static let sumiMarker = NSAttributedString.Key("sumi.marker")           // ListMarker, on a list item's first character
    static let sumiCode = NSAttributedString.Key("sumi.code")               // part of a code block
    static let sumiSummary = NSAttributedString.Key("sumi.summary")         // index of the <details> this summary toggles
    static let sumiHang = NSAttributedString.Key("sumi.hang")               // width of an opening quote that hangs in the margin
}

final class ChipStyle: NSObject {
    let fill: NSColor?
    let border: NSColor?
    let paddingX, paddingY, radius, borderBottom: CGFloat
    init(fill: NSColor?, border: NSColor?, paddingX: CGFloat, paddingY: CGFloat, radius: CGFloat, borderBottom: CGFloat = 0) {
        self.fill = fill; self.border = border; self.paddingX = paddingX; self.paddingY = paddingY; self.radius = radius; self.borderBottom = borderBottom
    }
}

final class ListMarker: NSObject {
    enum Kind { case disc, circle, square, number(String), disclosure(open: Bool) }
    let kind: Kind
    let font: NSFont
    let color: NSColor
    let right: CGFloat // the marker's right edge, in text-container coordinates
    init(kind: Kind, font: NSFont, color: NSColor, right: CGFloat) {
        self.kind = kind; self.font = font; self.color = color; self.right = right
    }
}

// A decorated region of the document; the layout manager paints these behind the text.
final class BlockBox {
    enum Kind { case code, quote, details, rule }
    let kind: Kind
    var range = NSRange(location: 0, length: 0)
    let left: CGFloat, right: CGFloat // insets from the column's edges
    let paddingTop: CGFloat
    var paddingBottom: CGFloat
    var code = ""
    var fontSize: CGFloat = 0
    var scrollX: CGFloat = 0 // how far a code block has been scrolled sideways
    var contentWidth: CGFloat = 0
    var thumbAlpha: CGFloat = 0
    var ruleWidth: CGFloat = 0
    init(kind: Kind, left: CGFloat, right: CGFloat, paddingTop: CGFloat = 0, paddingBottom: CGFloat = 0) {
        self.kind = kind; self.left = left; self.right = right; self.paddingTop = paddingTop; self.paddingBottom = paddingBottom
    }
}

// An image, drawn with the reader's rounded corners and never wider than the column.
final class ImageCell: NSTextAttachmentCell {
    var picture: NSImage?
    init(picture: NSImage?) {
        self.picture = picture
        super.init(imageCell: nil)
    }
    required init(coder: NSCoder) { fatalError() }

    override func cellFrame(for textContainer: NSTextContainer, proposedLineFragment lineFrag: NSRect, glyphPosition position: NSPoint, characterIndex charIndex: Int) -> NSRect {
        guard let picture = picture, picture.size.width > 0 else { return .zero }
        let scale = min(1, lineFrag.width / picture.size.width)
        return NSRect(x: 0, y: 0, width: floor(picture.size.width * scale), height: floor(picture.size.height * scale))
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        guard let picture = picture else { return }
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: cellFrame, xRadius: 10, yRadius: 10).addClip()
        NSGraphicsContext.current?.imageInterpolation = .high
        picture.draw(in: cellFrame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
    }
}

// The small boxes of a task list. They're display only, as on Windows.
final class CheckCell: NSTextAttachmentCell {
    let checked: Bool, side: CGFloat, gap: CGFloat
    let muted: NSColor, accent: NSColor, paper: NSColor
    let descent: CGFloat
    init(checked: Bool, side: CGFloat, gap: CGFloat, descent: CGFloat, muted: NSColor, accent: NSColor, paper: NSColor) {
        self.checked = checked; self.side = side; self.gap = gap; self.descent = descent; self.muted = muted; self.accent = accent; self.paper = paper
        super.init(imageCell: nil)
    }
    required init(coder: NSCoder) { fatalError() }

    override func cellSize() -> NSSize { NSSize(width: side + gap, height: side) }
    override func cellBaselineOffset() -> NSPoint { NSPoint(x: 0, y: -descent) }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        let box = NSRect(x: cellFrame.minX, y: cellFrame.minY, width: side, height: side).insetBy(dx: 0.75, dy: 0.75)
        let radius = side * 0.28
        let path = NSBezierPath(roundedRect: box, xRadius: radius, yRadius: radius)
        path.lineWidth = 1.5
        (checked ? accent : muted).setStroke()
        if checked {
            accent.setFill()
            path.fill()
        }
        path.stroke()
        if checked {
            let tick = NSBezierPath()
            let u = side / 0.95 // one em
            let flipped = controlView?.isFlipped ?? true
            let y: (CGFloat) -> CGFloat = { flipped ? box.minY + $0 * u : box.maxY - $0 * u }
            tick.move(to: NSPoint(x: box.minX + 0.2 * u, y: y(0.42)))
            tick.line(to: NSPoint(x: box.minX + 0.36 * u, y: y(0.6)))
            tick.line(to: NSPoint(x: box.minX + 0.7 * u, y: y(0.17)))
            tick.lineWidth = 0.12 * u
            tick.lineCapStyle = .butt
            tick.lineJoinStyle = .miter
            paper.setStroke()
            tick.stroke()
        }
    }
}

// A table cell with its rule drawn here, because TextKit's own borders only come in whole points.
final class TableCellBlock: NSTextTableBlock {
    var ruleHeight: CGFloat = 0
    var ruleColor: NSColor?

    override func drawBackground(withFrame frameRect: NSRect, in controlView: NSView, characterRange charRange: NSRange, layoutManager: NSLayoutManager) {
        guard ruleHeight > 0, let color = ruleColor else { return }
        color.setFill()
        NSRect(x: frameRect.minX, y: frameRect.maxY - ruleHeight, width: frameRect.width, height: ruleHeight).fill()
    }
}

struct HeadingEntry {
    let title: String
    let level: Int
    let id: String
    let location: Int
}

final class BuiltDocument {
    let text = NSMutableAttributedString()
    var boxes: [BlockBox] = []
    var headings: [HeadingEntry] = []
    var firstIsSoleH1 = false
    var trailingMargin: CGFloat = 0
    var widestTable: CGFloat = 0 // below this column width, table columns depend on the width
}

struct BuildStyle {
    let theme: Theme
    let face: Typeface
    let size: CGFloat
    let openDetails: Set<Int>
    let images: ImageStore
    let columnWidth: CGFloat
}

final class DocumentBuilder {
    private struct Context {
        var left: CGFloat = 0
        var right: CGFloat = 0
        var color: NSColor
        var italic = false
        var fontSize: CGFloat
        var weight: CGFloat
    }

    private struct Run {
        var font: NSFont
        var color: NSColor
        var fontSize: CGFloat
        var weight: CGFloat
        var italic: Bool
        var features: [String]
        var link: String?
        var underline = false
        var strike = false
        var chip: ChipStyle?
        var baselineShift: CGFloat = 0
    }

    private let style: BuildStyle
    private let out = BuiltDocument()
    private let base: CGFloat
    private var pendingGap: CGFloat = 0
    private var pendingPadding: CGFloat = 0 // a box's padding sits outside the margin collapsing
    private var atStart = true
    private var detailsIndex = 0
    private var usedIDs = Set<String>()
    private let family: String
    private var textFeatures: [String] {
        (style.face.ligatures ? ["kern", "liga", "calt"] : ["kern", "liga=0", "calt=0"]) + (style.face.numerals.map { [$0] } ?? [])
    }
    private var headingFeatures: [String] { style.face.ligatures ? ["kern", "liga", "lnum"] : ["kern", "liga=0", "calt=0", "lnum"] }

    init(style: BuildStyle) {
        self.style = style
        base = style.size * style.face.scale
        family = style.face.family
    }

    static func build(_ blocks: [Block], style: BuildStyle) -> BuiltDocument {
        let builder = DocumentBuilder(style: style)
        let context = Context(color: style.theme.ink, fontSize: builder.base, weight: style.face.bodyWeight)
        builder.emit(blocks, context)
        builder.finish()
        return builder.out
    }

    private func finish() {
        out.trailingMargin = pendingGap + pendingPadding
        if let first = firstBlockHeading, first {
            let h1s = out.headings.filter { $0.level == 1 }.count
            out.firstIsSoleH1 = h1s == 1
        }
        // The paragraph separator after the last block isn't needed.
        if out.text.length > 0, out.text.string.hasSuffix("\n") {
            out.text.deleteCharacters(in: NSRange(location: out.text.length - 1, length: 1))
            for box in out.boxes where NSMaxRange(box.range) > out.text.length {
                box.range.length = out.text.length - box.range.location
            }
        }
    }

    private var firstBlockHeading: Bool?

    private func gap(top: CGFloat) {
        pendingGap = max(pendingGap, top)
    }

    // Vertical margins collapse, as they do in CSS: the gap between two blocks is the larger of the two.
    private func takeGap() -> CGFloat {
        defer {
            pendingGap = 0
            pendingPadding = 0
        }
        if atStart {
            atStart = false
            return pendingPadding
        }
        return pendingGap + pendingPadding
    }

    private func paragraphStyle(_ context: Context, lineHeight: CGFloat?, first: CGFloat? = nil, gap: CGFloat, alignment: NSTextAlignment = .natural, clip: Bool = false) -> NSMutableParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.headIndent = context.left
        p.firstLineHeadIndent = first ?? context.left
        p.tailIndent = -context.right
        p.paragraphSpacingBefore = gap
        p.alignment = alignment
        if let height = lineHeight {
            p.minimumLineHeight = height
            p.maximumLineHeight = height
        }
        if clip { p.lineBreakMode = .byClipping }
        return p
    }

    private func emit(_ blocks: [Block], _ context: Context, tight: Bool = false) {
        for block in blocks { emit(block, context, tight: tight) }
    }

    private func emit(_ block: Block, _ context: Context, tight: Bool) {
        if firstBlockHeading == nil {
            if case .heading(1, _) = block { firstBlockHeading = true } else { firstBlockHeading = false }
        }
        switch block {
        case .heading(let level, let content): heading(level, content, context)
        case .paragraph(let content): paragraph(content, context, tight: tight)
        case .code(let code): codeBlock(code, context)
        case .quote(let blocks): quote(blocks, context)
        case .list(let ordered, let start, let loose, let items): list(ordered, start, loose, items, context)
        case .rule: rule(context)
        case .table(let aligns, let header, let rows): table(aligns, header, rows, context)
        case .details(let summary, let blocks): details(summary, blocks, context)
        }
    }

    // ---------- Text blocks ----------

    private func bodyRun(_ context: Context) -> Run {
        run(size: context.fontSize, weight: context.weight, italic: context.italic, color: context.color, features: textFeatures)
    }

    private func run(size: CGFloat, weight: CGFloat, italic: Bool, color: NSColor, features: [String]) -> Run {
        Run(font: Fonts.font(family, weight: weight, italic: italic, size: size, features: features), color: color, fontSize: size, weight: weight, italic: italic, features: features)
    }

    private func heading(_ level: Int, _ content: [Inline], _ context: Context) {
        let face = style.face
        let em = context.fontSize
        var size = em, weight = face.hWeight, top = 2.2 * em, height: CGFloat = 1.25, italic = context.italic
        var color = style.theme.ink
        var tracking: CGFloat = -0.005
        switch level {
        case 1: size = em * 2.15; weight = face.h1Weight; tracking = -0.015; height = 1.15; top = 1.2 * size
        case 2: size = em * 1.45; weight = face.h2Weight; top = 2.2 * size
        case 3: size = em * 1.18; top = 2.2 * size
        case 4, 5: weight = face.strongWeight
        default: weight = face.bodyWeight; italic = true; color = style.theme.inkSoft
        }
        gap(top: top)
        let start = out.text.length
        let spacing = takeGap()
        let r = run(size: size, weight: weight, italic: italic, color: color, features: headingFeatures)
        let para = paragraphStyle(context, lineHeight: floor(size * height), gap: spacing)
        let text = NSMutableAttributedString()
        appendInlines(content, r, to: text, tracking: tracking * size)
        finishParagraph(text, para, baseFont: r.font)
        pendingGap = 0.7 * size

        let title = plainText(content)
        out.headings.append(HeadingEntry(title: title, level: level, id: uniqueID(title), location: start))
    }

    private func uniqueID(_ title: String) -> String {
        var slug = title.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        slug = String(slug.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || CharacterSet.whitespaces.contains($0) || $0 == "-" }.map(Character.init))
        slug = slug.split(whereSeparator: \.isWhitespace).joined(separator: "-")
        if slug.isEmpty { slug = "section" }
        var candidate = slug
        var n = 1
        while usedIDs.contains(candidate) {
            candidate = "\(slug)-\(n)"
            n += 1
        }
        usedIDs.insert(candidate)
        return candidate
    }

    // Images are blocks of their own, so a paragraph holding some is split around them.
    private func paragraph(_ content: [Inline], _ context: Context, tight: Bool, marker: ListMarker? = nil, prefix: NSAttributedString? = nil, spacedList: Bool = false) {
        let em = context.fontSize
        let bottom = tight ? 0 : (spacedList ? 0.5 * em : 1.15 * em)
        var pieces: [[Inline]] = [[]]
        var images: [(Int, String, String?)] = []
        flatten(content, link: nil, into: &pieces, images: &images)

        var imageIterator = images.makeIterator()
        var nextImage = imageIterator.next()
        var usedMarker = marker
        var usedPrefix = prefix
        for (index, piece) in pieces.enumerated() {
            let visible = !plainText(piece).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if visible || usedPrefix != nil {
                let spacing = takeGap()
                let para = paragraphStyle(context, lineHeight: floor(em * style.face.lineHeight), gap: spacing)
                let r = bodyRun(context)
                let text = NSMutableAttributedString()
                if let usedPrefix = usedPrefix { text.append(usedPrefix) }
                usedPrefix = nil
                appendInlines(piece, r, to: text)
                if let m = usedMarker, text.length > 0 {
                    // Over the whole paragraph: an attribute on just the first letter would split a ligature like "Th".
                    text.addAttribute(.sumiMarker, value: m, range: NSRange(location: 0, length: text.length))
                    usedMarker = nil
                }
                markHanging(text, font: r.font)
                finishParagraph(text, para, baseFont: r.font)
                pendingGap = bottom
            }
            if let image = nextImage, image.0 == index {
                imageBlock(image.1, link: image.2, context)
                nextImage = imageIterator.next()
                pendingGap = max(pendingGap, 2.2 * em)
            }
        }
    }

    private func flatten(_ inlines: [Inline], link: String?, into pieces: inout [[Inline]], images: inout [(Int, String, String?)]) {
        for inline in inlines {
            switch inline {
            case .image(let src, _):
                images.append((pieces.count - 1, src, link))
                pieces.append([])
            case .link(let href, let children) where containsImage(children):
                flatten(children, link: href, into: &pieces, images: &images)
            default:
                pieces[pieces.count - 1].append(inline)
            }
        }
    }

    private func containsImage(_ inlines: [Inline]) -> Bool {
        inlines.contains {
            if case .image = $0 { return true }
            return false
        }
    }

    private func imageBlock(_ src: String, link: String?, _ context: Context) {
        gap(top: 2.2 * context.fontSize)
        let spacing = takeGap()
        let cell = ImageCell(picture: nil)
        style.images.load(src, into: cell)
        let attachment = NSTextAttachment()
        attachment.attachmentCell = cell
        let text = NSMutableAttributedString(attachment: attachment)
        if let link = link { text.addAttribute(.sumiLink, value: link, range: NSRange(location: 0, length: text.length)) }
        let para = paragraphStyle(context, lineHeight: nil, gap: spacing, alignment: .center)
        text.addAttribute(.paragraphStyle, value: para, range: NSRange(location: 0, length: text.length))
        out.text.append(text)
        out.text.append(NSAttributedString(string: "\n", attributes: [.paragraphStyle: para, .font: Fonts.ui(1)]))
    }

    // CSS's hanging-punctuation: an opening quote sits in the margin, so the words stay in line.
    private func markHanging(_ text: NSMutableAttributedString, font: NSFont) {
        guard let first = text.string.first, "“‘«‹".contains(first) else { return }
        let width = NSAttributedString(string: String(first), attributes: [.font: font]).size().width
        text.addAttribute(.sumiHang, value: width, range: NSRange(location: 0, length: 1))
    }

    private func finishParagraph(_ text: NSMutableAttributedString, _ para: NSParagraphStyle, baseFont: NSFont) {
        text.append(NSAttributedString(string: "\n", attributes: [.font: baseFont, .foregroundColor: style.theme.ink]))
        let whole = NSRange(location: 0, length: text.length)
        text.addAttribute(.paragraphStyle, value: para, range: whole)
        text.addAttribute(.sumiBaseFont, value: baseFont, range: whole)
        out.text.append(text)
    }

    // ---------- Inline text ----------

    private func appendInlines(_ inlines: [Inline], _ r: Run, to text: NSMutableAttributedString, tracking: CGFloat = 0) {
        for inline in inlines { append(inline, r, to: text, tracking: tracking) }
    }

    private func append(_ inline: Inline, _ r: Run, to text: NSMutableAttributedString, tracking: CGFloat) {
        switch inline {
        case .text(let s):
            text.append(NSAttributedString(string: s, attributes: attributes(r, tracking: tracking)))
        case .lineBreak:
            text.append(NSAttributedString(string: "\u{2028}", attributes: attributes(r, tracking: tracking)))
        case .emphasis(let c):
            var next = r
            next.italic = true
            next.font = Fonts.font(family, weight: r.weight, italic: true, size: r.fontSize, features: r.features)
            appendInlines(c, next, to: text, tracking: tracking)
        case .strong(let c):
            var next = r
            next.weight = style.face.strongWeight
            next.font = Fonts.font(family, weight: next.weight, italic: r.italic, size: r.fontSize, features: r.features)
            appendInlines(c, next, to: text, tracking: tracking)
        case .strike(let c):
            var next = r
            next.strike = true
            appendInlines(c, next, to: text, tracking: tracking)
        case .link(let href, let c):
            var next = r
            next.link = href
            next.underline = true
            next.color = style.theme.accent
            appendInlines(c, next, to: text, tracking: tracking)
        case .code(let s):
            let size = r.fontSize * 0.82
            let chip = ChipStyle(fill: style.theme.codeBg, border: nil, paddingX: 0.38 * size, paddingY: 0.14 * size, radius: 5)
            appendChip(s, font: Fonts.mono(size), color: style.theme.inkSoft, chip: chip, r, to: text)
        case .tag(let name, let c):
            tag(name, c, r, to: text, tracking: tracking)
        default:
            break
        }
    }

    private func tag(_ name: String, _ children: [Inline], _ r: Run, to text: NSMutableAttributedString, tracking: CGFloat) {
        switch name {
        case "kbd":
            let size = r.fontSize * 0.78
            let chip = ChipStyle(fill: nil, border: style.theme.rule, paddingX: 0.45 * size + 1, paddingY: 0.1 * size + 1, radius: 5, borderBottom: 2)
            appendChip(plainText(children), font: Fonts.mono(size), color: r.color, chip: chip, r, to: text)
        case "mark":
            let em = r.fontSize
            let chip = ChipStyle(fill: style.theme.select, border: nil, paddingX: 0.15 * em, paddingY: 0, radius: 3)
            appendChip(plainText(children), font: r.font, color: r.color, chip: chip, r, to: text)
        case "sup", "sub":
            var next = r
            next.fontSize = r.fontSize * 0.83
            next.font = Fonts.font(family, weight: r.weight, italic: r.italic, size: next.fontSize, features: r.features)
            next.baselineShift = (name == "sup" ? 0.33 : -0.2) * r.fontSize
            appendInlines(children, next, to: text, tracking: tracking)
        case "small":
            var next = r
            next.fontSize = r.fontSize * 0.83
            next.font = Fonts.font(family, weight: r.weight, italic: r.italic, size: next.fontSize, features: r.features)
            appendInlines(children, next, to: text, tracking: tracking)
        case "u":
            var next = r
            next.underline = true
            appendInlines(children, next, to: text, tracking: tracking)
        default:
            appendInlines(children, r, to: text, tracking: tracking)
        }
    }

    // A chip's padding is made of kerning: extra space after the character before it, and after its own last one.
    private func appendChip(_ string: String, font: NSFont, color: NSColor, chip: ChipStyle, _ r: Run, to text: NSMutableAttributedString) {
        guard !string.isEmpty else { return }
        var attrs = attributes(r, tracking: 0)
        attrs[.font] = font
        attrs[.foregroundColor] = color
        attrs[.sumiChip] = chip
        attrs[.underlineStyle] = nil
        if text.length > 0 {
            let before = NSRange(location: text.length - 1, length: 1)
            let existing = text.attribute(.kern, at: before.location, effectiveRange: nil) as? CGFloat ?? 0
            text.addAttribute(.kern, value: existing + chip.paddingX, range: before)
        } else {
            attrs[.sumiHang] = -chip.paddingX // nudges a chip that starts a line back inside the column
        }
        let piece = NSMutableAttributedString(string: string, attributes: attrs)
        piece.addAttribute(.kern, value: chip.paddingX, range: NSRange(location: piece.length - 1, length: 1))
        text.append(piece)
    }

    private func attributes(_ r: Run, tracking: CGFloat) -> [NSAttributedString.Key: Any] {
        var attrs: [NSAttributedString.Key: Any] = [.font: r.font, .foregroundColor: r.color]
        if tracking != 0 { attrs[.kern] = tracking }
        if let link = r.link { attrs[.sumiLink] = link }
        if r.underline { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        if r.strike { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue; attrs[.strikethroughColor] = r.color }
        if r.baselineShift != 0 { attrs[.baselineOffset] = r.baselineShift }
        return attrs
    }

    // ---------- Code ----------

    private func codeBlock(_ code: String, _ context: Context) {
        let em = context.fontSize
        let size = em * 0.76
        gap(top: 1.6 * size)
        let spacing = takeGap()
        let padY = 1.15 * size, padX = 1.35 * size
        let box = BlockBox(kind: .code, left: context.left, right: context.right, paddingTop: padY, paddingBottom: padY)
        box.code = code
        box.fontSize = size

        let font = Fonts.mono(size)
        let line = floor(size * 1.7)
        var inner = context
        inner.left += padX
        inner.right += padX
        let start = out.text.length
        let lines = code.components(separatedBy: "\n")
        for (index, text) in lines.enumerated() {
            let top = index == 0 ? spacing + padY : 0
            let para = paragraphStyle(inner, lineHeight: line, gap: top, clip: true)
            let tabbed = text.replacingOccurrences(of: "\t", with: "    ") // tab-size: 4
            var attrs: [NSAttributedString.Key: Any] = [
                .font: font, .foregroundColor: style.theme.inkSoft, .paragraphStyle: para, .sumiBaseFont: font, .sumiCode: true,
            ]
            attrs[.ligature] = 0
            out.text.append(NSAttributedString(string: tabbed + "\n", attributes: attrs))
        }
        box.range = NSRange(location: start, length: out.text.length - start)
        out.boxes.append(box)
        pendingGap = 1.8 * size
        pendingPadding = padY
    }

    // ---------- Quotes, lists, dividers ----------

    private func quote(_ blocks: [Block], _ context: Context) {
        let em = context.fontSize
        gap(top: 1.8 * em)
        let box = BlockBox(kind: .quote, left: context.left, right: context.right, paddingTop: 0.1 * em, paddingBottom: 0.1 * em)
        var inner = context
        inner.left += 1.3 * em + 2
        inner.color = style.theme.inkSoft
        inner.italic = true
        let start = out.text.length
        pendingPadding += 0.1 * em
        out.boxes.append(box)
        emit(blocks, inner)
        // A closing paragraph has no bottom margin here; anything else keeps its own, inside the quote's padding.
        if case .paragraph? = blocks.last { pendingGap = 0 }
        box.paddingBottom += pendingGap
        box.range = NSRange(location: start, length: max(0, out.text.length - start))
        pendingGap = 1.8 * em
        pendingPadding = box.paddingBottom
    }

    private func list(_ ordered: Bool, _ start: Int, _ loose: Bool, _ items: [ListItem], _ context: Context) {
        let em = context.fontSize
        listDepth += 1
        defer { listDepth -= 1 }
        var number = start
        for item in items {
            gap(top: 0.3 * em)
            var inner = context
            inner.left = context.left + 1.4 * em + 0.25 * em
            let markerRight = context.left + 1.4 * em
            let task = item.task != nil

            if task { inner.left = context.left + 0.25 * em }

            var marker: ListMarker?
            if !task {
                if ordered {
                    let size = em * 0.9
                    let font = Fonts.font(family, weight: style.face.bodyWeight, italic: false, size: size, features: ["lnum", "tnum"])
                    marker = ListMarker(kind: .number("\(number)."), font: font, color: style.theme.muted, right: markerRight)
                } else {
                    let kind: ListMarker.Kind = listBulletDepth(listDepth) == 0 ? .disc : listBulletDepth(listDepth) == 1 ? .circle : .square
                    marker = ListMarker(kind: kind, font: Fonts.font(family, weight: style.face.bodyWeight, size: em), color: style.theme.muted, right: markerRight)
                }
            }
            number += 1

            var prefix: NSAttributedString?
            if let checked = item.task {
                // A form control doesn't inherit the page's text size, so these ems are its own 11 points.
                let space = NSAttributedString(string: " ", attributes: [.font: bodyRun(inner).font]).size().width
                let cell = CheckCell(checked: checked, side: 0.95 * 11, gap: 0.6 * 11 + space, descent: 0.1 * 11, muted: style.theme.muted, accent: style.theme.accent, paper: style.theme.bg)
                let attachment = NSTextAttachment()
                attachment.attachmentCell = cell
                prefix = NSAttributedString(attachment: attachment)
            }

            var blocks = item.blocks
            let first: Block? = blocks.isEmpty ? nil : blocks[0]
            if case .paragraph(let content)? = first {
                blocks.removeFirst()
                paragraph(content, inner, tight: !loose, marker: marker, prefix: prefix, spacedList: loose)
            } else if marker != nil || prefix != nil {
                // An item that opens with something other than text: the marker sits on an empty first line.
                paragraph([.text("\u{200B}")], inner, tight: true, marker: marker, prefix: prefix)
            }
            for block in blocks { emit(block, inner, tight: !loose) }
            gap(top: 0.3 * em)
        }
        pendingGap = max(pendingGap, 1.15 * em)
    }

    private var listDepth = 0
    private func listBulletDepth(_ depth: Int) -> Int { min(depth - 1, 2) }

    private func rule(_ context: Context) {
        let em = context.fontSize
        gap(top: 2.8 * em)
        let spacing = takeGap()
        let box = BlockBox(kind: .rule, left: context.left, right: context.right)
        box.ruleWidth = 4 * em
        let para = paragraphStyle(context, lineHeight: 1, gap: spacing)
        box.range = NSRange(location: out.text.length, length: 1)
        out.text.append(NSAttributedString(string: "\n", attributes: [.font: Fonts.ui(1), .paragraphStyle: para, .sumiBaseFont: Fonts.ui(1)]))
        out.boxes.append(box)
        pendingGap = 2.8 * em
    }

    // ---------- Tables ----------

    private func table(_ aligns: [Alignment], _ header: [[Inline]], _ rows: [[[Inline]]], _ context: Context) {
        let em = context.fontSize
        gap(top: 1.8 * em)
        let spacing = takeGap()
        let size = em * 0.84
        let line = floor(size * 1.55)
        let features = ["kern", "liga", "lnum", "tnum"]

        let table = NSTextTable()
        table.numberOfColumns = aligns.count
        table.collapsesBorders = false
        table.hidesEmptyCells = false
        table.layoutAlgorithm = .fixedLayoutAlgorithm
        table.setContentWidth(100, type: .percentageValueType)
        let widths = columnPercentages(header, rows, size: size, features: features, available: style.columnWidth - context.left - context.right)

        func cell(_ content: [Inline], row: Int, column: Int, isHeader: Bool, isLast: Bool) {
            let block = TableCellBlock(table: table, startingRow: row, rowSpan: 1, startingColumn: column, columnSpan: 1)
            // TextKit rounds block padding up to whole points, so the pair is chosen to add up to the CSS height.
            let padY = (isHeader ? 0.55 : 0.6) * size
            let rule: CGFloat = isLast ? 0 : isHeader ? 1.5 : 1
            let padTop = floor(padY)
            block.setValue(widths[column], type: .percentageValueType, for: .width)
            block.setWidth(padTop, type: .absoluteValueType, for: .padding, edge: .minY)
            block.setWidth(floor(2 * padY + rule) - padTop, type: .absoluteValueType, for: .padding, edge: .maxY)
            block.setWidth(0, type: .absoluteValueType, for: .padding, edge: .minX)
            block.setWidth(0.9 * size, type: .absoluteValueType, for: .padding, edge: .maxX)
            if !isLast {
                block.ruleHeight = rule
                block.ruleColor = isHeader ? style.theme.faint : style.theme.rule
            }
            let para = NSMutableParagraphStyle()
            para.textBlocks = [block]
            para.minimumLineHeight = line
            para.maximumLineHeight = line
            para.alignment = isHeader ? .natural : aligns[column] == .center ? .center : aligns[column] == .right ? .right : .natural
            if row == 0 { para.paragraphSpacingBefore = spacing }
            let r = run(size: size, weight: isHeader ? style.face.strongWeight : style.face.bodyWeight, italic: false, color: style.theme.ink, features: features)
            let text = NSMutableAttributedString()
            appendInlines(content, r, to: text)
            if text.length == 0 { text.append(NSAttributedString(string: "\u{200B}", attributes: [.font: r.font])) }
            finishParagraph(text, para, baseFont: r.font)
        }

        for (column, content) in header.enumerated() { cell(content, row: 0, column: column, isHeader: true, isLast: false) }
        for (index, row) in rows.enumerated() {
            for (column, content) in row.enumerated() {
                cell(content, row: index + 1, column: column, isHeader: false, isLast: index == rows.count - 1)
            }
        }
        pendingGap = 1.8 * em
    }

    // The browser's automatic table layout: every column can have its widest line, and any space left over is shared
    // in proportion. Without room for that, columns shrink towards their longest word.
    private func columnPercentages(_ header: [[Inline]], _ rows: [[[Inline]]], size: CGFloat, features: [String], available: CGFloat) -> [CGFloat] {
        let padding = 0.9 * size
        var widest = [CGFloat](repeating: 0, count: header.count)
        var longestWord = widest
        func measure(_ content: [Inline], weight: CGFloat, column: Int) {
            let r = run(size: size, weight: weight, italic: false, color: style.theme.ink, features: features)
            let text = NSMutableAttributedString()
            appendInlines(content, r, to: text)
            widest[column] = max(widest[column], ceil(text.size().width) + padding)
            let string = text.string as NSString
            string.enumerateSubstrings(in: NSRange(location: 0, length: string.length), options: .byWords) { _, range, _, _ in
                longestWord[column] = max(longestWord[column], ceil(text.attributedSubstring(from: range).size().width) + padding)
            }
        }
        for (column, content) in header.enumerated() { measure(content, weight: style.face.strongWeight, column: column) }
        for row in rows { for (column, content) in row.enumerated() { measure(content, weight: style.face.bodyWeight, column: column) } }
        let total = widest.reduce(0, +), least = longestWord.reduce(0, +)
        out.widestTable = max(out.widestTable, total)
        guard total > 0, available > 0 else { return widest.map { _ in 100 / CGFloat(max(header.count, 1)) } }
        if total <= available { return widest.map { $0 / total * 100 } }
        if least >= available { return longestWord.map { $0 / max(least, 1) * 100 } }
        let share = (available - least) / max(total - least, 1)
        return zip(longestWord, widest).map { ($0 + ($1 - $0) * share) / available * 100 }
    }

    // ---------- Collapsible sections ----------

    private func details(_ summary: [Inline], _ blocks: [Block], _ context: Context) {
        let em = context.fontSize
        gap(top: 1.4 * em)
        let index = detailsIndex
        detailsIndex += 1
        let open = style.openDetails.contains(index)
        let padY = 0.7 * em, padX = 1.1 * em
        let spacing = takeGap()
        let box = BlockBox(kind: .details, left: context.left, right: context.right, paddingTop: padY, paddingBottom: padY)
        let start = out.text.length
        out.boxes.append(box)

        var inner = context
        inner.left += padX + 1
        inner.right += padX + 1
        let markerWidth = em
        var head = inner
        head.left += markerWidth
        let para = paragraphStyle(head, lineHeight: floor(em * style.face.lineHeight), gap: spacing + padY + 1)
        var r = bodyRun(context)
        r.color = style.theme.inkSoft
        let text = NSMutableAttributedString()
        appendInlines(summary, r, to: text)
        let marker = ListMarker(kind: .disclosure(open: open), font: r.font, color: style.theme.inkSoft, right: inner.left + markerWidth * 0.62)
        text.addAttribute(.sumiMarker, value: marker, range: NSRange(location: 0, length: text.length))
        text.addAttribute(.sumiSummary, value: index, range: NSRange(location: 0, length: text.length))
        finishParagraph(text, para, baseFont: r.font)
        pendingGap = 0

        if open {
            pendingGap = 0.7 * em
            emit(blocks, inner)
            pendingGap = 0
        }
        box.range = NSRange(location: start, length: out.text.length - start)
        pendingGap = 1.4 * em
        pendingPadding = padY + 1
    }
}
