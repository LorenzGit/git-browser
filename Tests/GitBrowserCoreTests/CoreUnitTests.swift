import XCTest
@testable import GitBrowserCore

final class GitHubRepoURLParserTests: XCTestCase {
    func testPlainRepoURL() {
        let p = GitHubRepoURLParser.parse("https://github.com/apple/swift")
        XCTAssertEqual(p, ParsedRepoURL(coordinates: .init(host: "github.com", owner: "apple", repo: "swift")))
    }

    func testDotGitSuffixAndTrailingSlash() {
        let p = GitHubRepoURLParser.parse("https://github.com/apple/swift.git/")
        XCTAssertEqual(p?.coordinates.repo, "swift")
    }

    func testTreeURLWithBranchAndPath() {
        let p = GitHubRepoURLParser.parse("https://github.com/apple/swift/tree/release/utils/build")
        XCTAssertEqual(p?.ref, "release")
        XCTAssertEqual(p?.initialPath, "utils/build")
    }

    func testBlobURL() {
        let p = GitHubRepoURLParser.parse("https://github.com/apple/swift/blob/main/README.md")
        XCTAssertEqual(p?.ref, "main")
        XCTAssertEqual(p?.initialPath, "README.md")
    }

    func testCommitSHARef() {
        let p = GitHubRepoURLParser.parse("github.com/o/r/tree/0123abc")
        XCTAssertEqual(p?.ref, "0123abc")
        XCTAssertNil(p?.initialPath)
    }

    func testShorthand() {
        let p = GitHubRepoURLParser.parse("apple/swift")
        XCTAssertEqual(p?.coordinates, .init(host: "github.com", owner: "apple", repo: "swift"))
    }

    func testEnterpriseHost() {
        let p = GitHubRepoURLParser.parse("https://github.example.corp/team/tool/blob/dev/docs/a.html")
        XCTAssertEqual(p?.coordinates.host, "github.example.corp")
        XCTAssertEqual(p?.ref, "dev")
        XCTAssertEqual(p?.initialPath, "docs/a.html")
    }

    func testSSHForm() {
        let p = GitHubRepoURLParser.parse("git@github.com:apple/swift.git")
        XCTAssertEqual(p?.coordinates, .init(host: "github.com", owner: "apple", repo: "swift"))
    }

    func testQueryAndFragmentIgnored() {
        let p = GitHubRepoURLParser.parse("https://github.com/a/b/tree/main/docs?tab=readme#x")
        XCTAssertEqual(p?.initialPath, "docs")
    }

    func testRejectsGarbage() {
        XCTAssertNil(GitHubRepoURLParser.parse(""))
        XCTAssertNil(GitHubRepoURLParser.parse("not a url"))
        XCTAssertNil(GitHubRepoURLParser.parse("https://github.com/onlyowner"))
        XCTAssertNil(GitHubRepoURLParser.parse("ftp://github.com/a/b"))
    }

    func testHostCaseNormalized() {
        let p = GitHubRepoURLParser.parse("https://GitHub.COM/Apple/Swift")
        XCTAssertEqual(p?.coordinates.host, "github.com")
        XCTAssertEqual(p?.coordinates.owner, "Apple") // owners stay case-preserved
    }
}

final class RepoPathTests: XCTestCase {
    func testBasicNormalization() {
        XCTAssertEqual(RepoPath.normalize("a/b/c.txt"), "a/b/c.txt")
        XCTAssertEqual(RepoPath.normalize("/a//b/"), "a/b")
        XCTAssertEqual(RepoPath.normalize("./a/./b"), "a/b")
        XCTAssertEqual(RepoPath.normalize(""), "")
    }

    func testDotDotWithinRoot() {
        XCTAssertEqual(RepoPath.normalize("a/b/../c"), "a/c")
        XCTAssertEqual(RepoPath.normalize("a/.."), "")
    }

