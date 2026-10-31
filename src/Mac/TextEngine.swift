// TextKit: paints what CSS would (code panels, chips, list markers) and scrolls code blocks sideways.
import AppKit

// Loads a document's images. Relative paths stay inside the document's folder; web images arrive when they arrive.
final class ImageStore {
    var folder: URL?
    var onLoad: (() -> Void)?
    private var known: [String: NSImage] = [:]
    private var waiting: [String: [ImageCell]] = [:]

    func reset() {
        known.removeAll()
        waiting.removeAll()
    }

    func load(_ src: String, into cell: ImageCell) {
        if let image = known[src] {
            cell.picture = image
            return
        }
        let lower = src.lowercased()
        if lower.hasPrefix("data:") {
            if let comma = src.firstIndex(of: ","), let data = Data(base64Encoded: String(src[src.index(after: comma)...])), let image = NSImage(data: data) {
                ImageStore.useNaturalSize(image)
                known[src] = image
                cell.picture = image
            }
        } else if lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("//") {
            fetch(src, into: cell)
        } else if isRelativeReference(src), let file = resolveInFolder(src, folder: folder), let image = NSImage(contentsOf: file) {
            ImageStore.useNaturalSize(image)
            known[src] = image
            cell.picture = image
        }
    }

    // One image pixel is one point, as in a browser, whatever resolution the file claims.
    private static func useNaturalSize(_ image: NSImage) {
        if let bitmap = image.representations.first as? NSBitmapImageRep, bitmap.pixelsWide > 0 {
            image.size = NSSize(width: bitmap.pixelsWide, height: bitmap.pixelsHigh)
        }
    }

    private func fetch(_ src: String, into cell: ImageCell) {
        if waiting[src] != nil {
            waiting[src]?.append(cell)
            return
        }
        guard let url = URL(string: src.hasPrefix("//") ? "https:" + src : src) else { return }
        waiting[src] = [cell]
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            let image = data.flatMap { NSImage(data: $0) }
            DispatchQueue.main.async {
                guard let self = self, let cells = self.waiting.removeValue(forKey: src), let image = image else { return }
                ImageStore.useNaturalSize(image)
                self.known[src] = image
                cells.forEach { $0.picture = image }
                self.onLoad?()
            }
        }.resume()
    }
}

func isRelativeReference(_ href: String) -> Bool {
    guard !href.isEmpty, !href.hasPrefix("#"), !href.hasPrefix("//") else { return false }
    guard let colon = href.firstIndex(of: ":") else { return true }
    let scheme = href[..<colon]
    guard let first = scheme.first, first.isASCII, first.isLetter else { return true }
    return !scheme.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "+.-".contains($0)) }
}

// Resolved the way a browser resolves it against the document's folder, so ../ can't climb out of that folder.
func resolveInFolder(_ href: String, folder: URL?) -> URL? {
    guard let folder = folder else { return nil }
    let cleaned = href.replacingOccurrences(of: "\\", with: "/")
    var allowed = CharacterSet.urlPathAllowed
    allowed.insert(charactersIn: "%?#")
    guard let encoded = cleaned.addingPercentEncoding(withAllowedCharacters: allowed),
          let url = URL(string: encoded, relativeTo: URL(string: "sumi://doc/")) else { return nil }
    return folder.appendingPathComponent(url.path).standardizedFileURL
}

final class ReaderLayoutManager: NSLayoutManager, NSLayoutManagerDelegate {
    var boxes: [BlockBox] = []
    var theme = Theme.light
    var hoveredLink: NSRange?
    var linkFade: CGFloat = 0
    var columnWidth: CGFloat = 0

    override init() {
        super.init()
        delegate = self
        allowsNonContiguousLayout = true
        usesFontLeading = false
    }
    required init?(coder: NSCoder) { fatalError() }

