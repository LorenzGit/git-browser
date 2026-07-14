import Foundation

/// A saved place: a repository (remote or local folder), optionally pinned to
/// a branch/tag and a file path. Bookmarks store only metadata — never
/// repository content.
public struct Bookmark: Codable, Equatable, Identifiable, Sendable {
    public enum Location: Codable, Equatable, Sendable {
        case remote(RepoCoordinates)
        case local(path: String)
    }

    public var id: UUID
    public var name: String
    public var location: Location
    /// Branch or tag (nil = default branch, or working tree for local folders).
    public var ref: String?
    /// Repo-root-relative file to open (nil = repository root).
    public var path: String?

    public init(id: UUID = UUID(), name: String, location: Location,
                ref: String? = nil, path: String? = nil) {
        self.id = id
        self.name = name
        self.location = location
        self.ref = ref
        self.path = path
    }

    public var locationDescription: String {
        switch location {
        case .remote(let coords): return coords.displayName
        case .local(let path): return (path as NSString).abbreviatingWithTildeInPath
        }
    }
}

/// UserDefaults-backed bookmark list (JSON; metadata only).
public final class BookmarkStore: @unchecked Sendable {
    public static let shared = BookmarkStore()
    public static let changedNotification = Notification.Name("BookmarkStoreChanged")

    private let key = "BookmarksV1"
    private let defaults: UserDefaults
    private let lock = NSLock()

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func all() -> [Bookmark] {
        lock.lock(); defer { lock.unlock() }
        guard let data = defaults.data(forKey: key),
              let list = try? JSONDecoder().decode([Bookmark].self, from: data)
        else { return [] }
        return list
    }

    public func bookmark(id: UUID) -> Bookmark? {
        all().first { $0.id == id }
    }

    public func add(_ bookmark: Bookmark) {
        mutate { $0.append(bookmark) }
    }

    /// Replaces the bookmark with the same id.
    public func update(_ bookmark: Bookmark) {
        mutate { list in
            if let index = list.firstIndex(where: { $0.id == bookmark.id }) {
                list[index] = bookmark
            }
        }
    }

    public func remove(id: UUID) {
        mutate { $0.removeAll { $0.id == id } }
    }

    private func mutate(_ transform: (inout [Bookmark]) -> Void) {
        lock.lock()
        var list: [Bookmark] = []
        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode([Bookmark].self, from: data) {
            list = decoded
        }
        transform(&list)
        if let encoded = try? JSONEncoder().encode(list) {
            defaults.set(encoded, forKey: key)
        }
        lock.unlock()
        NotificationCenter.default.post(name: Self.changedNotification, object: self)
    }
}

/// How a bookmark actually opens after checking that its branch and file
/// still exist.
public struct BookmarkResolution: Equatable, Sendable {
    /// Ref to open with (nil = default branch / working tree).
    public var ref: String?
    /// File to preview (nil when the file is gone everywhere).
    public var path: String?
    /// The bookmarked branch no longer works; the default branch is used.
    public var branchFellBack: Bool
    /// The bookmarked file is gone even on the default branch.
    public var fileMissing: Bool
}

/// Validates a bookmark against the current state of its repository:
/// a deleted branch — or a file that no longer exists on the bookmarked
/// branch — falls back to the default branch.
public enum BookmarkResolver {
    public static func resolve(
        bookmark: Bookmark,
        client: GitHubClient,
        coordinates: RepoCoordinates
    ) async -> BookmarkResolution {
        var ref = bookmark.ref
        var branchFellBack = false

        // 1. Does the bookmarked branch/tag still resolve?
        var sha = try? await client.resolveCommit(for: coordinates, ref: ref)
        if sha == nil, ref != nil {
            ref = nil
            branchFellBack = true
            sha = try? await client.resolveCommit(for: coordinates, ref: nil)
        }
        guard let commit = sha else {
            // Even the default branch failed; let the normal open path
            // surface the error.
            return BookmarkResolution(
                ref: bookmark.ref, path: bookmark.path,
                branchFellBack: false, fileMissing: false
            )
        }

        // 2. Does the bookmarked file still exist at that commit?
        guard let path = bookmark.path, !path.isEmpty else {
            return BookmarkResolution(ref: ref, path: nil, branchFellBack: branchFellBack, fileMissing: false)
        }
        if await entryExists(client: client, coordinates: coordinates, commit: commit, path: path) {
            return BookmarkResolution(ref: ref, path: path, branchFellBack: branchFellBack, fileMissing: false)
        }

        // 3. Missing on the bookmarked branch → try the default branch.
        if ref != nil,
           let defaultSHA = try? await client.resolveCommit(for: coordinates, ref: nil),
           await entryExists(client: client, coordinates: coordinates, commit: defaultSHA, path: path) {
            return BookmarkResolution(ref: nil, path: path, branchFellBack: true, fileMissing: false)
        }

        // 4. Gone everywhere: open the repository (original ref if it still
        //    exists) without a file preview.
        return BookmarkResolution(ref: ref, path: nil, branchFellBack: branchFellBack, fileMissing: true)
    }

    /// One parent-directory listing (metadata only) to check existence.
    private static func entryExists(
        client: GitHubClient, coordinates: RepoCoordinates, commit: String, path: String
    ) async -> Bool {
        let parent = RepoPath.parentDirectory(of: path)
        guard let entries = try? await client.listDirectory(
            for: coordinates, commit: commit, path: parent
        ) else { return false }
        return entries.contains { $0.path == path }
    }
}
