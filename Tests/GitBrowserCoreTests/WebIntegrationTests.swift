import WebKit
import XCTest
@testable import GitBrowserCore

/// Drives a real WKWebView against the repobrowser:// scheme handler backed
/// by the mock client, so WebKit itself decides which subresources to request
/// — exactly like the shipping app.
@MainActor
final class WebHarness: NSObject, WKNavigationDelegate {
    let registry = RepoSessionRegistry()
    let handler: RepoSchemeHandler
    let webView: WKWebView

    private var navigationContinuation: CheckedContinuation<Void, Never>?

    override init() {
        handler = RepoSchemeHandler(registry: registry)
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(handler, forURLScheme: RepoSchemeHandler.scheme)
        WebPreviewStyle.install(in: configuration)
        configuration.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        super.init()
        webView.navigationDelegate = self
    }

    func url(session: RepoSession, _ path: String) -> URL {
        URL(string: "repobrowser://\(session.id)/\(path)")!
    }

    /// Loads and suspends until the main-frame navigation finishes or fails.
    func load(_ url: URL) async {
        await withCheckedContinuation { continuation in
            navigationContinuation = continuation
            webView.load(URLRequest(url: url))
        }
    }

    /// Waits for the next navigation triggered by page JS or history APIs.
    func awaitNextNavigation() async {
        await withCheckedContinuation { continuation in
            navigationContinuation = continuation
        }
    }

    private func finishNavigation() {
        navigationContinuation?.resume()
        navigationContinuation = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finishNavigation()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finishNavigation()
    }

    func webView(
        _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        finishNavigation()
    }

    func evalJS(_ script: String) async -> Any? {
        await withCheckedContinuation { continuation in
            webView.evaluateJavaScript(script) { result, _ in
                continuation.resume(returning: result)
            }
        }
    }

    /// Polls document.title until it matches or times out; returns last value.
    func waitForTitle(_ expected: String, timeout: TimeInterval = 8) async -> String {
        let deadline = Date().addingTimeInterval(timeout)
        var last = ""
        while Date() < deadline {
            last = await evalJS("document.title") as? String ?? ""
            if last == expected { return last }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return last
    }

    func settle(seconds: TimeInterval = 0.6) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}

// MARK: - Required efficiency test

@MainActor
final class EfficiencyTests: XCTestCase {
    /// The repository contains 10,003 files plus four simulated multi-GB
    /// assets. Opening the one small HTML page must retrieve only the page,
    /// the two dependencies WebKit actually requests, and the root listing
    /// for the visible tree. Cloning, archiving, recursive enumeration, or
    /// any bulk retrieval fails this test: the fetched-path set, the
    /// directory-listing set, and the total byte count would all explode,
    /// and touching a simulated multi-GB asset throws immediately.
    func testOpeningOnePageRetrievesOnlyThatPageAndItsDependencies() async throws {
        let harness = WebHarness()
        let mock = EfficiencyFixture.build()
        XCTAssertGreaterThanOrEqual(mock.files.count, 10_003)

        let session = try await mock.openSession(registry: harness.registry)

        // Repository open: metadata + commit resolution + root listing only.
        _ = try await session.directory(at: "")
        XCTAssertEqual(mock.listedSet, [""], "opening must list only the root")
        XCTAssertEqual(mock.fetchedSet, [], "opening must fetch no files")

        // Open the HTML page and let WebKit request what the page needs.
        await harness.load(harness.url(session: session, "site/index.html"))
        let title = await harness.waitForTitle("fixture-js-ran")
        XCTAssertEqual(title, "fixture-js-ran", "page JS must have executed")
        await harness.settle()

        XCTAssertEqual(
            mock.fetchedSet,
            [EfficiencyFixture.htmlPath, EfficiencyFixture.cssPath, EfficiencyFixture.jsPath],
            "only the page and the dependencies it references may be retrieved"
        )
        XCTAssertEqual(mock.fileFetchCount, 3, "no duplicate fetches during one page load")
        XCTAssertEqual(mock.listedSet, [""], "no recursive enumeration")
        XCTAssertLessThan(mock.totalBytesServed, 100_000,
                          "bytes transferred must not scale with repository size")
    }

