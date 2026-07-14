import XCTest
@testable import GitBrowserCore

/// Stub with configurable branches and per-commit file lists, for exercising
/// bookmark fallback behavior.
private final class BookmarkStubClient: GitHubClient, @unchecked Sendable {
    var defaultBranchSHA: String
    var refs: [String: String]
    var filesByCommit: [String: Set<String>]

    init(defaultBranchSHA: String, refs: [String: String], filesByCommit: [String: Set<String>]) {
        self.defaultBranchSHA = defaultBranchSHA
        self.refs = refs
        self.filesByCommit = filesByCommit
    }

    func fetchMetadata(for repo: RepoCoordinates) async throws -> RepoMetadata {
        RepoMetadata(fullName: repo.displayName, defaultBranch: "main", description: nil, isPrivate: false)
    }

    func resolveCommit(for repo: RepoCoordinates, ref: String?) async throws -> String {
        guard let ref, !ref.isEmpty else { return defaultBranchSHA }
        guard let sha = refs[ref] else { throw GitHubClientError.notFound(ref) }
        return sha
    }

    func listDirectory(for repo: RepoCoordinates, commit: String, path: String) async throws -> [DirEntry] {
        guard let files = filesByCommit[commit] else { throw GitHubClientError.notFound(commit) }
        return files
            .filter { RepoPath.parentDirectory(of: $0) == path }
            .map { DirEntry(name: RepoPath.fileName(of: $0), path: $0, type: .file, size: 1) }
    }

    func fetchFile(for repo: RepoCoordinates, commit: String, path: String) async throws -> Data {
        throw GitHubClientError.notFound(path)
    }
}

final class BookmarkResolverTests: XCTestCase {
    private let coords = RepoCoordinates(host: "github.com", owner: "acme", repo: "x")

    private func bookmark(ref: String?, path: String?) -> Bookmark {
        Bookmark(name: "b", location: .remote(coords), ref: ref, path: path)
    }

    func testIntactBranchAndFileOpenAsBookmarked() async {
        let client = BookmarkStubClient(
            defaultBranchSHA: "MAIN",
            refs: ["feature": "FEAT"],
            filesByCommit: ["FEAT": ["docs/page.html"], "MAIN": []]
        )
        let res = await BookmarkResolver.resolve(
            bookmark: bookmark(ref: "feature", path: "docs/page.html"),
            client: client, coordinates: coords
        )
        XCTAssertEqual(res, BookmarkResolution(
            ref: "feature", path: "docs/page.html", branchFellBack: false, fileMissing: false
        ))
    }

    func testDeletedBranchFallsBackToDefault() async {
        let client = BookmarkStubClient(
            defaultBranchSHA: "MAIN",
            refs: [:], // "feature" no longer exists
            filesByCommit: ["MAIN": ["docs/page.html"]]
        )
        let res = await BookmarkResolver.resolve(
            bookmark: bookmark(ref: "feature", path: "docs/page.html"),
            client: client, coordinates: coords
        )
        XCTAssertEqual(res, BookmarkResolution(
            ref: nil, path: "docs/page.html", branchFellBack: true, fileMissing: false
        ))
    }

    func testFileGoneOnBranchButPresentOnDefaultFallsBack() async {
        let client = BookmarkStubClient(
            defaultBranchSHA: "MAIN",
            refs: ["feature": "FEAT"],
            filesByCommit: ["FEAT": ["other.txt"], "MAIN": ["docs/page.html"]]
        )
        let res = await BookmarkResolver.resolve(
            bookmark: bookmark(ref: "feature", path: "docs/page.html"),
            client: client, coordinates: coords
        )
        XCTAssertEqual(res, BookmarkResolution(
            ref: nil, path: "docs/page.html", branchFellBack: true, fileMissing: false
        ))
    }

    func testFileGoneEverywhereKeepsBranchDropsFile() async {
        let client = BookmarkStubClient(
            defaultBranchSHA: "MAIN",
            refs: ["feature": "FEAT"],
            filesByCommit: ["FEAT": [], "MAIN": []]
        )
        let res = await BookmarkResolver.resolve(
            bookmark: bookmark(ref: "feature", path: "docs/page.html"),
            client: client, coordinates: coords
        )
        XCTAssertEqual(res, BookmarkResolution(
            ref: "feature", path: nil, branchFellBack: false, fileMissing: true
        ))
    }

    func testDeletedBranchNoPath() async {
        let client = BookmarkStubClient(defaultBranchSHA: "MAIN", refs: [:], filesByCommit: ["MAIN": []])
        let res = await BookmarkResolver.resolve(
            bookmark: bookmark(ref: "gone", path: nil), client: client, coordinates: coords
        )
        XCTAssertEqual(res, BookmarkResolution(
            ref: nil, path: nil, branchFellBack: true, fileMissing: false
        ))
    }

    func testDefaultBranchBookmarkWithMissingFile() async {
        let client = BookmarkStubClient(defaultBranchSHA: "MAIN", refs: [:], filesByCommit: ["MAIN": []])
        let res = await BookmarkResolver.resolve(
            bookmark: bookmark(ref: nil, path: "gone.md"), client: client, coordinates: coords
        )
        XCTAssertEqual(res, BookmarkResolution(
            ref: nil, path: nil, branchFellBack: false, fileMissing: true
        ))
    }
}

final class BookmarkStoreTests: XCTestCase {
    private var store: BookmarkStore!
    private var suiteName: String!

    override func setUp() {
        suiteName = "gitbrowser-tests-\(UUID().uuidString)"
        store = BookmarkStore(defaults: UserDefaults(suiteName: suiteName)!)
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suiteName)
    }

    func testAddUpdateRemoveRoundtrip() {
        let coords = RepoCoordinates(host: "github.com", owner: "a", repo: "b")
        let bookmark = Bookmark(name: "Docs", location: .remote(coords), ref: "dev", path: "docs/index.html")
        store.add(bookmark)
        XCTAssertEqual(store.all(), [bookmark])

        var renamed = bookmark
        renamed.name = "Docs (dev)"
        renamed.ref = nil
        store.update(renamed)
        XCTAssertEqual(store.all(), [renamed])
        XCTAssertEqual(store.bookmark(id: bookmark.id)?.name, "Docs (dev)")

        store.remove(id: bookmark.id)
        XCTAssertEqual(store.all(), [])
    }

    func testLocalLocationRoundtrip() {
        let bookmark = Bookmark(name: "Site", location: .local(path: "/tmp/site"), ref: "main", path: "index.html")
        store.add(bookmark)
        let loaded = store.all().first
        XCTAssertEqual(loaded, bookmark)
        if case .local(let path) = loaded!.location {
            XCTAssertEqual(path, "/tmp/site")
        } else {
            XCTFail("expected local location")
        }
    }

    func testOrderPreserved() {
        for index in 0..<5 {
            store.add(Bookmark(name: "b\(index)", location: .local(path: "/tmp/\(index)")))
        }
        XCTAssertEqual(store.all().map(\.name), ["b0", "b1", "b2", "b3", "b4"])
    }
}
