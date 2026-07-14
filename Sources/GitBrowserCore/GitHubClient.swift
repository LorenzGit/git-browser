import Foundation

/// Read-only, on-demand access to a GitHub repository.
///
/// The protocol deliberately exposes only per-file and per-directory
/// operations: there is no way to clone, archive, or bulk-download a
/// repository through it.
public protocol GitHubClient: Sendable {
    func fetchMetadata(for repo: RepoCoordinates) async throws -> RepoMetadata

    /// Resolves a branch, tag, or commit name to a full commit SHA.
    /// `ref == nil` resolves the default branch.
    func resolveCommit(for repo: RepoCoordinates, ref: String?) async throws -> String

    /// Lists the immediate children of one directory. `path` is repo-root
    /// relative; "" is the root. Never recursive.
    func listDirectory(for repo: RepoCoordinates, commit: String, path: String) async throws -> [DirEntry]

    /// Fetches the bytes of a single file at a pinned commit.
    func fetchFile(for repo: RepoCoordinates, commit: String, path: String) async throws -> Data

    // MARK: Metadata-only extras (no file content is ever transferred)

    /// Full recursive path listing at a commit (one API call, paths + sizes
    /// only). Backs the fuzzy file finder.
    func fullTree(for repo: RepoCoordinates, commit: String) async throws -> FullTree

    /// Branch names (first page, up to 100).
    func listBranches(for repo: RepoCoordinates) async throws -> [String]

    /// Tag names (first page, up to 100).
    func listTags(for repo: RepoCoordinates) async throws -> [String]

    /// Server-side code search scoped to one repository (default branch only,
    /// a GitHub code-search limitation).
    func searchCode(for repo: RepoCoordinates, query: String) async throws -> [CodeSearchResult]

    /// Commits that touched one path, newest first.
    func fileHistory(for repo: RepoCoordinates, ref: String, path: String) async throws -> [CommitInfo]

    /// Pull request metadata (head SHA pins the preview session).
    func pullRequest(for repo: RepoCoordinates, number: Int) async throws -> PullRequestInfo

    /// Files changed by a pull request.
    func pullRequestFiles(for repo: RepoCoordinates, number: Int) async throws -> [PullRequestFile]
}

/// Defaults so simple clients (and test doubles) only implement what they use.
public extension GitHubClient {
    func fullTree(for repo: RepoCoordinates, commit: String) async throws -> FullTree {
        throw GitHubClientError.invalidResponse("full tree not supported by this client")
    }

    func listBranches(for repo: RepoCoordinates) async throws -> [String] { [] }

    func listTags(for repo: RepoCoordinates) async throws -> [String] { [] }

    func searchCode(for repo: RepoCoordinates, query: String) async throws -> [CodeSearchResult] {
        throw GitHubClientError.invalidResponse("code search not supported by this client")
    }

    func fileHistory(for repo: RepoCoordinates, ref: String, path: String) async throws -> [CommitInfo] {
        throw GitHubClientError.invalidResponse("file history not supported by this client")
    }

    func pullRequest(for repo: RepoCoordinates, number: Int) async throws -> PullRequestInfo {
        throw GitHubClientError.invalidResponse("pull requests not supported by this client")
    }

    func pullRequestFiles(for repo: RepoCoordinates, number: Int) async throws -> [PullRequestFile] {
        throw GitHubClientError.invalidResponse("pull requests not supported by this client")
    }
}