    func testEscapeAttemptsRejected() {
        XCTAssertNil(RepoPath.normalize(".."))
        XCTAssertNil(RepoPath.normalize("../etc/passwd"))
        XCTAssertNil(RepoPath.normalize("a/../../b"))
        XCTAssertNil(RepoPath.normalize("a/b/../../../c"))
        XCTAssertNil(RepoPath.normalize("a\\b"))
        XCTAssertNil(RepoPath.normalize("a\0b"))
    }

    func testPercentEncodedTraversalRejected() {
        // %2e%2e = ".."
        XCTAssertNil(RepoPath.normalizeURLPath("/%2e%2e/%2e%2e/secret"))
        XCTAssertEqual(RepoPath.normalizeURLPath("/docs/%20file.txt"), "docs/ file.txt")
    }

    func testResolveRelative() {
        XCTAssertEqual(RepoPath.resolve(relative: "img/a.png", against: "docs/page.md"), "docs/img/a.png")
        XCTAssertEqual(RepoPath.resolve(relative: "../top.md", against: "docs/page.md"), "top.md")
        XCTAssertEqual(RepoPath.resolve(relative: "/root.css", against: "docs/deep/page.md"), "root.css")
        XCTAssertNil(RepoPath.resolve(relative: "../../escape", against: "docs/page.md"))
    }

    func testExtensionAndFileName() {
        XCTAssertEqual(RepoPath.fileExtension(of: "a/b/Read.Me.HTML"), "html")
        XCTAssertEqual(RepoPath.fileExtension(of: "a/.gitignore"), "")
        XCTAssertEqual(RepoPath.fileName(of: "a/b/c.txt"), "c.txt")
        XCTAssertEqual(RepoPath.parentDirectory(of: "a/b/c.txt"), "a/b")
        XCTAssertEqual(RepoPath.parentDirectory(of: "c.txt"), "")
    }
}

final class MIMETypeTests: XCTestCase {
    func testWebCriticalTypes() {
        XCTAssertEqual(MIMEType.resolve(forPath: "x/index.html").type, "text/html")
        XCTAssertEqual(MIMEType.resolve(forPath: "s.css").type, "text/css")
        XCTAssertEqual(MIMEType.resolve(forPath: "app.js").type, "text/javascript")
        XCTAssertEqual(MIMEType.resolve(forPath: "mod.mjs").type, "text/javascript")
        XCTAssertEqual(MIMEType.resolve(forPath: "d.json").type, "application/json")
        XCTAssertEqual(MIMEType.resolve(forPath: "p.wasm").type, "application/wasm")
        XCTAssertEqual(MIMEType.resolve(forPath: "i.svg").type, "image/svg+xml")
    }

    func testTextEncodingOnlyForText() {
        XCTAssertEqual(MIMEType.resolve(forPath: "a.html").textEncoding, "utf-8")
        XCTAssertNil(MIMEType.resolve(forPath: "a.png").textEncoding)
        XCTAssertNil(MIMEType.resolve(forPath: "a.woff2").textEncoding)
    }

    func testSourceAndUnknown() {
        XCTAssertEqual(MIMEType.resolve(forPath: "main.swift").type, "text/plain")
        XCTAssertEqual(MIMEType.resolve(forPath: "LICENSE").type, "text/plain")
        XCTAssertEqual(MIMEType.resolve(forPath: "blob.xyzunknown").type, "application/octet-stream")
    }
}

final class LRUByteCacheTests: XCTestCase {
    func testStoresAndRetrieves() {
        let cache = LRUByteCache(maxTotalBytes: 100, maxEntryBytes: 50)
        cache.setValue(Data(repeating: 1, count: 10), forKey: "a")
        XCTAssertEqual(cache.value(forKey: "a")?.count, 10)
        XCTAssertNil(cache.value(forKey: "missing"))
    }

