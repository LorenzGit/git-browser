# GitBrowser

A macOS app that browses GitHub repositories **remotely, on demand**. It never
clones, checks out, archives, or mirrors a repository: every directory listing
and every file is fetched individually through your existing authenticated
GitHub CLI the moment it is needed. A repository with gigabytes of unrelated
assets opens just as fast as a tiny one when all you want is one HTML page.

## What it does

- Paste a GitHub URL (`https://github.com/owner/repo`, `owner/repo`,
  `…/tree/branch/path`, `…/blob/branch/file`, GitHub Enterprise hosts, or
  `git@host:owner/repo.git`) and browse the tree lazily — only the root
  listing is fetched on open, and each directory loads its children the first
  time you expand it.
- The selected branch/tag is resolved to one commit SHA up front; everything
  in the session (page + all subresources) comes from that same commit.
- Previews are routed by file type:
  - **HTML** renders in a WKWebView served by an internal
    `repobrowser://<session-id>/<path>` scheme (`WKURLSchemeHandler`) — no
    web server, no port, no localhost. Root-relative references like
    `/assets/logo.png` resolve to the repository root. WebKit requests each
    dependency (CSS, JS, images, fonts, ES modules, fetch/XHR targets)
    naturally, and only those files are downloaded.
  - **Markdown** renders locally with repo-relative links routed through the
    app.
  - **Source code** shows read-only with syntax highlighting.
  - **Images** decode straight from the fetched bytes; **PDFs** load via
    PDFKit from Data; **video/audio** play in AVKit from a single-asset
    temporary file (deleted when the preview closes and swept at startup).
- External `http(s)` links open in your default browser. `target="_blank"`,
  anchors, query strings, Back, Forward, and Reload all work.
- **Refresh** re-resolves the branch to its latest commit and clears all
  in-memory session data.
- **Go to File (⌘P)** — fuzzy-find any file from the repo's path listing
  (one metadata-only API call, fetched lazily; still no content downloads).
- **Search Code (⇧⌘F)** — GitHub's server-side code search scoped to the
  repo; results open directly (default branch only, an API limitation).
- **Branch/tag switcher** in the toolbar re-pins the session to any ref.
- **File history** (right-click → History…, or ⌘Y) — pick any commit that
  touched a file and view the file at that commit in a new tab.
- **Pull request preview** — paste a PR URL (`…/pull/123`): the session pins
  to the PR's head commit and the sidebar gains a changed-files list, so you
  can render a PR's HTML/docs output without checking anything out.
- README auto-opens on repo open (and on folder click when present), native
  tabs (⌘T, right-click → Open in New Tab), Find in page (⌘F), recent repos
  (File → Open Recent), Copy GitHub Link / Open on GitHub context actions,
  and syntax-highlighted code fences in Markdown.

## Install

Grab `GitBrowser-x.y.z-macos.zip` from the
[Releases page](https://github.com/LorenzGit/git-browser/releases), unzip,
and drag `GitBrowser.app` to Applications. The app is ad-hoc signed (not
notarized), so on first launch right-click the app → **Open** → **Open**.

Or build from source: `scripts/make-app.sh` produces `dist/GitBrowser.app`,
and `swift run GitBrowser` runs it directly during development.

## Requirements

- macOS 14+ (built against the macOS 26 SDK), Xcode toolchain
- [GitHub CLI](https://cli.github.com) installed and already signed in
  (`gh auth status`). The app never asks you to authenticate, never shows a
  token form, and never reads, prints, or stores your token — `gh` keeps
  authentication entirely to itself.
  - gh ≥ 2.96 uses the preview `gh repo read-dir` / `gh repo read-file`
    commands (feature-detected at runtime).
  - Older gh versions automatically fall back to `gh api` and GitHub's
    read-only repository APIs.

## Build, run, test

```sh
# If `xcode-select -p` points at CommandLineTools, prefix commands with:
#   DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

swift build
swift run GitBrowser                                    # empty window, paste a URL
swift run GitBrowser https://github.com/owner/repo      # open a repo at launch

swift test                                              # offline suite (55 tests)
GB_LIVE=1 swift test --filter LiveGHTests               # opt-in smoke tests against real GitHub
```

## Architecture

```
Sources/GitBrowserCore    # testable library
  GitHubRepoURL.swift       URL → host/owner/repo/ref/path
  GHCLIClient.swift         gh-backed client: feature detection + gh api fallback
  ProcessRunner.swift       Process with executable URL + argv (no shell, ever)
  RepoSession.swift         commit pinning, lazy dir cache, LRU byte cache, in-flight dedup
  RepoSchemeHandler.swift   repobrowser:// WKURLSchemeHandler (MIME, length, encoding, errors)
  MarkdownRenderer.swift    local markdown → HTML (raw HTML escaped)
  CodeHighlighter.swift     read-only highlighted code preview
  PreviewRouter.swift       extension → preview surface
  TempMediaFileManager.swift single-asset media temp files, crash-swept
Sources/GitBrowser        # AppKit app: window, lazy sidebar, preview container, web view
Tests/GitBrowserCoreTests # unit + scheme handler + WKWebView integration + efficiency tests
```

### Efficiency guarantee (tested)

`EfficiencyTests` builds a mock repository with one small HTML page, two
dependencies, **ten thousand** unrelated files, and several simulated
multi-gigabyte assets, then loads the page in a real WKWebView. The test
fails if anything beyond the page, the two dependencies WebKit actually
requested, and the root directory listing is retrieved — so cloning,
archiving, recursive enumeration, or any bulk materialization is a test
failure. Fetching a simulated multi-GB asset throws immediately.

### Security posture

- Repository JavaScript runs in WKWebView's content process with **no**
  script message handlers — there is no bridge to native code, `gh`,
  credentials, processes, or the local filesystem.
- Every requested path is percent-decoded, dot-segment-resolved, and
  validated to stay inside the virtual repository root (HTTP 400 otherwise).
- Session hosts are opaque random identifiers; in-memory only; nothing is
  persisted to disk (the web view uses a non-persistent data store, and the
  file cache is a bounded in-memory LRU).
- `gh` is invoked via `Process` with an explicit executable URL and argument
  array — no shell string concatenation anywhere.

### Known limitations

See [docs/web-compat.md](docs/web-compat.md) — most notably, `<video>` and
`<audio>` embedded in HTML pages cannot play because WebKit's media stack
bypasses custom scheme handlers; media files open in the dedicated AVKit
preview instead. Service workers and secure-origin-only APIs are out of
scope for the first release by design.

## License

[MIT](LICENSE)
