import WebKit
import XCTest
@testable import GitBrowserCore

final class LocalFolderClientTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitbrowser-local-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("docs/img"), withIntermediateDirectories: true
        )
        try "<h1>hello</h1>".write(to: root.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        try "# Readme".write(to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try "body {}".write(to: root.appendingPathComponent("docs/style.css"), atomically: true, encoding: .utf8)
        try Data([0x89, 0x50]).write(to: root.appendingPathComponent("docs/img/logo.png"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var coords: RepoCoordinates { LocalFolderClient.coordinates(for: root) }

    func testWorkingTreeBasics() async throws {
        let client = LocalFolderClient(rootURL: root)
        XCTAssertFalse(client.isGitRepository)

        let metadata = try await client.fetchMetadata(for: coords)
        XCTAssertEqual(metadata.defaultBranch, LocalFolderClient.workingTreeRef)

        let sha = try await client.resolveCommit(for: coords, ref: nil)
        XCTAssertEqual(sha, LocalFolderClient.workingTreeRef)

        let rootEntries = try await client.listDirectory(for: coords, commit: sha, path: "")
        let names = Set(rootEntries.map(\.name))
        XCTAssertEqual(names, ["index.html", "README.md", "docs"])
        XCTAssertEqual(rootEntries.first { $0.name == "docs" }?.type, .dir)

        let docs = try await client.listDirectory(for: coords, commit: sha, path: "docs")
        XCTAssertEqual(Set(docs.map(\.path)), ["docs/style.css", "docs/img"])

        let bytes = try await client.fetchFile(for: coords, commit: sha, path: "index.html")
        XCTAssertEqual(String(data: bytes, encoding: .utf8), "<h1>hello</h1>")
    }

    func testMissingFileAndDirectoryFetchRejected() async throws {
        let client = LocalFolderClient(rootURL: root)
        let sha = LocalFolderClient.workingTreeRef
        do {
            _ = try await client.fetchFile(for: coords, commit: sha, path: "nope.txt")
            XCTFail("expected notFound")
        } catch GitHubClientError.notFound {}
        do {
            _ = try await client.fetchFile(for: coords, commit: sha, path: "docs")
            XCTFail("directories must not be fetchable as files")
        } catch GitHubClientError.notFound {}
    }

    func testTraversalRejected() async throws {
        let client = LocalFolderClient(rootURL: root)
        let sha = LocalFolderClient.workingTreeRef
        for path in ["../secret", "a/../../b", "/etc/passwd"] {
            do {
                _ = try await client.fetchFile(for: coords, commit: sha, path: path)
                XCTFail("expected rejection for \(path)")
            } catch {}
        }
    }

    func testFullTreeSkipsGitDirectory() async throws {
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".git/objects"), withIntermediateDirectories: true
        )
        try "x".write(to: root.appendingPathComponent(".git/config"), atomically: true, encoding: .utf8)
        let client = LocalFolderClient(rootURL: root)
        let tree = try await client.fullTree(for: coords, commit: LocalFolderClient.workingTreeRef)
        XCTAssertFalse(tree.entries.contains { $0.path.hasPrefix(".git") }, "\(tree.entries.map(\.path))")
        XCTAssertTrue(tree.entries.contains { $0.path == "docs/img/logo.png" })
    }

    func testParseLsTree() {
        let sample = """
        100644 blob 8baef1b4abc478178b004d62031cf7fe6db6f903     130\tREADME.md
        040000 tree fcf0be4d7e45f0ebcfefbc9c95392bb14a268f57       -\tdocs
        120000 blob 47c1f9d1b26af1c58d5915a24a3b8b17a862348a      19\tlink-to-thing
        """
        let items = LocalFolderClient.parseLsTree(Data(sample.utf8))
        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(items[0].type, .file)
        XCTAssertEqual(items[0].size, 130)
        XCTAssertEqual(items[1].type, .dir)
        XCTAssertEqual(items[2].type, .symlink)
    }

    // MARK: - Git-backed refs

    /// Sets up a real git repo, commits one version, edits the working tree,
    /// and verifies both states are served from the right "commit".
    func testGitRefsServeCommittedStateWhileWorkingTreeServesDisk() async throws {
        let git = URL(fileURLWithPath: "/usr/bin/git")
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: git.path), "git not available")

        func run(_ args: [String]) async throws {
            let result = try await ProcessRunner.run(executable: git, arguments: ["-C", root.path] + args)
            XCTAssertEqual(result.status, 0, result.stderrText)
        }
        try await run(["init", "-q", "-b", "main"])
        try await run(["config", "user.email", "t@example.com"])
        try await run(["config", "user.name", "Test"])
        try await run(["add", "."])
        try await run(["commit", "-q", "-m", "first version"])

        // Edit the working tree after the commit.
        try "<h1>edited</h1>".write(to: root.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)

        let client = LocalFolderClient(rootURL: root)
        XCTAssertTrue(client.isGitRepository)

        let metadata = try await client.fetchMetadata(for: coords)
        XCTAssertEqual(metadata.defaultBranch, "main")

        // Working tree serves the edited file.
        let workingBytes = try await client.fetchFile(
            for: coords, commit: LocalFolderClient.workingTreeRef, path: "index.html"
        )
        XCTAssertEqual(String(data: workingBytes, encoding: .utf8), "<h1>edited</h1>")

        // The commit serves the original.
        let sha = try await client.resolveCommit(for: coords, ref: "main")
        XCTAssertEqual(sha.count, 40)
        let committedBytes = try await client.fetchFile(for: coords, commit: sha, path: "index.html")
        XCTAssertEqual(String(data: committedBytes, encoding: .utf8), "<h1>hello</h1>")

        // Committed directory listing and full tree.
        let entries = try await client.listDirectory(for: coords, commit: sha, path: "docs")
        XCTAssertTrue(entries.contains { $0.path == "docs/style.css" })
        let tree = try await client.fullTree(for: coords, commit: sha)
        XCTAssertTrue(tree.entries.contains { $0.path == "docs/img/logo.png" })

        // Branches and per-file history.
        let branches = try await client.listBranches(for: coords)
        XCTAssertTrue(branches.contains("main"))
        let history = try await client.fileHistory(
            for: coords, ref: LocalFolderClient.workingTreeRef, path: "index.html"
        )
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history[0].summary, "first version")
        XCTAssertEqual(history[0].sha, sha)
    }

    /// End to end: a session + scheme handler over a local working tree, with
    /// caching disabled so on-disk edits appear on the next request.
    @MainActor
    func testSchemeHandlerServesLocalWorkingTreeWithoutStaleCache() async throws {
        let client = LocalFolderClient(rootURL: root)
        let registry = RepoSessionRegistry()
        let session = try await RepoSession.open(
            client: client, coordinates: coords, ref: nil, cachesData: false
        )
        registry.register(session)
        let handler = RepoSchemeHandler(registry: registry)
        let webView = WKWebView()

        func request(_ path: String) async -> FakeSchemeTask {
            let task = FakeSchemeTask(url: URL(string: "repobrowser://\(session.id)/\(path)")!)
            handler.webView(webView, start: task)
            await fulfillment(of: [task.completion], timeout: 10)
            return task
        }

        let first = await request("index.html")
        XCTAssertEqual(first.httpResponse?.statusCode, 200)
        XCTAssertTrue(first.bodyText.contains("hello"))

        try "<h1>changed</h1>".write(to: root.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        let second = await request("index.html")
        XCTAssertTrue(second.bodyText.contains("changed"),
                      "working-tree sessions must not serve stale cached bytes")
    }
}
