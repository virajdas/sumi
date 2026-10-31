// A small GitHub-flavoured Markdown parser, covering what marked does for the Windows reader.
// Raw HTML is reduced to the safe subset the reader can show; scripts and the like are dropped.
import Foundation

indirect enum Inline {
    case text(String)
    case code(String)
    case lineBreak
    case emphasis([Inline])
    case strong([Inline])
    case strike([Inline])
    case link(href: String, children: [Inline])
    case image(src: String, alt: String)
    case tag(String, [Inline]) // kbd, mark, sup, sub, u, small
    // Only while parsing: raw HTML tags, folded into .tag and friends at the end.
    case open(String, [String: String])
    case close(String)
}

enum Alignment { case left, center, right }

struct ListItem {
    var task: Bool? // nil for an ordinary item, otherwise whether it's ticked
    var blocks: [Block]
}

indirect enum Block {
    case heading(Int, [Inline])
    case paragraph([Inline])
    case code(String)
    case quote([Block])
    case list(ordered: Bool, start: Int, loose: Bool, items: [ListItem])
    case rule
    case table(aligns: [Alignment], header: [[Inline]], rows: [[[Inline]]])
    case details(summary: [Inline], blocks: [Block])
}

func plainText(_ inlines: [Inline]) -> String {
    inlines.map { inline -> String in
        switch inline {
        case .text(let s), .code(let s): return s
        case .emphasis(let c), .strong(let c), .strike(let c), .tag(_, let c), .link(_, let c): return plainText(c)
        case .lineBreak: return " "
        default: return ""
        }
    }.joined()
}

struct Markdown {
    private var references: [String: String] = [:]

    static func parse(_ source: String) -> [Block] {
        var text = source.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        var parser = Markdown()
        let lines = parser.collectReferences(text.components(separatedBy: "\n"))
        return parser.blocks(lines)
    }

    // ---------- Link reference definitions ----------

    private mutating func collectReferences(_ lines: [String]) -> [String] {
        var out: [String] = []
        out.reserveCapacity(lines.count)
        var fence: String?
        for line in lines {
            let info = Line(line)
            if let open = fence {
                if info.content.hasPrefix(open) { fence = nil }
                out.append(line)
                continue
            }
            if info.indent < 4, info.content.hasPrefix("```") || info.content.hasPrefix("~~~") {
                fence = String(info.content.prefix(3))
                out.append(line)
                continue
            }
            if info.indent < 4, info.content.hasPrefix("["), let definition = Markdown.definition(info.content) {
                let key = Markdown.normalize(definition.label)
                if references[key] == nil { references[key] = definition.url }
                continue
            }
            out.append(line)
        }
        return out
    }

    private static func definition(_ line: String) -> (label: String, url: String)? {
        guard let close = line.range(of: "]:"), !line.hasPrefix("[^") else { return nil }
        let label = String(line[line.index(after: line.startIndex)..<close.lowerBound])
        guard !label.isEmpty, !label.contains("]") else { return nil }
        let rest = line[close.upperBound...].trimmingCharacters(in: .whitespaces)
        guard !rest.isEmpty else { return nil }
        var url: String
        if rest.hasPrefix("<"), let end = rest.firstIndex(of: ">") {
            url = String(rest[rest.index(after: rest.startIndex)..<end])
        } else {
            url = String(rest.prefix { !$0.isWhitespace })
        }
        url = unescape(url)
        return (label, url)
    }

    private static func normalize(_ label: String) -> String {
        label.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
    }

    // ---------- Blocks ----------

    private struct Line {
        let raw: String
        let indent: Int
        let content: String
        var isBlank: Bool { content.isEmpty }

        init(_ raw: String) {
            self.raw = raw
            var column = 0
            var index = raw.startIndex
            loop: while index < raw.endIndex {
                switch raw[index] {
                case " ": column += 1
                case "\t": column += 4 - column % 4
                default: break loop
                }
                index = raw.index(after: index)
            }
            indent = column
            content = String(raw[index...]).trimmingTrailingWhitespace()
        }

        // The line with up to `count` columns of indentation taken off.
        func removingIndent(_ count: Int) -> String {
            var column = 0
            var index = raw.startIndex
            while index < raw.endIndex, column < count {
                if raw[index] == " " { column += 1 } else if raw[index] == "\t" {
                    let width = 4 - column % 4
                    if column + width > count {
                        return String(repeating: " ", count: column + width - count) + raw[raw.index(after: index)...]
                    }
                    column += width
                } else { break }
                index = raw.index(after: index)
            }
            return String(raw[index...])
        }
    }

    private struct Marker {
        let ordered: Bool
        let delimiter: Character
        let start: Int
        let contentIndent: Int
        let isEmpty: Bool
    }

    private static func listMarker(_ line: Line) -> Marker? {
        guard line.indent < 4, let first = line.content.first else { return nil }
        let chars = Array(line.content)
        var width: Int
        var ordered = false
        var delimiter = first
        var start = 1
        if first == "-" || first == "*" || first == "+" {
            width = 1
        } else if first.isASCII, first.isNumber {
            var digits = 0
            while digits < chars.count, digits < 10, chars[digits].isASCII, chars[digits].isNumber { digits += 1 }
            guard digits <= 9, digits < chars.count, chars[digits] == "." || chars[digits] == ")" else { return nil }
            ordered = true
            delimiter = chars[digits]
            start = Int(String(chars[0..<digits])) ?? 1
            width = digits + 1
        } else {
            return nil
        }
        if width == chars.count { return Marker(ordered: ordered, delimiter: delimiter, start: start, contentIndent: line.indent + width + 1, isEmpty: true) }
        guard chars[width] == " " || chars[width] == "\t" else { return nil }
        var spaces = 0
        var i = width
        while i < chars.count, chars[i] == " " || chars[i] == "\t" {
            spaces += chars[i] == "\t" ? 4 - (line.indent + width + spaces) % 4 : 1
            i += 1
        }
        if spaces > 4 { spaces = 1 }
        return Marker(ordered: ordered, delimiter: delimiter, start: start, contentIndent: line.indent + width + spaces, isEmpty: false)
    }

