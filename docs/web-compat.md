# Web compatibility boundary

The first release targets static repository documentation and static HTML
artifacts, served through the internal `repobrowser://` scheme
(`WKURLSchemeHandler`). There is no HTTP server, no port, and no localhost
fallback. Findings below come from the integration tests in
`Tests/GitBrowserCoreTests/WebIntegrationTests.swift`, run on macOS 26.

## Verified working

| Capability | Test | Notes |
| --- | --- | --- |
| Inline CSS / JS | `testInlineAndExternalCSSAndJS` | |
| Repository-relative CSS / JS | `testInlineAndExternalCSSAndJS` | Correct `text/css` / `text/javascript` MIME types are required and served |
| Images and design canvases | `testImagesAndFonts`, `testWideImagesAreContainedByThePage`, `testWideCanvasFramesAreScaledToTheViewport` | Images are width-capped; fixed-width canvas-mode design frames are proportionally fitted to the preview |
| Fonts (`@font-face`) | `testImagesAndFonts` | Font file requests reach the scheme handler |
| ES modules (`<script type="module">`, nested `import`) | `testESModules` | `.mjs`/`.js` served as `text/javascript` |
| `fetch()` | `testFetchAPI` | Same-origin fetch to the session origin works; responses carry `Access-Control-Allow-Origin: *` |
| `XMLHttpRequest` | `testXMLHttpRequest` | |
| Relative HTML navigation | `testRelativeAndParentDirectoryNavigation` | |
| Parent-directory navigation (`../`) | `testRelativeAndParentDirectoryNavigation` | Dot segments resolve inside the repo root; escapes are rejected with HTTP 400 |
| Root-relative paths (`/assets/x`) | `testRootRelativePathResolvesToRepoRoot` | Resolve to the repository root of the same session |
| Anchors | `testQueryStringAndAnchorPreserved` | Same-document navigation allowed by the policy handler |
| Query strings | `testQueryStringAndAnchorPreserved` | Preserved in `location.search`; never change which file is fetched |
| Back / Forward | `testBackAndForward` | |
| Reload | `testReloadRefetchesThroughHandler` | Goes through the handler again; session cache prevents a duplicate `gh` call |
| `target="_blank"` | App-level (`WebPreviewController.createWebViewWith`) | Repo URLs load in the preview; external URLs open in the default browser |

## Limitations discovered

1. **`<video>` / `<audio>` elements do not work inside HTML pages.**
   `testMediaElementRequest` shows the media request never reaches
   `WKURLSchemeHandler`: WebKit's media stack loads media outside the custom
   scheme pipeline. This is a long-standing WebKit behavior, not a missing
   MIME type. Consequently a repository HTML page that embeds
   `<video src="clip.mp4">` will not play inline. Selecting a media file in
   the sidebar (or navigating to it) opens the dedicated media preview, which
   plays it with AVKit from a single-asset temporary file.

2. **No HTTP range responses.** Every response is a complete `200` body.
   This is invisible to static documentation but means no streaming
   semantics inside the web view.

3. **Service workers and secure-origin APIs are out of scope.** The
   `repobrowser://` origin is not a secure HTTP(S) origin, so service
   workers, and APIs gated on `isSecureContext`/https (camera, clipboard
   write, etc.), are unavailable. Per the product boundary, no localhost
   server fallback is added.

4. **Cross-session references.** Each open repository gets an opaque random
   host (`repo-xxxxxxxx`). Pages cannot enumerate or guess other sessions'
   hosts; fetch/XHR is same-origin in practice.

5. **Markdown preview escapes raw HTML.** Embedded `<script>`/`<iframe>` in
   `.md` files render as text. Formatting comes from the markdown subset
   documented in `MarkdownRenderer.swift` (headings, lists, tables, fenced
   code, blockquotes, emphasis, links, images, autolinks).

6. **URL parsing of branch names containing `/`.** In
   `…/tree/<ref>/<path>` URLs the first segment after `tree` is taken as the
   ref, so `feature/x` parses as ref `feature`. Resolution against the ref
   API would require network round-trips at parse time and is deferred.

7. **File size ceilings.** The `gh api` fallback uses the contents API,
   which serves raw blobs up to GitHub's documented limit (~100 MB). The
   in-memory cache only retains entries ≤ 8 MB (64 MB total, LRU); larger
   files are always re-fetched on demand and never cached.
