import Foundation
import UniformTypeIdentifiers

/// MIME type resolution for repository files served through the custom scheme.
public enum MIMEType {
    public struct Resolved: Equatable, Sendable {
        public var type: String
        /// IANA charset name for text types (used as URLResponse.textEncodingName).
        public var textEncoding: String?

        public var isText: Bool { textEncoding != nil }
    }

    /// Curated table. WebKit is strict about script/style MIME types, so the
    /// web-relevant entries must be exact.
    private static let table: [String: Resolved] = {
        var t: [String: Resolved] = [:]
        func text(_ ext: String, _ mime: String) { t[ext] = Resolved(type: mime, textEncoding: "utf-8") }
        func bin(_ ext: String, _ mime: String) { t[ext] = Resolved(type: mime, textEncoding: nil) }

        text("html", "text/html"); text("htm", "text/html"); text("xhtml", "application/xhtml+xml")
        text("css", "text/css")
        text("js", "text/javascript"); text("mjs", "text/javascript"); text("cjs", "text/javascript")
        text("json", "application/json"); text("map", "application/json")
        text("md", "text/markdown"); text("markdown", "text/markdown")
        text("txt", "text/plain"); text("text", "text/plain")
        text("xml", "text/xml"); text("svg", "image/svg+xml")
        text("csv", "text/csv"); text("yaml", "text/yaml"); text("yml", "text/yaml")
        text("webmanifest", "application/manifest+json")

        bin("wasm", "application/wasm")
        bin("png", "image/png"); bin("apng", "image/apng")
        bin("jpg", "image/jpeg"); bin("jpeg", "image/jpeg")
        bin("gif", "image/gif"); bin("webp", "image/webp"); bin("avif", "image/avif")
        bin("ico", "image/x-icon"); bin("bmp", "image/bmp")
        bin("tif", "image/tiff"); bin("tiff", "image/tiff"); bin("heic", "image/heic")
        bin("woff", "font/woff"); bin("woff2", "font/woff2")
        bin("ttf", "font/ttf"); bin("otf", "font/otf")
        bin("mp4", "video/mp4"); bin("m4v", "video/x-m4v"); bin("mov", "video/quicktime")
        bin("webm", "video/webm"); bin("mkv", "video/x-matroska")
        bin("mp3", "audio/mpeg"); bin("m4a", "audio/mp4"); bin("aac", "audio/aac")
        bin("wav", "audio/wav"); bin("flac", "audio/flac"); bin("ogg", "audio/ogg")
        bin("aiff", "audio/aiff"); bin("aif", "audio/aiff")
        bin("pdf", "application/pdf")
        bin("zip", "application/zip"); bin("gz", "application/gzip")
        return t
    }()

    /// Extensions of files that are source/config text but have no exact MIME
    /// entry: served as text/plain so browsers can display them.
    private static let plainTextExtensions: Set<String> = [
        "swift", "c", "h", "cpp", "cc", "cxx", "hpp", "hh", "m", "mm",
        "py", "rb", "go", "rs", "java", "kt", "kts", "scala", "cs",
        "ts", "tsx", "jsx", "php", "pl", "lua", "r", "sh", "bash", "zsh", "fish",
        "toml", "ini", "cfg", "conf", "properties", "env",
        "sql", "graphql", "proto", "cmake", "make", "mk", "gradle",
        "gitignore", "gitattributes", "editorconfig", "dockerfile", "lock",
        "log", "diff", "patch", "tex", "rst", "adoc", "org",
    ]

    public static func resolve(forPath path: String) -> Resolved {
        let ext = RepoPath.fileExtension(of: path)
        if let hit = table[ext] { return hit }
        if plainTextExtensions.contains(ext) {
            return Resolved(type: "text/plain", textEncoding: "utf-8")
        }
        if ext.isEmpty {
            // Extensionless files (LICENSE, Makefile, ...) are usually text.
            return Resolved(type: "text/plain", textEncoding: "utf-8")
        }
        if let ut = UTType(filenameExtension: ext), let mime = ut.preferredMIMEType {
            let isText = ut.conforms(to: .text) || mime.hasPrefix("text/")
            return Resolved(type: mime, textEncoding: isText ? "utf-8" : nil)
        }
        return Resolved(type: "application/octet-stream", textEncoding: nil)
    }
}
