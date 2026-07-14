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
}
