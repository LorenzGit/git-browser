import Foundation

/// Read-only code preview: escaped source rendered as HTML with line numbers
/// and lightweight regex-based syntax highlighting (keywords, strings,
/// comments, numbers). Purely local; good enough for reading, not a compiler.
public enum CodeHighlighter {
    struct LanguageSpec {
        var keywords: Set<String>
        var lineComment: String?
        var blockComment: (String, String)?
        var hashComment: Bool { lineComment == "#" }
    }

    static func spec(forExtension ext: String) -> LanguageSpec {
        switch ext {
        case "swift":
            return LanguageSpec(keywords: [
                "actor", "as", "assoicatedtype", "async", "await", "break", "case", "catch", "class",
                "continue", "default", "defer", "deinit", "do", "else", "enum", "extension", "fallthrough",
                "false", "fileprivate", "final", "for", "func", "guard", "if", "import", "in", "init",
                "inout", "internal", "is", "lazy", "let", "mutating", "nil", "nonisolated", "open",
                "operator", "override", "private", "protocol", "public", "repeat", "required", "rethrows",
                "return", "self", "Self", "static", "struct", "subscript", "super", "switch", "throw",
                "throws", "true", "try", "typealias", "var", "weak", "where", "while", "some", "any",
            ], lineComment: "//", blockComment: ("/*", "*/"))
        case "js", "mjs", "cjs", "ts", "tsx", "jsx":
            return LanguageSpec(keywords: [
                "abstract", "as", "async", "await", "break", "case", "catch", "class", "const", "continue",
                "debugger", "default", "delete", "do", "else", "enum", "export", "extends", "false",
                "finally", "for", "from", "function", "if", "implements", "import", "in", "instanceof",
                "interface", "let", "new", "null", "of", "return", "static", "super", "switch", "this",
                "throw", "true", "try", "type", "typeof", "undefined", "var", "void", "while", "yield",
            ], lineComment: "//", blockComment: ("/*", "*/"))
        case "py":
            return LanguageSpec(keywords: [
                "and", "as", "assert", "async", "await", "break", "class", "continue", "def", "del",
                "elif", "else", "except", "False", "finally", "for", "from", "global", "if", "import",
                "in", "is", "lambda", "None", "nonlocal", "not", "or", "pass", "raise", "return",
                "True", "try", "while", "with", "yield", "match", "case", "self",
            ], lineComment: "#", blockComment: nil)
        case "go":
            return LanguageSpec(keywords: [
                "break", "case", "chan", "const", "continue", "default", "defer", "else", "fallthrough",
                "false", "for", "func", "go", "goto", "if", "import", "interface", "map", "nil",
                "package", "range", "return", "select", "struct", "switch", "true", "type", "var",
            ], lineComment: "//", blockComment: ("/*", "*/"))
        case "rs":
            return LanguageSpec(keywords: [
                "as", "async", "await", "break", "const", "continue", "crate", "dyn", "else", "enum",
                "extern", "false", "fn", "for", "if", "impl", "in", "let", "loop", "match", "mod",
                "move", "mut", "pub", "ref", "return", "self", "Self", "static", "struct", "super",
                "trait", "true", "type", "unsafe", "use", "where", "while",
            ], lineComment: "//", blockComment: ("/*", "*/"))
        case "c", "h", "cpp", "cc", "cxx", "hpp", "hh", "m", "mm", "java", "kt", "kts", "cs", "scala":
            return LanguageSpec(keywords: [
                "abstract", "auto", "bool", "break", "case", "catch", "char", "class", "const", "continue",
                "default", "delete", "do", "double", "else", "enum", "extern", "false", "final", "finally",
                "float", "for", "goto", "if", "import", "include", "inline", "int", "interface", "long",
                "namespace", "new", "nil", "null", "nullptr", "override", "package", "private", "protected",
                "public", "return", "short", "signed", "sizeof", "static", "struct", "switch", "template",
                "this", "throw", "throws", "true", "try", "typedef", "union", "unsigned", "using",
                "val", "var", "virtual", "void", "volatile", "while", "fun", "when", "object",
            ], lineComment: "//", blockComment: ("/*", "*/"))
        case "rb":
            return LanguageSpec(keywords: [
                "alias", "and", "begin", "break", "case", "class", "def", "do", "else", "elsif", "end",
                "ensure", "false", "for", "if", "in", "module", "next", "nil", "not", "or", "raise",
                "redo", "require", "rescue", "retry", "return", "self", "super", "then", "true",
                "undef", "unless", "until", "when", "while", "yield", "attr_accessor",
            ], lineComment: "#", blockComment: nil)
        case "sh", "bash", "zsh", "fish":
            return LanguageSpec(keywords: [
                "case", "do", "done", "elif", "else", "esac", "exit", "export", "fi", "for", "function",
                "if", "in", "local", "read", "return", "then", "until", "while", "echo", "set", "source",
            ], lineComment: "#", blockComment: nil)
        case "css":
            return LanguageSpec(keywords: [], lineComment: nil, blockComment: ("/*", "*/"))
        case "yaml", "yml", "toml", "ini", "conf", "cfg", "properties", "r", "pl":
            return LanguageSpec(keywords: ["true", "false", "null", "yes", "no"], lineComment: "#", blockComment: nil)
        case "sql":
            return LanguageSpec(keywords: [
                "select", "from", "where", "insert", "into", "values", "update", "delete", "create",
                "table", "index", "join", "left", "right", "inner", "outer", "on", "group", "by",
                "order", "having", "limit", "offset", "as", "and", "or", "not", "null", "primary",
                "key", "foreign", "references", "distinct", "union", "all", "exists", "between", "like",
                "SELECT", "FROM", "WHERE", "INSERT", "INTO", "VALUES", "UPDATE", "DELETE", "CREATE",
                "TABLE", "INDEX", "JOIN", "LEFT", "RIGHT", "INNER", "OUTER", "ON", "GROUP", "BY",
                "ORDER", "HAVING", "LIMIT", "OFFSET", "AS", "AND", "OR", "NOT", "NULL", "PRIMARY",
                "KEY", "FOREIGN", "REFERENCES", "DISTINCT", "UNION", "ALL", "EXISTS", "BETWEEN", "LIKE",
            ], lineComment: "--", blockComment: ("/*", "*/"))
        case "json":
            return LanguageSpec(keywords: ["true", "false", "null"], lineComment: nil, blockComment: nil)
        case "php":
            return LanguageSpec(keywords: [
                "abstract", "array", "as", "break", "case", "catch", "class", "const", "continue",
                "declare", "default", "do", "echo", "else", "elseif", "extends", "false", "final",
                "finally", "for", "foreach", "function", "if", "implements", "include", "interface",
                "namespace", "new", "null", "print", "private", "protected", "public", "require",
                "return", "static", "switch", "throw", "trait", "true", "try", "use", "var", "while",
            ], lineComment: "//", blockComment: ("/*", "*/"))
        default:
            return LanguageSpec(keywords: [], lineComment: nil, blockComment: nil)
        }
    }