    private static func isRule(_ line: Line) -> Bool {
        guard line.indent < 4, let first = line.content.first, first == "-" || first == "*" || first == "_" else { return false }
        var count = 0
        for c in line.content {
            if c == first { count += 1 } else if c != " " && c != "\t" { return false }
        }
        return count >= 3
    }

    private static func heading(_ line: Line) -> (Int, String)? {
        guard line.indent < 4, line.content.hasPrefix("#") else { return nil }
        let level = line.content.prefix { $0 == "#" }.count
        guard level <= 6 else { return nil }
        let rest = line.content.dropFirst(level)
        guard rest.isEmpty || rest.first == " " || rest.first == "\t" else { return nil }
        var text = rest.trimmingCharacters(in: .whitespaces)
        // A closing run of #s is decoration, unless it's glued to a word.
        let hashes = text.reversed().prefix { $0 == "#" }.count
        if hashes > 0 {
            let body = text.dropLast(hashes)
            if body.isEmpty || body.last == " " || body.last == "\t" { text = body.trimmingCharacters(in: .whitespaces) }
        }
        return (level, text)
    }

    private static func fence(_ line: Line) -> (Character, Int)? {
        guard line.indent < 4, let first = line.content.first, first == "`" || first == "~" else { return nil }
        let count = line.content.prefix { $0 == first }.count
        guard count >= 3 else { return nil }
        if first == "`", line.content.dropFirst(count).contains("`") { return nil }
        return (first, count)
    }

    private static let blockTags: Set<String> = [
        "address", "article", "aside", "base", "basefont", "blockquote", "body", "caption", "center", "col", "colgroup", "dd",
        "details", "dialog", "dir", "div", "dl", "dt", "fieldset", "figcaption", "figure", "footer", "form", "frame", "frameset",
        "h1", "h2", "h3", "h4", "h5", "h6", "head", "header", "hr", "html", "iframe", "legend", "li", "link", "main", "menu",
        "menuitem", "meta", "nav", "noframes", "ol", "optgroup", "option", "p", "param", "section", "source", "summary",
        "table", "tbody", "td", "tfoot", "th", "thead", "title", "tr", "track", "ul", "pre", "script", "style", "textarea",
    ]

    private static func htmlTagName(_ content: String) -> String? {
        guard content.hasPrefix("<") else { return nil }
        var rest = content.dropFirst()
        if rest.first == "/" { rest = rest.dropFirst() }
        let name = rest.prefix { $0.isLetter || $0.isNumber }
        guard !name.isEmpty else { return nil }
        let after = rest.dropFirst(name.count).first
        guard after == nil || after == " " || after == "\t" || after == ">" || after == "/" else { return nil }
        return name.lowercased()
    }

    private static func startsHTMLBlock(_ line: Line) -> Bool {
        guard line.indent < 4, line.content.hasPrefix("<") else { return false }
        if line.content.hasPrefix("<!--") { return true }
        guard let name = htmlTagName(line.content) else { return false }
        return blockTags.contains(name)
    }

    // Would this line end a paragraph?
    private static func interruptsParagraph(_ line: Line) -> Bool {
        if isRule(line) || heading(line) != nil || fence(line) != nil || startsHTMLBlock(line) { return true }
        if line.indent < 4, line.content.hasPrefix(">") { return true }
        if let marker = listMarker(line), !marker.isEmpty, !marker.ordered || marker.start == 1 { return true }
        return false
    }