    // Places each line's baseline as CSS does, with the spare line height shared evenly above and below the letters.
    func layoutManager(_ layoutManager: NSLayoutManager, shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<NSRect>,
                       lineFragmentUsedRect: UnsafeMutablePointer<NSRect>, baselineOffset: UnsafeMutablePointer<CGFloat>,
                       in textContainer: NSTextContainer, forGlyphRange glyphRange: NSRange) -> Bool {
        guard let storage = textStorage, glyphRange.length > 0 else { return false }
        let index = characterIndexForGlyph(at: glyphRange.location)
        guard index < storage.length else { return false }
        var changed = false
        if let font = storage.attribute(.sumiBaseFont, at: index, effectiveRange: nil) as? NSFont {
            let ascent = font.ascender, descent = -font.descender
            let used = lineFragmentUsedRect.pointee
            let spacing = used.minY - lineFragmentRect.pointee.minY
            let lineHeight = used.height
            baselineOffset.pointee = spacing + ((lineHeight - (ascent + descent)) / 2 + ascent).rounded()
            changed = true
        }
        if let hang = storage.attribute(.sumiHang, at: index, effectiveRange: nil) as? CGFloat, hang != 0 {
            let starts = index == 0 || (storage.string as NSString).character(at: index - 1) == 10
            if starts {
                lineFragmentRect.pointee.origin.x -= hang
                lineFragmentUsedRect.pointee.origin.x -= hang
                changed = true
            }
        }
        return changed
    }

    // ---------- Geometry ----------

    func rect(of box: BlockBox) -> NSRect? {
        guard let container = textContainers.first, box.range.length > 0 else { return nil }
        let first = glyphIndexForCharacter(at: box.range.location)
        let last = glyphIndexForCharacter(at: NSMaxRange(box.range) - 1)
        guard first < numberOfGlyphs, last < numberOfGlyphs else { return nil }
        let top = lineFragmentUsedRect(forGlyphAt: first, effectiveRange: nil).minY - box.paddingTop
        let bottom = lineFragmentUsedRect(forGlyphAt: last, effectiveRange: nil).maxY + box.paddingBottom
        let width = columnWidth > 0 ? columnWidth : container.size.width
        return NSRect(x: box.left, y: top, width: width - box.left - box.right, height: bottom - top)
    }

    func codeBox(forCharacter index: Int) -> BlockBox? {
        boxes.first { $0.kind == .code && NSLocationInRange(index, $0.range) }
    }

    // ---------- Painting ----------