    /// Highlights source text into HTML `<span>`s (class: kw, str, com, num).
    public static func highlightHTML(source: String, fileExtension ext: String) -> String {
        let spec = spec(forExtension: ext)
        var out = ""
        out.reserveCapacity(source.count + source.count / 4)

        let chars = Array(source)
        var i = 0
        let n = chars.count

        func startsWith(_ token: String, at index: Int) -> Bool {
            let t = Array(token)
            guard index + t.count <= n else { return false }
            for (offset, ch) in t.enumerated() where chars[index + offset] != ch { return false }
            return true
        }

        func emit(_ ch: Character) { out += escapeChar(ch) }

        while i < n {
            let ch = chars[i]

            // Block comment
            if let (open, close) = spec.blockComment, startsWith(open, at: i) {
                out += "<span class=\"com\">"
                var j = i
                while j < n, !startsWith(close, at: j) { j += 1 }
                let end = min(n, j + close.count)
                for k in i..<end { emit(chars[k]) }
                out += "</span>"
                i = end
                continue
            }

            // Line comment
            if let lc = spec.lineComment, startsWith(lc, at: i) {
                out += "<span class=\"com\">"
                var j = i
                while j < n, chars[j] != "\n" { emit(chars[j]); j += 1 }
                out += "</span>"
                i = j
                continue
            }

            // String literal
            if ch == "\"" || ch == "'" || ch == "`" {
                let quote = ch
                out += "<span class=\"str\">"
                emit(quote)
                var j = i + 1
                while j < n {
                    if chars[j] == "\\", j + 1 < n {
                        emit(chars[j]); emit(chars[j + 1])
                        j += 2
                        continue
                    }
                    if chars[j] == quote || chars[j] == "\n" { break }
                    emit(chars[j])
                    j += 1
                }
                if j < n, chars[j] == quote { emit(quote); j += 1 }
                out += "</span>"
                i = j
                continue
            }

            // Number
            if ch.isNumber, i == 0 || !(chars[i - 1].isLetter || chars[i - 1] == "_") {
                var j = i
                var literal = ""
                while j < n, chars[j].isHexDigit || "xXoObB._eE+-".contains(chars[j]) {
                    // stop at +/- unless directly after e/E
                    if "+-".contains(chars[j]), j > i, !"eE".contains(chars[j - 1]) { break }
                    literal.append(chars[j])
                    j += 1
                }
                out += "<span class=\"num\">\(HTMLEscape.escape(literal))</span>"
                i = j
                continue
            }

            // Identifier / keyword
            if ch.isLetter || ch == "_" {
                var j = i
                var word = ""
                while j < n, chars[j].isLetter || chars[j].isNumber || chars[j] == "_" {
                    word.append(chars[j])
                    j += 1
                }
                if spec.keywords.contains(word) {
                    out += "<span class=\"kw\">\(word)</span>"
                } else {
                    out += HTMLEscape.escape(word)
                }
                i = j
                continue
            }

            emit(ch)
            i += 1
        }
        return out
    }

