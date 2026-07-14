import WebKit
import XCTest
@testable import GitBrowserCore

/// Records what the scheme handler reports for one request.
final class FakeSchemeTask: NSObject, WKURLSchemeTask {
    let request: URLRequest
    private(set) var response: URLResponse?
    private(set) var body = Data()
    private(set) var finished = false
    private(set) var error: Error?
    let completion = XCTestExpectation(description: "scheme task completed")

    init(url: URL) {
        request = URLRequest(url: url)
    }

    func didReceive(_ response: URLResponse) { self.response = response }
    func didReceive(_ data: Data) { body.append(data) }

    func didFinish() {
        finished = true
        completion.fulfill()
    }

    func didFailWithError(_ error: Error) {
        self.error = error
        completion.fulfill()
    }

    var httpResponse: HTTPURLResponse? { response as? HTTPURLResponse }
    var bodyText: String { String(data: body, encoding: .utf8) ?? "" }
}

@MainActor
final class SchemeHandlerTests: XCTestCase {
    private var registry: RepoSessionRegistry!
    private var handler: RepoSchemeHandler!
    private var webView: WKWebView!
    private var mock: MockGitHubClient!
    private var session: RepoSession!

    override func setUp() async throws {
        registry = RepoSessionRegistry()
        handler = RepoSchemeHandler(registry: registry)
        webView = WKWebView()
        mock = EfficiencyFixture.build()
        session = try await mock.openSession(registry: registry)
    }

    private func perform(_ urlString: String) async -> FakeSchemeTask {
        let task = FakeSchemeTask(url: URL(string: urlString)!)
        handler.webView(webView, start: task)
        await fulfillment(of: [task.completion], timeout: 10)
        return task
    }

    func testServesFileWithCorrectHeaders() async throws {
        let task = await perform("repobrowser://\(session.id)/site/style.css")
        XCTAssertEqual(task.httpResponse?.statusCode, 200)
        XCTAssertEqual(
            task.httpResponse?.value(forHTTPHeaderField: "Content-Type"),
            "text/css; charset=utf-8"
        )
        XCTAssertEqual(
            task.httpResponse?.value(forHTTPHeaderField: "Content-Length"),
            String(task.body.count)
        )
        XCTAssertEqual(task.response?.textEncodingName?.lowercased(), "utf-8")
        XCTAssertTrue(task.bodyText.contains("rebeccapurple"))
        XCTAssertTrue(task.finished)
    }