    private func characterRange(_ glyphs: NSRange) -> NSRange { characterRange(forGlyphRange: glyphs, actualGlyphRange: nil) }

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.setShouldSmoothFonts(false)
        let chars = characterRange(glyphsToShow)
        for box in boxes where NSIntersectionRange(box.range, chars).length > 0 || NSLocationInRange(chars.location, box.range) {
            draw(box, at: origin)
        }
        split(glyphsToShow, origin) { range, point in
            super.drawBackground(forGlyphRange: range, at: point)
        }
        drawChips(chars, origin)
        drawMarkers(chars, origin)
    }

    override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        NSGraphicsContext.current?.cgContext.setShouldSmoothFonts(false)
        split(glyphsToShow, origin) { range, point in
            super.drawGlyphs(forGlyphRange: range, at: point)
        }
        // A code block's thin scrollbar, while it's in use.
        let chars = characterRange(glyphsToShow)
        for box in boxes where box.kind == .code && box.thumbAlpha > 0 && NSIntersectionRange(box.range, chars).length > 0 {
            guard let frame = rect(of: box), box.contentWidth > frame.width else { continue }
            let track = frame.width - 8
            let width = max(24, track * frame.width / box.contentWidth)
            let x = frame.minX + 4 + (track - width) * box.scrollX / (box.contentWidth - frame.width)
            theme.faint.withOpacity(box.thumbAlpha).setFill()
            let thumb = NSRect(x: x + origin.x, y: frame.maxY + origin.y - 6, width: width, height: 4)
            NSBezierPath(roundedRect: thumb, xRadius: 2, yRadius: 2).fill()
        }
    }

    // Runs `body` for the plain text and for each code block, which is clipped to its panel and shifted by its scroll.
    private func split(_ glyphs: NSRange, _ origin: NSPoint, _ body: (NSRange, NSPoint) -> Void) {
        var cursor = glyphs.location
        let end = NSMaxRange(glyphs)
        for box in boxes where box.kind == .code {
            let range = glyphRange(forCharacterRange: box.range, actualCharacterRange: nil)
            let shared = NSIntersectionRange(range, NSRange(location: cursor, length: max(0, end - cursor)))
            guard shared.length > 0 else { continue }
            if shared.location > cursor { body(NSRange(location: cursor, length: shared.location - cursor), origin) }
            if let frame = rect(of: box) {
                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(rect: frame.offsetBy(dx: origin.x, dy: origin.y)).addClip()
                body(shared, NSPoint(x: origin.x - box.scrollX, y: origin.y))
                NSGraphicsContext.restoreGraphicsState()
            } else {
                body(shared, origin)
            }
            cursor = NSMaxRange(shared)
        }
        if cursor < end { body(NSRange(location: cursor, length: end - cursor), origin) }
    }

    override func fillBackgroundRectArray(_ rectArray: UnsafePointer<NSRect>, count rectCount: Int, forCharacterRange charRange: NSRange, color: NSColor) {
        // The selection colour is translucent, so it has to blend rather than replace.
        color.setFill()
        for i in 0..<rectCount { rectArray[i].fill(using: .sourceOver) }
    }

    private func draw(_ box: BlockBox, at origin: NSPoint) {
        guard let local = rect(of: box) else { return }
        let frame = local.offsetBy(dx: origin.x, dy: origin.y)
        switch box.kind {
        case .code:
            theme.codeBg.setFill()
            NSBezierPath(roundedRect: frame, xRadius: 8, yRadius: 8).fill()
        case .quote:
            theme.faint.setFill()
            NSRect(x: frame.minX, y: frame.minY, width: 2, height: frame.height).fill()
        case .details:
            theme.rule.setStroke()
            let path = NSBezierPath(roundedRect: frame.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)
            path.lineWidth = 1
            path.stroke()
        case .rule:
            theme.faint.setFill()
            let x = frame.minX + (frame.width - box.ruleWidth) / 2
            NSRect(x: x, y: frame.minY, width: box.ruleWidth, height: 1).fill()
        }
    }

    private func drawChips(_ chars: NSRange, _ origin: NSPoint) {
        guard let storage = textStorage, let container = textContainers.first else { return }
        storage.enumerateAttribute(.sumiChip, in: chars, options: []) { value, range, _ in
            guard let chip = value as? ChipStyle, let font = storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont else { return }
            let glyphs = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let noSelection = NSRange(location: NSNotFound, length: 0)
            enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: noSelection, in: container) { rect, _ in
                let line = self.lineFragmentRect(forGlyphAt: self.glyphIndex(for: NSPoint(x: rect.midX, y: rect.midY), in: container), effectiveRange: nil)
                let glyph = self.glyphIndex(for: NSPoint(x: rect.midX, y: rect.midY), in: container)
                let baseline = line.minY + self.location(forGlyphAt: glyph).y
                let top = baseline - font.ascender - chip.paddingY
                let height = font.ascender - font.descender + 2 * chip.paddingY + (chip.borderBottom > 1 ? chip.borderBottom - 1 : 0)
                let frame = NSRect(x: rect.minX - chip.paddingX + origin.x, y: top + origin.y, width: rect.width + chip.paddingX, height: height)
                if let fill = chip.fill {
                    fill.setFill()
                    let path = NSBezierPath(roundedRect: frame, xRadius: chip.radius, yRadius: chip.radius)
                    path.fill()
                }
                if let border = chip.border {
                    border.setStroke()
                    let path = NSBezierPath(roundedRect: frame.insetBy(dx: 0.5, dy: 0.5), xRadius: chip.radius, yRadius: chip.radius)
                    path.lineWidth = 1
                    path.stroke()
                    if chip.borderBottom > 1 {
                        NSGraphicsContext.saveGraphicsState()
                        NSRect(x: frame.minX, y: frame.maxY - chip.borderBottom, width: frame.width, height: chip.borderBottom).clip()
                        let thick = NSBezierPath(roundedRect: frame.insetBy(dx: 0.5, dy: 0.5).offsetBy(dx: 0, dy: -0.5), xRadius: chip.radius, yRadius: chip.radius)
                        thick.lineWidth = 1
                        thick.stroke()
                        NSGraphicsContext.restoreGraphicsState()
                    }
                }
            }
        }
    }

    private func drawMarkers(_ chars: NSRange, _ origin: NSPoint) {
        guard let storage = textStorage else { return }
        storage.enumerateAttribute(.sumiMarker, in: chars, options: []) { value, range, _ in
            guard let marker = value as? ListMarker else { return }
            var whole = NSRange()
            _ = storage.attribute(.sumiMarker, at: range.location, longestEffectiveRange: &whole, in: NSRange(location: 0, length: storage.length))
            let glyph = glyphIndexForCharacter(at: whole.location)
            let line = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let baseline = line.minY + location(forGlyphAt: glyph).y + origin.y
            let em = marker.font.pointSize
            let right = marker.right + origin.x
            marker.color.set()
            switch marker.kind {
            case .disc:
                NSBezierPath(ovalIn: NSRect(x: right - 0.72 * em, y: baseline - 0.42 * em, width: 0.35 * em, height: 0.35 * em)).fill()
            case .circle:
                let path = NSBezierPath(ovalIn: NSRect(x: right - 0.72 * em, y: baseline - 0.42 * em, width: 0.35 * em, height: 0.35 * em).insetBy(dx: 0.5, dy: 0.5))
                path.lineWidth = 1
                path.stroke()
            case .square:
                NSRect(x: right - 0.72 * em, y: baseline - 0.42 * em, width: 0.35 * em, height: 0.35 * em).fill()
            case .number(let text):
                let label = NSAttributedString(string: text, attributes: [.font: marker.font, .foregroundColor: marker.color])
                label.draw(at: NSPoint(x: right - label.size().width - 0.54 * em, y: baseline - marker.font.ascender))
            case .disclosure(let open):
                let path = NSBezierPath()
                let x = right - 0.62 * em + 2, y = baseline - 0.33 * em
                if open {
                    path.move(to: NSPoint(x: x, y: y - 0.3 * em))
                    path.line(to: NSPoint(x: x + 0.62 * em, y: y - 0.3 * em))
                    path.line(to: NSPoint(x: x + 0.31 * em, y: y + 0.3 * em))
                } else {
                    path.move(to: NSPoint(x: x, y: y - 0.33 * em))
                    path.line(to: NSPoint(x: x + 0.6 * em, y: y))
                    path.line(to: NSPoint(x: x, y: y + 0.33 * em))
                }
                path.close()
                path.fill()
            }
        }
    }

    // A one-pixel underline set well below the baseline, faint until the pointer is on the link.
    override func drawUnderline(forGlyphRange glyphRange: NSRange, underlineType: NSUnderlineStyle, baselineOffset: CGFloat,
                                lineFragmentRect: NSRect, lineFragmentGlyphRange: NSRange, containerOrigin: NSPoint) {
        guard let storage = textStorage, let container = textContainers.first, glyphRange.length > 0 else { return }
        let index = characterIndexForGlyph(at: glyphRange.location)
        let font = storage.attribute(.font, at: index, effectiveRange: nil) as? NSFont
        let color = storage.attribute(.foregroundColor, at: index, effectiveRange: nil) as? NSColor ?? theme.ink
        var alpha: CGFloat = 1
        if storage.attribute(.sumiLink, at: index, effectiveRange: nil) != nil {
            alpha = 0.35
            if let hovered = hoveredLink, NSLocationInRange(index, hovered) { alpha = 0.35 + 0.65 * linkFade }
        }
        let bounds = boundingRect(forGlyphRange: glyphRange, in: container)
        let baseline = lineFragmentRect.minY + location(forGlyphAt: glyphRange.location).y
        let y = (baseline + 0.2 * (font?.pointSize ?? 16) + containerOrigin.y).rounded()
        color.withOpacity(alpha).setFill()
        NSRect(x: bounds.minX + containerOrigin.x, y: y, width: bounds.width, height: 1).fill(using: .sourceOver)
    }

    // ---------- Sideways scrolling ----------

    func measure(_ box: BlockBox) {
        guard let storage = textStorage, box.range.length > 0 else { return }
        var widest: CGFloat = 0
        let string = storage.string as NSString
        string.enumerateSubstrings(in: box.range, options: [.byLines, .substringNotRequired]) { _, range, _, _ in
            guard range.length > 0 else { return }
            widest = max(widest, storage.attributedSubstring(from: range).size().width)
        }
        let padding = box.fontSize * 1.35 * 2
        box.contentWidth = widest + padding
    }
}

