import Foundation

/// Which preview surface a repository file opens in. Top-level navigations in
/// the HTML preview are routed through this too, so clicking a link to a
/// markdown file opens the Markdown preview, an image opens the image
/// preview, and so on.
public enum PreviewKind: String, Sendable {
    case html
    case markdown
    case code
    case image
    case media
    case pdf
}

public enum PreviewRouter {
    private static let htmlExts: Set<String> = ["html", "htm", "xhtml"]
    private static let markdownExts: Set<String> = ["md", "markdown", "mdown", "mkd"]
    private static let imageExts: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "bmp", "tif", "tiff", "ico", "icns",
        "heic", "svg", "avif", "apng",
    ]
    private static let mediaExts: Set<String> = [
        "mp4", "m4v", "mov", "webm", "mkv",
        "mp3", "m4a", "aac", "wav", "flac", "ogg", "aiff", "aif", "caf",
    ]

    public static func kind(forPath path: String) -> PreviewKind {
        let ext = RepoPath.fileExtension(of: path)
        if htmlExts.contains(ext) { return .html }
        if markdownExts.contains(ext) { return .markdown }
        if imageExts.contains(ext) { return .image }
        if mediaExts.contains(ext) { return .media }
        if ext == "pdf" { return .pdf }
        return .code
    }
}
