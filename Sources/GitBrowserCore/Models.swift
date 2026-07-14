import Foundation

/// Identifies a repository on a GitHub host (github.com or GitHub Enterprise).
public struct RepoCoordinates: Hashable, Sendable {
    public var host: String
    public var owner: String
    public var repo: String

    public init(host: String, owner: String, repo: String) {
        self.host = host.lowercased()
        self.owner = owner
        self.repo = repo
    }

    public var displayName: String { "\(owner)/\(repo)" }
}

public struct RepoMetadata: Sendable {
    public var fullName: String
    public var defaultBranch: String
    public var description: String?
    public var isPrivate: Bool

    public init(fullName: String, defaultBranch: String, description: String?, isPrivate: Bool) {
        self.fullName = fullName
        self.defaultBranch = defaultBranch
        self.description = description
        self.isPrivate = isPrivate
    }
}

public enum DirEntryType: String, Sendable {
    case file
    case dir
    case symlink
    case submodule
    case other
}

public struct DirEntry: Hashable, Sendable {
    public var name: String
    /// Path relative to the repository root, no leading slash.
    public var path: String
    public var type: DirEntryType
    public var size: Int64

    public init(name: String, path: String, type: DirEntryType, size: Int64) {
        self.name = name
        self.path = path
        self.type = type
        self.size = size
    }
}

/// One entry of a full (recursive) repository tree — metadata only, used by
/// the fuzzy file finder. No file content is ever fetched for this.
public struct TreeEntry: Hashable, Sendable {
    public var path: String
    public var type: DirEntryType
    public var size: Int64

    public init(path: String, type: DirEntryType, size: Int64) {
        self.path = path
        self.type = type
        self.size = size
    }
}

public struct FullTree: Sendable {
    public var entries: [TreeEntry]
    /// True when GitHub truncated the listing (extremely large repos).
    public var truncated: Bool

    public init(entries: [TreeEntry], truncated: Bool) {
        self.entries = entries
        self.truncated = truncated
    }
}

public struct CommitInfo: Hashable, Sendable {
    public var sha: String
    /// First line of the commit message.
    public var summary: String
    public var authorName: String
    /// ISO-8601 date string as returned by the API.
    public var date: String

    public init(sha: String, summary: String, authorName: String, date: String) {
        self.sha = sha
        self.summary = summary
        self.authorName = authorName
        self.date = date
    }
}

public struct CodeSearchResult: Sendable {
    public var path: String
    /// Matching text fragments (may be empty).
    public var fragments: [String]

    public init(path: String, fragments: [String]) {
        self.path = path
        self.fragments = fragments
    }
}

public struct PullRequestInfo: Sendable {
    public var number: Int
    public var title: String
    public var state: String
    public var author: String
    public var headSHA: String
    public var headRef: String
    public var baseRef: String

    public init(number: Int, title: String, state: String, author: String,
                headSHA: String, headRef: String, baseRef: String) {
        self.number = number
        self.title = title
        self.state = state
        self.author = author
        self.headSHA = headSHA
        self.headRef = headRef
        self.baseRef = baseRef
    }
}

public struct PullRequestFile: Sendable {
    /// added | modified | removed | renamed | copied | changed | unchanged
    public var status: String
    public var path: String
    public var previousPath: String?
    public var additions: Int
    public var deletions: Int

    public init(status: String, path: String, previousPath: String?, additions: Int, deletions: Int) {
        self.status = status
        self.path = path
        self.previousPath = previousPath
        self.additions = additions
        self.deletions = deletions
    }
}

public enum GitHubClientError: Error, LocalizedError {
    case ghNotFound
    case notAuthenticated
    case notFound(String)
    case commandFailed(command: String, status: Int32, stderr: String)
    case invalidResponse(String)

    public var errorDescription: String? {
        switch self {
        case .ghNotFound:
            return "The GitHub CLI (gh) was not found. Install it and sign in with your existing account."
        case .notAuthenticated:
            return """
            The GitHub CLI is installed but not signed in (or its token is no longer valid). \
            Open Terminal, run “gh auth login”, and try again. \
            GitBrowser never handles GitHub credentials itself.
            """
        case .notFound(let what):
            return "Not found: \(what)"
        case .commandFailed(let command, let status, let stderr):
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return "gh \(command) failed (exit \(status))\(detail.isEmpty ? "" : ": \(detail)")"
        case .invalidResponse(let what):
            return "Unexpected response from GitHub: \(what)"
        }
    }
}
