import Foundation

/// One open repository, pinned to a single commit.
///
/// Owns the per-session in-memory state: lazily loaded directory listings,
/// a bounded LRU byte cache for small files, and in-flight request
/// deduplication so one page load never fetches the same path twice.
/// Everything is discarded when the session closes; nothing persists to disk.
public actor RepoSession {
    /// Opaque host identifier used in repobrowser:// URLs, e.g. "repo-a81f2c9d".
    public nonisolated let id: String
    public nonisolated let coordinates: RepoCoordinates
    public nonisolated let metadata: RepoMetadata
    /// Branch/tag requested by the user (nil = default branch); re-resolved on refresh.
    public nonisolated let requestedRef: String?

    public private(set) var commitSHA: String

    private let client: GitHubClient
    private var directoryCache: [String: [DirEntry]] = [:]
    private var inflightDirectories: [String: Task<[DirEntry], Error>] = [:]
    private let fileCache: LRUByteCache
    private var inflightFiles: [String: Task<Data, Error>] = [:]
    /// Bumped on refresh so stale in-flight tasks are not cached afterwards.
    private var generation = 0
    /// False for mutable sources (a local working tree), where cached bytes
    /// would go stale the moment the user edits a file.
    private let cachesData: Bool

    public init(
        id: String,
        client: GitHubClient,
        coordinates: RepoCoordinates,
        metadata: RepoMetadata,
        requestedRef: String?,
        commitSHA: String,
        cacheLimitBytes: Int = 64 * 1024 * 1024,
        cachesData: Bool = true
    ) {
        self.id = id
        self.client = client
        self.coordinates = coordinates
        self.metadata = metadata
        self.requestedRef = requestedRef
        self.commitSHA = commitSHA
        self.fileCache = LRUByteCache(maxTotalBytes: cacheLimitBytes)
        self.cachesData = cachesData
    }

    /// Opens a repository: fetches metadata and resolves the requested ref to
    /// a commit SHA. Does not enumerate any repository content.
    public static func open(
        client: GitHubClient,
        coordinates: RepoCoordinates,
        ref: String?,
        cachesData: Bool = true
    ) async throws -> RepoSession {
        let metadata = try await client.fetchMetadata(for: coordinates)
        let sha = try await client.resolveCommit(for: coordinates, ref: ref)
        return RepoSession(
            id: Self.makeSessionID(),
            client: client,
            coordinates: coordinates,
            metadata: metadata,
            requestedRef: ref,
            commitSHA: sha,
            cachesData: cachesData
        )
    }

    static func makeSessionID() -> String {
        let hex = (0..<8).map { _ in String(format: "%x", Int.random(in: 0...15)) }.joined()
        return "repo-\(hex)"
    }

    // MARK: - Directories

    /// Immediate children of one directory ("" = root). Cached for the session.
    public func directory(at rawPath: String) async throws -> [DirEntry] {
        guard let path = RepoPath.normalize(rawPath) else {
            throw GitHubClientError.notFound(rawPath)
        }
        if cachesData, let cached = directoryCache[path] { return cached }
        if let inflight = inflightDirectories[path] {
            return try await inflight.value
        }
        let gen = generation
        let sha = commitSHA
        let client = self.client
        let coords = coordinates
        let task = Task {
            try await client.listDirectory(for: coords, commit: sha, path: path)
        }
        inflightDirectories[path] = task
        defer { inflightDirectories[path] = nil }
        do {
            let entries = try await task.value
            if generation == gen, cachesData {
                directoryCache[path] = entries
            }
            return entries
        } catch {
            throw error
        }
    }

    // MARK: - Files

    /// Bytes of a single file, deduplicated across concurrent requests and
    /// served from the bounded in-memory cache when possible.
    public func file(at rawPath: String) async throws -> Data {
        guard let path = RepoPath.normalize(rawPath), !path.isEmpty else {
            throw GitHubClientError.notFound(rawPath)
        }
        if cachesData, let cached = fileCache.value(forKey: path) {
            return cached
        }
        if let inflight = inflightFiles[path] {
            return try await inflight.value
        }
        let gen = generation
        let sha = commitSHA
        let client = self.client
        let coords = coordinates
        let task = Task {
            try await client.fetchFile(for: coords, commit: sha, path: path)
        }
        inflightFiles[path] = task
        defer { inflightFiles[path] = nil }
        let data = try await task.value
        if generation == gen, cachesData {
            fileCache.setValue(data, forKey: path)
        }
        return data
    }

    // MARK: - Refresh / close

    /// Re-resolves the requested ref to its latest commit and clears all
    /// in-memory directory and file data.
    public func refresh() async throws {
        let newSHA = try await client.resolveCommit(for: coordinates, ref: requestedRef)
        generation += 1
        commitSHA = newSHA
        directoryCache.removeAll()
        fileCache.removeAll()
        inflightFiles.removeAll()
        inflightDirectories.removeAll()
    }

    /// Drops all in-memory state. Called when the repository session closes.
    public func close() {
        generation += 1
        directoryCache.removeAll()
        fileCache.removeAll()
        inflightFiles.removeAll()
        inflightDirectories.removeAll()
    }
}
