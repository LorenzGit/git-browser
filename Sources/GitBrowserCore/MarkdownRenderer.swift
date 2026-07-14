import Foundation

/// Local Markdown → HTML renderer for the Markdown preview.
///
/// Renders entirely in-process (no network, no external converter). Raw HTML
/// in the source is escaped, not passed through, so a markdown file cannot
/// smuggle script into the preview. Relative links and images are left
/// relative: the preview loads the result with the file's repobrowser:// URL
/// as base, so they resolve inside the repository and route through the app.
///
/// Supported: ATX headings (with anchor ids), paragraphs, fenced code blocks,
/// blockquotes, unordered/ordered lists (one nesting level per 2 spaces),
/// GFM tables, horizontal rules, inline code/bold/italic/strikethrough,
/// links, images, autolinks.
public enum MarkdownRenderer {
    public static func renderDocument(markdown: String, title: String) -> String {
        let body = renderBody(markdown: markdown)
        return """
        <!DOCTYPE html>
        <html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(HTMLEscape.escape(title))</title>
        <style>\(css)</style>
        </head><body><article class="markdown-body">
        \(body)
        </article></body></html>
        """
    }

    // MARK: - Block parsing

    public static func renderBody(markdown: String) -> String {
        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var html = ""
        var i = 0

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty { i += 1; continue }

            // Fenced code block
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                let fence = String(trimmed.prefix(3))
                let language = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    code.append(lines[i])
                    i += 1
                }
                i += 1 // closing fence
                let source = code.joined(separator: "\n")
                let classAttr = language.isEmpty ? "" : " class=\"language-\(HTMLEscape.escape(language))\""
                // Reuse the code-preview highlighter inside fences; unknown
                // languages fall through to plain escaping.
                let body = CodeHighlighter.highlightHTML(
                    source: source, fileExtension: Self.fileExtension(forFenceLanguage: language)
                )
                html += "<pre><code\(classAttr)>\(body)</code></pre>\n"
                continue
            }

            // ATX heading
            if let heading = parseHeading(trimmed) {
                let inner = renderInline(heading.text)
                let slug = slugify(heading.text)
                html += "<h\(heading.level) id=\"\(slug)\">\(inner)</h\(heading.level)>\n"
                i += 1
                continue
            }

            // Horizontal rule
            if isHorizontalRule(trimmed) {
                html += "<hr>\n"
                i += 1
                continue
            }

            // Blockquote
            if trimmed.hasPrefix(">") {
                var quoted: [String] = []
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    guard t.hasPrefix(">") else { break }
                    quoted.append(String(t.dropFirst(t.hasPrefix("> ") ? 2 : 1)))
                    i += 1
                }
                html += "<blockquote>\n\(renderBody(markdown: quoted.joined(separator: "\n")))</blockquote>\n"
                continue
            }

            // Table (header row + separator row)
            if trimmed.contains("|"), i + 1 < lines.count,
               isTableSeparator(lines[i + 1].trimmingCharacters(in: .whitespaces)) {
                let header = tableCells(trimmed)
                var rows: [[String]] = []
                i += 2
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    guard t.contains("|"), !t.isEmpty else { break }
                    rows.append(tableCells(t))
                    i += 1
                }
                html += "<table><thead><tr>"
                html += header.map { "<th>\(renderInline($0))</th>" }.joined()
                html += "</tr></thead><tbody>"
                for row in rows {
                    html += "<tr>" + row.map { "<td>\(renderInline($0))</td>" }.joined() + "</tr>"
                }
                html += "</tbody></table>\n"
                continue
            }

            // Lists
            if listItemMarker(line) != nil {
                let (rendered, consumed) = renderList(lines: lines, start: i, indent: leadingSpaces(line))
                html += rendered
                i = consumed
                continue
            }

            // Paragraph: gather until blank line or block start
            var paragraph: [String] = []
            while i < lines.count {
                let t = lines[i].trimmingCharacters(in: .whitespaces)
                if t.isEmpty || t.hasPrefix("```") || t.hasPrefix("~~~") || parseHeading(t) != nil
                    || t.hasPrefix(">") || isHorizontalRule(t) || listItemMarker(lines[i]) != nil {
                    break
                }
                paragraph.append(t)
                i += 1
            }
            html += "<p>\(renderInline(paragraph.joined(separator: "\n")))</p>\n"
        }
        return html
    }

    private static func renderList(lines: [String], start: Int, indent: Int) -> (String, Int) {
        var i = start
        guard let firstMarker = listItemMarker(lines[i]) else { return ("", start + 1) }
        let ordered = firstMarker.ordered
        var html = ordered ? "<ol>\n" : "<ul>\n"

        while i < lines.count {
            let line = lines[i]
            let lineIndent = leadingSpaces(line)
            guard let marker = listItemMarker(line), lineIndent >= indent else { break }

            if lineIndent > indent + 1 {
                // Nested list under the previous item
                let (nested, consumed) = renderList(lines: lines, start: i, indent: lineIndent)
                html = String(html.dropLast("</li>\n".count)) + "\n" + nested + "</li>\n"
                i = consumed
                continue
            }
            html += "<li>\(renderInline(marker.content))</li>\n"
            i += 1
        }
        html += ordered ? "</ol>\n" : "</ul>\n"
        return (html, i)
    }

    private struct ListMarker {
        var ordered: Bool
        var content: String
    }

    private static func listItemMarker(_ line: String) -> ListMarker? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        for prefix in ["- ", "* ", "+ "] where trimmed.hasPrefix(prefix) {
            return ListMarker(ordered: false, content: String(trimmed.dropFirst(2)))
        }
        if trimmed == "-" || trimmed == "*" || trimmed == "+" {
            return ListMarker(ordered: false, content: "")
        }
        // Ordered: digits followed by ". " or ") "
        var idx = trimmed.startIndex
        while idx < trimmed.endIndex, trimmed[idx].isNumber { idx = trimmed.index(after: idx) }
        if idx > trimmed.startIndex, idx < trimmed.endIndex,
           trimmed[idx] == "." || trimmed[idx] == ")" {
            let after = trimmed.index(after: idx)
            if after < trimmed.endIndex, trimmed[after] == " " {
                return ListMarker(ordered: true, content: String(trimmed[trimmed.index(after: after)...]))
            }
        }
        return nil
    }

    private static func leadingSpaces(_ line: String) -> Int {
        var count = 0
        for ch in line {
            if ch == " " { count += 1 } else if ch == "\t" { count += 4 } else { break }
        }
        return count
    }

    private static func parseHeading(_ line: String) -> (level: Int, text: String)? {
        guard line.hasPrefix("#") else { return nil }
        var level = 0
        var idx = line.startIndex
        while idx < line.endIndex, line[idx] == "#", level < 6 {
            level += 1
            idx = line.index(after: idx)
        }
        guard level > 0, idx < line.endIndex, line[idx] == " " else {
            return level > 0 && idx == line.endIndex ? (level, "") : nil
        }
        var text = String(line[line.index(after: idx)...])
        // Strip trailing closing hashes
        while text.hasSuffix("#") { text = String(text.dropLast()) }
        return (level, text.trimmingCharacters(in: .whitespaces))
    }

    private static func isHorizontalRule(_ line: String) -> Bool {
        let stripped = line.replacingOccurrences(of: " ", with: "")
        guard stripped.count >= 3 else { return false }
        return stripped.allSatisfy { $0 == "-" } || stripped.allSatisfy { $0 == "*" }
            || stripped.allSatisfy { $0 == "_" }
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        guard line.contains("-"), line.contains("|") || line.contains(":") else { return false }
        return line.allSatisfy { "|-: ".contains($0) }
    }

    private static func tableCells(_ line: String) -> [String] {
        var t = line
        if t.hasPrefix("|") { t = String(t.dropFirst()) }
        if t.hasSuffix("|") { t = String(t.dropLast()) }
        return t.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// Maps a fence language tag ("swift", "python", "js"…) onto the file
    /// extension the CodeHighlighter keys on.
    static func fileExtension(forFenceLanguage language: String) -> String {
        switch language.lowercased() {
        case "javascript", "node": return "js"
        case "typescript": return "ts"
        case "python", "python3": return "py"
        case "rust": return "rs"
        case "ruby": return "rb"
        case "shell", "console", "terminal", "shellscript": return "sh"
        case "objective-c", "objc": return "m"
        case "c++": return "cpp"
        case "kotlin": return "kt"
        case "csharp", "c#": return "cs"
        case "yaml": return "yml"
        case "makefile": return "make"
        default: return language.lowercased()
        }
    }

    public static func slugify(_ text: String) -> String {
        let lowered = text.lowercased()
        var slug = ""
        for ch in lowered {
            if ch.isLetter || ch.isNumber { slug.append(ch) }
            else if ch == " " || ch == "-" || ch == "_" { slug.append("-") }
        }
        while slug.contains("--") { slug = slug.replacingOccurrences(of: "--", with: "-") }
        return slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    // MARK: - Inline parsing

    /// Escapes HTML, then applies inline markdown. Code spans are extracted
    /// first so their contents are never styled.
    public static func renderInline(_ text: String) -> String {
        var placeholders: [String] = []

        // 1. Extract code spans on the raw text.
        var working = ""
        var rest = Substring(text)
        while let tickStart = rest.firstIndex(of: "`") {
            let afterTick = rest.index(after: tickStart)
            if let tickEnd = rest[afterTick...].firstIndex(of: "`") {
                working += rest[..<tickStart]
                let code = String(rest[afterTick..<tickEnd])
                placeholders.append("<code>\(HTMLEscape.escape(code))</code>")
                working += "\u{0}\(placeholders.count - 1)\u{0}"
                rest = rest[rest.index(after: tickEnd)...]
            } else {
                working += rest[...tickStart]
                rest = rest[afterTick...]
            }
        }
        working += rest

        var html = HTMLEscape.escape(working)

        // 2. Images before links: ![alt](src "title")
        html = replaceRegex(html, pattern: #"!\[([^\]]*)\]\(([^)\s]+)(?:\s+&quot;([^&]*)&quot;)?\)"#) { groups in
            let alt = groups[1] ?? ""
            let src = groups[2] ?? ""
            let title = groups[3].map { " title=\"\($0)\"" } ?? ""
            return "<img src=\"\(src)\" alt=\"\(alt)\"\(title)>"
        }

        // 3. Links: [text](href "title")
        html = replaceRegex(html, pattern: #"\[([^\]]+)\]\(([^)\s]+)(?:\s+&quot;([^&]*)&quot;)?\)"#) { groups in
            let label = groups[1] ?? ""
            let href = groups[2] ?? ""
            let title = groups[3].map { " title=\"\($0)\"" } ?? ""
            return "<a href=\"\(href)\"\(title)>\(label)</a>"
        }

        // 4. Autolinks: &lt;https://...&gt;
        html = replaceRegex(html, pattern: #"&lt;(https?://[^&\s]+)&gt;"#) { groups in
            let url = groups[1] ?? ""
            return "<a href=\"\(url)\">\(url)</a>"
        }

        // 5. Emphasis / strikethrough
        html = replaceRegex(html, pattern: #"\*\*([^*]+)\*\*"#) { "<strong>\($0[1] ?? "")</strong>" }
        html = replaceRegex(html, pattern: #"__([^_]+)__"#) { "<strong>\($0[1] ?? "")</strong>" }
        html = replaceRegex(html, pattern: #"\*([^*\s][^*]*)\*"#) { "<em>\($0[1] ?? "")</em>" }
        html = replaceRegex(html, pattern: #"(?<![\w])_([^_\s][^_]*)_(?![\w])"#) { "<em>\($0[1] ?? "")</em>" }
        html = replaceRegex(html, pattern: #"~~([^~]+)~~"#) { "<del>\($0[1] ?? "")</del>" }

        // 6. Restore code spans.
        for (index, replacement) in placeholders.enumerated() {
            html = html.replacingOccurrences(of: "\u{0}\(index)\u{0}", with: replacement)
        }
        return html
    }

    private static func replaceRegex(
        _ input: String, pattern: String,
        transform: ([String?]) -> String
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return input }
        let ns = input as NSString
        var result = ""
        var location = 0
        for match in regex.matches(in: input, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: location, length: match.range.location - location))
            var groups: [String?] = []
            for g in 0..<match.numberOfRanges {
                let r = match.range(at: g)
                groups.append(r.location == NSNotFound ? nil : ns.substring(with: r))
            }
            result += transform(groups)
            location = match.range.location + match.range.length
        }
        result += ns.substring(from: location)
        return result
    }

    // MARK: - Style

    static let css = """
    :root { color-scheme: light dark; }
    body { margin: 0; background: #ffffff; }
    .markdown-body {
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Helvetica, Arial, sans-serif;
      font-size: 15px; line-height: 1.6; color: #1f2328;
      max-width: 860px; margin: 0 auto; padding: 24px 32px 64px;
      word-wrap: break-word;
    }
    .markdown-body h1, .markdown-body h2 {
      border-bottom: 1px solid #d1d9e0; padding-bottom: .3em;
    }
    .markdown-body h1 { font-size: 1.8em; }
    .markdown-body a { color: #0969da; text-decoration: none; }
    .markdown-body a:hover { text-decoration: underline; }
    .markdown-body code {
      background: rgba(129,139,152,.18); border-radius: 5px;
      padding: .15em .35em; font-size: .9em;
      font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
    }
    .markdown-body pre {
      background: #f6f8fa; border-radius: 8px; padding: 14px; overflow-x: auto;
    }
    .markdown-body pre code { background: none; padding: 0; font-size: .875em; }
    .markdown-body blockquote {
      margin: 0; padding: 0 1em; color: #59636e; border-left: 4px solid #d1d9e0;
    }
    .markdown-body table { border-collapse: collapse; margin: 1em 0; display: block; overflow-x: auto; }
    .markdown-body th, .markdown-body td { border: 1px solid #d1d9e0; padding: 6px 13px; }
    .markdown-body th { background: #f6f8fa; }
    .markdown-body img { max-width: 100%; }
    .markdown-body hr { border: none; border-top: 3px solid #d1d9e0; margin: 24px 0; }
    .markdown-body .kw { color: #cf222e; }
    .markdown-body .str { color: #0a3069; }
    .markdown-body .com { color: #6e7781; font-style: italic; }
    .markdown-body .num { color: #0550ae; }
    @media (prefers-color-scheme: dark) {
      body { background: #0d1117; }
      .markdown-body { color: #f0f6fc; }
      .markdown-body h1, .markdown-body h2 { border-color: #3d444d; }
      .markdown-body a { color: #4493f8; }
      .markdown-body pre { background: #161b22; }
      .markdown-body blockquote { color: #9198a1; border-color: #3d444d; }
      .markdown-body th, .markdown-body td { border-color: #3d444d; }
      .markdown-body th { background: #161b22; }
      .markdown-body .kw { color: #ff7b72; }
      .markdown-body .str { color: #a5d6ff; }
      .markdown-body .com { color: #8b949e; }
      .markdown-body .num { color: #79c0ff; }
    }
    """
}