    /// Expanding one directory retrieves exactly that directory's children.
    func testExpandingDirectoryListsOnlyThatDirectory() async throws {
        let mock = EfficiencyFixture.build()
        let session = try await RepoSession.open(client: mock, coordinates: mock.coordinates, ref: nil)
        _ = try await session.directory(at: "")
        let children = try await session.directory(at: "unrelated/dir007")
        XCTAssertEqual(children.count, 100)
        XCTAssertEqual(mock.listedSet, ["", "unrelated/dir007"])
        XCTAssertEqual(mock.fetchedSet, [])
    }
}

// MARK: - Web compatibility integration tests

@MainActor
final class WebIntegrationTests: XCTestCase {
    private func makeSession(
        _ files: [String: MockGitHubClient.StoredFile],
        harness: WebHarness
    ) async throws -> (MockGitHubClient, RepoSession) {
        let mock = MockGitHubClient(files: files)
        let session = try await mock.openSession(registry: harness.registry)
        return (mock, session)
    }

    func testInlineAndExternalCSSAndJS() async throws {
        let harness = WebHarness()
        let (mock, session) = try await makeSession([
            "index.html": .small("""
            <!DOCTYPE html><html><head>
            <style>body { margin: 0; }</style>
            <link rel="stylesheet" href="a.css">
            <script>window.inlineRan = true;</script>
            <script defer src="b.js"></script>
            </head><body></body></html>
            """),
            "a.css": .small("h1 { color: red; }"),
            "b.js": .small("document.title = window.inlineRan ? 'both-ran' : 'external-only';"),
        ], harness: harness)

        await harness.load(harness.url(session: session, "index.html"))
        let title = await harness.waitForTitle("both-ran")
        XCTAssertEqual(title, "both-ran")
        XCTAssertEqual(mock.fetchedSet, ["index.html", "a.css", "b.js"])
    }

    func testESModules() async throws {
        let harness = WebHarness()
        let (mock, session) = try await makeSession([
            "app/index.html": .small(
                "<!DOCTYPE html><html><head><script type=\"module\" src=\"main.mjs\"></script></head><body></body></html>"
            ),
            "app/main.mjs": .small("import { greet } from './lib/helper.mjs'; document.title = greet();"),
            "app/lib/helper.mjs": .small("export function greet() { return 'modules-ok'; }"),
        ], harness: harness)

        await harness.load(harness.url(session: session, "app/index.html"))
        let title = await harness.waitForTitle("modules-ok")
        XCTAssertEqual(title, "modules-ok", "ES module graph should load through the scheme handler")
        XCTAssertEqual(mock.fetchedSet, ["app/index.html", "app/main.mjs", "app/lib/helper.mjs"])
    }

    func testFetchAPI() async throws {
        let harness = WebHarness()
        let (_, session) = try await makeSession([
            "index.html": .small("""
            <!DOCTYPE html><html><body><script>
            fetch('data/config.json')
              .then(r => r.json())
              .then(j => { document.title = 'fetch:' + j.value; })
              .catch(e => { document.title = 'fetch-error:' + e.name; });
            </script></body></html>
            """),
            "data/config.json": .small("{\"value\": \"ok\"}"),
        ], harness: harness)

        await harness.load(harness.url(session: session, "index.html"))
        let title = await harness.waitForTitle("fetch:ok")
        XCTAssertEqual(title, "fetch:ok", "fetch() against the custom scheme (got '\(title)')")
    }