    private func blocks(_ lines: [String]) -> [Block] {
        let infos = lines.map(Line.init)
        var out: [Block] = []
        var i = 0
        while i < infos.count {
            let line = infos[i]
            if line.isBlank { i += 1; continue }

            if line.indent >= 4 {
                var code: [String] = []
                while i < infos.count, infos[i].isBlank || infos[i].indent >= 4 {
                    code.append(infos[i].isBlank ? "" : infos[i].removingIndent(4))
                    i += 1
                }
                while code.last == "" { code.removeLast() }
                out.append(.code(code.joined(separator: "\n")))
                continue
            }

            if let (char, count) = Markdown.fence(line) {
                var code: [String] = []
                i += 1
                while i < infos.count {
                    let next = infos[i]
                    if next.indent < 4, next.content.first == char, next.content.prefix(while: { $0 == char }).count >= count,
                       next.content.allSatisfy({ $0 == char }) {
                        i += 1
                        break
                    }
                    code.append(next.removingIndent(line.indent))
                    i += 1
                }
                out.append(.code(code.joined(separator: "\n")))
                continue
            }

            if let (level, text) = Markdown.heading(line) {
                out.append(.heading(level, inlines(text)))
                i += 1
                continue
            }

            if Markdown.isRule(line) {
                out.append(.rule)
                i += 1
                continue
            }

            if line.content.hasPrefix(">") {
                var inner: [String] = []
                var inParagraph = false
                while i < infos.count {
                    let next = infos[i]
                    if next.indent < 4, next.content.hasPrefix(">") {
                        var body = next.removingIndent(next.indent).dropFirst()
                        if body.first == " " { body = body.dropFirst() }
                        inner.append(String(body))
                        inParagraph = !Line(String(body)).isBlank && Markdown.heading(Line(String(body))) == nil && Markdown.fence(Line(String(body))) == nil
                    } else if !next.isBlank, inParagraph, !Markdown.interruptsParagraph(next) {
                        inner.append(next.content) // lazy continuation
                    } else {
                        break
                    }
                    i += 1
                }
                out.append(.quote(blocks(inner)))
                continue
            }

            if let marker = Markdown.listMarker(line) {
                out.append(list(infos, &i, first: marker))
                continue
            }

            if Markdown.startsHTMLBlock(line) {
                out.append(contentsOf: html(infos, &i))
                continue
            }

            if i + 1 < infos.count, line.content.contains("|"), let aligns = Markdown.delimiterRow(infos[i + 1]) {
                let header = Markdown.cells(line.content)
                if header.count == aligns.count {
                    i += 2
                    var rows: [[[Inline]]] = []
                    while i < infos.count, !infos[i].isBlank, !Markdown.interruptsParagraph(infos[i]) {
                        var row = Markdown.cells(infos[i].content)
                        if row.count > aligns.count { row.removeLast(row.count - aligns.count) }
                        while row.count < aligns.count { row.append("") }
                        rows.append(row.map(inlines))
                        i += 1
                    }
                    out.append(.table(aligns: aligns, header: header.map(inlines), rows: rows))
                    continue
                }
            }

            // Paragraph, or a setext heading once an underline turns up.
            var text: [String] = []
            var level = 0
            while i < infos.count {
                let next = infos[i]
                if next.isBlank { break }
                if !text.isEmpty {
                    if next.indent < 4, !next.content.isEmpty, next.content.allSatisfy({ $0 == "=" }) { level = 1; i += 1; break }
                    if next.indent < 4, !next.content.isEmpty, next.content.allSatisfy({ $0 == "-" }) { level = 2; i += 1; break }
                    if Markdown.interruptsParagraph(next) { break }
                    if i + 1 < infos.count, next.content.contains("|"), let aligns = Markdown.delimiterRow(infos[i + 1]),
                       Markdown.cells(next.content).count == aligns.count { break }
                }
                text.append(next.raw.trimmingLeadingWhitespace())
                i += 1
            }
            var joined = text.joined(separator: "\n")
            joined = joined.trimmingTrailingWhitespace()
            out.append(level > 0 ? .heading(level, inlines(joined)) : .paragraph(inlines(joined)))
        }
        return out
    }

    private func list(_ infos: [Line], _ i: inout Int, first: Marker) -> Block {
        var items: [ListItem] = []
        var loose = false
        var marker = first
        items: while i < infos.count {
            var inner: [String] = [infos[i].isBlank ? "" : Line(infos[i].raw).removingIndent(0)]
            // The first line, with the marker replaced by nothing.
            let raw = infos[i].raw
            inner[0] = Markdown.afterMarker(raw, contentIndent: marker.contentIndent)
            i += 1
            var sawBlank = false
            var blankInside = false
            var ended = false
            var inFence: (Character, Int)? = Markdown.fence(Line(inner[0]))
            lines: while i < infos.count {
                let next = infos[i]
                if next.isBlank {
                    sawBlank = true
                    inner.append("")
                    i += 1
                    continue
                }
                if next.indent >= marker.contentIndent {
                    if sawBlank, inFence == nil { blankInside = true }
                    sawBlank = false
                    let stripped = next.removingIndent(marker.contentIndent)
                    if let open = inFence {
                        let l = Line(stripped)
                        if l.content.first == open.0, l.content.prefix(while: { $0 == open.0 }).count >= open.1, l.content.allSatisfy({ $0 == open.0 }) { inFence = nil }
                    } else {
                        inFence = Markdown.fence(Line(stripped))
                    }
                    inner.append(stripped)
                    i += 1
                    continue
                }
                if let nextMarker = Markdown.listMarker(next), !Markdown.isRule(next),
                   nextMarker.ordered == first.ordered, nextMarker.delimiter == first.delimiter {
                    if sawBlank { loose = true }
                    marker = nextMarker
                    break lines
                }
                if sawBlank || Markdown.interruptsParagraph(next) || Markdown.listMarker(next) != nil || inFence != nil {
                    ended = true
                    break lines
                }
                inner.append(next.content) // lazy continuation
                i += 1
            }
            if i >= infos.count { ended = true }
            while inner.last?.isEmpty == true { inner.removeLast() }
            if blankInside { loose = true }

            var task: Bool?
            if let head = inner.first, head.count >= 3 {
                let lead = head.prefix(3)
                let after = head.dropFirst(3).first
                if after == nil || after == " " || after == "\t" {
                    if lead == "[ ]" { task = false } else if lead == "[x]" || lead == "[X]" { task = true }
                    if task != nil { inner[0] = String(head.dropFirst(3)).trimmingLeadingWhitespace() }
                }
            }
            items.append(ListItem(task: task, blocks: blocks(inner)))
            if ended { break items }
        }
        return .list(ordered: first.ordered, start: first.start, loose: loose, items: items)
    }

    private static func afterMarker(_ raw: String, contentIndent: Int) -> String {
        // Blank out the marker's columns, then take off the item's indent.
        var column = 0
        var index = raw.startIndex
        var past = false
        while index < raw.endIndex {
            let c = raw[index]
            if !past, c != " ", c != "\t" { past = true }
            if past, c == " " || c == "\t" { break }
            column += c == "\t" ? 4 - column % 4 : 1
            index = raw.index(after: index)
        }
        var rest = raw[index...]
        while column < contentIndent, let c = rest.first, c == " " || c == "\t" {
            column += c == "\t" ? 4 - column % 4 : 1
            rest = rest.dropFirst()
        }
        return String(rest)
    }

    private static func delimiterRow(_ line: Line) -> [Alignment]? {
        guard line.indent < 4, line.content.contains("-"), line.content.allSatisfy({ "|-: \t".contains($0) }) else { return nil }
        var aligns: [Alignment] = []
        for cell in cells(line.content) {
            let left = cell.hasPrefix(":"), right = cell.hasSuffix(":")
            let dashes = cell.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            guard !dashes.isEmpty, dashes.allSatisfy({ $0 == "-" }) else { return nil }
            aligns.append(left && right ? .center : right ? .right : .left)
        }
        return aligns.isEmpty ? nil : aligns
    }

