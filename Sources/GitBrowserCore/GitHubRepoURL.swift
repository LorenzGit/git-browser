import Foundation

/// The result of parsing a user-supplied GitHub repository URL.
public struct ParsedRepoURL: Equatable, Sendable {
    public var coordinates: RepoCoordinates
    /// Branch, tag, or commit named in the URL, if any.
    public var ref: String?
    /// Initial file or directory path named in the URL, if any (repo-root relative).
    public var initialPath: String?

    public init(coordinates: RepoCoordinates, ref: String? = nil, initialPath: String? = nil) {
        self.coordinates = coordinates
        self.ref = ref
        self.initialPath = initialPath
    }
}

/// Parses GitHub repository URLs into host, owner, repo, optional ref, and optional path.
///
/// Supported forms:
///   - https://github.com/owner/repo
///   - https://github.com/owner/repo.git
///   - https://github.com/owner/repo/tree/REF[/dir[/...]]
///   - https://github.com/owner/repo/blob/REF/file[/...]
///   - https://github.com/owner/repo/raw/REF/file[/...]
///   - https://github.com/owner/repo/commits/REF
///   - github.com/owner/repo (scheme optional)
///   - owner/repo (assumes github.com)
///   - git@host:owner/repo.git
///   - GitHub Enterprise hosts work in all of the above forms.
///
/// Limitation: for /tree/ and /blob/ URLs the first segment after the marker is
/// taken as the ref, so branch names containing "/" are read as ref + path.
public enum GitHubRepoURLParser {
    public static func parse(_ input: String) -> ParsedRepoURL? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        // SSH form: git@host:owner/repo(.git)
        if text.hasPrefix("git@") {
            let body = String(text.dropFirst("git@".count))
            guard let colon = body.firstIndex(of: ":") else { return nil }
            let host = String(body[..<colon])
            let rest = String(body[body.index(after: colon)...])
            return parsePathPortion(host: host, pathPortion: rest)
        }

        if let schemeRange = text.range(of: "://") {
            let scheme = text[..<schemeRange.lowerBound].lowercased()
            guard scheme == "http" || scheme == "https" else { return nil }
            text = String(text[schemeRange.upperBound...])
        }

        // Now text is "host/owner/repo[...]" or "owner/repo[...]" (shorthand).
        let firstSlash = text.firstIndex(of: "/")
        guard let firstSlash else { return nil }
        let head = String(text[..<firstSlash])

        if head.contains(".") || head.contains(":") {
            // Looks like a hostname (github.com, github.example.com, host:port unsupported).
            guard !head.contains(":") else { return nil }
            let rest = String(text[text.index(after: firstSlash)...])
            return parsePathPortion(host: head, pathPortion: rest)
        }
        // Shorthand owner/repo on github.com.
        return parsePathPortion(host: "github.com", pathPortion: text)
    }

    private static func parsePathPortion(host: String, pathPortion: String) -> ParsedRepoURL? {
        guard isPlausibleHost(host) else { return nil }
        // Drop query and fragment.
        var path = pathPortion
        if let q = path.firstIndex(where: { $0 == "?" || $0 == "#" }) {
            path = String(path[..<q])
        }
        var segments = path.split(separator: "/", omittingEmptySubsequences: true).map {
            $0.removingPercentEncoding ?? String($0)
        }
        guard segments.count >= 2 else { return nil }

        let owner = segments[0]
        var repo = segments[1]
        if repo.hasSuffix(".git") { repo = String(repo.dropLast(4)) }
        guard isValidName(owner), isValidName(repo) else { return nil }

        let coords = RepoCoordinates(host: host, owner: owner, repo: repo)
        segments.removeFirst(2)
        guard !segments.isEmpty else {
            return ParsedRepoURL(coordinates: coords)
        }

        let marker = segments.removeFirst()
        switch marker {
        case "tree", "blob", "raw", "commits", "commit":
            guard !segments.isEmpty else {
                return ParsedRepoURL(coordinates: coords)
            }
            let ref = segments.removeFirst()
            let initialPath = segments.isEmpty ? nil : segments.joined(separator: "/")
            return ParsedRepoURL(coordinates: coords, ref: ref, initialPath: initialPath)
        default:
            // Unknown trailing segments (issues, pulls, ...) — treat as plain repo URL.
            return ParsedRepoURL(coordinates: coords)
        }
    }

    private static func isPlausibleHost(_ host: String) -> Bool {
        guard !host.isEmpty, host.contains("."), !host.hasPrefix("."), !host.hasSuffix(".") else {
            return false
        }
        return host.allSatisfy { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }
    }

    private static func isValidName(_ name: String) -> Bool {
        guard !name.isEmpty, name != ".", name != ".." else { return false }
        return !name.contains("/")
    }
}