    func testBinaryHasNoCharset() async throws {
        // PNG magic bytes so this is a genuine binary file.
        mock = MockGitHubClient(files: [
            "logo.png": .bytes(Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])),
        ])
        session = try await mock.openSession(registry: registry)
        let task = await perform("repobrowser://\(session.id)/logo.png")
        XCTAssertEqual(task.httpResponse?.value(forHTTPHeaderField: "Content-Type"), "image/png")
        XCTAssertEqual(task.body.count, 8)
    }

    func testMissingFileGivesUseful404() async {
        let task = await perform("repobrowser://\(session.id)/nope/missing.html")
        XCTAssertEqual(task.httpResponse?.statusCode, 404)
        XCTAssertTrue(task.bodyText.contains("nope/missing.html"), "error page should name the path")
        XCTAssertTrue(task.bodyText.contains("acme/fixture"), "error page should name the repo")
    }

    func testUnknownSessionHostGives404() async {
        let task = await perform("repobrowser://repo-doesnotexist/x.html")
        XCTAssertEqual(task.httpResponse?.statusCode, 404)
    }

    func testPathTraversalRejected() async {
        let task = await perform("repobrowser://\(session.id)/../../../etc/passwd")
        XCTAssertEqual(task.httpResponse?.statusCode, 400)
        XCTAssertEqual(mock.fileFetchCount, 0, "traversal must be rejected before any fetch")
    }

    func testEncodedTraversalRejected() async {
        let task = await perform("repobrowser://\(session.id)/%2e%2e/%2e%2e/secret")
        XCTAssertEqual(task.httpResponse?.statusCode, 400)
        XCTAssertEqual(mock.fileFetchCount, 0)
    }

    func testDotDotWithinRootIsServed() async {
        let task = await perform("repobrowser://\(session.id)/site/sub/../style.css")
        XCTAssertEqual(task.httpResponse?.statusCode, 200)
        XCTAssertEqual(mock.fetchedSet, [EfficiencyFixture.cssPath])
    }

    func testRootServesIndexHTML() async throws {
        mock = MockGitHubClient(files: ["index.html": .small("<h1>root</h1>")])
        session = try await mock.openSession(registry: registry)
        let task = await perform("repobrowser://\(session.id)/")
        XCTAssertEqual(task.httpResponse?.statusCode, 200)
        XCTAssertTrue(task.bodyText.contains("root"))
    }

    func testQueryStringIgnoredForFetch() async {
        let task = await perform("repobrowser://\(session.id)/site/app.js?version=42&x=y")
        XCTAssertEqual(task.httpResponse?.statusCode, 200)
        XCTAssertEqual(mock.fetchedSet, [EfficiencyFixture.jsPath])
    }

    func testRenderedMarkdownView() async throws {
        mock = MockGitHubClient(files: [
            "README.md": .small("# Title\n\nSee [guide](docs/guide.md)."),
        ])
        session = try await mock.openSession(registry: registry)

        let raw = await perform("repobrowser://\(session.id)/README.md")
        XCTAssertEqual(raw.httpResponse?.value(forHTTPHeaderField: "Content-Type"), "text/markdown; charset=utf-8")
        XCTAssertTrue(raw.bodyText.hasPrefix("# Title"))

        let rendered = await perform("repobrowser://\(session.id)/README.md?gb-view=rendered")
        XCTAssertEqual(rendered.httpResponse?.value(forHTTPHeaderField: "Content-Type"), "text/html; charset=utf-8")
        XCTAssertTrue(rendered.bodyText.contains("<h1 id=\"title\">Title</h1>"))
        XCTAssertTrue(rendered.bodyText.contains("<a href=\"docs/guide.md\">guide</a>"))
    }

    func testRenderedCodeView() async throws {
        mock = MockGitHubClient(files: [
            "main.swift": .small("let answer = 42 // meaning"),
        ])
        session = try await mock.openSession(registry: registry)
        let rendered = await perform("repobrowser://\(session.id)/main.swift?gb-view=rendered")
        XCTAssertEqual(rendered.httpResponse?.value(forHTTPHeaderField: "Content-Type"), "text/html; charset=utf-8")
        XCTAssertTrue(rendered.bodyText.contains("<span class=\"kw\">let</span>"), rendered.bodyText)
        XCTAssertTrue(rendered.bodyText.contains("<span class=\"num\">42</span>"))
        XCTAssertTrue(rendered.bodyText.contains("<span class=\"com\">// meaning</span>"))
    }

    func testSimultaneousRequestsForSamePathHitGHOnce() async throws {
        mock = EfficiencyFixture.build()
        mock.artificialDelayNanoseconds = 100_000_000
        session = try await mock.openSession(registry: registry)

        let url = URL(string: "repobrowser://\(session.id)/site/app.js")!
        let tasks = (0..<5).map { _ in FakeSchemeTask(url: url) }
        for task in tasks {
            handler.webView(webView, start: task)
        }
        await fulfillment(of: tasks.map(\.completion), timeout: 10)
        for task in tasks {
            XCTAssertEqual(task.httpResponse?.statusCode, 200)
        }
        XCTAssertEqual(mock.fileFetchCount, 1, "in-flight dedup must collapse identical requests")
    }

    func testStoppedTaskReceivesNothing() async throws {
        mock = EfficiencyFixture.build()
        mock.artificialDelayNanoseconds = 200_000_000
        session = try await mock.openSession(registry: registry)

        let task = FakeSchemeTask(url: URL(string: "repobrowser://\(session.id)/site/app.js")!)
        handler.webView(webView, start: task)
        handler.webView(webView, stop: task)
        // Give the fetch time to complete; the handler must stay silent.
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertNil(task.response)
        XCTAssertFalse(task.finished)
        XCTAssertNil(task.error)
    }
}