// The document itself. A real NSTextView, so selection, Look Up, Services and VoiceOver are the system's own.
final class ReaderTextView: NSTextView {
    weak var reader: Reader?
    var columnLeft: CGFloat = 0
    var topInset: CGFloat = 92
    private let copyButton = CopyButton()
    private var hoveredBox: BlockBox?
    private var thumbTimers: [ObjectIdentifier: Timer] = [:]

    private var manager: ReaderLayoutManager { layoutManager as! ReaderLayoutManager }

    override var textContainerOrigin: NSPoint { NSPoint(x: columnLeft, y: topInset) }
    override var isFlipped: Bool { true }

    func configure() {
        isEditable = false
        isSelectable = true
        isRichText = false
        importsGraphics = false
        drawsBackground = false
        usesFontPanel = false
        usesRuler = false
        allowsUndo = false
        isAutomaticLinkDetectionEnabled = false
        displaysLinkToolTips = false
        linkTextAttributes = [:]
        isVerticallyResizable = true
        isHorizontallyResizable = false
        autoresizingMask = [.width]
        textContainerInset = .zero
        unregisterDraggedTypes() // files dropped on the window are the window's business
        copyButton.isHidden = true
        addSubview(copyButton)
    }

    // ---------- Pointer ----------

    override func resetCursorRects() {}
    override func cursorUpdate(with event: NSEvent) {}
    override func mouseMoved(with event: NSEvent) {}
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func containerPoint(_ point: NSPoint) -> NSPoint {
        var p = NSPoint(x: point.x - columnLeft, y: point.y - topInset)
        if let box = codeBox(atContainerPoint: p) { p.x += box.scrollX }
        return p
    }

