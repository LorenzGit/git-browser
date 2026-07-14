import Foundation
import WebKit

/// WKURLSchemeHandler for the internal `repobrowser://` scheme.
///
/// URL shape: `repobrowser://<session-id>/<repo-root-relative-path>[?query][#fragment]`
/// The path maps 1:1 onto the repository root at the session's pinned commit,
/// so root-relative references like `/assets/logo.png` resolve inside the repo.
///
/// Each request is normalized, validated to stay inside the virtual root,
/// fetched individually through the GitHub CLI (deduplicated and cached by
/// the session), and answered with correct MIME type, content length, and
/// text encoding. No server, no port, no disk cache.
public final class RepoSchemeHandler: NSObject, WKURLSchemeHandler {
    public static let scheme = "repobrowser"

    private let registry: RepoSessionRegistry

    /// Tasks that have been stopped by WebKit; guarded by `lock`. Reporting on
    /// a stopped task raises an Objective-C exception, so every callback
    /// checks membership first.
    private var activeTasks = Set<ObjectIdentifier>()
    private let lock = NSLock()

    public init(registry: RepoSessionRegistry) {
        self.registry = registry
    }

    public func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        let taskID = ObjectIdentifier(urlSchemeTask)
        lock.lock()
        activeTasks.insert(taskID)
        lock.unlock()

        guard let url = urlSchemeTask.request.url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = components.host?.lowercased()
        else {
            finish(urlSchemeTask, error: URLError(.badURL))
            return
        }

        guard let session = registry.session(forHost: host) else {
            respondError(urlSchemeTask, url: url, status: 404,
                         message: "No open repository session for “\(host)”.")
            return
        }

        // Percent-decoded, dot-segment-resolved, root-contained path.
        guard var path = RepoPath.normalizeURLPath(components.percentEncodedPath) else {
            respondError(urlSchemeTask, url: url, status: 400,
                         message: "The requested path is outside the repository root.")
            return
        }
        // Directory-style URLs serve the directory's index.html.
        if path.isEmpty || components.path.hasSuffix("/") {
            path = path.isEmpty ? "index.html" : path + "/index.html"
        }

        // Reserved rendering parameter: `?gb-view=rendered` serves markdown and
        // source files as locally rendered HTML (Markdown preview / code
        // preview). Without it, the raw bytes are returned, so page
        // subresources and fetch() always see the real file.
        let wantsRendered = components.queryItems?
            .contains(where: { $0.name == "gb-view" && $0.value == "rendered" }) ?? false

        let fetchPath = path
        Task { [weak self] in
            guard let self else { return }
            do {
                let data = try await session.file(at: fetchPath)
                if wantsRendered, let rendered = Self.renderedPreview(path: fetchPath, data: data) {
                    self.respond(urlSchemeTask, url: url, status: 200,
                                 mime: .init(type: "text/html", textEncoding: "utf-8"),
                                 body: Data(rendered.utf8))
                    return
                }
                let mime = MIMEType.resolve(forPath: fetchPath)
                self.respond(urlSchemeTask, url: url, status: 200, mime: mime, body: data)
            } catch {
                let (status, message): (Int, String)
                if case GitHubClientError.notFound = error {
                    let commit = await session.commitSHA
                    status = 404
                    message = """
                    “\(fetchPath)” does not exist in \(session.coordinates.displayName) \
                    at commit \(String(commit.prefix(12))).
                    """
                } else {
                    status = 502
                    message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
                }
                self.respondError(urlSchemeTask, url: url, status: status, message: message)
            }
        }
    }

    public func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        lock.lock()
        activeTasks.remove(ObjectIdentifier(urlSchemeTask))
        lock.unlock()
    }

    /// Rendered representation for `?gb-view=rendered`, or nil to serve raw.
    static func renderedPreview(path: String, data: Data) -> String? {
        switch PreviewRouter.kind(forPath: path) {
        case .markdown:
            let text = String(data: data, encoding: .utf8) ?? "(binary content)"
            return MarkdownRenderer.renderDocument(
                markdown: text, title: RepoPath.fileName(of: path)
            )
        case .code:
            guard let text = String(data: data, encoding: .utf8) else {
                let message = "“\(RepoPath.fileName(of: path))” is not UTF-8 text (\(data.count) bytes)."
                return errorPage(status: 200, message: message,
                                 url: URL(string: "\(scheme)://unknown/\(path)") ?? URL(fileURLWithPath: "/"))
            }
            return CodeHighlighter.renderDocument(source: text, path: path)
        default:
            return nil
        }
    }

    // MARK: - Responding

    private func isActive(_ task: WKURLSchemeTask) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return activeTasks.contains(ObjectIdentifier(task))
    }

    private func deactivate(_ task: WKURLSchemeTask) {
        lock.lock()
        activeTasks.remove(ObjectIdentifier(task))
        lock.unlock()
    }

    private func respond(
        _ task: WKURLSchemeTask, url: URL, status: Int,
        mime: MIMEType.Resolved, body: Data, extraHeaders: [String: String] = [:]
    ) {
        var headers: [String: String] = [
            "Content-Type": mime.isText ? "\(mime.type); charset=utf-8" : mime.type,
            "Content-Length": String(body.count),
            "Cache-Control": "no-store",
            // Pages live on an opaque per-session origin; allow the page's own
            // fetch/XHR subresource loads to read responses.
            "Access-Control-Allow-Origin": "*",
        ]
        for (k, v) in extraHeaders { headers[k] = v }

        guard let response = HTTPURLResponse(
            url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers
        ) else {
            finish(task, error: URLError(.cannotParseResponse))
            return
        }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isActive(task) else { return }
            task.didReceive(response)
            task.didReceive(body)
            task.didFinish()
            self.deactivate(task)
        }
    }

    private func respondError(_ task: WKURLSchemeTask, url: URL, status: Int, message: String) {
        let html = Self.errorPage(status: status, message: message, url: url)
        respond(
            task, url: url, status: status,
            mime: .init(type: "text/html", textEncoding: "utf-8"),
            body: Data(html.utf8)
        )
    }

    private func finish(_ task: WKURLSchemeTask, error: Error) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isActive(task) else { return }
            task.didFailWithError(error)
            self.deactivate(task)
        }
    }

    static func errorPage(status: Int, message: String, url: URL) -> String {
        let title = status == 404 ? "File not found" : "Request failed (\(status))"
        return """
        <!DOCTYPE html>
        <html><head><meta charset="utf-8"><title>\(title)</title>
        <style>
        body { font-family: -apple-system, sans-serif; margin: 3em auto; max-width: 40em; color: #333; }
        @media (prefers-color-scheme: dark) { body { color: #ddd; background: #1e1e1e; } }
        code { word-break: break-all; }
        </style></head>
        <body><h1>\(title)</h1>
        <p>\(HTMLEscape.escape(message))</p>
        <p><code>\(HTMLEscape.escape(url.absoluteString))</code></p>
        </body></html>
        """
    }
}

public enum HTMLEscape {
    public static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
