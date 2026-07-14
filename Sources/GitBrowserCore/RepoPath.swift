import Foundation

/// Normalization and containment validation for repository-relative paths.
///
/// Every path served through the repobrowser:// scheme goes through
/// `normalize(_:)`, which resolves "." and ".." segments and refuses any path
/// that would escape the virtual repository root.
public enum RepoPath {
    /// Normalizes a slash-separated path. Returns a root-relative path with no
    /// leading slash, or nil if the path escapes the repository root or
    /// contains forbidden components.
    public static func normalize(_ raw: String) -> String? {
        // Reject NUL and backslash tricks outright.
        guard !raw.contains("\0"), !raw.contains("\\") else { return nil }

        var stack: [String] = []
        for segment in raw.split(separator: "/", omittingEmptySubsequences: true) {
            switch segment {
            case ".":
                continue
            case "..":
                guard !stack.isEmpty else { return nil } // escape attempt
                stack.removeLast()
            default:
                stack.append(String(segment))
            }
        }
        return stack.joined(separator: "/")
    }

    /// Normalizes the path component of a repobrowser:// URL. Percent-decodes
    /// first, then applies `normalize`. Returns nil for invalid/escaping paths.
    public static func normalizeURLPath(_ urlPath: String) -> String? {
        guard let decoded = urlPath.removingPercentEncoding else { return nil }
        return normalize(decoded)
    }

    /// Resolves a relative reference against the directory of `basePath`
    /// (both repo-root relative). Used for markdown link routing.
    public static func resolve(relative reference: String, against basePath: String) -> String? {
        if reference.hasPrefix("/") {
            return normalize(reference)
        }
        let baseDir = parentDirectory(of: basePath)
        return normalize(baseDir.isEmpty ? reference : baseDir + "/" + reference)
    }

    public static func parentDirectory(of path: String) -> String {
        guard let idx = path.lastIndex(of: "/") else { return "" }
        return String(path[..<idx])
    }

    public static func fileName(of path: String) -> String {
        guard let idx = path.lastIndex(of: "/") else { return path }
        return String(path[path.index(after: idx)...])
    }

    public static func fileExtension(of path: String) -> String {
        let name = fileName(of: path)
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return "" }
        return String(name[name.index(after: dot)...]).lowercased()
    }
}