    func codeBox(atContainerPoint p: NSPoint) -> BlockBox? {
        manager.boxes.first { box in
            guard box.kind == .code, let frame = manager.rect(of: box) else { return false }
            return frame.contains(p)
        }
    }

    private func glyph(at point: NSPoint) -> Int? {
        guard let container = textContainer, manager.numberOfGlyphs > 0 else { return nil }
        return manager.glyphIndex(for: containerPoint(point), in: container)
    }

    func characterIndex(at point: NSPoint) -> Int {
        guard let container = textContainer, let storage = textStorage, storage.length > 0 else { return 0 }
        var fraction: CGFloat = 0
        let p = containerPoint(point)
        let glyph = manager.glyphIndex(for: p, in: container, fractionOfDistanceThroughGlyph: &fraction)
        let index = manager.characterIndexForGlyph(at: glyph)
        return min(fraction > 0.5 ? index + 1 : index, storage.length)
    }

    // The character actually under the point, if there is one.
    private func characterUnder(_ point: NSPoint) -> (index: Int, box: NSRect)? {
        guard let container = textContainer, let storage = textStorage, storage.length > 0, let glyph = glyph(at: point) else { return nil }
        let p = containerPoint(point)
        let bounds = manager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
        guard p.x >= bounds.minX - 2, p.x <= bounds.maxX + 2, p.y >= bounds.minY - 2, p.y <= bounds.maxY + 2 else { return nil }
        let index = manager.characterIndexForGlyph(at: glyph)
        return (index, bounds)
    }