    private static func cells(_ row: String) -> [String] {
        var text = row.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("|") { text.removeFirst() }
        if text.hasSuffix("|"), !text.hasSuffix("\\|") { text.removeLast() }
        var cells: [String] = []
        var current = ""
        var escaped = false
        for c in text {
            if escaped {
                if c != "|" { current.append("\\") }
                current.append(c)
                escaped = false
            } else if c == "\\" {
                escaped = true
            } else if c == "|" {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(c)
            }
        }
        if escaped { current.append("\\") }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells
    }

    // ---------- Raw HTML blocks ----------

    private static let droppedTags: Set<String> = ["script", "style", "iframe", "object", "embed", "form", "head", "title", "textarea", "noframes"]

    private func html(_ infos: [Line], _ i: inout Int) -> [Block] {
        let line = infos[i]
        if line.content.hasPrefix("<!--") {
            while i < infos.count {
                let done = infos[i].content.contains("-->")
                i += 1
                if done { break }
            }
            return []
        }
        let name = Markdown.htmlTagName(line.content) ?? ""

        if name == "details", !line.content.hasPrefix("</") {
            return [details(infos, &i)]
        }
        if name == "hr" {
            i += 1
            return [.rule]
        }
        if Markdown.droppedTags.contains(name) || name == "pre" {
            // Runs to its closing tag, which may be several lines down.
            var text: [String] = []
            while i < infos.count {
                text.append(infos[i].raw)
                let done = infos[i].content.lowercased().contains("</\(name)>")
                i += 1
                if done { break }
            }
            guard name == "pre" else { return [] }
            let joined = text.joined(separator: "\n")
            let body = Markdown.strippingTags(joined)
            return [.code(Markdown.decodeEntities(body).trimmingCharacters(in: .newlines))]
        }

        // Anything else: up to the next blank line, read for its inline content.
        var text: [String] = []
        while i < infos.count, !infos[i].isBlank {
            text.append(infos[i].content)
            i += 1
        }
        let joined = text.joined(separator: "\n")
        if name.count == 2, name.hasPrefix("h"), let level = Int(name.dropFirst()), (1...6).contains(level) {
            return [.heading(level, inlines(Markdown.strippingBlockTags(joined)))]
        }
        if name == "table" { return Markdown.htmlTable(joined, inlines: inlines).map { [$0] } ?? [] }
        let content = inlines(Markdown.strippingBlockTags(joined))
        return content.isEmpty || plainText(content).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !Markdown.hasImage(content) ? [] : [.paragraph(content)]
    }

    private static func hasImage(_ inlines: [Inline]) -> Bool {
        inlines.contains { inline in
            switch inline {
            case .image: return true
            case .link(_, let c), .tag(_, let c), .emphasis(let c), .strong(let c), .strike(let c): return hasImage(c)
            default: return false
            }
        }
    }

    private func details(_ infos: [Line], _ i: inout Int) -> Block {
        var depth = 0
        var inner: [String] = []
        var fence: (Character, Int)?
        while i < infos.count {
            let raw = infos[i].raw
            let line = infos[i]
            i += 1
            if let open = fence {
                if line.content.first == open.0, line.content.allSatisfy({ $0 == open.0 }) { fence = nil }
            } else if let opened = Markdown.fence(line) {
                fence = opened
            } else {
                let lower = line.content.lowercased()
                depth += lower.components(separatedBy: "<details").count - 1
                depth -= lower.components(separatedBy: "</details>").count - 1
            }
            inner.append(raw)
            if depth <= 0 { break }
        }
        var body = inner.joined(separator: "\n")
        if let open = body.range(of: "<details", options: .caseInsensitive), let end = body.range(of: ">", range: open.upperBound..<body.endIndex) {
            body.removeSubrange(open.lowerBound..<end.upperBound)
        }
        if let close = body.range(of: "</details>", options: [.caseInsensitive, .backwards]) {
            body.removeSubrange(close.lowerBound..<body.endIndex)
        }
        var summary: [Inline] = [.text("Details")]
        if let open = body.range(of: "<summary", options: .caseInsensitive),
           let tagEnd = body.range(of: ">", range: open.upperBound..<body.endIndex),
           let close = body.range(of: "</summary>", options: .caseInsensitive, range: tagEnd.upperBound..<body.endIndex) {
            summary = inlines(String(body[tagEnd.upperBound..<close.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines))
            body.removeSubrange(open.lowerBound..<close.upperBound)
        }
        return .details(summary: summary, blocks: blocks(body.components(separatedBy: "\n")))
    }

    private static func strippingTags(_ html: String) -> String {
        replacing(html, pattern: "<[^>]*>", with: "")
    }

    private static func strippingBlockTags(_ html: String) -> String {
        var out = ""
        var rest = Substring(html)
        while let open = rest.firstIndex(of: "<") {
            out += rest[..<open]
            guard let close = rest[open...].firstIndex(of: ">") else {
                rest = rest[open...]
                break
            }
            let tag = String(rest[open...close])
            if let name = htmlTagName(tag), blockTags.contains(name) {
                out += " "
            } else {
                out += tag
            }
            rest = rest[rest.index(after: close)...]
        }
        out += rest
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func replacing(_ text: String, pattern: String, with replacement: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return text }
        return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: replacement)
    }