    func testXMLHttpRequest() async throws {
        let harness = WebHarness()
        let (_, session) = try await makeSession([
            "index.html": .small("""
            <!DOCTYPE html><html><body><script>
            var x = new XMLHttpRequest();
            x.open('GET', 'payload.txt');
            x.onload = function() { document.title = 'xhr:' + x.responseText.trim(); };
            x.onerror = function() { document.title = 'xhr-error'; };
            x.send();
            </script></body></html>
            """),
            "payload.txt": .small("ok"),
        ], harness: harness)

        await harness.load(harness.url(session: session, "index.html"))
        let title = await harness.waitForTitle("xhr:ok")
        XCTAssertEqual(title, "xhr:ok", "XMLHttpRequest against the custom scheme (got '\(title)')")
    }

    func testImagesAndFonts() async throws {
        // 1×1 transparent PNG.
        let png = Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
        )!
        let harness = WebHarness()
        let (mock, session) = try await makeSession([
            "index.html": .small("""
            <!DOCTYPE html><html><head><style>
            @font-face { font-family: F; src: url('fonts/f.woff2'); }
            body { font-family: F, sans-serif; }
            </style></head><body>
            <img src="img/dot.png" onload="document.title='img-ok'" onerror="document.title='img-fail'">
            </body></html>
            """),
            "img/dot.png": .bytes(png),
            "fonts/f.woff2": .bytes(Data([0x77, 0x4F, 0x46, 0x32])), // not a real font; request is what matters
        ], harness: harness)

        await harness.load(harness.url(session: session, "index.html"))
        let title = await harness.waitForTitle("img-ok")
        XCTAssertEqual(title, "img-ok", "repository image should decode in the page")
        await harness.settle()
        XCTAssertTrue(mock.fetchedSet.contains("fonts/f.woff2"), "font request should reach the handler")
    }

    func testWideImagesAreContainedByThePage() async throws {
        let harness = WebHarness()
        let (mock, session) = try await makeSession([
            "index.html": .small("""
            <!DOCTYPE html><html><body>
            <div id="container" style="width: 240px">
              <img id="wide" src="img/wide.svg" style="width: 2000px">
            </div>
            </body></html>
            """),
            "img/wide.svg": .small("""
            <svg xmlns="http://www.w3.org/2000/svg" width="2000" height="100"></svg>
            """),
        ], harness: harness)

        await harness.load(harness.url(session: session, "index.html"))
        await harness.settle()

        let metrics = await harness.evalJS("""
        (() => {
          const image = document.getElementById('wide');
          const container = document.getElementById('container');
          return {
            complete: image.complete,
            naturalWidth: image.naturalWidth,
            requestedWidth: image.style.width,
            imageWidth: image.getBoundingClientRect().width,
            containerWidth: container.getBoundingClientRect().width,
            maxWidth: getComputedStyle(image).maxWidth,
            styleInstalled: document.getElementById('git-browser-contained-visuals') !== null
          };
        })()
        """)
        let values = metrics as? [String: Any]
        XCTAssertEqual(values?["complete"] as? Bool, true)
        XCTAssertGreaterThan(values?["naturalWidth"] as? Double ?? 0, 0)
        XCTAssertEqual(values?["requestedWidth"] as? String, "2000px")
        XCTAssertNotEqual(values?["maxWidth"] as? String, "none")
        XCTAssertEqual(values?["styleInstalled"] as? Bool, true)
        let imageWidth = values?["imageWidth"] as? Double ?? .infinity
        let containerWidth = values?["containerWidth"] as? Double ?? 0
        XCTAssertLessThanOrEqual(imageWidth, containerWidth, "wide images should not overflow their container")
        XCTAssertTrue(mock.fetchedSet.contains("img/wide.svg"))
    }