    func link(at point: NSPoint) -> (href: String, range: NSRange)? {
        guard let storage = textStorage, let (index, _) = characterUnder(point) else { return nil }
        var range = NSRange()
        guard let href = storage.attribute(.sumiLink, at: index, effectiveRange: &range) as? String else { return nil }
        return (href, range)
    }

    func summary(at point: NSPoint) -> Int? {
        guard let storage = textStorage, let (index, _) = characterUnder(point) else {
            // The disclosure triangle counts as part of the summary.
            guard let storage = textStorage, let glyph = glyph(at: point) else { return nil }
            let index = manager.characterIndexForGlyph(at: glyph)
            guard index < storage.length, let details = storage.attribute(.sumiSummary, at: index, effectiveRange: nil) as? Int else { return nil }
            let line = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let p = containerPoint(point)
            return line.contains(p) ? details : nil
        }
        return storage.attribute(.sumiSummary, at: index, effectiveRange: nil) as? Int
    }

    enum PointerShape { case plain, clickable, text(centerY: CGFloat, height: CGFloat) }

    func pointerShape(at point: NSPoint, selecting: Bool) -> PointerShape {
        if !selecting, link(at: point) != nil || summary(at: point) != nil { return .clickable }
        guard let (index, _) = characterUnder(point), let storage = textStorage, index < storage.length else { return .plain }
        let scalar = (storage.string as NSString).character(at: index)
        if scalar == 10 || scalar == 0x2028 || scalar == 0xFFFC { return .plain }
        guard let font = storage.attribute(.font, at: index, effectiveRange: nil) as? NSFont else { return .plain }
        // Snap to the middle of the line, sized to that line's letters.
        let glyph = manager.glyphIndexForCharacter(at: index)
        let line = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let baseline = line.minY + manager.location(forGlyphAt: glyph).y + topInset
        let height = font.ascender - font.descender
        return .text(centerY: baseline - font.ascender + height / 2, height: height)
    }

    // Shows the copy button on the code block under the pointer.
    func updateHover(at point: NSPoint?) {
        var box: BlockBox?
        if let point = point { box = codeBox(atContainerPoint: NSPoint(x: point.x - columnLeft, y: point.y - topInset)) }
        hoveredBox = box
        guard let found = box, let frame = manager.rect(of: found) else {
            copyButton.setVisible(false)
            return
        }
        copyButton.configure(box: found, theme: manager.theme)
        let size = copyButton.fittingSize
        let inset = 0.6 * found.fontSize * 0.78
        copyButton.frame = NSRect(x: frame.maxX + columnLeft - inset - size.width, y: frame.minY + topInset + inset, width: size.width, height: size.height)
        copyButton.setVisible(true)
    }

    // ---------- Selecting ----------

    private var anchor = 0
    private var granularity = NSSelectionGranularity.selectByCharacter
    private var downPoint = NSPoint.zero
    private var clickTarget: (() -> Void)?
    private var maybeDragging = false
    private(set) var isSelecting = false

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        downPoint = point
        clickTarget = nil
        maybeDragging = false

        if event.clickCount == 1, !event.modifierFlags.contains(.shift) {
            if let found = link(at: point) {
                clickTarget = { [weak self] in self?.reader?.follow(found.href) }
            } else if let details = summary(at: point) {
                clickTarget = { [weak self] in self?.reader?.toggleDetails(details) }
            }
        }

