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
