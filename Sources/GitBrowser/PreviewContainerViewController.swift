import AppKit
import AVKit
import GitBrowserCore
import PDFKit
import WebKit

/// Hosts the active preview surface and switches between them:
/// web (HTML / rendered Markdown / code), image, PDF, and media.
final class PreviewContainerViewController: NSViewController {
    let web: WebPreviewController

    private let imagePreview = ImagePreviewController()
    private let pdfPreview = PDFPreviewController()
    private let mediaPreview = MediaPreviewController()
    private let placeholder = NSTextField(labelWithString: "Open a GitHub repository URL to begin.")

    private var current: NSViewController?
    private var currentPath: String?
    private var currentKind: PreviewKind?
    private var currentSession: RepoSession?
    /// Increases on each show() so a slow fetch can't clobber a newer preview.
    private var loadToken = 0

    init(schemeHandler: RepoSchemeHandler) {
        web = WebPreviewController(schemeHandler: schemeHandler)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 980, height: 760))
        placeholder.textColor = .secondaryLabelColor
        placeholder.alignment = .center
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(placeholder)
        NSLayoutConstraint.activate([
            placeholder.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }

    func showWelcome(repoName: String) {
        swapTo(nil)
        placeholder.stringValue = "\(repoName) is open — select a file in the sidebar."
        placeholder.isHidden = false
        currentPath = nil
        currentKind = nil
    }

    // MARK: - Showing previews

    func show(path: String, kind: PreviewKind, session: RepoSession) {
        currentPath = path
        currentKind = kind
        currentSession = session
        loadToken += 1
        let token = loadToken

        switch kind {
        case .html:
            guard let url = repoURL(session: session, path: path, rendered: false) else { return }
            swapTo(web)
            web.load(url: url)

        case .markdown, .code:
            guard let url = repoURL(session: session, path: path, rendered: true) else { return }
            swapTo(web)
            web.load(url: url)

        case .image:
            swapTo(imagePreview)
            imagePreview.beginLoading(name: RepoPath.fileName(of: path))
            Task { [weak self] in
                await self?.deliver(token: token, path: path, session: session) { data in
                    self?.imagePreview.show(data: data, name: RepoPath.fileName(of: path))
                }
            }

        case .pdf:
            swapTo(pdfPreview)
            Task { [weak self] in
                await self?.deliver(token: token, path: path, session: session) { data in
                    self?.pdfPreview.show(data: data)
                }
            }

        case .media:
            swapTo(mediaPreview)
            Task { [weak self] in
                await self?.deliver(token: token, path: path, session: session) { data in
                    self?.mediaPreview.show(data: data, fileExtension: RepoPath.fileExtension(of: path))
                }
            }
        }
    }

    /// Fetches one file through the session (dedup + cache) and hands the
    /// bytes to the preview if this request is still the active one.
    private func deliver(
        token: Int, path: String, session: RepoSession,
        to sink: @MainActor (Data) -> Void
    ) async {
        do {
            let data = try await session.file(at: path)
            await MainActor.run {
                guard token == self.loadToken else { return }
                sink(data)
            }
        } catch {
            await MainActor.run {
                guard token == self.loadToken else { return }
                self.placeholder.stringValue = "Could not load “\(path)”: \(error.localizedDescription)"
                self.swapTo(nil)
                self.placeholder.isHidden = false
            }
        }
    }

    private func repoURL(session: RepoSession, path: String, rendered: Bool) -> URL? {
        var components = URLComponents()
        components.scheme = RepoSchemeHandler.scheme
        components.host = session.id
        components.path = "/" + path
        if rendered {
            components.queryItems = [URLQueryItem(name: "gb-view", value: "rendered")]
        }
        return components.url
    }

    // MARK: - Toolbar passthrough

    func goBack() {
        if current === web { web.goBack() }
    }

    func goForward() {
        if current === web { web.goForward() }
    }

    func reload() {
        if current === web { web.reload() } else { reloadCurrent() }
    }

    /// After a repository refresh: reload whatever is on screen from the new commit.
    func reloadCurrent() {
        if current === web {
            web.reload()
        } else if let path = currentPath, let kind = currentKind, let session = currentSession {
            show(path: path, kind: kind, session: session)
        }
    }

    // MARK: - Swapping

    private func swapTo(_ controller: NSViewController?) {
        guard current !== controller else {
            placeholder.isHidden = controller != nil
            return
        }
        if let current {
            if current === mediaPreview { mediaPreview.closePreview() }
            current.view.removeFromSuperview()
            current.removeFromParent()
        }
        current = controller
        placeholder.isHidden = controller != nil
        guard let controller else { return }
        addChild(controller)
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(controller.view)
        // Pin below the unified toolbar: the split-view window uses a
        // full-size content view and WKWebView ignores safe areas, so
        // without this the page bleeds behind the title bar.
        NSLayoutConstraint.activate([
            controller.view.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            controller.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            controller.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
    }
}

// MARK: - Image preview

/// Decodes the fetched bytes directly into an NSImage.
final class ImagePreviewController: NSViewController {
    private let imageView = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let scrollView = NSScrollView()

    override func loadView() {
        imageView.imageScaling = .scaleProportionallyDown
        imageView.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(imageView)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        NSLayoutConstraint.activate([
            imageView.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            imageView.widthAnchor.constraint(lessThanOrEqualTo: container.widthAnchor, constant: -40),
            imageView.heightAnchor.constraint(lessThanOrEqualTo: container.heightAnchor, constant: -60),
            label.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
        ])
        view = container
    }

    func beginLoading(name: String) {
        imageView.image = nil
        label.stringValue = "Loading \(name)…"
    }

    func show(data: Data, name: String) {
        guard let image = NSImage(data: data) else {
            label.stringValue = "\(name): not a decodable image (\(data.count) bytes)."
            return
        }
        imageView.image = image
        let size = image.representations.first.map { "\($0.pixelsWide)×\($0.pixelsHigh)" } ?? ""
        label.stringValue = "\(name)  \(size)  \(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file))"
    }
}

// MARK: - PDF preview

/// PDFKit view initialized from the fetched Data.
final class PDFPreviewController: NSViewController {
    private let pdfView = PDFView()

    override func loadView() {
        pdfView.autoScales = true
        view = pdfView
    }

    func show(data: Data) {
        pdfView.document = PDFDocument(data: data)
    }
}

// MARK: - Media preview

/// AVKit playback. AVPlayer needs a seekable file, so the selected asset —
/// and only that asset — is written to a temporary file that is deleted when
/// the preview closes (and swept at startup after a crash).
final class MediaPreviewController: NSViewController {
    private let playerView = AVPlayerView()
    private var tempFileURL: URL?

    override func loadView() {
        playerView.controlsStyle = .floating
        playerView.showsFullScreenToggleButton = true
        view = playerView
    }

    func show(data: Data, fileExtension: String) {
        closePreview()
        do {
            let url = try TempMediaFileManager.shared.makeTempFile(data: data, fileExtension: fileExtension)
            tempFileURL = url
            playerView.player = AVPlayer(url: url)
        } catch {
            playerView.player = nil
        }
    }

    func closePreview() {
        playerView.player?.pause()
        playerView.player = nil
        if let url = tempFileURL {
            TempMediaFileManager.shared.remove(url)
            tempFileURL = nil
        }
    }

    deinit {
        if let url = tempFileURL {
            TempMediaFileManager.shared.remove(url)
        }
    }
}