        let index = characterIndex(at: point)
        let selected = selectedRange()
        if event.clickCount == 1, selected.length > 0, NSLocationInRange(index, selected), !event.modifierFlags.contains(.shift) {
            maybeDragging = true
            return
        }
        isSelecting = true
        switch event.clickCount {
        case 1: granularity = .selectByCharacter
        case 2: granularity = .selectByWord
        default: granularity = .selectByParagraph
        }
        if event.modifierFlags.contains(.shift), selected.length >= 0 {
            anchor = selected.location
            extendSelection(to: index)
        } else {
            anchor = index
            let proposed = NSRange(location: index, length: 0)
            setSelectedRange(selectionRange(forProposedRange: proposed, granularity: granularity))
        }
        needsDisplay = true
    }

    private func extendSelection(to index: Int) {
        let low = min(anchor, index), high = max(anchor, index)
        let proposed = NSRange(location: low, length: high - low)
        setSelectedRange(selectionRange(forProposedRange: proposed, granularity: granularity))
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if hypot(point.x - downPoint.x, point.y - downPoint.y) > 3 { clickTarget = nil }
        if maybeDragging {
            if hypot(point.x - downPoint.x, point.y - downPoint.y) > 4 {
                maybeDragging = false
                _ = dragSelection(with: event, offset: .zero, slideBack: true)
            }
            return
        }
        guard isSelecting else { return }
        autoscroll(with: event)
        scrollCodeBlockWhileSelecting(point)
        extendSelection(to: characterIndex(at: convert(event.locationInWindow, from: nil)))
    }

    private func scrollCodeBlockWhileSelecting(_ point: NSPoint) {
        let p = NSPoint(x: point.x - columnLeft, y: point.y - topInset)
        guard let box = codeBox(atContainerPoint: p), let frame = manager.rect(of: box) else { return }
        if p.x > frame.maxX - 16 { scroll(box, by: 12) } else if p.x < frame.minX + 16 { scroll(box, by: -12) }
    }

    override func mouseUp(with event: NSEvent) {
        if let click = clickTarget {
            clickTarget = nil
            click()
        } else if maybeDragging, selectedRange().length > 0 {
            setSelectedRange(NSRange(location: characterIndex(at: downPoint), length: 0))
            needsDisplay = true
        }
        maybeDragging = false
        isSelecting = false
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        if manager.boxes.contains(where: { $0.scrollX != 0 }) { needsDisplay = true }
    }

    // Plain text only: the document's fonts aren't installed anywhere else, and line breaks read better than rich pasting.
    override var writablePasteboardTypes: [NSPasteboard.PasteboardType] { [.string] }
    override func writeSelection(to pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        guard type == .string, let storage = textStorage else { return false }
        let pieces = selectedRanges.map { (storage.string as NSString).substring(with: $0.rangeValue) }
        let text = pieces.joined(separator: "\n")
            .replacingOccurrences(of: "\u{2028}", with: "\n")
            .replacingOccurrences(of: "\u{FFFC}", with: "")
            .replacingOccurrences(of: "\u{200B}", with: "")
        pboard.setString(text, forType: .string)
        return true
    }

    // ---------- Keys and wheel ----------

    override func keyDown(with event: NSEvent) {
        guard let reader = reader, event.modifierFlags.intersection([.command, .control, .option]).isEmpty else {
            super.keyDown(with: event)
            return
        }
        let shift = event.modifierFlags.contains(.shift)
        switch event.keyCode {
        case 49: reader.scrollPage(shift ? -1 : 1)                  // space
        case 116: reader.scrollPage(-1)                             // page up
        case 121: reader.scrollPage(1)                              // page down
        case 115: reader.scrollToEnd(top: true)                     // home
        case 119: reader.scrollToEnd(top: false)                    // end
        case 125: reader.scrollBy(40)                               // down arrow
        case 126: reader.scrollBy(-40)                              // up arrow
        case 53: reader.escape()                                    // escape
        default: super.keyDown(with: event)
        }
    }

    private var pinch: CGFloat = 0

    override func magnify(with event: NSEvent) {
        pinch += event.magnification
        if abs(pinch) > 0.12 {
            reader?.stepSize(pinch > 0 ? 1 : -1)
            pinch = 0
        }
    }

    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            if event.scrollingDeltaY != 0 { reader?.stepSize(event.scrollingDeltaY > 0 ? 1 : -1) }
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        let p = NSPoint(x: point.x - columnLeft, y: point.y - topInset)
        if abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY), let box = codeBox(atContainerPoint: p) {
            if box.contentWidth == 0 { manager.measure(box) }
            let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 12
            scroll(box, by: -event.scrollingDeltaX * scale)
            return
        }
        super.scrollWheel(with: event)
    }

    func scroll(_ box: BlockBox, by delta: CGFloat) {
        guard let frame = manager.rect(of: box) else { return }
        if box.contentWidth == 0 { manager.measure(box) }
        let limit = max(0, box.contentWidth - frame.width)
        let next = min(max(box.scrollX + delta, 0), limit)
        guard next != box.scrollX || limit > 0 else { return }
        box.scrollX = next
        box.thumbAlpha = 1
        setNeedsDisplay(frame.offsetBy(dx: columnLeft, dy: topInset))
        let id = ObjectIdentifier(box)
        thumbTimers[id]?.invalidate()
        thumbTimers[id] = Timer.scheduledTimer(withTimeInterval: 0.9, repeats: false) { [weak self, weak box] _ in
            guard let self = self, let box = box else { return }
            box.thumbAlpha = 0
            self.setNeedsDisplay(frame.offsetBy(dx: self.columnLeft, dy: self.topInset))
        }
    }

    // Find reveals a match even when it's scrolled out of sight inside a code block.
    func reveal(_ range: NSRange) {
        if let box = manager.codeBox(forCharacter: range.location), let frame = manager.rect(of: box), let container = textContainer {
            if box.contentWidth == 0 { manager.measure(box) }
            let glyphs = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let found = manager.boundingRect(forGlyphRange: glyphs, in: container)
            if found.maxX - box.scrollX > frame.maxX - 20 || found.minX - box.scrollX < frame.minX + 20 {
                box.scrollX = min(max(found.midX - frame.midX, 0), max(0, box.contentWidth - frame.width))
                needsDisplay = true
            }
        }
        scrollRangeToVisible(range)
        showFindIndicator(for: range)
    }
}