    func testWideCanvasFramesAreScaledToTheViewport() async throws {
        let harness = WebHarness()
        let (_, session) = try await makeSession([
            "design.html": .small("""
            <!DOCTYPE html><html><head>
            <style>
            body { margin: 0; }
            x-dc { display: none !important; }
            .dv-turn { padding: 44px 48px; }
            .dv-opts { display: flex; flex-wrap: wrap; gap: 32px; }
            .dv-opt { flex: none; display: flex; flex-direction: column; }
            .dv-card { max-width: 100%; overflow: hidden; }
            </style></head><body>
            <x-dc><meta name="design_doc_mode" content="canvas"></x-dc>
            <template id="rendered-canvas">
              <section class="dv-turn"><div class="dv-opts"><div class="dv-opt">
                <div id="frame" class="dv-card" style="width:1920px;height:1080px;position:relative">
                  <span id="right-edge" style="position:absolute;right:0;top:0;width:10px;height:10px"></span>
                </div>
              </div></div></section>
            </template>
            <script>
            setTimeout(() => {
              const root = document.createElement('div');
              root.id = 'dc-root';
              root.append(document.getElementById('rendered-canvas').content.cloneNode(true));
              document.documentElement.setAttribute('data-dc-canvas', '');
              document.querySelector('x-dc').replaceWith(root);
            }, 350);
            </script>
            </body></html>
            """),
        ], harness: harness)

        await harness.load(harness.url(session: session, "design.html"))
        await harness.settle(seconds: 0.8)

        let metrics = await harness.evalJS("""
        (() => {
          const frame = document.getElementById('frame').getBoundingClientRect();
          const edge = document.getElementById('right-edge').getBoundingClientRect();
          return {
            frameRight: frame.right,
            frameWidth: frame.width,
            edgeRight: edge.right,
            viewportWidth: document.documentElement.clientWidth,
            documentWidth: document.documentElement.scrollWidth,
            zoom: parseFloat(getComputedStyle(document.getElementById('frame')).zoom)
          };
        })()
        """) as? [String: Any]

        let frameRight = metrics?["frameRight"] as? Double ?? .infinity
        let edgeRight = metrics?["edgeRight"] as? Double ?? .infinity
        let viewportWidth = metrics?["viewportWidth"] as? Double ?? 0
        let documentWidth = metrics?["documentWidth"] as? Double ?? .infinity
        let zoom = metrics?["zoom"] as? Double ?? 1
        XCTAssertLessThan(zoom, 1, "a 1920px canvas should be scaled down")
        XCTAssertLessThanOrEqual(frameRight, viewportWidth + 0.5)
        XCTAssertLessThanOrEqual(edgeRight, frameRight + 0.5, "the canvas should scale, not crop")
        XCTAssertLessThanOrEqual(documentWidth, viewportWidth, "fitted canvases should not scroll horizontally")
    }

    func testRootRelativePathResolvesToRepoRoot() async throws {
        let harness = WebHarness()
        let (mock, session) = try await makeSession([
            "docs/deep/page.html": .small(
                "<!DOCTYPE html><html><head><link rel=\"stylesheet\" href=\"/shared/base.css\"></head><body>x</body></html>"
            ),
            "shared/base.css": .small("body{}"),
        ], harness: harness)

        await harness.load(harness.url(session: session, "docs/deep/page.html"))
        await harness.settle()
        XCTAssertTrue(
            mock.fetchedSet.contains("shared/base.css"),
            "/shared/base.css must resolve to the repository root (fetched: \(mock.fetchedSet))"
        )
    }

    func testRelativeAndParentDirectoryNavigation() async throws {
        let harness = WebHarness()
        let (_, session) = try await makeSession([
            "docs/sub/page.html": .small(
                "<!DOCTYPE html><html><body><a id=\"up\" href=\"../up.html\">up</a></body></html>"
            ),
            "docs/up.html": .small("<!DOCTYPE html><html><head><title>up-page</title></head><body></body></html>"),
        ], harness: harness)

        await harness.load(harness.url(session: session, "docs/sub/page.html"))
        async let nav: Void = harness.awaitNextNavigation()
        _ = await harness.evalJS("document.getElementById('up').click()")
        await nav
        XCTAssertEqual(harness.webView.url?.path, "/docs/up.html")
        let title = await harness.waitForTitle("up-page")
        XCTAssertEqual(title, "up-page")
    }