    func testEvictsLeastRecentlyUsed() {
        let cache = LRUByteCache(maxTotalBytes: 100, maxEntryBytes: 100)
        cache.setValue(Data(repeating: 0, count: 40), forKey: "a")
        cache.setValue(Data(repeating: 0, count: 40), forKey: "b")
        _ = cache.value(forKey: "a") // a is now most recent
        cache.setValue(Data(repeating: 0, count: 40), forKey: "c") // evicts b
        XCTAssertNotNil(cache.value(forKey: "a"))
        XCTAssertNil(cache.value(forKey: "b"))
        XCTAssertNotNil(cache.value(forKey: "c"))
        XCTAssertLessThanOrEqual(cache.currentBytes, 100)
    }

    func testOversizedEntryNotCached() {
        let cache = LRUByteCache(maxTotalBytes: 100, maxEntryBytes: 10)
        cache.setValue(Data(repeating: 0, count: 50), forKey: "big")
        XCTAssertNil(cache.value(forKey: "big"))
        XCTAssertEqual(cache.currentBytes, 0)
    }

    func testReplaceUpdatesCost() {
        let cache = LRUByteCache(maxTotalBytes: 100, maxEntryBytes: 100)
        cache.setValue(Data(repeating: 0, count: 60), forKey: "a")
        cache.setValue(Data(repeating: 0, count: 10), forKey: "a")
        XCTAssertEqual(cache.currentBytes, 10)
        XCTAssertEqual(cache.count, 1)
    }
}

final class MarkdownRendererTests: XCTestCase {
    func testHeadingWithAnchor() {
        let html = MarkdownRenderer.renderBody(markdown: "## Hello World")
        XCTAssertTrue(html.contains("<h2 id=\"hello-world\">Hello World</h2>"))
    }

    func testRelativeLinkAndImagePreserved() {
        let html = MarkdownRenderer.renderBody(markdown: "See [docs](docs/guide.md) and ![logo](assets/logo.png)")
        XCTAssertTrue(html.contains("<a href=\"docs/guide.md\">docs</a>"), html)
        XCTAssertTrue(html.contains("<img src=\"assets/logo.png\" alt=\"logo\">"), html)
    }

    func testRawHTMLIsEscaped() {
        let html = MarkdownRenderer.renderBody(markdown: "hello <script>alert(1)</script>")
        XCTAssertFalse(html.contains("<script>"))
        XCTAssertTrue(html.contains("&lt;script&gt;"))
    }

    func testFencedCodeBlockEscapes() {
        let html = MarkdownRenderer.renderBody(markdown: "```html\n<b>x</b>\n```")
        XCTAssertTrue(html.contains("<pre><code class=\"language-html\">&lt;b&gt;x&lt;/b&gt;</code></pre>"), html)
    }

    func testInlineCodeNotStyled() {
        let html = MarkdownRenderer.renderBody(markdown: "use `**not bold**` here")
        XCTAssertTrue(html.contains("<code>**not bold**</code>"), html)
    }

    func testEmphasisAndStrikethrough() {
        let html = MarkdownRenderer.renderBody(markdown: "**bold** and *it* and ~~gone~~")
        XCTAssertTrue(html.contains("<strong>bold</strong>"))
        XCTAssertTrue(html.contains("<em>it</em>"))
        XCTAssertTrue(html.contains("<del>gone</del>"))
    }

    func testLists() {
        let html = MarkdownRenderer.renderBody(markdown: "- one\n- two\n\n1. first\n2. second")
        XCTAssertTrue(html.contains("<ul>"))
        XCTAssertTrue(html.contains("<li>one</li>"))
        XCTAssertTrue(html.contains("<ol>"))
        XCTAssertTrue(html.contains("<li>second</li>"))
    }

    func testTable() {
        let html = MarkdownRenderer.renderBody(markdown: "| a | b |\n|---|---|\n| 1 | 2 |")
        XCTAssertTrue(html.contains("<th>a</th>"), html)
        XCTAssertTrue(html.contains("<td>2</td>"), html)
    }

    func testBlockquoteAndRule() {
        let html = MarkdownRenderer.renderBody(markdown: "> quoted\n\n---")
        XCTAssertTrue(html.contains("<blockquote>"))
        XCTAssertTrue(html.contains("<hr>"))
    }
}

