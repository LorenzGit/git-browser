import Foundation
@testable import GitBrowserCore

/// In-memory GitHubClient double that records every remote interaction.
///
/// Files with `data == nil` simulate multi-gigabyte assets: any attempt to
/// fetch one throws `hugeAssetTouched`, so a test fails immediately if the
/// implementation tries to materialize them.
final class MockGitHubClient: GitHubClient, @unchecked Sendable {
    struct StoredFile {
        var data: Data?
        var declaredSize: Int64

        static func small(_ text: String) -> StoredFile {
            let d = Data(text.utf8)
            return StoredFile(data: d, declaredSize: Int64(d.count))
        }

        static func bytes(_ data: Data) -> StoredFile {
            StoredFile(data: data, declaredSize: Int64(data.count))
        }

        static func huge(gigabytes: Int64) -> StoredFile {
            StoredFile(data: nil, declaredSize: gigabytes * 1_000_000_000)
        }
    }

    enum MockError: Error, LocalizedError {
        case hugeAssetTouched(String)

        var errorDescription: String? {
            switch self {
            case .hugeAssetTouched(let path):
                return "EFFICIENCY VIOLATION: fetched simulated multi-GB asset '\(path)'"
            }
        }
    }

    let coordinates: RepoCoordinates
    let commit: String
    private(set) var files: [String: StoredFile]
    /// path → immediate children, precomputed from the file map.
    private let directoryIndex: [String: [DirEntry]]

    var artificialDelayNanoseconds: UInt64 = 0

    private let lock = NSLock()
    private(set) var fetchedFilePaths: [String] = []
    private(set) var listedDirectoryPaths: [String] = []
    private(set) var metadataFetchCount = 0
    private(set) var resolveCount = 0
    private(set) var bytesServed = 0

    init(
        coordinates: RepoCoordinates = RepoCoordinates(host: "github.com", owner: "acme", repo: "fixture"),
        commit: String = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        files: [String: StoredFile]
    ) {
        self.coordinates = coordinates
        self.commit = commit
        self.files = files
        self.directoryIndex = Self.buildDirectoryIndex(files: files)
    }

    private static func buildDirectoryIndex(files: [String: StoredFile]) -> [String: [DirEntry]] {
        var dirs: [String: [String: DirEntry]] = ["": [:]]
        for (path, file) in files {
            let components = path.split(separator: "/").map(String.init)
            var parent = ""
            for (i, component) in components.enumerated() {
                let childPath = parent.isEmpty ? component : parent + "/" + component
                let isLeaf = i == components.count - 1
                let entry = DirEntry(
                    name: component,
                    path: childPath,
                    type: isLeaf ? .file : .dir,
                    size: isLeaf ? file.declaredSize : 0
                )
                dirs[parent, default: [:]][childPath] = entry
                if !isLeaf, dirs[childPath] == nil { dirs[childPath] = [:] }
                parent = childPath
            }
        }
        return dirs.mapValues { Array($0.values) }
    }

    // MARK: - Recorded views for assertions

    var fetchedSet: Set<String> {
        lock.lock(); defer { lock.unlock() }
        return Set(fetchedFilePaths)
    }

    var listedSet: Set<String> {
        lock.lock(); defer { lock.unlock() }
        return Set(listedDirectoryPaths)
    }

    var totalBytesServed: Int {
        lock.lock(); defer { lock.unlock() }
        return bytesServed
    }

    var fileFetchCount: Int {
        lock.lock(); defer { lock.unlock() }
        return fetchedFilePaths.count
    }

    // MARK: - GitHubClient

    func fetchMetadata(for repo: RepoCoordinates) async throws -> RepoMetadata {
        lock.lock(); metadataFetchCount += 1; lock.unlock()
        return RepoMetadata(
            fullName: repo.displayName, defaultBranch: "main",
            description: "fixture repo", isPrivate: false
        )
    }

    func resolveCommit(for repo: RepoCoordinates, ref: String?) async throws -> String {
        lock.lock(); resolveCount += 1; lock.unlock()
        return commit
    }

    func listDirectory(for repo: RepoCoordinates, commit: String, path: String) async throws -> [DirEntry] {
        lock.lock(); listedDirectoryPaths.append(path); lock.unlock()
        if artificialDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: artificialDelayNanoseconds)
        }
        guard let entries = directoryIndex[path] else {
            throw GitHubClientError.notFound(path)
        }
        return entries
    }

    func fetchFile(for repo: RepoCoordinates, commit: String, path: String) async throws -> Data {
        lock.lock(); fetchedFilePaths.append(path); lock.unlock()
        if artificialDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: artificialDelayNanoseconds)
        }
        guard let file = files[path] else {
            throw GitHubClientError.notFound(path)
        }
        guard let data = file.data else {
            throw MockError.hugeAssetTouched(path)
        }
        lock.lock(); bytesServed += data.count; lock.unlock()
        return data
    }
}

// MARK: - Session helper

extension MockGitHubClient {
    /// Opens a session against this mock and registers it, returning both.
    func openSession(registry: RepoSessionRegistry) async throws -> RepoSession {
        let session = try await RepoSession.open(client: self, coordinates: coordinates, ref: nil)
        registry.register(session)
        return session
    }
}

// MARK: - The required efficiency fixture

enum EfficiencyFixture {
    static let htmlPath = "site/index.html"
    static let cssPath = "site/style.css"
    static let jsPath = "site/app.js"

    /// One small HTML file, two small dependencies, ten thousand unrelated
    /// files, and several simulated multi-gigabyte unrelated assets.
    static func build() -> MockGitHubClient {
        var files: [String: MockGitHubClient.StoredFile] = [:]

        files[htmlPath] = .small("""
        <!DOCTYPE html>
        <html><head>
        <meta charset="utf-8">
        <link rel="stylesheet" href="style.css">
        <script defer src="app.js"></script>
        <title>fixture</title>
        </head><body><h1 id="h">hello</h1></body></html>
        """)
        files[cssPath] = .small("h1 { color: rebeccapurple; }")
        files[jsPath] = .small("document.title = 'fixture-js-ran';")

        // Ten thousand unrelated files spread over 100 directories.
        for dir in 0..<100 {
            for file in 0..<100 {
                files["unrelated/dir\(String(format: "%03d", dir))/file\(String(format: "%03d", file)).txt"] =
                    .small("unrelated \(dir)/\(file)")
            }
        }

        // Several simulated multi-gigabyte assets. Fetching any of these throws.
        files["bulk/dataset-a.bin"] = .huge(gigabytes: 4)
        files["bulk/dataset-b.bin"] = .huge(gigabytes: 9)
        files["bulk/video-master.mov"] = .huge(gigabytes: 22)
        files["bulk/archive.tar"] = .huge(gigabytes: 3)

        return MockGitHubClient(files: files)
    }
}