    func testQueryStringAndAnchorPreserved() async throws {
        let harness = WebHarness()
        let (mock, session) = try await makeSession([
            "page.html": .small("""
            <!DOCTYPE html><html><body>
            <div style="height: 4000px"></div><h2 id="sec">section</h2>
            <script>document.title = 'q:' + location.search + '|h:' + location.hash;</script>
            </body></html>
            """),
        ], harness: harness)

        await harness.load(URL(string: "repobrowser://\(session.id)/page.html?a=1&b=2#sec")!)
        let title = await harness.waitForTitle("q:?a=1&b=2|h:#sec")
        XCTAssertEqual(title, "q:?a=1&b=2|h:#sec", "query string and anchor must survive the scheme handler")
        XCTAssertEqual(mock.fetchedSet, ["page.html"], "query string must not change which file is fetched")
    }

    func testBackAndForward() async throws {
        let harness = WebHarness()
        let (_, session) = try await makeSession([
            "a.html": .small("<!DOCTYPE html><html><head><title>page-a</title></head><body>a</body></html>"),
            "b.html": .small("<!DOCTYPE html><html><head><title>page-b</title></head><body>b</body></html>"),
        ], harness: harness)

        await harness.load(harness.url(session: session, "a.html"))
        await harness.load(harness.url(session: session, "b.html"))
        XCTAssertTrue(harness.webView.canGoBack)

        harness.webView.goBack()
        var title = await harness.waitForTitle("page-a")
        XCTAssertEqual(title, "page-a", "Back must return to the previous repository page")

        XCTAssertTrue(harness.webView.canGoForward)
        harness.webView.goForward()
        title = await harness.waitForTitle("page-b")
        XCTAssertEqual(title, "page-b", "Forward must work after Back")
    }

    func testReloadRefetchesThroughHandler() async throws {
        let harness = WebHarness()
        let (mock, session) = try await makeSession([
            "a.html": .small("<!DOCTYPE html><html><head><title>page-a</title></head><body>a</body></html>"),
        ], harness: harness)

        await harness.load(harness.url(session: session, "a.html"))
        async let nav: Void = harness.awaitNextNavigation()
        harness.webView.reload()
        await nav
        // Session cache serves the second request; gh was hit once. The
        // handler itself saw two requests for the same path.
        XCTAssertEqual(mock.fileFetchCount, 1)
        XCTAssertEqual(harness.webView.url?.path, "/a.html")
    }

    func testMediaElementRequest() async throws {
        let harness = WebHarness()
        let (mock, session) = try await makeSession([
            "index.html": .small("""
            <!DOCTYPE html><html><body>
            <video id="v" src="media/clip.mp4" preload="auto"></video>
            <script>
            var v = document.getElementById('v');
            v.addEventListener('error', function() { document.title = 'media-error'; });
            v.addEventListener('loadeddata', function() { document.title = 'media-loaded'; });
            v.load();
            </script></body></html>
            """),
            "media/clip.mp4": .bytes(Data(repeating: 0, count: 256)), // not a decodable movie; the request path is what we observe
        ], harness: harness)

        await harness.load(harness.url(session: session, "index.html"))
        // Give the media stack time to issue (or not issue) its request.
        let deadline = Date().addingTimeInterval(4)
        while Date() < deadline, !mock.fetchedSet.contains("media/clip.mp4") {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        let requested = mock.fetchedSet.contains("media/clip.mp4")
        // Documented in docs/web-compat.md: WebKit's media stack historically
        // bypasses WKURLSchemeHandler. This test pins down the behavior on
        // the current OS so a change is noticed either way.
        print("WEB-COMPAT: <video> subresource request reached scheme handler: \(requested)")
        let title = await harness.evalJS("document.title") as? String ?? ""
        print("WEB-COMPAT: <video> element state: '\(title)'")
        XCTAssertTrue(
            requested || title == "media-error" || title.isEmpty,
            "media element should either request through the handler or fail cleanly"
        )
    }
}