final class PreviewRouterTests: XCTestCase {
    func testRouting() {
        XCTAssertEqual(PreviewRouter.kind(forPath: "a/b.html"), .html)
        XCTAssertEqual(PreviewRouter.kind(forPath: "README.md"), .markdown)
        XCTAssertEqual(PreviewRouter.kind(forPath: "src/main.swift"), .code)
        XCTAssertEqual(PreviewRouter.kind(forPath: "img/x.png"), .image)
        XCTAssertEqual(PreviewRouter.kind(forPath: "v/clip.mp4"), .media)
        XCTAssertEqual(PreviewRouter.kind(forPath: "doc.pdf"), .pdf)
        XCTAssertEqual(PreviewRouter.kind(forPath: "Makefile"), .code)
    }
}

final class RepoSessionTests: XCTestCase {
    func testOpenFetchesOnlyMetadataAndCommit() async throws {
        let mock = EfficiencyFixture.build()
        _ = try await RepoSession.open(client: mock, coordinates: mock.coordinates, ref: nil)
        XCTAssertEqual(mock.metadataFetchCount, 1)
        XCTAssertEqual(mock.resolveCount, 1)
        XCTAssertTrue(mock.listedSet.isEmpty, "opening a repo must not enumerate anything")
        XCTAssertTrue(mock.fetchedSet.isEmpty)
    }

    func testConcurrentFileRequestsAreDeduplicated() async throws {
        let mock = EfficiencyFixture.build()
        mock.artificialDelayNanoseconds = 50_000_000
        let session = try await RepoSession.open(client: mock, coordinates: mock.coordinates, ref: nil)

        async let a = session.file(at: EfficiencyFixture.htmlPath)
        async let b = session.file(at: EfficiencyFixture.htmlPath)
        async let c = session.file(at: EfficiencyFixture.htmlPath)
        let results = try await [a, b, c]
        XCTAssertEqual(results[0], results[1])
        XCTAssertEqual(results[1], results[2])
        XCTAssertEqual(mock.fileFetchCount, 1, "identical concurrent requests must hit gh once")
    }

    func testFileCacheAvoidsSecondFetch() async throws {
        let mock = EfficiencyFixture.build()
        let session = try await RepoSession.open(client: mock, coordinates: mock.coordinates, ref: nil)
        _ = try await session.file(at: EfficiencyFixture.cssPath)
        _ = try await session.file(at: EfficiencyFixture.cssPath)
        XCTAssertEqual(mock.fileFetchCount, 1)
    }

    func testDirectoryListingCachedPerSession() async throws {
        let mock = EfficiencyFixture.build()
        let session = try await RepoSession.open(client: mock, coordinates: mock.coordinates, ref: nil)
        let first = try await session.directory(at: "")
        let second = try await session.directory(at: "")
        XCTAssertEqual(first.count, second.count)
        XCTAssertEqual(mock.listedDirectoryPaths.count, 1)
    }

    func testRefreshClearsCachesAndReresolves() async throws {
        let mock = EfficiencyFixture.build()
        let session = try await RepoSession.open(client: mock, coordinates: mock.coordinates, ref: nil)
        _ = try await session.directory(at: "")
        _ = try await session.file(at: EfficiencyFixture.cssPath)

        try await session.refresh()
        XCTAssertEqual(mock.resolveCount, 2)

        _ = try await session.directory(at: "")
        _ = try await session.file(at: EfficiencyFixture.cssPath)
        XCTAssertEqual(mock.listedDirectoryPaths.count, 2, "refresh must clear the directory cache")
        XCTAssertEqual(mock.fileFetchCount, 2, "refresh must clear the file cache")
    }

    func testInvalidPathRejected() async throws {
        let mock = EfficiencyFixture.build()
        let session = try await RepoSession.open(client: mock, coordinates: mock.coordinates, ref: nil)
        do {
            _ = try await session.file(at: "../outside")
            XCTFail("expected rejection")
        } catch {}
        XCTAssertEqual(mock.fileFetchCount, 0)
    }
}