    private static func htmlTable(_ html: String, inlines: (String) -> [Inline]) -> Block? {
        func matches(_ pattern: String, _ text: String) -> [String] {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return [] }
            return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { Range($0.range(at: 1), in: text).map { String(text[$0]) } }
        }
        let rows = matches("<tr[^>]*>(.*?)</tr>", html).map { row in matches("<t[dh][^>]*>(.*?)</t[dh]>", row).map { inlines(strippingBlockTags($0)) } }
        guard let first = rows.first, !first.isEmpty else { return nil }
        let normal = rows.dropFirst().map { row -> [[Inline]] in
            var row = Array(row.prefix(first.count))
            while row.count < first.count { row.append([]) }
            return row
        }
        return .table(aligns: Array(repeating: .left, count: first.count), header: first, rows: normal)
    }

    // ---------- Inlines ----------

    private enum Item {
        case inline(Inline)
        case delimiter(Delimiter)
        case bracket(image: Bool, position: Int, active: Bool)
    }

    private final class Delimiter {
        let char: Character
        var count: Int
        let original: Int
        let canOpen: Bool
        let canClose: Bool
        init(char: Character, count: Int, canOpen: Bool, canClose: Bool) {
            self.char = char; self.count = count; original = count; self.canOpen = canOpen; self.canClose = canClose
        }
    }

    private func inlines(_ source: String) -> [Inline] {
        let chars = Array(source)
        var items: [Item] = []
        var buffer = ""
        var i = 0
        func flush() {
            if !buffer.isEmpty { items.append(.inline(.text(buffer))); buffer = "" }
        }

        while i < chars.count {
            let c = chars[i]
            switch c {
            case "\\":
                if i + 1 < chars.count, chars[i + 1] == "\n" {
                    flush(); items.append(.inline(.lineBreak)); i += 2
                    while i < chars.count, chars[i] == " " { i += 1 }
                } else if i + 1 < chars.count, Markdown.isPunctuationASCII(chars[i + 1]) {
                    buffer.append(chars[i + 1]); i += 2
                } else {
                    buffer.append(c); i += 1
                }
            case "&":
                if let (decoded, length) = Markdown.entity(chars, i) {
                    buffer += decoded; i += length
                } else {
                    buffer.append(c); i += 1
                }
            case "`":
                var run = 0
                while i + run < chars.count, chars[i + run] == "`" { run += 1 }
                var j = i + run
                var found = -1
                while j < chars.count {
                    if chars[j] == "`" {
                        var closing = 0
                        while j + closing < chars.count, chars[j + closing] == "`" { closing += 1 }
                        if closing == run { found = j; break }
                        j += closing
                    } else { j += 1 }
                }
                if found >= 0 {
                    flush()
                    var code = String(chars[(i + run)..<found]).replacingOccurrences(of: "\n", with: " ")
                    if code.count >= 2, code.hasPrefix(" "), code.hasSuffix(" "), code.contains(where: { $0 != " " }) {
                        code = String(code.dropFirst().dropLast())
                    }
                    items.append(.inline(.code(code)))
                    i = found + run
                } else {
                    buffer += String(repeating: "`", count: run); i += run
                }
            case "<":
                if let (inline, length) = Markdown.angle(chars, i) {
                    flush()
                    if let inline = inline { items.append(.inline(inline)) }
                    i += length
                } else {
                    buffer.append(c); i += 1
                }
            case "\n":
                var hard = false
                var end = buffer.endIndex
                var spaces = 0
                while end > buffer.startIndex, buffer[buffer.index(before: end)] == " " {
                    end = buffer.index(before: end); spaces += 1
                }
                if spaces >= 2 { hard = true }
                buffer = String(buffer[..<end])
                if hard { flush(); items.append(.inline(.lineBreak)) } else { buffer.append(" ") }
                i += 1
                while i < chars.count, chars[i] == " " || chars[i] == "\t" { i += 1 }
            case "*", "_", "~":
                var run = 0
                while i + run < chars.count, chars[i + run] == c { run += 1 }
                if c == "~", run > 2 { buffer += String(repeating: "~", count: run); i += run; break }
                let before: Character = i > 0 ? chars[i - 1] : " "
                let after: Character = i + run < chars.count ? chars[i + run] : " "
                let beforeSpace = before.isWhitespace, afterSpace = after.isWhitespace
                let beforePunct = Markdown.isPunctuation(before), afterPunct = Markdown.isPunctuation(after)
                let left = !afterSpace && (!afterPunct || beforeSpace || beforePunct)
                let right = !beforeSpace && (!beforePunct || afterSpace || afterPunct)
                let canOpen = c == "_" ? left && (!right || beforePunct) : left
                let canClose = c == "_" ? right && (!left || afterPunct) : right
                flush()
                items.append(.delimiter(Delimiter(char: c, count: run, canOpen: canOpen, canClose: canClose)))
                i += run
            case "!":
                if i + 1 < chars.count, chars[i + 1] == "[" {
                    flush()
                    items.append(.bracket(image: true, position: i + 2, active: true))
                    i += 2
                } else {
                    buffer.append(c); i += 1
                }
            case "[":
                flush()
                items.append(.bracket(image: false, position: i + 1, active: true))
                i += 1
            case "]":
                flush()
                closeBracket(chars, &i, &items)
            default:
                if let (href, length) = Markdown.autolink(chars, i) {
                    flush()
                    let shown = String(chars[i..<(i + length)])
                    items.append(.inline(.link(href: href, children: [.text(shown)])))
                    i += length
                } else {
                    buffer.append(c); i += 1
                }
            }
        }
        flush()
        Markdown.resolveEmphasis(&items, from: 0)
        let flat: [Inline] = items.map { item in
            switch item {
            case .inline(let inline): return inline
            case .delimiter(let d): return .text(String(repeating: d.char, count: d.count))
            case .bracket(let image, _, _): return .text(image ? "![" : "[")
            }
        }
        return Markdown.fold(Markdown.merge(flat))
    }

    private func closeBracket(_ chars: [Character], _ i: inout Int, _ items: inout [Item]) {
        var opener = -1
        for k in items.indices.reversed() {
            if case .bracket = items[k] { opener = k; break }
        }
        guard opener >= 0, case .bracket(let image, let position, let active) = items[opener] else {
            items.append(.inline(.text("]")))
            i += 1
            return
        }
        guard active else {
            items[opener] = .inline(.text(image ? "![" : "["))
            items.append(.inline(.text("]")))
            i += 1
            return
        }

        var target: String?
        var after = i + 1
        if after < chars.count, chars[after] == "(", let (url, end) = Markdown.linkDestination(chars, after) {
            target = url
            after = end
        } else {
            // [text][ref], [text][] or [text]
            var label: String?
            var end = after
            if after < chars.count, chars[after] == "[" {
                var j = after + 1
                while j < chars.count, chars[j] != "]", chars[j] != "[" { j += chars[j] == "\\" ? 2 : 1 }
                if j < chars.count, chars[j] == "]" {
                    let inner = String(chars[(after + 1)..<j])
                    label = inner.isEmpty ? String(chars[position..<i]) : inner
                    end = j + 1
                }
            } else {
                label = String(chars[position..<i])
            }
            if let label = label, let url = references[Markdown.normalize(label)] {
                target = url
                after = end
            }
        }

        guard let url = target else {
            items[opener] = .inline(.text(image ? "![" : "["))
            items.append(.inline(.text("]")))
            i += 1
            return
        }

        var inner = Array(items[(opener + 1)...])
        Markdown.resolveEmphasis(&inner, from: 0)
        let children: [Inline] = inner.map { item in
            switch item {
            case .inline(let inline): return inline
            case .delimiter(let d): return .text(String(repeating: d.char, count: d.count))
            case .bracket(let img, _, _): return .text(img ? "![" : "[")
            }
        }
        items.removeSubrange(opener...)
        if image {
            items.append(.inline(.image(src: url, alt: plainText(Markdown.fold(children)))))
        } else {
            items.append(.inline(.link(href: url, children: Markdown.merge(children))))
            // Links can't contain links: earlier openers no longer count.
            for k in items.indices {
                if case .bracket(false, let p, _) = items[k] { items[k] = .bracket(image: false, position: p, active: false) }
            }
        }
        i = after
    }

    private static func linkDestination(_ chars: [Character], _ open: Int) -> (String, Int)? {
        var i = open + 1
        func skipSpace() { while i < chars.count, chars[i].isWhitespace { i += 1 } }
        skipSpace()
        var url = ""
        if i < chars.count, chars[i] == "<" {
            i += 1
            while i < chars.count, chars[i] != ">" {
                if chars[i] == "\n" { return nil }
                if chars[i] == "\\", i + 1 < chars.count { i += 1 }
                url.append(chars[i])
                i += 1
            }
            guard i < chars.count else { return nil }
            i += 1
        } else {
            var depth = 0
            while i < chars.count {
                let c = chars[i]
                if c.isWhitespace { break }
                if c == "\\", i + 1 < chars.count, isPunctuationASCII(chars[i + 1]) {
                    url.append(chars[i + 1]); i += 2
                    continue
                }
                if c == "(" { depth += 1 }
                if c == ")" {
                    if depth == 0 { break }
                    depth -= 1
                }
                url.append(c)
                i += 1
            }
        }
        skipSpace()
        if i < chars.count, chars[i] == "\"" || chars[i] == "'" || chars[i] == "(" {
            let close: Character = chars[i] == "(" ? ")" : chars[i]
            i += 1
            while i < chars.count, chars[i] != close {
                if chars[i] == "\\" { i += 1 }
                i += 1
            }
            guard i < chars.count else { return nil }
            i += 1
            skipSpace()
        }
        guard i < chars.count, chars[i] == ")" else { return nil }
        return (decodeEntities(url), i + 1)
    }

    // The CommonMark delimiter algorithm, plus GFM's ~~strikethrough~~.
    private static func resolveEmphasis(_ items: inout [Item], from start: Int) {
        var closerIndex = start
        while closerIndex < items.count {
            guard case .delimiter(let closer) = items[closerIndex], closer.canClose, closer.count > 0 else {
                closerIndex += 1
                continue
            }
            var openerIndex = closerIndex - 1
            var found = false
            while openerIndex >= start {
                if case .delimiter(let opener) = items[openerIndex], opener.char == closer.char, opener.canOpen, opener.count > 0 {
                    let oddMatch = (opener.canClose || closer.canOpen) && (opener.original + closer.original) % 3 == 0
                        && !(opener.original % 3 == 0 && closer.original % 3 == 0)
                    let tildeMismatch = closer.char == "~" && opener.count != closer.count
                    if !(oddMatch && closer.char != "~") && !tildeMismatch { found = true; break }
                }
                openerIndex -= 1
            }
            guard found, case .delimiter(let opener) = items[openerIndex] else {
                closerIndex += 1
                continue
            }

            let inner: [Inline] = items[(openerIndex + 1)..<closerIndex].map { item in
                switch item {
                case .inline(let inline): return inline
                case .delimiter(let d): return .text(String(repeating: d.char, count: d.count))
                case .bracket(let image, _, _): return .text(image ? "![" : "[")
                }
            }
            let merged = merge(inner)
            let wrapped: Inline
            let used: Int
            if closer.char == "~" {
                wrapped = .strike(merged)
                used = closer.count
            } else if opener.count >= 2, closer.count >= 2 {
                wrapped = .strong(merged)
                used = 2
            } else {
                wrapped = .emphasis(merged)
                used = 1
            }
            opener.count -= used
            closer.count -= used
            items.replaceSubrange((openerIndex + 1)..<closerIndex, with: [.inline(wrapped)])
            closerIndex = openerIndex + 2
            if opener.count == 0 {
                items.remove(at: openerIndex)
                closerIndex -= 1
            }
            if closer.count == 0 {
                items.remove(at: closerIndex)
            }
        }
    }

    private static func merge(_ inlines: [Inline]) -> [Inline] {
        var out: [Inline] = []
        for inline in inlines {
            if case .text(let s) = inline {
                if s.isEmpty { continue }
                if case .text(let last)? = out.last {
                    out[out.count - 1] = .text(last + s)
                    continue
                }
            }
            out.append(inline)
        }
        return out
    }

    // Pairs raw HTML tags up. Tags with no partner just vanish, and their contents stay.
    private static func fold(_ inlines: [Inline]) -> [Inline] {
        var stack: [(name: String, attrs: [String: String], children: [Inline])] = [("", [:], [])]
        func foldChildren(_ inline: Inline) -> Inline {
            switch inline {
            case .emphasis(let c): return .emphasis(fold(c))
            case .strong(let c): return .strong(fold(c))
            case .strike(let c): return .strike(fold(c))
            case .link(let href, let c): return .link(href: href, children: fold(c))
            default: return inline
            }
        }
        func wrap(_ name: String, _ attrs: [String: String], _ children: [Inline]) -> [Inline] {
            switch name {
            case "b", "strong": return [.strong(children)]
            case "i", "em", "cite", "dfn", "var": return [.emphasis(children)]
            case "s", "del", "strike": return [.strike(children)]
            case "code", "tt", "samp": return [.code(plainText(children))]
            case "a":
                if let href = attrs["href"] { return [.link(href: href, children: children)] }
                return children
            case "kbd", "mark", "sup", "sub", "u", "ins", "small": return [.tag(name == "ins" ? "u" : name, children)]
            default: return children
            }
        }
        for inline in inlines {
            switch inline {
            case .open(let name, let attrs):
                stack.append((name, attrs, []))
            case .close(let name):
                guard let index = stack.lastIndex(where: { $0.name == name }), index > 0 else { continue }
                while stack.count - 1 > index {
                    let dangling = stack.removeLast()
                    stack[stack.count - 1].children += dangling.children
                }
                let done = stack.removeLast()
                stack[stack.count - 1].children += wrap(done.name, done.attrs, done.children)
            default:
                stack[stack.count - 1].children.append(foldChildren(inline))
            }
        }
        while stack.count > 1 {
            let dangling = stack.removeLast()
            stack[stack.count - 1].children += wrap(dangling.name, dangling.attrs, dangling.children)
        }
        return merge(stack[0].children)
    }

    // <http://autolinks>, comments and raw tags.
    private static func angle(_ chars: [Character], _ i: Int) -> (Inline?, Int)? {
        if i + 3 < chars.count, chars[i + 1] == "!", chars[i + 2] == "-", chars[i + 3] == "-" {
            var j = i + 4
            while j + 2 < chars.count {
                if chars[j] == "-", chars[j + 1] == "-", chars[j + 2] == ">" { return (nil, j + 3 - i) }
                j += 1
            }
            return nil
        }
        var close = i + 1
        var quote: Character?
        while close < chars.count {
            let c = chars[close]
            if let q = quote {
                if c == q { quote = nil }
            } else if c == "\"" || c == "'" {
                quote = c
            } else if c == ">" {
                break
            } else if c == "<" {
                return nil
            }
            close += 1
        }
        guard close < chars.count else { return nil }
        let body = String(chars[(i + 1)..<close])
        let length = close + 1 - i

        // <https://…> and <someone@example.com>
        if !body.contains(" "), !body.contains("\n") {
            if let scheme = body.range(of: ":"), body[..<scheme.lowerBound].count >= 2,
               body[..<scheme.lowerBound].allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "+.-".contains($0)) }) {
                return (.link(href: body, children: [.text(body)]), length)
            }
            if body.contains("@"), !body.hasPrefix("/"), body.first?.isLetter == true || body.first?.isNumber == true,
               body.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || ".!#$%&'*+/=?^_`{|}~@-".contains($0)) }) {
                return (.link(href: "mailto:" + body, children: [.text(body)]), length)
            }
        }

        var rest = Substring(body)
        let closing = rest.first == "/"
        if closing { rest = rest.dropFirst() }
        let nameEnd = rest.prefix { $0.isLetter || $0.isNumber || $0 == "-" }
        guard !nameEnd.isEmpty, nameEnd.first!.isLetter else { return nil }
        let name = nameEnd.lowercased()
        let attrText = rest.dropFirst(nameEnd.count)
        guard attrText.isEmpty || attrText.first!.isWhitespace || attrText.first == "/" else { return nil }
        if closing { return (.close(name), length) }
        let attrs = attributes(String(attrText))
        switch name {
        case "br", "wbr": return (name == "br" ? .lineBreak : nil, length)
        case "img":
            guard let src = attrs["src"], !isUnsafe(src) else { return (nil, length) }
            return (.image(src: src, alt: attrs["alt"] ?? ""), length)
        case "a":
            var safe = attrs
            if let href = attrs["href"], isUnsafe(href) { safe["href"] = nil }
            return (.open(name, safe), length)
        default:
            return (.open(name, attrs), length)
        }
    }

    private static func isUnsafe(_ url: String) -> Bool {
        let lower = url.trimmingCharacters(in: .whitespaces).lowercased()
        return lower.hasPrefix("javascript:") || lower.hasPrefix("vbscript:")
    }

    private static func attributes(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            while i < chars.count, chars[i].isWhitespace || chars[i] == "/" { i += 1 }
            var name = ""
            while i < chars.count, !chars[i].isWhitespace, chars[i] != "=", chars[i] != "/" { name.append(chars[i]); i += 1 }
            while i < chars.count, chars[i].isWhitespace { i += 1 }
            var value = ""
            if i < chars.count, chars[i] == "=" {
                i += 1
                while i < chars.count, chars[i].isWhitespace { i += 1 }
                if i < chars.count, chars[i] == "\"" || chars[i] == "'" {
                    let quote = chars[i]
                    i += 1
                    while i < chars.count, chars[i] != quote { value.append(chars[i]); i += 1 }
                    i += 1
                } else {
                    while i < chars.count, !chars[i].isWhitespace { value.append(chars[i]); i += 1 }
                }
            }
            if !name.isEmpty { result[name.lowercased()] = decodeEntities(value) }
        }
        return result
    }

    // Bare http://, https:// and www. addresses, and email addresses.
    private static func autolink(_ chars: [Character], _ i: Int) -> (String, Int)? {
        let c = chars[i]
        guard c == "h" || c == "w" || c == "H" || c == "W" else { return nil }
        if i > 0, !(chars[i - 1].isWhitespace || "*_~(".contains(chars[i - 1])) { return nil }
        func has(_ prefix: String) -> Bool {
            let p = Array(prefix)
            guard i + p.count <= chars.count else { return false }
            for k in 0..<p.count where chars[i + k].lowercased() != String(p[k]) { return false }
            return true
        }
        var prefix = ""
        if has("https://") || has("http://") { prefix = "" } else if has("www.") { prefix = "http://" } else { return nil }
        var end = i
        while end < chars.count, !chars[end].isWhitespace, chars[end] != "<" { end += 1 }
        // Trailing punctuation stays outside, as do closing brackets without an opening partner.
        while end > i {
            let last = chars[end - 1]
            if "?!.,:*_~'\"".contains(last) { end -= 1; continue }
            if last == ")" {
                let slice = chars[i..<end]
                if slice.filter({ $0 == ")" }).count > slice.filter({ $0 == "(" }).count { end -= 1; continue }
            }
            break
        }
        let text = String(chars[i..<end])
        let schemeless = text.replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: "")
        guard !schemeless.isEmpty, end - i > 4 else { return nil }
        return (prefix + text, end - i)
    }

    private static func isPunctuationASCII(_ c: Character) -> Bool {
        "!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~".contains(c)
    }

    private static func isPunctuation(_ c: Character) -> Bool {
        if isPunctuationASCII(c) { return true }
        return c.unicodeScalars.first.map { CharacterSet.punctuationCharacters.contains($0) || CharacterSet.symbols.contains($0) } ?? false
    }

    private static func unescape(_ text: String) -> String {
        var out = ""
        var escaped = false
        for c in text {
            if escaped {
                if !isPunctuationASCII(c) { out.append("\\") }
                out.append(c)
                escaped = false
            } else if c == "\\" {
                escaped = true
            } else {
                out.append(c)
            }
        }
        return decodeEntities(out)
    }

    private static let entities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{A0}", "copy": "©", "reg": "®", "trade": "™",
        "mdash": "—", "ndash": "–", "hellip": "…", "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”", "laquo": "«", "raquo": "»",
        "times": "×", "divide": "÷", "plusmn": "±", "minus": "−", "deg": "°", "middot": "·", "bull": "•", "sect": "§", "para": "¶",
        "dagger": "†", "Dagger": "‡", "larr": "←", "rarr": "→", "uarr": "↑", "darr": "↓", "harr": "↔", "check": "✓", "cross": "✗",
        "euro": "€", "pound": "£", "yen": "¥", "cent": "¢", "frac12": "½", "frac14": "¼", "frac34": "¾", "ensp": "\u{2002}", "emsp": "\u{2003}",
        "thinsp": "\u{2009}", "zwj": "\u{200D}", "zwnj": "\u{200C}", "shy": "\u{AD}", "eacute": "é", "egrave": "è", "agrave": "à", "aacute": "á",
        "ouml": "ö", "uuml": "ü", "auml": "ä", "szlig": "ß", "ccedil": "ç", "ntilde": "ñ", "iexcl": "¡", "iquest": "¿", "hearts": "♥", "star": "☆",
    ]

    private static func entity(_ chars: [Character], _ i: Int) -> (String, Int)? {
        var j = i + 1
        while j < chars.count, j - i <= 32, chars[j] != ";" {
            guard chars[j].isASCII, chars[j].isLetter || chars[j].isNumber || chars[j] == "#" else { return nil }
            j += 1
        }
        guard j < chars.count, chars[j] == ";", j > i + 1 else { return nil }
        let name = String(chars[(i + 1)..<j])
        if name.hasPrefix("#") {
            let digits = name.dropFirst()
            let value = digits.first == "x" || digits.first == "X" ? UInt32(digits.dropFirst(), radix: 16) : UInt32(digits)
            guard let code = value else { return nil }
            let scalar = code == 0 ? Unicode.Scalar(0xFFFD) : Unicode.Scalar(code)
            return (scalar.map { String(Character($0)) } ?? "\u{FFFD}", j + 1 - i)
        }
        guard let decoded = entities[name] else { return nil }
        return (decoded, j + 1 - i)
    }

    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        let chars = Array(text)
        var out = ""
        var i = 0
        while i < chars.count {
            if chars[i] == "&", let (decoded, length) = entity(chars, i) {
                out += decoded
                i += length
            } else {
                out.append(chars[i])
                i += 1
            }
        }
        return out
    }
}

extension String {
    func trimmingTrailingWhitespace() -> String {
        var end = endIndex
        while end > startIndex {
            let previous = index(before: end)
            if self[previous] != " ", self[previous] != "\t" { break }
            end = previous
        }
        return String(self[..<end])
    }

    func trimmingLeadingWhitespace() -> String {
        String(drop { $0 == " " || $0 == "\t" })
    }
}