// "Copy", then "Copied" for a moment, in the corner of a code block.
final class CopyButton: ChromeControl {
    private var box: BlockBox?
    private var theme = Theme.light
    private var label = "Copy"
    private var size: CGFloat = 12

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer?.opacity = 0
        onClick = { [weak self] in self?.copyCode() }
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(box: BlockBox, theme: Theme) {
        if self.box !== box { label = "Copy" }
        self.box = box
        self.theme = theme
        size = (box.fontSize * 0.78).rounded()
        needsDisplay = true
    }

    private var attributed: NSAttributedString {
        NSAttributedString(string: label, attributes: [.font: Fonts.ui(size), .foregroundColor: theme.inkSoft])
    }

    override var fittingSize: NSSize {
        let text = attributed.size()
        return NSSize(width: ceil(text.width + 1.3 * size + 2), height: ceil(text.height + 0.4 * size + 2))
    }

    func setVisible(_ visible: Bool) {
        if visible { isHidden = false }
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = layer?.presentation()?.opacity ?? layer?.opacity
        animation.toValue = visible ? 1 : 0
        animation.duration = Motion.duration(0.15)
        layer?.opacity = visible ? 1 : 0
        layer?.add(animation, forKey: "opacity")
    }

    private func copyCode() {
        guard let box = box else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(box.code, forType: .string)
        label = "Copied"
        needsDisplay = true
        frame.size = fittingSize
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.label = "Copy"
            self?.needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let frame = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: frame, xRadius: 5, yRadius: 5)
        theme.popBg.setFill()
        path.fill()
        theme.edge.setStroke()
        path.lineWidth = 1
        path.stroke()
        let text = attributed
        text.draw(at: NSPoint(x: (bounds.width - text.size().width) / 2, y: (bounds.height - text.size().height) / 2))
    }
}