    private static func escapeChar(_ ch: Character) -> String {
        switch ch {
        case "&": return "&amp;"
        case "<": return "&lt;"
        case ">": return "&gt;"
        case "\"": return "&quot;"
        default: return String(ch)
        }
    }

    /// Full HTML document for the code preview.
    public static func renderDocument(source: String, path: String) -> String {
        let ext = RepoPath.fileExtension(of: path)
        let highlighted = highlightHTML(source: source, fileExtension: ext)
        let lineCount = max(1, source.reduce(into: 1) { if $1 == "\n" { $0 += 1 } })
        let gutter = (1...lineCount).map(String.init).joined(separator: "\n")
        return """
        <!DOCTYPE html>
        <html><head><meta charset="utf-8"><title>\(HTMLEscape.escape(RepoPath.fileName(of: path)))</title>
        <style>
        :root { color-scheme: light dark; }
        body { margin: 0; background: #ffffff; color: #1f2328;
               font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 12.5px; }
        .wrap { display: flex; align-items: flex-start; }
        .gutter { user-select: none; text-align: right; padding: 12px 10px 40px 16px;
                  color: #8a929c; white-space: pre; line-height: 1.5; position: sticky; left: 0;
                  background: inherit; }
        pre.code { margin: 0; padding: 12px 24px 40px 12px; line-height: 1.5; flex: 1;
                   overflow: visible; white-space: pre; tab-size: 4; }
        .kw { color: #cf222e; font-weight: 600; }
        .str { color: #0a3069; }
        .com { color: #6e7781; font-style: italic; }
        .num { color: #0550ae; }
        @media (prefers-color-scheme: dark) {
          body { background: #0d1117; color: #f0f6fc; }
          .kw { color: #ff7b72; }
          .str { color: #a5d6ff; }
          .com { color: #8b949e; }
          .num { color: #79c0ff; }
        }
        </style></head>
        <body><div class="wrap"><div class="gutter">\(gutter)</div><pre class="code">\(highlighted)</pre></div></body></html>
        """
    }
}
